import CryptoKit
import Foundation

/// A filter from RetroArch's GLSL shader collection that the launcher offers (S-014). Each was tried
/// in the game first; the list and its files are in RetroArchCatalog.swift, written by
/// tools/gen-retroarch-filters.py. Nothing is bundled: the player downloads them from GitHub.
public struct RetroArchFilter: Equatable, Hashable, Sendable, Identifiable {
    public struct File: Equatable, Hashable, Sendable {
        /// Path in the repo, such as `crt/shaders/crt-lottes.glsl`.
        public var path: String
        public var sha256: String
        public var size: Int
    }

    public var id: String
    /// Its name in RetroArch, shown as it is in every language.
    public var name: String
    /// The .glslp in the repo, such as `crt/crt-lottes.glslp`.
    public var preset: String
    public var files: [File]

    /// Every file of every filter, once.
    public static var allFiles: [File] {
        var seen = Set<String>()
        return all.flatMap(\.files).filter { seen.insert($0.path).inserted }
    }

    /// The subfolder of a profile's `assets/shaders` the filters go in.
    public static let folder = "retroarch"

    /// What config.ini's Shader holds for this filter.
    public var shaderPath: String { "\(ShaderPreset.folder)/\(Self.folder)/\(preset)" }

    public static func named(_ id: String) -> RetroArchFilter? { all.first { $0.id == id } }

    public enum Failure: Error, Equatable, Sendable {
        case offline
        case github(Int)
        case damaged(String)
        case failed(String)
    }

    /// The raw file on GitHub at the pinned commit.
    public static func url(of file: File) -> URL {
        URL(string: "https://raw.githubusercontent.com/libretro/glsl-shaders/\(commit)/\(file.path)")!
    }

    /// True when every file is in `cache` with the right checksum.
    public static func isDownloaded(in cache: URL) -> Bool {
        allFiles.allSatisfy { isValid($0, in: cache) }
    }

    static func isValid(_ file: File, in cache: URL) -> Bool {
        guard let data = try? Data(contentsOf: cache.appending(path: file.path)), data.count == file.size else { return false }
        return sha256(data) == file.sha256
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the files missing from `cache`, checks each against its SHA-256, and writes it in place
    /// only when it matches. `progress` gets 0…1.
    public static func download(into cache: URL, session: URLSession = .shared,
                                progress: @Sendable (Double) -> Void = { _ in }) async throws(Failure) {
        let files = allFiles
        for (index, file) in files.enumerated() {
            progress(Double(index) / Double(files.count))
            if isValid(file, in: cache) { continue }
            var request = URLRequest(url: url(of: file))
            request.setValue("SMLauncherPlus", forHTTPHeaderField: "User-Agent")
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) } catch { throw .offline }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw .github((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard data.count == file.size, sha256(data) == file.sha256 else { throw .damaged(file.path) }
            let target = cache.appending(path: file.path)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                throw .failed(error.localizedDescription)
            }
        }
        progress(1)
    }

    /// Copies the downloaded filters into a profile's `assets/shaders/retroarch/`, adding missing files and
    /// refreshing changed ones. Returns the files it wrote.
    @discardableResult
    public static func install(from cache: URL, game: URL) throws -> [String] {
        guard isDownloaded(in: cache) else { return [] }
        let target = game.appending(path: "\(ShaderPreset.folder)/\(folder)", directoryHint: .isDirectory)
        var written: [String] = []
        for file in allFiles {
            let data = try Data(contentsOf: cache.appending(path: file.path))
            let to = target.appending(path: file.path)
            if (try? Data(contentsOf: to)) == data { continue }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: to, options: .atomic)
            written.append(file.path)
        }
        return written
    }

    /// Removes them from a profile. A profile whose Shader points at one goes back to none.
    public static func uninstall(game: URL) {
        try? FileManager.default.removeItem(at: game.appending(path: "\(ShaderPreset.folder)/\(folder)", directoryHint: .isDirectory))
    }
}
