import LogKit
import LogKitUI
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.sidebar ?? .overview {
            case .overview: OverviewPage()
            case .log: LogPage()
            }
        }
        .task {
            model.load()
            SeedData.addIfRequested(log: model.log)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }
}

/// The sidebar. Snapshot mode walks through every case; rawValue names the PNG.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .log: String(localized: "Log")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gamecontroller"
        case .log: "doc.text.magnifyingglass"
        }
    }
}

/// What SM Launcher Plus will do, until the Play page arrives (S-001).
struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Super Metroid, Native on Your Mac", systemImage: "gamecontroller")
        } description: {
            if let error = model.storeError {
                Text("The library could not be opened: \(error)")
            } else {
                Text("SM Launcher Plus will install SuperMetroidRecomp from your own ROM, keep it up to date, and let you tune its settings and mods. Your ROM stays where it is.")
            }
        }
        .gridArea("overview")
        .navigationTitle("Overview")
    }
}

/// What the launcher did, line by line.
struct LogPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LogViewer(model: model.logViewer, options: LogViewerOptions(
            emptyTitle: String(localized: "No Activity Yet"),
            emptyMessage: String(localized: "What SM Launcher Plus does is written here: downloads, installs, and each time the game starts or stops.")
        ))
        .navigationTitle("Log")
    }
}

/// Seed mode for snapshots: a few log lines so the Log page has something to show.
enum SeedData {
    static func addIfRequested(log: LogStore) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1", Store.isOverridden else { return }
        log.post(.info, "Checked the ROM: Super Metroid (Japan, USA)", source: "ROM")
        log.post(.info, "Found SuperMetroidRecomp v0.4.6", source: "Updates")
        log.post(.debug, "Downloading supermetroid-v0.4.6-macos-arm64.zip", source: "Updates")
        log.post(.info, "Installed v0.4.6 in the Default profile", source: "Install")
        log.post(.info, "Started the game", source: "Game")
        log.post(.warning, "The game took 4 seconds to open its window", source: "Game")
        log.post(.error, "The game quit with code 6", source: "Game")
    }
}
