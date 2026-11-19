import AppKit
import IOKit.pwr_mgt
import SMLauncherPlusKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus
/// writes <page>-light.png and <page>-dark.png for every sidebar page, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=play,log limits the pages. Add "settings" to include Settings, and
/// "install-progress", "install-error", "install-setup-error", "install-ready" for the install page (S-002, S-003), and
/// "play-running", "play-rom-missing" for the Play page (S-004), "play-failed", "log-sheet" (S-005), and
/// "welcome", "welcome-checking", "welcome-error" (yellow), "welcome-wrong" (red), "welcome-ready" for the welcome page's states (S-001).
/// Add APP_ACCENT=<id> to see the pages in another accent.
/// Add APP_SNAPSHOT_MIN=1 to shrink the main window to its smallest size first.
enum Snapshot {
    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real database.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            if env["APP_SNAPSHOT_MIN"] != nil, let main = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) {
                // The window clamps to its content's minimum size.
                main.setContentSize(NSSize(width: 1, height: 1))
                try? await Task.sleep(for: .seconds(0.5))
            }
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in SidebarItem.allCases where only?.contains(page.rawValue) ?? true {
                    model.sidebar = page
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                }
            }
            // Welcome page states (S-001).
            let welcomeStates: [(String, WelcomeState)] = [
                ("welcome", .empty),
                ("welcome-checking", .checking("Super Metroid (Japan, USA) (En,Ja).zip")),
                ("welcome-error", .failed(.patched, "Super Metroid (Japan, USA) (En,Ja).sfc")),
                ("welcome-wrong", .failed(.otherGame("ZELDA"), "Zelda.sfc")),
                ("welcome-ready", .ready),
            ]
            let savedWelcome = model.welcome
            for (name, state) in welcomeStates where only?.contains(name) ?? true {
                model.sidebar = .play
                model.forceWelcome = true
                model.welcome = state
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(name)-\(mode).png")
                }
            }
            model.welcome = savedWelcome
            model.forceWelcome = false
            // Install states (S-002, S-003).
            var downloading = InstallState()
            downloading.version = "0.4.6"
            downloading.bytesDone = 7_340_032
            downloading.bytesTotal = 16_355_313
            var offline = InstallState()
            offline.failure = GameRelease.Failure.offline.message
            var setUpFailed = InstallState()
            setUpFailed.version = "0.4.6"
            setUpFailed.step = .setUp
            setUpFailed.failure = String(localized: "SM Launcher Plus couldn't set up the game. \(ProfileBuilder.Failure.copyFailed("").reason)")
            var ready = InstallState()
            ready.version = "0.4.6"
            ready.step = .setUp
            ready.finishedName = "Super Metroid"
            for (name, state) in [("install-progress", downloading), ("install-error", offline),
                                  ("install-setup-error", setUpFailed), ("install-ready", ready)]
            where only?.contains(name) ?? true {
                model.sidebar = .play
                model.install = state
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(name)-\(mode).png")
                }
            }
            model.install = nil
            // S-005: the failure banner, then the log sheet over it.
            if let profile = model.currentProfile, only == nil || only?.contains("play-failed") == true || only?.contains("log-sheet") == true {
                let log = SeedData.gameLog()
                model.sidebar = .play
                model.lastGameFailure = GameFailure(profile: profile.uuid, log: log, status: 6, pid: 1, gameFolder: profile.gameFolder, newCrashFiles: [])
                for mode in ["light", "dark"] where only?.contains("play-failed") ?? true {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/play-failed-\(mode).png")
                }
                if only?.contains("log-sheet") ?? true {
                    model.showGameLog()
                    for mode in ["light", "dark"] {
                        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                        try? await Task.sleep(for: .seconds(1.2))
                        capture(to: "\(dir)/log-sheet-\(mode).png", window: NSApp.windows.first { $0.isSheet && $0.isVisible })
                    }
                    model.logSheet = nil
                    try? await Task.sleep(for: .seconds(0.5))
                }
                model.lastGameFailure = nil
            }
            // S-021: the Mods page after an install, and after a refused one.
            for (name, message) in [("mods-install", ModMessage.installed(name: "Better HUD", version: "1.2.0")),
                                    ("mods-install-error", ModMessage.failed(ModArchive.Failure.wrongGame(name: "Yoshi Tweaks", games: ["smw-usa"]).message))]
            where only?.contains(name) ?? true {
                model.sidebar = .mods
                try? await Task.sleep(for: .seconds(0.5))
                model.modMessage = message
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(name)-\(mode).png")
                }
                model.modMessage = nil
            }
            // Play states (S-004): the game isn't started, only what the page shows.
            for name in ["play-running", "play-rom-missing"] where only?.contains(name) ?? true {
                model.sidebar = .play
                if name == "play-running" { model.playStartedAt = Date.now.addingTimeInterval(-754) }
                else { model.playFailure = .rom(.missing) }
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(name)-\(mode).png")
                }
                model.playStartedAt = nil
                model.playFailure = nil
            }
            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    private static func capture(to path: String, window: NSWindow? = nil) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}
