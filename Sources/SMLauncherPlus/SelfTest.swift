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
