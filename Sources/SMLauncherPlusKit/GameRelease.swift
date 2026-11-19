import CryptoKit
import Foundation

/// SuperMetroidRecomp's macOS build from its latest GitHub release (S-002).
/// Ported from AM2R Launcher Plus's PatchData: the GitHub API, a typed Failure, and a download
/// that never looks finished until it is checked.
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

    struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int
            var browser_download_url: URL
        }
        var tag_name: String
        var published_at: Date?
        var assets: [Asset]
    }

    /// Reads the latest release and its SHA256SUMS (one API call, one download).
    public static func latest(architecture: String = architecture, session: URLSession = .shared) async throws(Failure) -> GameRelease {
        let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        let json = try await get(api, accept: "application/vnd.github+json", session: session)
        let (release, sums) = try parse(json, architecture: architecture)
        let text = String(decoding: try await get(sums, accept: nil, session: session), as: UTF8.self)
        guard let hash = checksum(for: release.zipName, in: text) else { throw .noChecksum }
        var verified = release
        verified.sha256 = hash
        return verified
    }

    /// The release's zip for this Mac and the URL of its SHA256SUMS. `sha256` is empty until read from it.
    static func parse(_ json: Data, architecture: String) throws(Failure) -> (GameRelease, URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(ReleaseResponse.self, from: json) else { throw .badResponse }
        let suffix = "-macos-\(architecture).zip"
        guard let zip = response.assets.first(where: { $0.name.hasPrefix("supermetroid-") && $0.name.hasSuffix(suffix) }) else {
            throw .noMacBuild
        }
        guard let sums = response.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw .noChecksum }
        let version = response.tag_name.hasPrefix("v") ? String(response.tag_name.dropFirst()) : response.tag_name
        let release = GameRelease(version: version, tag: response.tag_name, zipName: zip.name, zipURL: zip.browser_download_url,
                                  size: zip.size, sha256: "", published: response.published_at)
        return (release, sums.browser_download_url)
    }

    /// The hash on the line for `name` in a SHA256SUMS file ("<hash>  <name>", or "<hash> *<name>").
    public static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            let hash = parts[0].lowercased()
            if file == name, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    private static func get(_ url: URL, accept: String?, session: URLSession) async throws(Failure) -> Data {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.setValue("SMLauncherPlus", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .offline }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        guard http.statusCode == 200 else { throw .github(http.statusCode) }
        return data
    }

    // MARK: Download

    /// Where a release's zip lives: `<downloads>/<version>/<zip name>`.
    public func zipFile(in downloads: URL) -> URL {
        downloads.appending(path: version, directoryHint: .isDirectory).appending(path: zipName)
    }

    /// True when the zip is already in `downloads` and matches its checksum.
    public func isDownloaded(in downloads: URL) -> Bool {
        Self.sha256(of: zipFile(in: downloads)) == sha256
    }

    /// Downloads the zip into `<downloads>/<version>/`, or reuses one already there and verified.
    /// The bytes go to a `.partial` file first, so a cancelled download never looks finished; a zip
    /// that doesn't match its checksum is deleted and reported as `.damaged`.
    /// `progress` gets bytes done and bytes total; `checking` is called once the bytes are all in.
    public func download(into downloads: URL, session: URLSession = .shared,
                         progress: (@Sendable (Int, Int) -> Void)? = nil,
                         checking: (@Sendable () -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        let final = zipFile(in: downloads)
        if isDownloaded(in: downloads) { return final }
        try? fm.removeItem(at: final)
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = final.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        fm.createFile(atPath: partial.path, contents: nil)
        var finished = false
        defer { if !finished { try? fm.removeItem(at: partial) } }

        var request = URLRequest(url: zipURL)
        request.setValue("SMLauncherPlus", forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch is CancellationError { throw CancellationError() } catch { throw Failure.offline }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else { throw Failure.github(http.statusCode) }
        let total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : size

        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var done = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    try Task.checkCancellation()
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    done += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    progress?(done, total)
                }
            }
        } catch is CancellationError {
            try? handle.close()
            throw CancellationError()
        } catch {
            try? handle.close()
            throw Failure.offline
        }
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        try handle.close()
        done += buffer.count
        progress?(done, total)
        try Task.checkCancellation()

        checking?()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == sha256 else { throw Failure.damaged }
        try fm.moveItem(at: partial, to: final)
        finished = true
        return final
    }

    /// Streams a file through SHA-256 in 1 MB chunks; nil when it can't be read.
    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
