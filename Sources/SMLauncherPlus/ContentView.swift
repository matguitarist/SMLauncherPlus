import AppKit
import AppTestKit
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
            Group {
                switch model.sidebar ?? .play {
                case .play: PlayPage()
                case .mods: ModsPage()
                case .profiles: ProfilesPage()
                case .log: LogPage()
                }
            }
            .id(model.dataFolderMoves)  // pages that hold a path into the data folder start over after a move (S-013)
        }
        .noInitialFocus()
        .modifier(ProfileDialogs())
        .task {
            model.load()
            SeedData.addIfRequested(model: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
            if !SelfTest.requested, ProcessInfo.processInfo.environment["APP_SNAPSHOT"] == nil {
                await model.checkForGameUpdate()
            }
        }
    }
}

/// The sidebar. Snapshot mode walks through every case; rawValue names the PNG.
enum SidebarItem: String, CaseIterable, Identifiable {
    case play, mods, profiles, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: String(localized: "Play")
        case .mods: String(localized: "Mods")
        case .profiles: String(localized: "Profiles")
        case .log: String(localized: "Log")
        }
    }

    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .mods: "puzzlepiece.extension"
        case .profiles: "square.stack"
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
                if let failure = model.lastGameFailure, failure.profile == profile.uuid, !model.isPlaying {
                    FailureBanner(failure: failure)
                }
                if let latest = model.availableUpdate(for: profile) {
                    UpdateBanner(latest: latest, profile: profile)
                }
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
        .sheet(item: $model.logSheet) { item in
            LogSheet(item: item)
        }
        .onChange(of: model.lastGameFailure) { _, failure in
            if failure != nil { AccessibilityNotification.Announcement(String(localized: "The game stopped unexpectedly")).post() }
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
            Button("Play", systemImage: "play.fill") { Task { await model.play() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .help("Start Super Metroid (⌘R)")
        }
    }
}

/// The game quit with an error: inline on the Play page, not an alert (S-005).
struct FailureBanner: View {
    @Environment(AppModel.self) private var model
    let failure: GameFailure

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("The game stopped unexpectedly")
                        .font(.headline)
                    Text(failure.newCrashFiles.isEmpty
                         ? String(localized: "It quit with code \(failure.status).")
                         : String(localized: "It quit with code \(failure.status) and left a crash report."))
                        .foregroundStyle(.secondary)
                    if let error = model.reportError {
                        Text(error).foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            HStack(spacing: Space.md) {
                Button("Show Log") { model.showGameLog() }
                    .help("Read what the game wrote before it stopped")
                Button("Report a Problem") { model.reportProblem() }
                    .help("Save the log, replay and crash files to a zip on your Desktop, without your ROM")
            }
            .padding(.leading, Space.xxl)
        }
        .padding(Space.lg)
        .frame(width: 480, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// "Last played 1 hour ago · 2 hr, 14 min in total". Ported from AM2R Launcher Plus.
enum PlayStats {
    static func summary(lastPlayed: Date?, playTime: Double) -> String {
        guard let lastPlayed else { return String(localized: "Never played") }
        let when = lastPlayed.formatted(.relative(presentation: .named).locale(.app))
        return String(localized: "Last played \(when) · \(Self.playTime(playTime)) in total")
    }

    /// "2 hours ago", or "Never" (the Profiles list).
    static func lastPlayed(_ date: Date?) -> String {
        date.map { $0.formatted(.relative(presentation: .named).locale(.app)) } ?? String(localized: "Never")
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
        guard TestRun.isSeeded() else { return }
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
        if model.profiles.count == 1 {
            let practice = Profile(name: "Practice", gameVersion: "0.4.5")
            practice.installedAt = Date(timeIntervalSince1970: 1_794_500_000)
            practice.lastPlayedAt = Date.now.addingTimeInterval(-5 * 86400)
            practice.playTime = 1260
            model.context.insert(practice)
            try? model.context.save()
        }
        if let profile = model.currentProfile {
            if profile.installedMods.isEmpty {
                profile.installedMods = ["seed.better-hud/1.2.0"]
                try? model.context.save()
            }
            seedMods(in: profile.gameFolder)
            seedShaders(in: profile.gameFolder)
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

    /// Two made-up releases newer than the seeded 0.4.6, for the update banner and What's New.
    static func latestUpdate() -> UpdateCheck.Latest {
        let release = GameRelease(version: "0.4.8", tag: "v0.4.8", zipName: "supermetroid-0.4.8-macos-arm64.zip",
                                  zipURL: URL(string: "https://github.com/mstan/SuperMetroidRecomp/releases/download/v0.4.8/supermetroid-0.4.8-macos-arm64.zip")!,
                                  size: 16_400_000, sha256: String(repeating: "0", count: 64))
        let page = URL(string: "https://github.com/mstan/SuperMetroidRecomp/releases/tag/v0.4.8")!
        return UpdateCheck.Latest(release: release, notes: [
            .init(version: "0.4.8", published: Date(timeIntervalSince1970: 1_795_600_000), body: """
            # Super Metroid 0.4.8

            The pause map remembers its zoom between visits, and the minimap no longer
            hides the energy tanks in widescreen.

            New optional mods:

            - **Quick morph:** press Down twice to morph without stopping.
            - **Item counter:** show collected items on the pause screen.
            """, page: page),
            .init(version: "0.4.7", published: Date(timeIntervalSince1970: 1_795_300_000), body: """
            Super Metroid v0.4.7 fixes a crash when a controller was unplugged during
            the Ceres escape, and keeps `config.ini` comments when settings are saved.
            """, page: nil),
            .init(version: "0.4.6", published: Date(timeIntervalSince1970: 1_795_100_000), body: "Already installed.", page: nil),
        ], checkedAt: .now)
    }

    /// A short made-up game log in the game's own style, for the log sheet snapshot.
    static func gameLog() -> URL {
        let folder = DataFolder.url.appending(path: "Logs/seed", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "2026-11-19T14-32-52.log")
        try? """
        [sm] session pid=8519; console=off
        [host +0.000s] host_report: Super Metroid 0.4.6
        [host +0.002s] config parsed: output=0 new_renderer=1 scale=3 fullscreen=0 audio=1
        [host +0.023s] rom resolved: Super Metroid.sfc
        [host +0.051s] SDL init ok: video=cocoa audio=coreaudio
        [mods] vanilla bug fixes: 13/13 on
        [mods] intro skip: 1/1 hooks
        [Gamepad] No joysticks detected.
        [host +0.083s] entering main loop
        [host +812.410s] error: audio device lost
        [host +812.412s] fatal: renderer failed to present frame

        """.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Empty presets named like the game's, for the Display tab's filter list, and the CRT one chosen.
    private static func seedShaders(in game: URL) {
        let folder = game.appending(path: ShaderPreset.folder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["scanlines-light", "scanlines", "scanlines-strong", "crt-light", "crt", "crt-strong",
                     "crt-soft", "sharp", "lcd-grid", "warm-composite"] {
            try? Data().write(to: folder.appending(path: "\(name).glslp"))
        }
        if !FileManager.default.fileExists(atPath: DisplaySettings.configFile(game: game).path) {
            var settings = DisplaySettings()
            settings.shader = "\(ShaderPreset.folder)/crt.glslp"
            try? settings.write(game: game)
        }
    }

    /// Two small made-up packages for the Mods page snapshots, with each kind of option.
    /// A made-up clock face for the S-022 picker (bytes only, not an image), checked like the game checks a file.
    private static var seedFace: URL { DataFolder.url.appending(path: "Seed/Clock Face.png") }
    private static var seedFaceHash: String {
        try? FileManager.default.createDirectory(at: seedFace.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: seedFace.path) { try? Data("seed clock face".utf8).write(to: seedFace) }
        return ModResource.normalizedSHA256(of: seedFace) ?? ""
    }

    private static func seedMods(in game: URL) {
        let root = ModCatalog.root(game: game)
        let packages: [(String, String)] = [
            ("seed.pacing", """
            format_version = 1
            id = "seed.pacing"
            version = "1.0.0"
            name = "Pacing"
            author = "Seed"
            [[target]]
            game_id = "supermetroid-jpn"
            [[feature]]
            id = "intro-skip"
            name = "Skippable intro"
            description = "Press Start during the story intro to go straight to the flight to Ceres."
            group = "Pacing"
            [[feature]]
            id = "elevators"
            name = "Faster elevators"
            description = "Elevators travel faster between areas."
            group = "Pacing"
            [[option]]
            feature = "elevators"
            id = "speed"
            label = "Speed"
            type = "choice"
            default = "2x"
            [[option.choice]]
            value = "2x"
            label = "2x"
            [[option.choice]]
            value = "3x"
            label = "3x"
            """),
            ("seed.better-hud", """
            format_version = 1
            id = "seed.better-hud"
            version = "1.2.0"
            name = "Better HUD"
            author = "Samus Fan Club"
            [[target]]
            game_id = "supermetroid-jpn"
            [[feature]]
            id = "clock"
            name = "Real-time clock"
            description = "Shows the time you've played this run in the corner of the HUD."
            group = "HUD"
            [[resource]]
            feature = "clock"
            id = "face"
            label = "Clock face (optional)"
            description = "Choose a PNG to draw the clock with."
            normalized_sha256 = "\(seedFaceHash)"
            file_patterns = "*.png"
            file_description = "a clock face PNG"
            required = false
            [[feature]]
            id = "font"
            name = "Your own HUD font"
            description = "Draws the HUD's numbers with a font image you made."
            group = "HUD"
            [[resource]]
            feature = "font"
            id = "font"
            label = "Font image"
            description = "A 128×128 PNG with the digits 0 to 9 in one row."
            file_patterns = "*.png"
            """),
            ("seed.combat", """
            format_version = 1
            id = "seed.combat"
            version = "1.0.0"
            name = "Combat"
            author = "Seed"
            [[target]]
            game_id = "supermetroid-jpn"
            [[feature]]
            id = "bomb-limit"
            name = "More bombs at once"
            description = "Lay more bombs before the first one explodes."
            group = "Combat"
            experimental = true
            [[option]]
            feature = "bomb-limit"
            id = "limit"
            label = "Bombs at once"
            type = "integer"
            default = 8
            min = 5
            max = 10
            step = 1
            [[option]]
            feature = "bomb-limit"
            id = "sound"
            label = "Play the original sound"
            type = "boolean"
            default = true
            [[feature]]
            id = "beam-select"
            name = "Beam combos with Select"
            description = "Cycle through beam combinations with the Select button."
            group = "Combat"
            """),
        ]
        for (id, text) in packages {
            let version = id == "seed.better-hud" ? "1.2.0" : "1.0.0"
            let folder = root.appending(path: "packages/\(id)/\(version)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: folder.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
        }
        try? """
        format_version = 1

        [[feature]]
        package_id = "seed.better-hud"
        id = "clock"
        enabled = true

        [[resource]]
        package_id = "seed.better-hud"
        feature_id = "clock"
        id = "face"
        path = "\(seedFace.path)"

        [[feature]]
        package_id = "seed.combat"
        id = "bomb-limit"
        enabled = true

        [[feature]]
        package_id = "seed.pacing"
        id = "elevators"
        enabled = true

        [feature.values]
        speed = "3x"

        """.write(to: root.appending(path: "state.toml"), atomically: true, encoding: .utf8)
    }
}
