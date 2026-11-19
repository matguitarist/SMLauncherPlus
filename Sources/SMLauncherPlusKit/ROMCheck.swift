import CryptoKit
import Foundation

/// Recognizes the player's own Super Metroid ROM (S-001): a .sfc or .smc file, or a .zip holding one.
/// The ROM is read where it is, into memory; nothing is unpacked to disk or copied.
/// Ported from AM2R Launcher Plus's AM2R11Check.
public enum ROMCheck {
    public enum Kind: String, Codable, Sendable { case file, zip }

    /// A checked, supported ROM.
    public struct ROM: Equatable, Sendable {
        public var url: URL
        public var kind: Kind
        /// The ROM's name inside the zip, or "" for a plain file.
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
        /// Not a .sfc, .smc or .zip, or no SNES header inside.
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
    }

    static let romExtensions: Set<String> = ["sfc", "smc"]
    /// The largest SNES ROM plus a copier header; anything bigger isn't read.
    static let maxBytes = 8 * 1024 * 1024 + 512

    /// Checks a .sfc, .smc or .zip file.
    public static func check(_ url: URL) throws(Problem) -> ROM {
        let ext = url.pathExtension.lowercased()
        if romExtensions.contains(ext) {
            guard let size = fileSize(url) else { throw .unreadable }
            guard size <= maxBytes else { throw .wrongSize }
            guard let data = try? Data(contentsOf: url) else { throw .unreadable }
            let (headered, hash) = try identify(data)
            return ROM(url: url, kind: .file, member: "", headered: headered, sha256: hash)
        }
        guard ext == "zip" else { throw .notROM }
        guard let entries = Zip.list(url) else { throw .unreadable }
        let roms = entries.filter { romExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix("__MACOSX/") }
        guard !roms.isEmpty else { throw .zipWithoutROM }
        guard roms.count == 1 else { throw .zipWithSeveralROMs }
        guard let data = Zip.read(roms[0], in: url, limit: maxBytes) else { throw .unreadable }
        guard data.count <= maxBytes else { throw .wrongSize }
        let (headered, hash) = try identify(data)
        return ROM(url: url, kind: .zip, member: roms[0], headered: headered, sha256: hash)
    }

    /// Checks a ROM's bytes. Returns whether it had a copier header, and its SHA-256 without it.
    /// `supported` is the hash to accept; tests pass the hash of a made-up ROM.
    public static func identify(_ data: Data, supported: String = SupportedROM.sha256) throws(Problem) -> (headered: Bool, sha256: String) {
        let headered = data.count % 1024 == 512
        let body = headered ? data.dropFirst(512) : data[...]
        guard body.count >= 256 * 1024, body.count <= 8 * 1024 * 1024, body.count % (32 * 1024) == 0 else { throw .wrongSize }
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
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

/// Reads zips with the system's /usr/bin/unzip and zipinfo: no third-party code, nothing written to disk.
enum Zip {
    static func list(_ zip: URL) -> [String]? {
        guard let output = run("/usr/bin/zipinfo", ["-1", zip.path], limit: 1 << 20) else { return nil }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// One member's bytes, at most `limit` + 1 of them (so a caller can tell it's too large).
    static func read(_ member: String, in zip: URL, limit: Int) -> Data? {
        // unzip treats [ ] * ? in names as patterns; escape them so the exact member is read.
        let literal = member.replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "*", with: "[*]").replacingOccurrences(of: "?", with: "[?]")
        guard let data = run("/usr/bin/unzip", ["-p", zip.path, literal], limit: limit + 1), !data.isEmpty else { return nil }
        return data
    }

    private static func run(_ tool: String, _ arguments: [String], limit: Int) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        let reader = pipe.fileHandleForReading
        while data.count <= limit, let chunk = try? reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
        }
        if data.count > limit { process.terminate() }
        process.waitUntilExit()
        guard data.count > limit || process.terminationStatus == 0 else { return nil }
        return data
    }
}
