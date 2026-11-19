import AppKit
import LogKitUI
import SMLauncherPlusKit
import SwiftData
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
            switch model.sidebar ?? .play {
            case .play: PlayPage()
            case .log: LogPage()
            }
        }
        .noInitialFocus()
        .task {
            model.load()
            SeedData.addIfRequested(model: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }
}

/// The sidebar. Snapshot mode walks through every case; rawValue names the PNG.
enum SidebarItem: String, CaseIterable, Identifiable {
    case play, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: String(localized: "Play")
        case .log: String(localized: "Log")
        }
    }

    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .log: "doc.text.magnifyingglass"
        }
    }
}

/// The Play page: the welcome page until a game is installed, the install progress while it installs.
struct PlayPage: View {
    @Environment(AppModel.self) private var model
    // Read so the page redraws when a profile is added.
    @Query private var profiles: [Profile]

    var body: some View {
        Group {
            if let install = model.install {
                InstallPage(state: install)
            } else if !model.forceWelcome, !profiles.isEmpty, let profile = model.currentProfile {
                ProfileSummary(profile: profile)
            } else {
                WelcomePage()
            }
        }
        .navigationTitle("Play")
    }
}

/// An installed profile. The Play button and the game's log arrive with S-004 and S-005.
struct ProfileSummary: View {
    let profile: Profile

    var body: some View {
        VStack(spacing: Space.xxl) {
            VStack(spacing: Space.sm) {
                Text(profile.name)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("SuperMetroidRecomp \(profile.gameVersion), installed \(profile.installedAt.formatted(date: .abbreviated, time: .omitted))")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Space.sm) {
                Button("Play") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(true)
                    .help("Playing comes in the next build.")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.gameFolder]) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Seed mode for snapshots: a chosen ROM (only its path; there is no file), and a few log lines.
enum SeedData {
    static func addIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1", Store.isOverridden else { return }
        if model.rom == nil {
            let url = URL(fileURLWithPath: "/Users/Shared/ROMs/Super Metroid (Japan, USA) (En,Ja).zip")
            model.context.insert(RomSource(rom: ROMCheck.ROM(url: url, kind: .zip, member: "Super Metroid (Japan, USA) (En,Ja).sfc",
                                                             headered: false, sha256: SupportedROM.sha256)))
            try? model.context.save()
        }
        if model.currentProfile == nil {
            let profile = Profile(name: "Super Metroid", gameVersion: "0.4.6")
            profile.installedAt = Date(timeIntervalSince1970: 1_795_100_000)
            model.context.insert(profile)
            try? model.context.save()
        }
        let log = model.log
        log.post(.info, "Checked the ROM: Super Metroid (Japan, USA)", source: "ROM")
        log.post(.info, "Found SuperMetroidRecomp v0.4.6", source: "Updates")
        log.post(.debug, "Downloading supermetroid-v0.4.6-macos-arm64.zip", source: "Updates")
        log.post(.info, "Installed v0.4.6 in the Default profile", source: "Install")
        log.post(.info, "Started the game", source: "Game")
        log.post(.warning, "The game took 4 seconds to open its window", source: "Game")
        log.post(.error, "The game quit with code 6", source: "Game")
    }
}
