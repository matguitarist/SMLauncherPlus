import AppKit
import LogKit
import LogKitUI
import SwiftUI
import SMLauncherPlusKit

// SMLauncherPlus
//   SMLauncherPlus                      the app
//   APP_STORE=<file> SMLauncherPlus     use <file> (in /tmp) instead of the real library; nothing outside it changes
//   APP_SNAPSHOT=<dir> SMLauncherPlus   save a PNG of every sidebar page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 SMLauncherPlus           with APP_STORE: sample log lines for the snapshots (tools/snap.sh)
//   SMLauncherPlus --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> SMLauncherPlus      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 SMLauncherPlus           draw the 8 pt grid and the layout probes over the window

@main
struct SMLauncherPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("SM Launcher Plus", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
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

/// The app's state: the library, the sidebar, the Settings tab, and the log.
@Observable
final class AppModel {
    var sidebar: SidebarItem? = .overview
    var settingsTab: SettingsTab = .general
    var language = AppLanguage.current {
        didSet { language.apply() }
    }
    var checksForUpdates = Updater.shared.automaticallyChecks {
        didSet { Updater.shared.automaticallyChecks = checksForUpdates }
    }
    private(set) var library = Library()
    /// Why the library could not be read or saved, shown on the Overview page.
    var storeError: String?

    let log = Store.log
    /// Kept for the whole session, so filters survive leaving the Log page.
    let logViewer: LogViewerModel

    init() {
        logViewer = LogViewerModel(store: Store.log)
    }

    /// Reads the library file. Called once at launch.
    func load() {
        do {
            library = try Library.load(from: Store.url)
            try library.save(to: Store.url)
            storeError = nil
            log.post(.info, "Opened the library", source: "App")
        } catch {
            storeError = error.localizedDescription
            log.post(.error, "Could not open the library: \(error.localizedDescription)", source: "App")
        }
    }
}

/// Where the data lives: ~/Library/Application Support/SMLauncherPlus/library.json.
/// With APP_STORE set (tests, snapshots, self-test), it lives in that file instead,
/// which must be in /tmp, and the log sits next to it.
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, self-test).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "SMLauncherPlus", directoryHint: .isDirectory)
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            // Test runs never touch the real library.
            precondition(path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"), "APP_STORE must be in /tmp")
            return URL(fileURLWithPath: path)
        }
        return folder.appending(path: "library.json")
    }

    /// ~/Library/Logs/SMLauncherPlus/SMLauncherPlus.log, or next to APP_STORE.
    static var logURL: URL {
        isOverridden ? url.deletingPathExtension().appendingPathExtension("log") : LogStore.defaultFileURL(app: "SMLauncherPlus")
    }

    static let log = LogStore(fileURL: logURL)
}
