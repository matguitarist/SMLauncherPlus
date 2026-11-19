import Foundation

/// The one ROM SuperMetroidRecomp plays: Super Metroid (Japan, USA) (En,Ja), unheadered.
/// From the game's rom_identity.txt (docs/research/recomp.md).
public enum SupportedROM {
    public static let size = 3_145_728
    public static let sha256 = "12b77c4bc9c1832cee8881244659065ee1d84c70c3d29e6eaf92e6798cc2ca72"
    public static let name = "Super Metroid (Japan, USA)"

    /// True for a file of the right size and hash. The hash is compared without regard to case.
    public static func matches(size: Int, sha256 hash: String) -> Bool {
        size == Self.size && hash.lowercased() == sha256
    }
}

/// What the launcher keeps between runs, saved as JSON in the data folder.
/// Profiles, the ROM bookmark and the release cache join it story by story.
public struct Library: Codable, Equatable, Sendable {
    public var version = 1

    public init() {}

    /// Reads the file, or starts empty when there is none yet.
    public static func load(from url: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
