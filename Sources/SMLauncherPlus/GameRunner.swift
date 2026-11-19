import AppKit
import SMLauncherPlusKit
import SwiftData

/// Starts and watches the game for one profile (S-004). Ported from AM2R Launcher Plus's GameRunner,
/// without its Rosetta and helper-app paths: SuperMetroidRecomp is a plain arm64 executable.
@MainActor
final class GameRunner {
    let profileID: UUID
    let startedAt = Date.now
    /// The game's own output for this run, in `Logs/<profile>/`.
    let log: URL
    private let process: Process
    private let rom: GameLaunch.ROMFile
    private(set) var stoppedByUser = false
    /// The game's folder, and the crash files in it before this run (S-005).
    let gameFolder: URL
    let crashFilesBefore: Set<String>
    /// Replay files carry the process id in their names.
    private(set) var pid: Int32 = 0

    static func logFolder(for profile: Profile) -> URL {
        DataFolder.url.appending(path: "Logs/\(profile.uuid.uuidString)", directoryHint: .isDirectory)
    }

    /// The profile's config.ini, passed with --config.
    static func config(for profile: Profile) -> URL { profile.gameFolder.appending(path: "config.ini") }

    enum StartError: Error, Equatable {
        case gameMissing, rom(GameLaunch.ROMProblem), couldNotStart(String)

        /// The ROM is gone or changed: the page offers Choose….
        var needsROM: Bool { if case .rom(let problem) = self { problem != .unwritable } else { false } }

        var message: String {
            switch self {
            case .gameMissing: String(localized: "The game files of this profile are missing. Install the game again.")
            case .rom(.missing): String(localized: "Your ROM moved. Choose it again.")
            case .rom(.changed): String(localized: "Your ROM has changed since it was checked. Choose it again.")
            case .rom(.unwritable): String(localized: "Unable to prepare your ROM for the game. There may not be enough space on the disk.")
            case .couldNotStart(let reason): String(localized: "Unable to start the game: \(reason)")
            }
        }
    }

    /// Launches the game. `extraArguments` and `environment` let the self-test run it headless.
    init(profile: Profile, rom source: ROMCheck.ROM, extraArguments: [String] = [], environment extra: [String: String] = [:],
         onExit: @escaping @MainActor (Int32) -> Void) throws(StartError) {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: profile.executable.path) else { throw .gameMissing }
        do { rom = try GameLaunch.prepareROM(source, root: DataFolder.runROM) } catch { throw .rom(error) }

        let logs = Self.logFolder(for: profile)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        Self.pruneLogs(in: logs, keep: 4)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        log = logs.appending(path: "\(stamp).log")
        fm.createFile(atPath: log.path, contents: nil)
        profileID = profile.uuid
        gameFolder = profile.gameFolder
        crashFilesBefore = GameReport.crashFiles(in: profile.gameFolder)

        process = Process()
        process.executableURL = profile.executable
        // The game keeps saves, keybinds and replays beside itself.
        process.currentDirectoryURL = profile.gameFolder
        process.arguments = GameLaunch.arguments(rom: rom.url, config: Self.config(for: profile), extra: extraArguments)
        var environment = ProcessInfo.processInfo.environment
        environment.merge(extra) { _, new in new }
        process.environment = environment
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        let rom = rom
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // The temporary ROM copy goes the moment the game quits.
            rom.discard()
            Task { @MainActor in onExit(status) }
        }
        do { try process.run() } catch {
            rom.discard()
            throw .couldNotStart(error.localizedDescription)
        }
        pid = process.processIdentifier
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        stoppedByUser = true
        process.terminate()
    }

    /// Keeps the newest `keep` logs, so with the new one there are at most keep + 1.
    static func pruneLogs(in folder: URL, keep: Int) {
        let fm = FileManager.default
        let logs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}

extension RomSource {
    var rom: ROMCheck.ROM {
        ROMCheck.ROM(url: url, kind: ROMCheck.Kind(rawValue: kindRaw) ?? .file, member: member, headered: headered, sha256: sha256)
    }
}

extension AppModel {
    var isPlaying: Bool { playStartedAt != nil }

    /// Play (Return, ⌘R): starts the current profile with the player's ROM.
    func play(extraArguments: [String] = [], environment: [String: String] = [:]) {
        guard game == nil, install == nil, let profile = currentProfile else { return }
        playFailure = nil
        lastGameFailure = nil
        guard let source = rom else {
            playFailure = .rom(.missing)
            return
        }
        log.post(.info, "Starting \(profile.name) (\(profile.gameVersion)) from \(profile.gameFolder.path)", source: "Play")
        do {
            game = try GameRunner(profile: profile, rom: source.rom, extraArguments: extraArguments, environment: environment) { [weak self] status in
                self?.gameEnded(status: status)
            }
        } catch {
            log.post(.error, "\(error.message) (\(error))", source: "Play")
            playFailure = error
        }
    }

    func stopGame() {
        if game != nil { log.post(.info, "Stop", source: "Play") }
        game?.stop()
    }

    private func gameEnded(status: Int32) {
        guard let game else { return }
        let profiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        if let profile = profiles.first(where: { $0.uuid == game.profileID }) {
            profile.playTime += Date.now.timeIntervalSince(game.startedAt)
            profile.lastPlayedAt = .now
            try? context.save()
        }
        let crashFiles = GameReport.crashFiles(in: game.gameFolder)
        if GameReport.isFailure(status: status, stoppedByUser: game.stoppedByUser, crashFilesBefore: game.crashFilesBefore, after: crashFiles) {
            lastGameFailure = GameFailure(profile: game.profileID, log: game.log, status: status, pid: game.pid, gameFolder: game.gameFolder,
                                          newCrashFiles: crashFiles.subtracting(game.crashFilesBefore).sorted())
        }
        let seconds = Int(Date.now.timeIntervalSince(game.startedAt))
        log.post(status == 0 || game.stoppedByUser ? .info : .error,
                 "The game ended after \(seconds) s with status \(status)\(game.stoppedByUser ? " (stopped)" : ""). Log: \(game.log.path)",
                 source: "Play")
        self.game = nil
    }
}

/// A run that ended with an error code or a crash file (S-005).
struct GameFailure: Equatable {
    var profile: UUID
    var log: URL
    var status: Int32
    var pid: Int32
    var gameFolder: URL
    var newCrashFiles: [String]
}

/// The game log shown in a sheet.
struct LogSheetItem: Identifiable, Equatable {
    var log: URL
    var profileName: String
    var id: URL { log }
}

extension AppModel {
    /// Show Log on the failure banner: the failed run's log in a sheet.
    func showGameLog() {
        guard let failure = lastGameFailure else { return }
        let name = currentProfile?.name ?? String(localized: "Super Metroid")
        logSheet = LogSheetItem(log: failure.log, profileName: name)
    }

    /// Where Report a Problem saves its zip: the Desktop, or the test data folder.
    static var reportFolder: URL {
        Store.isOverridden ? DataFolder.url.appending(path: "Reports", directoryHint: .isDirectory) : URL.desktopDirectory
    }

    /// Report a Problem: the files the game's README asks for, zipped, then shown in Finder.
    @discardableResult
    func reportProblem(reveal: Bool = true) -> URL? {
        guard let failure = lastGameFailure else { return nil }
        let profile = currentProfile
        let files = GameReport.files(game: failure.gameFolder, sessionLog: failure.log, pid: failure.pid)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let about = """
        SM Launcher Plus \(version)
        SuperMetroidRecomp \(profile?.gameVersion ?? "?")
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(GameRelease.architecture)
        Exit code: \(failure.status)
        New crash files: \(failure.newCrashFiles.isEmpty ? "none" : failure.newCrashFiles.joined(separator: ", "))
        Date: \(Date.now.formatted(.iso8601))

        What happened, and roughly when:

        """
        let folder = Self.reportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let zip = try GameReport.makeZip(files: files, about: about, in: folder)
            log.post(.info, "Saved a problem report with \(files.count) files: \(zip.path)", source: "Report")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            reportError = nil
            return zip
        } catch {
            log.post(.error, "Report a Problem failed: \(error)", source: "Report")
            reportError = error == .nothingToReport
                ? String(localized: "The game left nothing to report.")
                : String(localized: "Unable to save the report. There may not be enough space on the disk.")
            return nil
        }
    }
}
