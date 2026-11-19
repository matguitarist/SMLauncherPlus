import Foundation

/// Unpacks a verified SuperMetroidRecomp zip into a profile (S-003):
/// `<profiles>/<id>/game/` holds the game, `<profiles>/<id>/profile.json` says what it is.
/// Ported from AM2R Launcher Plus's ProfileBuilder: built in a staging folder, swapped in only when complete.
public enum ProfileBuilder {
    /// The game's executable, at the top of the zip's folder.
    public static let executable = "SuperMetroidSNESRecomp"

    public enum Failure: Error, Equatable, Sendable {
        /// The zip can't be listed or unpacked.
        case unreadableZip
        /// An entry would land outside the game folder ("../x", "/etc/x", or a link that points out).
        case unsafePath(String)
        /// No SuperMetroidSNESRecomp in the zip.
        case missingExecutable
        /// Moving the files into place failed (disk full, permissions).
        case copyFailed(String)
    }

    /// What the launcher records about a profile, next to its game folder.
    public struct Info: Codable, Equatable, Sendable {
        public var version: String
        public var installedAt: Date
        /// The ROM the profile was set up with.
        public var romSHA256: String

        public init(version: String, installedAt: Date = .now, romSHA256: String) {
            self.version = version
            self.installedAt = installedAt
            self.romSHA256 = romSHA256
        }

        public static func read(from profile: URL) -> Info? {
            guard let data = try? Data(contentsOf: profile.appending(path: "profile.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Info.self, from: data)
        }

        func write(to profile: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: profile.appending(path: "profile.json"), options: .atomic)
        }
    }

    /// Unpacks `zip` into `profile/game/` and writes `profile/profile.json`.
    /// `profile` is replaced only once the new game folder is complete.
    @discardableResult
    public static func build(zip: URL, profile: URL, info: Info) throws(Failure) -> URL {
        let fm = FileManager.default
        guard let entries = Zip.list(zip) else { throw .unreadableZip }
        let root = try commonRoot(of: entries)

        let staging = profile.deletingLastPathComponent().appending(path: profile.lastPathComponent + ".partial", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw .copyFailed("\(error)")
        }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: staging) } }

        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        guard unzip(zip, to: unpacked) else { throw .unreadableZip }
        try checkLinks(in: unpacked)
        let top = root.isEmpty ? unpacked : unpacked.appending(path: root, directoryHint: .isDirectory)
        let game = staging.appending(path: "game", directoryHint: .isDirectory)
        do { try fm.moveItem(at: top, to: game) } catch { throw .copyFailed("\(error)") }
        try? fm.removeItem(at: unpacked)

        let binary = game.appending(path: executable)
        guard fm.isExecutableFile(atPath: binary.path) else { throw .missingExecutable }
        clearQuarantine(in: game)
        do {
            try info.write(to: staging)
            if fm.fileExists(atPath: profile.path) { try fm.removeItem(at: profile) }
            try fm.moveItem(at: staging, to: profile)
        } catch {
            throw .copyFailed("\(error)")
        }
        finished = true
        return profile.appending(path: "game", directoryHint: .isDirectory)
    }

    /// The one folder every entry sits in ("supermetroid-0.4.6-macos-arm64/"), or "" when there isn't one.
    /// Refuses an entry that would land outside the folder it's unpacked into.
    static func commonRoot(of entries: [String]) throws(Failure) -> String {
        guard !entries.isEmpty else { throw .unreadableZip }
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || entry.hasPrefix("~") || entry.contains("\\") || parts.contains("..") {
                throw .unsafePath(entry)
            }
        }
        let firsts = Set(entries.map { $0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? $0 })
        guard firsts.count == 1, let only = firsts.first, entries.allSatisfy({ $0.hasPrefix(only + "/") }) else { return "" }
        return only + "/"
    }

    /// A symbolic link in the zip may only point inside the game folder.
    static func checkLinks(in folder: URL) throws(Failure) {
        let base = folder.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return }
        // Relative paths, as they are in the zip.
        for case let path as String in walker {
            let url = folder.appending(path: path)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            if !url.resolvingSymlinksInPath().path.hasPrefix(base) { throw .unsafePath(path) }
        }
    }

    /// /usr/bin/ditto keeps the executable bit and links, and adds no quarantine flag.
    private static func unzip(_ zip: URL, to folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Removes com.apple.quarantine from every file, so macOS never asks before the game opens.
    /// A download by the launcher has none; this covers a zip the player brought in another way.
    static func clearQuarantine(in folder: URL) {
        let paths = [folder.path] + (FileManager.default.subpaths(atPath: folder.path) ?? []).map { folder.path + "/" + $0 }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// True when the file carries com.apple.quarantine.
    public static func isQuarantined(_ file: URL) -> Bool {
        getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
