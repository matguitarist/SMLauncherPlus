import FileKit
import Foundation
import SMLauncherPlusKit

/// Where downloads, profiles, saves and logs live: ~/Library/Application Support/SMLauncherPlus,
/// or `<test store>-data` next to APP_STORE. The player can move it (S-013); the database stays behind.
nonisolated enum DataFolder {
    static let defaultsKey = "dataFolder"
    /// Test and snapshot runs keep their moved location in memory, never in the real defaults.
    nonisolated(unsafe) static var testLocation: URL?

    static var defaultURL: URL {
        Store.isOverridden
            ? Store.url.deletingLastPathComponent().appending(path: Store.url.deletingPathExtension().lastPathComponent + "-data", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "SMLauncherPlus", directoryHint: .isDirectory)
    }

    /// The location the player chose, if any.
    private static var chosen: URL? {
        Store.isOverridden ? testLocation : UserDefaults.standard.string(forKey: defaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The chosen location, or the default.
    static var url: URL {
        let base = chosen ?? defaultURL
        // Never recreate a folder on a disk that's unplugged: that would make a fake /Volumes/<disk>.
        if chosen == nil || FileManager.default.fileExists(atPath: base.deletingLastPathComponent().path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: chosen == nil)
        }
        return base
    }

    /// Remembers a new location; the default location is stored as no choice.
    static func setLocation(_ url: URL) {
        let isDefault = url.standardizedFileURL.resolvingSymlinksInPath().path == defaultURL.standardizedFileURL.resolvingSymlinksInPath().path
        if Store.isOverridden {
            testLocation = isDefault ? nil : url
        } else if isDefault {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(url.path, forKey: defaultsKey)
        }
    }

    /// The data was moved to a disk that isn't connected now.
    static var isMissing: Bool {
        guard let chosen else { return false }
        return !FileManager.default.fileExists(atPath: chosen.deletingLastPathComponent().path)
    }

    /// What stays behind when the data folder moves: the database, when it sits in the folder (the default).
    static func keeping(for folder: URL) -> Set<String> {
        FolderMove.databaseFiles(store: Store.url, in: folder)
    }

    /// Profiles, downloads and logs, without the database.
    static func size() -> Int64 {
        let folder = url
        return FolderMove.size(of: folder, excluding: keeping(for: folder))
    }

    /// The last answer from GitHub about the newest release (S-030).
    static var latestUpdate: URL { url.appending(path: "Caches/latest-update.json") }

    /// Downloaded game zips, one folder per version.
    static var downloads: URL { url.appending(path: "Downloads", directoryHint: .isDirectory) }

    /// One folder per profile: `<id>/game/` and `<id>/profile.json`.
    static var profiles: URL { url.appending(path: "Profiles", directoryHint: .isDirectory) }

    /// Where a zipped or headered ROM is unpacked for one run (S-004), private to this user (mode 700).
    /// In ~/Library/Caches, never next to the profiles or the player's ROM; emptied at launch.
    static var runROM: URL {
        let folder = Store.isOverridden
            ? url.appending(path: "RunROM", directoryHint: .isDirectory)
            : URL.cachesDirectory.appending(path: "SMLauncherPlus/RunROM", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
}

/// Progress of installing the game: download and check (S-002), then set up a profile (S-003).
struct InstallState: Equatable {
    enum Step: Int, CaseIterable, Comparable {
        case download, check, setUp

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var step: Step = .download
    /// "0.4.6" once the latest release is known.
    var version: String?
    var bytesDone = 0
    var bytesTotal = 0
    /// The zip was already downloaded and verified.
    var reused = false
    var failure: String?
    /// Set when the profile is ready; the page shows it for a moment, then Play.
    var finishedName: String?
    /// S-031: the profile being updated, instead of a new one.
    var updating: UUID?

    func title(of step: Step) -> String {
        switch step {
        case .download:
            if let version { reused ? String(localized: "Using the downloaded \(version)") : String(localized: "Downloading SuperMetroidRecomp \(version)") }
            else { String(localized: "Finding the latest SuperMetroidRecomp") }
        case .check: String(localized: "Checking the download")
        case .setUp: updating == nil ? String(localized: "Setting up the game")
                                     : String(localized: "Moving your saves, settings and mods over")
        }
    }

    var title: String {
        if let finishedName {
            return updating == nil ? String(localized: "\(finishedName) Is Ready") : String(localized: "\(finishedName) Is Up to Date")
        }
        return updating == nil ? String(localized: "Installing Super Metroid") : String(localized: "Updating Super Metroid")
    }
}

extension GameRelease.Failure {
    /// What the install page says under the step that failed.
    var message: String {
        switch self {
        case .offline: String(localized: "Unable to reach GitHub. Check your connection, then try again.")
        case .github(let status) where status == 403 || status == 429:
            String(localized: "GitHub is limiting downloads right now. Try again in a few minutes.")
        case .github(let status): String(localized: "GitHub answered with an error (\(status)). Try again later.")
        case .badResponse: String(localized: "GitHub sent an unexpected answer. Try again later.")
        case .noMacBuild: String(localized: "The latest release has no build for this Mac yet. Try again later.")
        case .noChecksum: String(localized: "The latest release can't be checked: it has no checksum for the Mac build. Try again later.")
        case .damaged: String(localized: "The download is damaged. Try again.")
        }
    }
}

extension ProfileBuilder.Failure {
    /// Why setting up failed, after "SM Launcher Plus couldn't set up the game."
    var reason: String {
        switch self {
        case .unreadableZip: String(localized: "The downloaded zip can't be opened.")
        case .unsafePath(let path): String(localized: "The download holds a file that would land outside the game folder (\(path)).")
        case .missingExecutable: String(localized: "The download has no SuperMetroidSNESRecomp in it.")
        case .copyFailed: String(localized: "The files couldn't be put in place. There may not be enough space on the disk.")
        }
    }
}

extension AppModel {
    /// Reads the latest release, downloads and checks it (S-002), then sets it up as a new profile (S-003),
    /// or installs it into `updating` keeping its saves, settings and mods (S-031).
    func startInstall(updating target: Profile? = nil) {
        guard installTask == nil, !isPlaying else { return }
        guard let romSHA256 = rom?.sha256 ?? target.flatMap({ ProfileBuilder.Info.read(from: $0.folder)?.romSHA256 }) else { return }
        install = InstallState(updating: target?.uuid)
        log.post(.info, target.map { "Updating \($0.name) from \($0.gameVersion)" } ?? "Looking for the latest SuperMetroidRecomp", source: "Install")
        let session = Self.installSession
        installTask = Task {
            defer { installTask = nil }
            do {
                let release = try await GameRelease.latest(session: session)
                let downloads = DataFolder.downloads
                let reused = release.isDownloaded(in: downloads)
                install?.version = release.version
                install?.reused = reused
                install?.bytesTotal = release.size
                log.post(.info, reused ? "Using the downloaded \(release.zipName)" : "Downloading \(release.zipName) (\(release.size.formatted(.byteCount(style: .file))))", source: "Install")
                let zip = try await release.download(into: downloads, session: session, progress: { done, total in
                    Task { @MainActor in self.install?.bytesDone = done; self.install?.bytesTotal = total }
                }, checking: {
                    Task { @MainActor in self.install?.step = .check }
                })
                try Task.checkCancellation()
                log.post(.info, "\(release.zipName) matches its checksum: \(zip.path)", source: "Install")
                install?.step = .setUp
                if let target {
                    try await update(target, to: release, from: zip, romSHA256: romSHA256)
                    return
                }
                let uuid = UUID()
                let folder = DataFolder.profiles.appending(path: uuid.uuidString, directoryHint: .isDirectory)
                let info = ProfileBuilder.Info(version: release.version, romSHA256: romSHA256)
                let game = try await Task.detached(priority: .userInitiated) {
                    try await ProfileBuilder.build(zip: zip, profile: folder, info: info)
                }.value
                try Task.checkCancellation()
                installFilters(in: game)
                let profile = Profile(name: String(localized: "Super Metroid"), gameVersion: release.version)
                profile.uuid = uuid
                profile.installedAt = info.installedAt
                context.insert(profile)
                try? context.save()
                log.post(.info, "\(profile.name) \(release.version) is ready in \(game.path)", source: "Install")
                selection = uuid
                forceWelcome = false
                install?.finishedName = profile.name
                try? await Task.sleep(for: .seconds(1))
                install = nil
                sidebar = .play
            } catch where error is CancellationError || Task.isCancelled {
                // A request stopped by Cancel fails like any other; the cancel is what happened.
                log.post(.info, "Install cancelled", source: "Install")
                install = nil
            } catch let failure as GameRelease.Failure {
                log.post(.error, "\(failure.message) (\(failure))", source: "Install")
                install?.failure = failure.message
            } catch let failure as UpdateFailure {
                log.post(.error, "Update stopped: \(failure)", source: "Install")
                install?.failure = failure.message
            } catch let failure as ProfileBuilder.Failure {
                log.post(.error, "Setting up failed: \(failure)", source: "Install")
                install?.failure = String(localized: "SM Launcher Plus couldn't set up the game. \(failure.reason)")
            } catch {
                log.post(.error, "Install failed: \(error)", source: "Install")
                install?.failure = String(localized: "Unable to install: \(error.localizedDescription)")
            }
        }
    }

    /// S-031: installs a verified zip into `profile`, keeping its saves, settings, mod choices, packages
    /// and logs; the old build stays in previous/ for Roll Back.
    private func update(_ profile: Profile, to release: GameRelease, from zip: URL, romSHA256: String) async throws {
        guard !isPlaying else { throw CancellationError() }
        // S-033: a backup of the saves first; no backup, no update.
        if ProfileFiles.hasSaves(game: profile.gameFolder),
           await backUpSaves(profile, label: String(localized: "before update to \(release.version)")) == nil {
            throw UpdateFailure.backup(backupError ?? "")
        }
        let folder = profile.folder
        let old = profile.gameVersion
        let keeping = Set(profile.installedMods.compactMap { $0.split(separator: "/").first.map(String.init) })
        let info = ProfileBuilder.Info(version: release.version, romSHA256: romSHA256)
        _ = try await Task.detached(priority: .userInitiated) {
            try await ProfileUpdate.update(zip: zip, profile: folder, info: info, keepingPackages: keeping)
        }.value
        installFilters(in: profile.gameFolder)
        profile.gameVersion = release.version
        try? context.save()
        updateCheckMessage = nil
        log.post(.info, "Updated \(profile.name) from \(old) to \(release.version); \(old) is kept for Roll Back", source: "Install")
        selection = profile.uuid
        install?.finishedName = profile.name
        try? await Task.sleep(for: .seconds(1))
        install = nil
        sidebar = .play
    }

    /// The version Roll Back would bring back, when the last update kept one.
    func previousVersion(of profile: Profile) -> String? {
        guard FileManager.default.fileExists(atPath: ProfileUpdate.previousFolder(of: profile.folder).path) else { return nil }
        return ProfileBuilder.Info.read(from: profile.folder)?.previousVersion ?? ProfileUpdate.version(of: ProfileUpdate.previousFolder(of: profile.folder))
    }

    /// S-031: brings back the build from before the last update, with the saves made since.
    func rollBack(_ profile: Profile) async {
        guard !isPlaying, install == nil else { return }
        let folder = profile.folder
        let newer = profile.gameVersion
        let keeping = Set(profile.installedMods.compactMap { $0.split(separator: "/").first.map(String.init) })
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ProfileBuilder.Info?, ProfileBuilder.Failure> in
            Result { () throws(ProfileBuilder.Failure) in try ProfileUpdate.rollBack(profile: folder, keepingPackages: keeping) }
        }.value
        switch result {
        case .success(let info?):
            profile.gameVersion = info.version
            try? context.save()
            installFilters(in: profile.gameFolder)
            updateCheckMessage = String(localized: "\(profile.name) is back on \(info.version), with your saves.")
            log.post(.info, "Rolled \(profile.name) back from \(newer) to \(info.version)", source: "Install")
        case .success(nil):
            updateCheckMessage = String(localized: "There is no earlier version to go back to.")
        case .failure(let failure):
            log.post(.error, "Roll Back failed: \(failure)", source: "Install")
            updateCheckMessage = String(localized: "Unable to go back to the earlier version. \(failure.reason)")
        }
    }

    /// Stops the install and removes its partial files (the download does that itself), or closes a failed one.
    func cancelInstall() {
        if let installTask {
            installTask.cancel()
        } else {
            install = nil
        }
    }

    /// True makes every request fail like no connection: the self-test sets it, or APP_GITHUB=offline.
    /// Only on a test store.
    static var simulateOffline = ProcessInfo.processInfo.environment["APP_GITHUB"] == "offline"

    static var installSession: URLSession {
        guard Store.isOverridden, simulateOffline else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Why an update stopped before touching the profile (S-033).
enum UpdateFailure: Error {
    case backup(String)

    var message: String {
        switch self {
        case .backup(let reason): String(localized: "The saves couldn't be backed up, so nothing was updated. \(reason)")
        }
    }
}

/// Fails every request with "not connected", like a Mac with no network.
nonisolated final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

extension Locale {
    /// The language the app's text is in, so numbers match the words around them.
    static var app: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }
}
