import AppKit
import LogKit
import SwiftData
import SMLauncherPlusKit

/// Self-test for agents: drives the app model on a /tmp store, prints PASS or
/// FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/SMLauncherPlus-self.store ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            let before = (try? model.context.fetchCount(FetchDescriptor<Profile>())) ?? -1
            check("the database opens empty", before == 0, "\(before) profiles")
            model.context.insert(Profile(name: "Self-test", gameVersion: "0.4.6"))
            try? model.context.save()
            check("a profile is saved and read back",
                  (try? model.context.fetch(FetchDescriptor<Profile>()))?.map(\.name) == ["Self-test"])
            check("the database file is in the test folder",
                  FileManager.default.fileExists(atPath: Store.url.path) && Store.url.path.hasPrefix("/tmp/"))
            try? model.context.delete(model: Profile.self)
            try? model.context.save()

            // S-001: choosing the ROM
            let folder = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-roms", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fake = folder.appending(path: "Super Metroid.sfc")
            try? Data(repeating: 0, count: SupportedROM.size).write(to: fake)
            check("the welcome page starts empty", model.welcome == .empty, "\(model.welcome)")
            await model.choose(fake)
            check("a file that isn't a ROM is refused with its reason", model.welcome == .failed(.notROM, fake.lastPathComponent), "\(model.welcome)")
            check("a refused file isn't kept", model.rom == nil)
            try? await Task.sleep(for: .milliseconds(300))  // the log hands lines to the viewer in batches
            check("the refusal is in the log", model.log.entries.contains { $0.source == "ROM" && $0.level == .warning })
            try? FileManager.default.removeItem(at: folder)
            if let real = ProcessInfo.processInfo.environment["SM_ROM_PATH"] {
                let before = Self.dataFiles()
                await model.choose(URL(fileURLWithPath: real))
                check("the player's ROM is accepted", model.welcome == .ready, "\(model.welcome)")
                check("the ROM is kept with its bookmark", model.rom?.bookmark != nil && model.rom?.url.path == real)
                check("the ROM is still chosen after a restart",
                      AppModel(container: model.container).welcome == .ready && AppModel(container: model.container).rom?.path == real)
                check("the ROM is never copied", Self.dataFiles() == before)
            } else {
                print("SKIP the player's ROM: set SM_ROM_PATH to check it")
            }

            // S-002: downloading the game. Offline first, on a pretend ROM, then the real download when asked.
            let hadROM = model.rom != nil
            if !hadROM {
                model.context.insert(RomSource(rom: ROMCheck.ROM(url: URL(fileURLWithPath: "/tmp/none.sfc"), kind: .file, member: "",
                                                                 headered: false, sha256: SupportedROM.sha256)))
            }
            AppModel.simulateOffline = true
            model.startInstall()
            await Self.waitForInstall(model)
            check("offline, the install says GitHub can't be reached",
                  model.install?.failure == GameRelease.Failure.offline.message && model.install?.step == .download)
            check("offline, nothing is left in Downloads", Self.files(in: DataFolder.downloads).isEmpty)
            model.cancelInstall()
            check("Cancel on a failed install goes back to the welcome page", model.install == nil)
            AppModel.simulateOffline = false
            if ProcessInfo.processInfo.environment["APP_SELFTEST_INSTALL"] == "1" {
                model.startInstall()
                model.cancelInstall()
                await Self.waitForInstall(model)
                check("Cancel stops the download and removes its partial file",
                      model.install == nil && !Self.files(in: DataFolder.downloads).contains { $0.hasSuffix(".partial") })
                model.startInstall()
                await Self.waitForInstall(model)
                check("the latest build downloads and matches its checksum", model.install?.downloaded == true, model.install?.failure ?? "")
                let zips = Self.files(in: DataFolder.downloads).filter { $0.hasSuffix("-macos-\(GameRelease.architecture).zip") }
                check("the zip is kept in Downloads/<version>/", zips.count == 1, "\(Self.files(in: DataFolder.downloads))")
                model.install = nil
                model.startInstall()
                await Self.waitForInstall(model)
                check("a verified download is reused", model.install?.reused == true && model.install?.downloaded == true)
                model.install = nil
            } else {
                print("SKIP the real download: set APP_SELFTEST_INSTALL=1 to download the game from GitHub")
            }
            if !hadROM {
                try? model.context.delete(model: RomSource.self)
                try? model.context.save()
            }

            model.log.post(.info, "Self-test line", source: "SelfTest")
            try? await Task.sleep(for: .milliseconds(300))
            check("the app writes a log line", model.log.entries.contains { $0.message == "Self-test line" })
            let file = (try? String(contentsOf: Store.logURL, encoding: .utf8)) ?? ""
            check("the log line reaches the log file", file.contains("Self-test line"))

            for item in SidebarItem.allCases {
                model.sidebar = item
                try? await Task.sleep(for: .milliseconds(200))
                check("the \(item.rawValue) page opens", model.sidebar == item)
            }
            for tab in SettingsTab.allCases {
                model.settingsTab = tab
                check("the \(tab.rawValue) Settings tab is selectable", model.settingsTab == tab)
            }

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// Waits until the install task finishes (up to two minutes, for a real download).
    private static func waitForInstall(_ model: AppModel) async {
        for _ in 0..<1200 where model.installTask != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Every file under a folder, as paths relative to it.
    private static func files(in folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { !$0.hasSuffix("/") }.sorted()
    }

    /// Every file next to the test database, to show the ROM wasn't copied there.
    private static func dataFiles() -> [String] {
        let folder = Store.url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("SMLauncherPlus") && !$0.hasSuffix(".log") && !$0.hasPrefix("SMLauncherPlus-shots") }.sorted()
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
