import AppKit
import AppTestKit
import SMLauncherPlusKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus
/// writes <page>-light.png and <page>-dark.png for every sidebar page, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=play,log limits the pages. Add "settings" to include Settings, and
/// "install-progress", "install-error", "install-setup-error", "install-ready" for the install page (S-002, S-003),
/// "install-updating" (S-031), and
/// "play-running", "play-rom-missing" for the Play page (S-004), "play-failed", "log-sheet" (S-005), and
/// "welcome", "welcome-checking", "welcome-error" (yellow), "welcome-wrong" (red), "welcome-ready" for the welcome page's states (S-001).
/// Add APP_ACCENT=<id> to see the pages in another accent.
/// Add APP_SNAPSHOT_MIN=1 to shrink the main window to its smallest size first.
/// The capture, the light and dark looks, the refusal and the SNAPSHOT lines come from AppTestKit.
enum Snapshot {
    /// The sheet over the main window (the log, What's New, Saves).
    static func sheet() -> NSWindow? { NSApp.windows.first { $0.isSheet && $0.isVisible } }

    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        guard let run = SnapshotRun.requested(layout: { GridProbes.shared.write(to: $0.path, window: $1) }) else { return }
        Task {
            await run.start()
            await run.shootPages(SidebarItem.allCases.map(\.rawValue)) { model.sidebar = SidebarItem(rawValue: $0)! }
            // Welcome page states (S-001).
            let welcomeStates: [(String, WelcomeState)] = [
                ("welcome", .empty),
                ("welcome-checking", .checking("Super Metroid (Japan, USA) (En,Ja).zip")),
                ("welcome-error", .failed(.patched, "Super Metroid (Japan, USA) (En,Ja).sfc")),
                ("welcome-wrong", .failed(.otherGame("ZELDA"), "Zelda.sfc")),
                ("welcome-ready", .ready),
            ]
            let savedWelcome = model.welcome
            for (name, state) in welcomeStates {
                await run.shoot(name, settle: .seconds(0.8)) {
                    model.sidebar = .play
                    model.forceWelcome = true
                    model.welcome = state
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
            var updating = InstallState(updating: model.currentProfile?.uuid)
            updating.version = "0.4.8"
            updating.step = .setUp
            for (name, state) in [("install-progress", downloading), ("install-error", offline),
                                  ("install-setup-error", setUpFailed), ("install-ready", ready), ("install-updating", updating)] {
                await run.shoot(name, settle: .seconds(0.8)) {
                    model.sidebar = .play
                    model.install = state
                }
            }
            model.install = nil
            // S-005: the failure banner, then the log sheet over it.
            if let profile = model.currentProfile, run.wantsAny(["play-failed", "log-sheet"]) {
                let log = SeedData.gameLog()
                model.sidebar = .play
                model.lastGameFailure = GameFailure(profile: profile.uuid, log: log, status: 6, pid: 1, gameFolder: profile.gameFolder, newCrashFiles: [])
                await run.shoot("play-failed", settle: .seconds(0.8))
                if run.wants("log-sheet") {
                    model.showGameLog()
                    await run.forEachAppearance { look in
                        await run.pause(.seconds(1.2))
                        await run.capture("log-sheet", look, window: sheet())
                    }
                    model.logSheet = nil
                    await run.pause(.seconds(0.5))
                }
                model.lastGameFailure = nil
            }
            // S-030: the update banner on the Play page, then What's New over it.
            if run.wantsAny(["update-banner", "whats-new"]) {
                let saved = model.latestUpdate
                model.latestUpdate = SeedData.latestUpdate()
                model.sidebar = .play
                await run.shoot("update-banner", settle: .seconds(0.8))
                if run.wants("whats-new") {
                    model.showWhatsNew = true
                    await run.forEachAppearance { look in
                        await run.pause(.seconds(1.2))
                        await run.capture("whats-new", look, window: sheet())
                    }
                    model.showWhatsNew = false
                    await run.pause(.seconds(0.5))
                }
                model.latestUpdate = saved
            }
            // S-021: the Mods page after an install, and after a refused one.
            for (name, message) in [("mods-install", ModMessage.installed(name: "Better HUD", version: "1.2.0")),
                                    ("mods-install-error", ModMessage.failed(ModArchive.Failure.wrongGame(name: "Yoshi Tweaks", games: ["smw-usa"]).message))] {
                await run.shoot(name, settle: .seconds(0.8), show: {
                    model.sidebar = .mods
                    await run.pause(.seconds(0.5))
                    model.modMessage = message
                }, hide: { model.modMessage = nil })
            }
            // S-033: the Saves sheet with a backup and an automatic one before an update.
            if run.wants("saves"), let profile = model.currentProfile {
                let saves = SaveBackup.saves(game: profile.gameFolder)
                try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
                try? Data(repeating: 1, count: 8192).write(to: saves.appending(path: "save.srm"))
                let folder = DataFolder.backups(for: profile.uuid)
                if SaveBackup.list(in: folder).isEmpty {
                    let date = Date.now.addingTimeInterval(-86400)
                    _ = try? await SaveBackup.backup(saves: saves, into: folder, profileName: profile.name, label: String(localized: "before update to \("0.4.11")"), date: date)
                    _ = try? await SaveBackup.backup(saves: saves, into: folder, profileName: profile.name)
                }
                model.sidebar = .play
                model.backupsFor = profile
                model.backupMessage = String(localized: "Backed up as \(SaveBackup.list(in: folder).first?.name ?? "").")
                await run.forEachAppearance { look in
                    await run.pause(.seconds(1.2))
                    await run.capture("saves", look, window: sheet())
                }
                model.backupsFor = nil
                await run.pause(.seconds(0.5))
            }
            // S-032: the Profiles page after Delete, Keep Saves.
            await run.shoot("profiles-kept", settle: .seconds(0.8), show: {
                model.sidebar = .profiles
                model.profileMessage = .kept(name: "Practice", folder: DataFolder.keptSaves)
            }, hide: { model.profileMessage = nil })
            // Play states (S-004): the game isn't started, only what the page shows.
            await run.shoot("play-running", settle: .seconds(0.8), show: {
                model.sidebar = .play
                model.playStartedAt = Date.now.addingTimeInterval(-754)
            }, hide: { model.playStartedAt = nil })
            await run.shoot("play-rom-missing", settle: .seconds(0.8), show: {
                model.sidebar = .play
                model.playFailure = .rom(.missing)
            }, hide: { model.playFailure = nil })
            if run.wants("settings") {
                let main = WindowShot.mainWindow()
                await run.shootSettings(tabs: SettingsTab.allCases.map(\.rawValue), open: { openSettings() },
                                        select: { model.settingsTab = SettingsTab(rawValue: $0)! })
                let settings = { WindowShot.otherWindow(excluding: [main]) }
                // S-031: Updates with a newer release and a kept build for Roll Back.
                if let profile = model.currentProfile {
                    let saved = model.latestUpdate
                    let previous = ProfileUpdate.previousFolder(of: profile.folder)
                    try? FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
                    try? Data("0.4.5\n".utf8).write(to: previous.appending(path: "VERSION"))
                    model.latestUpdate = SeedData.latestUpdate()
                    model.settingsTab = .updates
                    await run.forEachAppearance { look in
                        await run.pause()
                        await run.capture("settings-updates-available", look, window: settings())
                    }
                    try? FileManager.default.removeItem(at: previous)
                    model.latestUpdate = saved
                }
                // S-014: Display while the RetroArch filters download.
                model.retroArchProgress = 0.4
                model.settingsTab = .display
                await run.forEachAppearance { look in
                    await run.pause()
                    await run.capture("settings-display-downloading", look, window: settings())
                }
                model.retroArchProgress = nil
            }
            run.finish()
        }
    }
}
