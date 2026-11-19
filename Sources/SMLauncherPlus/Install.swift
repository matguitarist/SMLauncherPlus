import Foundation
import SMLauncherPlusKit

/// Where downloads, profiles, saves and caches live: ~/Library/Application Support/SMLauncherPlus,
/// or `<test store>-data` next to APP_STORE. Moving it is S-013 (port the rest of AM2R's DataFolder then).
nonisolated enum DataFolder {
    static var url: URL {
        let base = Store.isOverridden
            ? Store.url.deletingLastPathComponent().appending(path: Store.url.deletingPathExtension().lastPathComponent + "-data", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "SMLauncherPlus", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Downloaded game zips, one folder per version.
    static var downloads: URL { url.appending(path: "Downloads", directoryHint: .isDirectory) }
}

/// Progress of installing the game (S-002, then S-003 sets it up).
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
    /// Download and check are done. Setting up the game arrives with S-003.
    var downloaded = false

    func title(of step: Step) -> String {
        switch step {
        case .download:
            if let version { reused ? String(localized: "Using the downloaded \(version)") : String(localized: "Downloading SuperMetroidRecomp \(version)") }
            else { String(localized: "Finding the latest SuperMetroidRecomp") }
        case .check: String(localized: "Checking the download")
        case .setUp: String(localized: "Setting up the game")
        }
    }

    var title: String {
        if downloaded, let version { return String(localized: "SuperMetroidRecomp \(version) Is Downloaded") }
        return String(localized: "Installing Super Metroid")
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

extension AppModel {
    /// Reads the latest release, then downloads and checks it (S-002).
    func startInstall() {
        guard rom != nil, installTask == nil else { return }
        install = InstallState()
        log.post(.info, "Looking for the latest SuperMetroidRecomp", source: "Install")
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
                install?.step = .setUp
                install?.downloaded = true
                log.post(.info, "\(release.zipName) matches its checksum: \(zip.path)", source: "Install")
            } catch where error is CancellationError || Task.isCancelled {
                // A request stopped by Cancel fails like any other; the cancel is what happened.
                log.post(.info, "Install cancelled", source: "Install")
                install = nil
            } catch let failure as GameRelease.Failure {
                log.post(.error, "\(failure.message) (\(failure))", source: "Install")
                install?.failure = failure.message
            } catch {
                log.post(.error, "Install failed: \(error)", source: "Install")
                install?.failure = String(localized: "Unable to install: \(error.localizedDescription)")
            }
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
