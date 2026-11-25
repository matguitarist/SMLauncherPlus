import DownloadKit
import Foundation

/// SuperMetroidRecomp's macOS build from its latest GitHub release (S-002).
/// The lookup and the download go through DownloadKit; what stays here is which asset is this Mac's,
/// where it goes, and a typed Failure the app turns into sentences.
public struct GameRelease: Equatable, Sendable, Codable {
    public static let owner = "mstan"
    public static let repo = "SuperMetroidRecomp"

    /// "0.4.6", from the tag "v0.4.6".
    public var version: String
    public var tag: String
    public var zipName: String
    public var zipURL: URL
    public var size: Int
    /// The zip's line in the release's SHA256SUMS.
    public var sha256: String
    public var published: Date?

    public init(version: String, tag: String, zipName: String, zipURL: URL, size: Int, sha256: String, published: Date? = nil) {
        self.version = version
        self.tag = tag
        self.zipName = zipName
        self.zipURL = zipURL
        self.size = size
        self.sha256 = sha256
        self.published = published
    }

    /// Why the release couldn't be read or downloaded. The app turns each into a sentence.
    public enum Failure: Error, Equatable, Sendable {
        case offline
        case github(Int)
        case badResponse
        /// The release has no zip for this Mac's processor.
        case noMacBuild
        /// No line for the zip in SHA256SUMS, so it can't be checked.
        case noChecksum
        /// The zip doesn't match its checksum; it was deleted.
        case damaged
    }

    /// "arm64" on Apple silicon, "x64" on Intel.
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    // MARK: Latest release

    /// Every request names the launcher, as before. Lookups aren't retried, so offline is told at once.
    static func options(_ session: URLSession, retry: RetryPolicy = .none) -> DownloadOptions {
        DownloadOptions(session: session, userAgent: "SMLauncherPlus", retry: retry)
    }

    /// Reads the latest release and its checksum (GitHub's digest of the zip, else its line in SHA256SUMS).
    public static func latest(architecture: String = architecture, session: URLSession = .shared) async throws(Failure) -> GameRelease {
        let options = options(session)
        let response: GitHubRelease
        do { response = try await GitHubRelease.latest(owner: owner, repo: repo, token: nil, options: options) } catch { throw Failure(error) }
        let (release, asset) = try pick(response, architecture: architecture)
        let hash: String?
        do { hash = try await response.checksum(for: asset, options: options) } catch { throw Failure(error) }
        guard let hash else { throw .noChecksum }
        var verified = release
        verified.sha256 = hash
        return verified
    }

    /// The release's zip for this Mac. `sha256` is empty until its checksum is read.
    static func pick(_ response: GitHubRelease, architecture: String) throws(Failure) -> (GameRelease, GitHubRelease.Asset) {
        let suffix = "-macos-\(architecture).zip"
        guard let zip = response.assets.first(where: { $0.name.hasPrefix("supermetroid-") && $0.name.hasSuffix(suffix) }) else {
            throw .noMacBuild
        }
        let release = GameRelease(version: response.version, tag: response.tag, zipName: zip.name, zipURL: zip.url,
                                  size: Int(zip.size), sha256: "", published: response.published)
        return (release, zip)
    }

    // MARK: Download

    /// Where a release's zip lives: `<downloads>/<version>/<zip name>`.
    public func zipFile(in downloads: URL) -> URL {
        downloads.appending(path: version, directoryHint: .isDirectory).appending(path: zipName)
    }

    /// True when the zip is already in `downloads` and matches its checksum.
    public func isDownloaded(in downloads: URL) -> Bool {
        (try? SHA256Hex.ofFile(zipFile(in: downloads))) == sha256
    }

    /// Downloads the zip into `<downloads>/<version>/`, or reuses one already there and verified.
    /// The bytes go to a hidden `.part` file first, hashed as they come, so a cancelled download never
    /// looks finished; a zip that doesn't match its checksum is deleted and reported as `.damaged`.
    /// A dropped connection is tried again from where it stopped.
    /// `progress` gets bytes done and bytes total; `checking` is called once the bytes are all in.
    public func download(into downloads: URL, session: URLSession = .shared,
                         progress: (@Sendable (Int, Int) -> Void)? = nil,
                         checking: (@Sendable () -> Void)? = nil) async throws -> URL {
        let final = zipFile(in: downloads)
        let size = size
        do {
            try await Download.file(zipURL, to: final, sha256: sha256, options: Self.options(session, retry: .standard)) { step in
                progress?(Int(step.received), step.total.map(Int.init) ?? size)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as DownloadError {
            throw Failure(error)
        } catch let error as URLError {
            throw Failure(error)
        }
        checking?()
        return final
    }
}

extension GameRelease.Failure {
    /// DownloadKit's errors in the launcher's words: no connection, GitHub's status, a damaged file.
    init(_ error: any Error) {
        switch error {
        // A refusal or rate limit keeps the status GitHub sent (403 or 429), so the message matches it.
        case let error as DownloadError where error.status != nil: self = .github(error.status ?? 0)
        case DownloadError.checksumMismatch: self = .damaged
        case DownloadError.badResponse, DownloadError.invalidChecksum, DownloadError.rangesNotSupported: self = .badResponse
        default: self = .offline
        }
    }
}
