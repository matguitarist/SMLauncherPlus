import ArchiveKit
import DownloadKit
import Foundation

/// Recognizes the player's own Super Metroid ROM (S-001): a .sfc or .smc file, or a .zip or .7z holding one.
/// The ROM is read where it is, into memory; nothing is unpacked to disk or copied.
/// Ported from AM2R Launcher Plus's AM2R11Check.
public enum ROMCheck {
    public enum Kind: String, Codable, Sendable { case file, zip, sevenZip = "7z" }

    /// A checked, supported ROM.
    public struct ROM: Equatable, Sendable {
        public var url: URL
        public var kind: Kind
        /// The ROM's name inside the archive, or "" for a plain file.
        public var member: String
        /// True when the file starts with a 512-byte copier header, skipped for the check.
        public var headered: Bool
        public var sha256: String

        public init(url: URL, kind: Kind, member: String, headered: Bool, sha256: String) {
            self.url = url
            self.kind = kind
            self.member = member
            self.headered = headered
            self.sha256 = sha256
        }
    }

    /// Why a file isn't the supported ROM. The app turns each into a sentence (ROMProblem+Message.swift).
    public enum Problem: Error, Equatable, Sendable {
        /// Not a .sfc, .smc, .zip or .7z, or no SNES header inside.
        case notROM
        case unreadable
        case zipWithoutROM
        case zipWithSeveralROMs
        /// Too small, too large, or not a whole number of 32 KB banks.
        case wrongSize
        /// A SNES ROM of another game, with its internal title.
        case otherGame(String)
        /// Super Metroid, but another region or release (the PAL one).
        case otherVersion
        /// Super Metroid (Japan, USA) that doesn't match the original bytes.
        case patched

        /// True when the file is Super Metroid but not the supported copy (yellow on the welcome page);
        /// false when it isn't recognized as Super Metroid at all (red).
        public var isSuperMetroid: Bool {
            switch self {
            case .patched, .otherVersion: true
            default: false
            }
        }
    }

    static let romExtensions: Set<String> = ["sfc", "smc"]
    /// The largest SNES ROM plus a copier header; anything bigger isn't read.
    static let maxBytes = 8 * 1024 * 1024 + 512

    /// Checks a .sfc, .smc, .zip or .7z file.
    public static func check(_ url: URL) async throws(Problem) -> ROM {
        let ext = url.pathExtension.lowercased()
        if romExtensions.contains(ext) {
            guard let size = fileSize(url) else { throw .unreadable }
            guard size <= maxBytes else { throw .wrongSize }
            guard let data = try? Data(contentsOf: url) else { throw .unreadable }
            let (headered, hash) = try identify(data)
            return ROM(url: url, kind: .file, member: "", headered: headered, sha256: hash)
        }
        guard let kind: Kind = ext == "zip" ? .zip : ext == "7z" ? .sevenZip : nil else { throw .notROM }
        let entries: [String]
        do { entries = kind == .zip ? try Zip.names(url) : try await AnyArchive.names(url) } catch { throw .unreadable }
        let roms = entries.filter { romExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix("__MACOSX/") }
        guard !roms.isEmpty else { throw .zipWithoutROM }
        guard roms.count == 1 else { throw .zipWithSeveralROMs }
        let data: Data
        do { data = try await read(roms[0], in: url, kind: kind) } catch ArchiveError.tooLarge { throw .wrongSize } catch { throw .unreadable }
        let (headered, hash) = try identify(data)
        return ROM(url: url, kind: kind, member: roms[0], headered: headered, sha256: hash)
    }

    /// One member of a .zip or .7z, read into memory (ArchiveKit's `tooLarge` past `maxBytes`); the file itself for a plain one.
    static func read(_ member: String, in url: URL, kind: Kind) async throws -> Data {
        switch kind {
        case .file: try Data(contentsOf: url)
        case .zip: try await Zip.read(member, from: url, limit: maxBytes)
        case .sevenZip: try await AnyArchive.read(member, from: url, limit: maxBytes)
        }
    }

    /// Checks a ROM's bytes. Returns whether it had a copier header, and its SHA-256 without it.
    /// `supported` is the hash to accept; tests pass the hash of a made-up ROM.
    public static func identify(_ data: Data, supported: String = SupportedROM.sha256) throws(Problem) -> (headered: Bool, sha256: String) {
        let headered = data.count % 1024 == 512
        let body = headered ? data.dropFirst(512) : data[...]
        guard body.count >= 256 * 1024, body.count <= 8 * 1024 * 1024, body.count % (32 * 1024) == 0 else { throw .wrongSize }
        let hash = SHA256Hex.of(body)
        if body.count == SupportedROM.size, hash == supported { return (headered, hash) }

        let header = Header(body, at: 0x7FC0)
        if header.title == SupportedROM.title {
            // 0 Japan, 1 USA: the supported release. 2 and up are the PAL release.
            throw header.country >= 2 ? .otherVersion : .patched
        }
        if let named = [header, Header(body, at: 0xFFC0)].first(where: \.isValid) {
            throw .otherGame(named.title)
        }
        throw .notROM
    }

    /// The SNES internal header: a 21-byte title, the country, and a checksum with its complement.
    struct Header {
        var title = ""
        var country = 0
        var isValid = false

        init(_ body: Data.SubSequence, at offset: Int) {
            let start = body.startIndex + offset
            guard body.count >= offset + 0x20 else { return }
            let titleBytes = body[start..<start + 21]
            title = String(decoding: titleBytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            country = Int(body[start + 0x19])
            let complement = Int(body[start + 0x1C]) | Int(body[start + 0x1D]) << 8
            let checksum = Int(body[start + 0x1E]) | Int(body[start + 0x1F]) << 8
            isValid = complement ^ checksum == 0xFFFF && !title.isEmpty
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

extension SupportedROM {
    /// The title in the ROM's internal header.
    static let title = "Super Metroid"
}
