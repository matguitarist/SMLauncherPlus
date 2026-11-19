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
                let zips = Self.files(in: DataFolder.downloads).filter { $0.hasSuffix("-macos-\(GameRelease.architecture).zip") }
                check("the latest build downloads, matches its checksum and is kept in Downloads/<version>/",
                      zips.count == 1, model.install?.failure ?? "\(Self.files(in: DataFolder.downloads))")
                // S-003: the profile
                let profiles = (try? model.context.fetch(FetchDescriptor<Profile>())) ?? []
                check("the install adds one profile named Super Metroid",
                      profiles.count == 1 && profiles.first?.name == String(localized: "Super Metroid"), "\(profiles.map(\.name))")
                if let profile = profiles.first {
                    check("the Play page opens on the new profile",
                          model.install == nil && model.sidebar == .play && model.currentProfile?.uuid == profile.uuid && !model.forceWelcome)
                    check("the game is unpacked into Profiles/<id>/game/",
                          FileManager.default.isExecutableFile(atPath: profile.executable.path))
                    let info = ProfileBuilder.Info.read(from: profile.folder)
                    check("profile.json records the version and the ROM",
                          info?.version == profile.gameVersion && info?.romSHA256 == SupportedROM.sha256)
                    check("the game has no quarantine flag", !ProfileBuilder.isQuarantined(profile.executable))
                    let help = Self.runHeadless(profile.executable, ["--help"])
                    check("the game runs right after unpacking (--help)", help.status == 0 && help.output.contains("usage:"),
                          "exit \(help.status): \(help.output.prefix(200))")
                }
                model.startInstall()
                await Self.waitForInstall(model)
                check("a verified download is reused",
                      model.log.entries.contains { $0.message.hasPrefix("Using the downloaded") })
                if model.rom != nil, ProcessInfo.processInfo.environment["SM_ROM_PATH"] != nil {
                    await Self.checkPlay(model)
                } else {
                    print("SKIP Play: needs SM_ROM_PATH")
                }
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

    /// S-004: Play starts the game straight to the title screen, then Stop records the time and removes the ROM copy.
    /// The game runs headless and dumps each frame's RAM; Super Metroid's game state ($0998) is 1 on the title screen.
    private static func checkPlay(_ model: AppModel) async {
        guard let profile = model.currentProfile else { return check("Play has a profile", false, "") }
        let frames = FileManager.default.temporaryDirectory.appending(path: "SMLauncherPlus-frames-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: frames) }
        // S-020: the game's own packages, and choices written the way the game writes them.
        let mods = ModsModel(game: profile.gameFolder)
        let stateFile = mods.root.appending(path: "state.toml")
        Self.check("the Mods page reads the game's packages", mods.packages.count >= 5, "\(mods.packages.map(\.id))")
        let features = mods.packages.flatMap(\.features)
        let introSkip = features.first { $0.key == "super-metroid.pacing/intro-skip" }
        let elevators = features.first { $0.key == "super-metroid.pacing/elevators" }
        if let introSkip, let elevators, let speed = elevators.options.first(where: { $0.id == "speed" }) {
            mods.setEnabled(true, introSkip) { _ in }
            mods.setEnabled(true, elevators) { _ in }
            mods.setValue("3x", of: speed, in: elevators) { _ in }
        }
        Self.check("Skippable intro and Faster elevators (3x) are saved",
                   introSkip != nil && ModState.read(from: mods.root).isEnabled(introSkip!) && mods.error == nil)
        let before = profile.playTime
        model.play(extraArguments: ["--framedump", frames.path], environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"])
        check("Play starts the game", model.isPlaying, model.playFailure?.message ?? "")
        guard let game = model.game else { return }
        let copies = Self.files(in: DataFolder.runROM).filter { $0.hasSuffix(".sfc") }
        let zipped = model.rom?.kindRaw == ROMCheck.Kind.zip.rawValue
        check("a zipped ROM is unpacked privately for the run, a plain one is passed in place",
              zipped ? copies.count == 1 : copies.isEmpty, "\(copies)")
        var title = false
        let deadline = Date.now.addingTimeInterval(30)
        while !title, game.isRunning, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            title = Self.reachedTitle(in: frames)
        }
        check("the game boots past its own launcher to the title screen", title,
              (try? String(contentsOf: game.log, encoding: .utf8).suffix(400)).map(String.init) ?? "")
        let arguments = (try? String(contentsOf: game.log, encoding: .utf8)) ?? ""
        check("the game read the profile's config.ini", arguments.contains("config parsed"))
        check("the game turns on the features chosen on the Mods page",
              arguments.contains("[mods] intro skip: 1/1") && arguments.contains("[mods] elevators 3x"),
              arguments.components(separatedBy: "\n").filter { $0.hasPrefix("[mods]") }.joined(separator: " | "))
        // The game rewrites state.toml when it starts: the launcher's reading and writing must give back the same text.
        let original = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        let rewritten = ModState.parse(original).text()
        let difference = zip(original.components(separatedBy: "\n"), rewritten.components(separatedBy: "\n"))
            .enumerated().first { $0.element.0 != $0.element.1 }
            .map { "line \($0.offset + 1): \($0.element.0) → \($0.element.1)" } ?? "\(original.count) vs \(rewritten.count) characters"
        check("the launcher writes state.toml exactly as the game does", !original.isEmpty && rewritten == original, difference)
        check("the game keeps the launcher's choices", original.contains("speed = \"3x\""))
        model.stopGame()
        let stopDeadline = Date.now.addingTimeInterval(10)
        while model.isPlaying, Date.now < stopDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        check("Stop ends the game and Play comes back", !model.isPlaying)
        check("play time and last played are saved", profile.playTime > before && profile.lastPlayedAt != nil,
              "\(profile.playTime)")
        check("the temporary ROM copy is deleted when the game quits",
              Self.files(in: DataFolder.runROM).isEmpty, "\(Self.files(in: DataFolder.runROM))")
    }

    /// True once a dumped frame shows game state 1 (title screen) at $0998.
    private static func reachedTitle(in frames: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasSuffix("_wram.bin") }.sorted()
        // Only the newest few; earlier ones are deleted to keep the dump small.
        for name in names.dropLast(3) { try? FileManager.default.removeItem(at: frames.appending(path: name)) }
        for name in names.suffix(3).reversed() {
            guard let data = try? Data(contentsOf: frames.appending(path: name)), data.count > 0x999 else { continue }
            if data[0x998] == 1, data[0x999] == 0 { return true }
        }
        return false
    }

    /// Runs the game with SDL's dummy video and audio, for at most 20 seconds.
    private static func runHeadless(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["SDL_VIDEODRIVER"] = "dummy"
        environment["SDL_AUDIODRIVER"] = "dummy"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let deadline = Date.now.addingTimeInterval(20)
        while process.isRunning, Date.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return (-2, "timed out") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
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
