import AppKit
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
                Button("Play") { model.sidebar = .play; model.play() }
                    .keyboardShortcut("r")
                    .disabled(model.isPlaying || model.install != nil || model.currentProfile == nil)
                Button("Stop") { model.sidebar = .play; model.confirmStop = true }
                    .keyboardShortcut(".")
                    .disabled(!model.isPlaying)
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
        if SelfTest.requested { exit(SelfTest.exitCode) }
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
    /// Why Play didn't start, shown under the button.
    var playFailure: GameRunner.StartError?
    var confirmStop = false
    /// S-005: the last run failed; the Play page shows a banner until the next Play.
    var lastGameFailure: GameFailure?
    var logSheet: LogSheetItem?
    var reportError: String?

    var install: InstallState?
    var installTask: Task<Void, Never>?

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

    /// Checks a .sfc, .smc or .zip and, when it's the supported ROM, keeps it (S-001).
    /// Only a bookmark to the file is saved; the ROM itself is never copied.
    func choose(_ url: URL) async {
        welcome = .checking(url.lastPathComponent)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ROMCheck.ROM, ROMCheck.Problem> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return Result { () throws(ROMCheck.Problem) in try ROMCheck.check(url) }
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

    /// Called once at launch.
    func load() {
        let profiles = (try? context.fetchCount(FetchDescriptor<Profile>())) ?? 0
        log.post(.info, "Opened the database (\(profiles) profiles)", source: "App")
        // A temporary ROM copy left by a crash or a forced quit.
        GameLaunch.removeLeftoverROMs(in: DataFolder.runROM)
    }
}

/// Where the data lives: ~/Library/Application Support/SMLauncherPlus/SMLauncherPlus.store.
/// With APP_STORE set (tests, snapshots, self-test), the database is that file instead,
/// which must be in /tmp, and the log sits next to it.
nonisolated enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, self-test).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            // Test runs never touch the real database.
            precondition(path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"), "APP_STORE must be in /tmp")
            return URL(fileURLWithPath: path)
        }
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
