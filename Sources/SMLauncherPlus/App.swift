import AppKit
import AppTestKit
import FileKit
import LogKit
import LogKitUI
import SwiftData
import SwiftUI
import SMLauncherPlusKit

// SMLauncherPlus
//   SMLauncherPlus                      the app
//   APP_STORE=<file> SMLauncherPlus     use the database <file> (in /tmp) instead of the real one; nothing outside it changes
//   APP_SNAPSHOT=<dir> SMLauncherPlus   save a PNG of every sidebar page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 SMLauncherPlus           with APP_STORE: sample log lines for the snapshots (tools/snap.sh)
//   SMLauncherPlus --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> SMLauncherPlus      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 SMLauncherPlus           draw the 8 pt grid and the layout probes over the window

@main
struct SMLauncherPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    var body: some Scene {
        Window("SM Launcher Plus", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 820, minHeight: 520)
                .modelContainer(model.container)
        }
        .defaultSize(width: 1000, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Choose ROM…") { model.sidebar = .play; model.forceWelcome = true; model.showChooser = true }
                    .keyboardShortcut("o")
                    .disabled(model.isCheckingROM)
            }
            CommandMenu("Game") {
                Button("Play") { model.sidebar = .play; Task { await model.play() } }
                    .keyboardShortcut("r")
                    .disabled(model.isPlaying || model.install != nil || model.currentProfile == nil)
                Button("Stop") { model.sidebar = .play; model.confirmStop = true }
                    .keyboardShortcut(".")
                    .disabled(!model.isPlaying)
                Divider()
                Button("Update SuperMetroidRecomp") {
                    model.sidebar = .play
                    model.startInstall(updating: model.currentProfile)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!model.canUpdate)
            }
            CommandMenu("Profile") {
                let profile = model.currentProfile
                let off = profile == nil || model.renameTarget != nil || model.deleteTarget != nil
                Button("Rename…") { model.renameTarget = profile }
                    .disabled(off)
                Button("Duplicate") { if let profile { model.startDuplicate(profile) } }
                    .keyboardShortcut("d")
                    .disabled(off || model.duplicating || profile.map(model.isBusy) == true)
                Button("Show in Finder") { if let profile { model.reveal(profile) } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(off)
                Divider()
                Button("Back Up Saves") { if let profile { model.startBackup(profile) } }
                    .keyboardShortcut("b")
                    .disabled(off || model.backingUp || model.backupsFor != nil)
                Button("Saves…") { model.backupsFor = profile }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(off || model.backupsFor != nil)
                Divider()
                Button("Delete…") { model.deleteTarget = profile }
                    .keyboardShortcut(.delete)
                    .disabled(off || profile.map(model.isBusy) == true)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About SM Launcher Plus") { AboutCredits.show(gameVersion: model.currentProfile?.gameVersion) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.isAvailable)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Log") { model.sidebar = .log }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("SuperMetroidRecomp on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/mstan/SuperMetroidRecomp")!)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        _ = Updater.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        SelfTest.exitIfRequested()
    }
}

/// The app's state: the database, the sidebar, the Settings tab, and the log.
@Observable
final class AppModel {
    var sidebar: SidebarItem? = .play
    var settingsTab: SettingsTab = .general
    var language = AppLanguage.current {
        didSet { language.apply() }
    }
    var checksForUpdates = Updater.shared.automaticallyChecks {
        didSet { Updater.shared.automaticallyChecks = checksForUpdates }
    }

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let log = Store.log
    /// Kept for the whole session, so filters survive leaving the Log page.
    let logViewer: LogViewerModel

    /// S-001: the welcome page's state and its open panel.
    var welcome = WelcomeState.empty
    var showChooser = false
    /// The profile shown on the Play page (S-003); nil picks the newest.
    var selection: UUID?
    /// The welcome page is open over an installed profile, to choose another ROM (⌘O).
    var forceWelcome = false

    /// Every profile, newest first.
    var profiles: [Profile] {
        (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.installedAt, order: .reverse)]))) ?? []
    }

    /// The selected profile, or the most recently installed one.
    var currentProfile: Profile? {
        let all = (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.installedAt, order: .reverse)]))) ?? []
        return all.first { $0.uuid == selection } ?? all.first
    }

    /// S-002: the install in progress, shown in place of the welcome page.
    /// S-004: the game while it runs.
    var game: GameRunner? { didSet { playStartedAt = game?.startedAt } }
    /// When the running game started; the Play page shows Playing… and the timer while it's set.
    var playStartedAt: Date?
    /// Play was pressed and the game is being prepared (its ROM or mod files read out of a .zip or .7z).
    var startingGame = false
    /// Why Play didn't start, shown under the button.
    var playFailure: GameRunner.StartError?
    var confirmStop = false
    /// S-005: the last run failed; the Play page shows a banner until the next Play.
    var lastGameFailure: GameFailure?
    var logSheet: LogSheetItem?
    var reportError: String?

    var install: InstallState?
    var installTask: Task<Void, Never>?

    /// S-013: the data folder move in progress (bytes copied of total), and why the last one failed.
    var dataMove: (done: Int64, total: Int64)?
    var dataMoveError: String?
    /// Counts finished moves, so pages that hold a path into the data folder are rebuilt.
    var dataFolderMoves = 0

    /// S-032: the profile being renamed or deleted (the dialogs ask), a duplicate in progress, and what the last action did.
    var renameTarget: Profile?
    var deleteTarget: Profile?
    var duplicating = false
    var profileMessage: ProfileMessage?
    /// S-033: the profile whose Saves sheet is open, a backup or restore in progress, and what it did.
    var backupsFor: Profile?
    var backingUp = false
    var backupMessage: String?
    var backupError: String?
    /// S-014: the RetroArch filters' download (0…1 while it runs), its error, and a count that reloads Display.
    var retroArchProgress: Double?
    var retroArchError: String?
    var retroArchChanges = 0

    /// S-021: what the last .snesmod install or removal did, shown at the top of the Mods page.
    var modMessage: ModMessage?

    /// S-030: the newest release when GitHub was last asked, kept between launches.
    var latestUpdate: UpdateCheck.Latest? = UpdateCheck.read(from: DataFolder.latestUpdate)
    var checkingForUpdates = false
    /// What Check Now in Settings found ("Super Metroid is up to date."), or why it couldn't check.
    var updateCheckMessage: String?
    /// The release notes sheet (What's New).
    var showWhatsNew = false

    var isCheckingROM: Bool {
        if case .checking = welcome { return true }
        return false
    }

    init(container: ModelContainer) {
        self.container = container
        logViewer = LogViewerModel(store: Store.log)
        if rom != nil { welcome = .ready }
    }

    /// The accepted ROM, kept where it is.
    var rom: RomSource? {
        (try? context.fetch(FetchDescriptor<RomSource>()))?.first
    }

    /// Checks a .sfc, .smc, .zip or .7z and, when it's the supported ROM, keeps it (S-001).
    /// Only a bookmark to the file is saved; the ROM itself is never copied.
    func choose(_ url: URL) async {
        welcome = .checking(url.lastPathComponent)
        let result = await Task.detached(priority: .userInitiated) { () async -> Result<ROMCheck.ROM, ROMCheck.Problem> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do throws(ROMCheck.Problem) { return .success(try await ROMCheck.check(url)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let found):
            log.post(.info, "ROM accepted: \(found.url.path)\(found.member.isEmpty ? "" : " (\(found.member))")\(found.headered ? ", with a copier header" : "")", source: "ROM")
            for old in (try? context.fetch(FetchDescriptor<RomSource>())) ?? [] { context.delete(old) }
            context.insert(RomSource(rom: found))
            try? context.save()
            welcome = .ready
        case .failure(let problem):
            log.post(.warning, "ROM refused: \(url.path): \(problem)", source: "ROM")
            welcome = .failed(problem, url.lastPathComponent)
        }
    }

    /// Moves the data folder into `parent` (S-013). Not while the game runs or an install is going.
    /// The database stays where it is; profiles, downloads and logs move.
    func moveDataFolder(into parent: URL) async {
        guard game == nil, install == nil, dataMove == nil else { return }
        dataMoveError = nil
        dataMove = (0, 0)
        let source = DataFolder.url
        let keeping = DataFolder.keeping(for: source)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, FolderMove.Failure> in
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            return Result { () throws(FolderMove.Failure) in
                try FolderMove.move(source, into: parent, keeping: keeping) { done, total in
                    Task { @MainActor in self.dataMove = (done, total) }
                }
            }
        }.value
        switch result {
        case .success(let moved):
            log.post(.info, "Moved the data folder from \(source.path) to \(moved.path)", source: "Data")
            DataFolder.setLocation(moved)
            dataFolderMoves += 1
        case .failure(let failure):
            log.post(.error, "Unable to move the data folder to \(parent.path): \(failure)", source: "Data")
            dataMoveError = failure.message
        }
        dataMove = nil
    }

    /// Called once at launch.
    func load() {
        let profiles = (try? context.fetchCount(FetchDescriptor<Profile>())) ?? 0
        log.post(.info, "Opened the database (\(profiles) profiles)", source: "App")
        // A temporary ROM copy left by a crash or a forced quit.
        GameLaunch.removeLeftoverROMs(in: DataFolder.runROM)
        ModFiles.restoreLeftovers(in: DataFolder.runROM)
        if DataFolder.isMissing { log.post(.warning, "The data folder's disk isn't connected: \(DataFolder.url.path)", source: "Data") }
        // Profiles from an earlier launcher, or a filter that changed in this one.
        for profile in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] { installFilters(in: profile.gameFolder) }
    }

    /// The launcher's filter presets (Sharp, CRT Soft, LCD Grid, Warm Composite) in a profile's
    /// assets/shaders, beside the game's own (S-010).
    func installFilters(in game: URL) {
        guard FileManager.default.fileExists(atPath: game.path),
              let source = Bundle.module.url(forResource: "Shaders", withExtension: nil) else { return }
        do {
            let written = try ShaderPreset.installBundled(from: source, game: game)
            if !written.isEmpty { log.post(.info, "Added filters to \(game.path): \(written.joined(separator: ", "))", source: "Display") }
            // S-014: the RetroArch filters, when the player downloaded them.
            let retroArch = try RetroArchFilter.install(from: DataFolder.retroArchFilters, game: game)
            if !retroArch.isEmpty { log.post(.info, "Added \(retroArch.count) RetroArch filter files to \(game.path)", source: "Display") }
        } catch {
            log.post(.error, "Unable to add the filters to \(game.path): \(error.localizedDescription)", source: "Display")
        }
    }
}

/// Where the data lives: ~/Library/Application Support/SMLauncherPlus/SMLauncherPlus.store.
/// With APP_STORE set (tests, snapshots, self-test), the database is that file instead,
/// which must be in /tmp (AppTestKit quits with 1 otherwise), and the log sits next to it.
nonisolated enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, self-test). The shared UI files read it.
    static var isOverridden: Bool { TestRun.isTestRun() }

    static var url: URL {
        // Test runs never touch the real database.
        if let test = TestRun.store() { return test }
        let dir = URL.applicationSupportDirectory.appending(path: "SMLauncherPlus", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "SMLauncherPlus.store")
    }

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Profile.self, RomSource.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }

    /// ~/Library/Logs/SMLauncherPlus/SMLauncherPlus.log, or next to APP_STORE.
    static var logURL: URL {
        isOverridden ? url.deletingPathExtension().appendingPathExtension("log") : LogStore.defaultFileURL(app: "SMLauncherPlus")
    }

    @MainActor static let log = LogStore(fileURL: logURL)
}
