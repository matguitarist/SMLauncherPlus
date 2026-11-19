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

/// An installed profile: name, version, last played, and Play (S-004).
struct ProfileSummary: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Space.xxl) {
            VStack(spacing: Space.sm) {
                Text(profile.name)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("SuperMetroidRecomp \(profile.gameVersion)")
                    .foregroundStyle(.secondary)
            }
            playControls
            VStack(spacing: Space.sm) {
                Text(PlayStats.summary(lastPlayed: profile.lastPlayedAt, playTime: profile.playTime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let failure = model.playFailure, !model.isPlaying {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    if failure.needsROM {
                        Button("Choose…") { model.forceWelcome = true; model.showChooser = true }
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([profile.gameFolder]) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Stop the game?", isPresented: $model.confirmStop) {
            Button("Stop", role: .destructive) { model.stopGame() }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("Unsaved progress since your last save station is lost.")
        }
        .onChange(of: model.playFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure.message).post() }
        }
    }

    @ViewBuilder var playControls: some View {
        if let startedAt = model.playStartedAt {
            VStack(spacing: Space.sm) {
                HStack(spacing: Space.md) {
                    Button("Playing…", systemImage: "gamecontroller.fill") {}
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                        .disabled(true)
                    Button("Stop") { model.confirmStop = true }
                        .controlSize(.extraLarge)
                        .help("Stop the game (⌘.)")
                }
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(PlayStats.clock(context.date.timeIntervalSince(startedAt)))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Playing for \(PlayStats.playTime(context.date.timeIntervalSince(startedAt)))"))
                }
            }
        } else {
            Button("Play", systemImage: "play.fill") { model.play() }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .help("Start Super Metroid (⌘R)")
        }
    }
}

/// "Last played 1 hour ago · 2 hr, 14 min in total". Ported from AM2R Launcher Plus.
enum PlayStats {
    static func summary(lastPlayed: Date?, playTime: Double) -> String {
        guard let lastPlayed else { return String(localized: "Never played") }
        let when = lastPlayed.formatted(.relative(presentation: .named).locale(.app))
        return String(localized: "Last played \(when) · \(Self.playTime(playTime)) in total")
    }

    /// "2 hr, 14 min", "less than a minute"
    static func playTime(_ seconds: Double) -> String {
        seconds < 60 ? String(localized: "less than a minute")
            : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(.app))
    }

    /// "0:12:34" for the running timer.
    static func clock(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
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
            profile.lastPlayedAt = Date.now.addingTimeInterval(-2 * 3600)
            profile.playTime = 8040
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
