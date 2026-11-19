import Foundation

/// Installs and removes `.snesmod` packages (S-021) the way the game does: snesrecomp's
/// runner/src/mod_runtime.cpp `parse_zip`, `extract_zip` and `install_archive`.
/// A ZIP with a root manifest.toml, stored or DEFLATE entries only, no encryption, no unsafe paths,
/// at most 4096 files and 256 MiB expanded, every CRC checked. Unpacked into a staging folder,
/// then published as `packages/<id>/<version>/` in one rename.
public enum ModArchive {
    public static let maxFiles = 4096
    public static let maxBytes: UInt64 = 256 * 1024 * 1024

    public enum Failure: Error, Equatable, Sendable {
        /// The file's name doesn't end in .snesmod.
        case notSnesmod
        /// Not a ZIP, or its records are cut or inconsistent.
        case damaged
        case encrypted
        /// A compression method other than stored (0) or DEFLATE (8).
        case unsupportedCompression
        /// An absolute path, "..", ".", a drive letter, or a symbolic link.
        case unsafePath(String)
        case tooManyFiles
        case tooLarge
        /// An entry's data doesn't match its CRC.
        case checksumFailed(String)
        case noManifest
        /// manifest.toml lacks format_version 1, a valid id, version, name, target or feature.
        case invalidManifest
        /// No `[[target]]` names supermetroid-jpn.
        case wrongGame(name: String, games: [String])
        /// It targets supermetroid-jpn but another ROM than the supported one.
        case wrongROM(name: String)
        case alreadyInstalled(name: String, version: String)
        case writeFailed(String)
    }

    struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var isDirectory: Bool
    }

    /// Checks `archive` and installs it into `root` (`<game>/mods/preloaded`), then records its
    /// version in state.toml like the game's provider_install. Returns the installed package.
    @discardableResult
    public static func install(_ archive: URL, into root: URL, romSHA256: String = SupportedROM.sha256) throws(Failure) -> ModPackage {
        guard archive.pathExtension.lowercased() == "snesmod" else { throw .notSnesmod }
        let fm = FileManager.default
        // A stored archive at the limit is a little over 256 MiB; anything far past it can't pass.
        if let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value,
           size > maxBytes + 64 * 1024 * 1024 { throw .tooLarge }
        guard let bytes = try? Data(contentsOf: archive, options: .alwaysMapped) else { throw .damaged }
        let entries = try parse(bytes)
        guard entries.contains(where: { $0.name == "manifest.toml" && !$0.isDirectory }) else { throw .noManifest }

        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try extract(bytes, entries, to: staging)

        guard let text = try? String(contentsOf: staging.appending(path: "manifest.toml"), encoding: .utf8),
              let package = ModCatalog.parseManifest(text),
              package.formatVersion == 1, isValidID(package.id), isSafeName(package.version),
              !package.name.isEmpty, !package.gameIDs.isEmpty, !package.features.isEmpty
        else { throw .invalidManifest }
        guard package.gameIDs.contains(ModCatalog.gameID) else { throw .wrongGame(name: package.name, games: package.gameIDs) }
        guard zip(package.gameIDs, package.targetROMs).contains(where: { $0 == ModCatalog.gameID && $1 == romSHA256.lowercased() })
        else { throw .wrongROM(name: package.name) }

        let destination = root.appending(path: "packages/\(package.id)/\(package.version)", directoryHint: .isDirectory)
        if fm.fileExists(atPath: destination.path) { throw .alreadyInstalled(name: package.name, version: package.version) }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: destination)
            var state = ModState.read(from: root)
            state.packages[package.id] = package.version
            try state.write(to: root)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        return package
    }

    /// Removes one installed version: its folder, and, when no other version is left, the package's
    /// folder and every entry it has in state.toml. Otherwise state.toml points at the newest one left.
    public static func remove(id: String, version: String, from root: URL) throws(Failure) {
        guard isValidID(id), isSafeName(version) else { throw .unsafePath(id + "/" + version) }
        let fm = FileManager.default
        let folder = root.appending(path: "packages/\(id)", directoryHint: .isDirectory)
        do {
            let target = folder.appending(path: version, directoryHint: .isDirectory)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let left = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: folder.appending(path: "\($0)/manifest.toml").path) }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            var state = ModState.read(from: root)
            if let newest = left.first {
                state.packages[id] = newest
            } else {
                try? fm.removeItem(at: folder)
                state.packages[id] = nil
                state.features = state.features.filter { !$0.key.hasPrefix(id + "/") }
            }
            try state.write(to: root)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    // MARK: - The game's ZIP reader

    /// parse_zip: the end record, then every central directory record.
    static func parse(_ bytes: Data) throws(Failure) -> [Entry] {
        let count = bytes.count
        guard count >= 22 else { throw .damaged }
        return try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws(Failure) -> [Entry] in
            func u16(_ at: Int) -> Int { Int(raw[at]) | Int(raw[at + 1]) << 8 }
            func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
            var eocd: Int?
            let floor = max(0, count - 65557)
            var pos = count - 22
            while pos >= floor {
                if u32(pos) == 0x06054b50 { eocd = pos; break }
                pos -= 1
            }
            guard let eocd else { throw .damaged }
            let entryCount = u16(eocd + 10), centralSize = u32(eocd + 12), centralOffset = u32(eocd + 16)
            if entryCount > maxFiles { throw .tooManyFiles }
            guard centralOffset + centralSize <= count else { throw .damaged }
            var entries: [Entry] = []
            var at = centralOffset
            var expanded: UInt64 = 0
            for _ in 0..<entryCount {
                guard at + 46 <= count, u32(at) == 0x02014b50 else { throw .damaged }
                let flags = u16(at + 8), method = u16(at + 10)
                if flags & 1 != 0 { throw .encrypted }
                if method != 0 && method != 8 { throw .unsupportedCompression }
                let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
                guard at + 46 + nameLength + extraLength + commentLength <= count else { throw .damaged }
                let nameBytes = UnsafeRawBufferPointer(rebasing: raw[(at + 46)..<(at + 46 + nameLength)])
                let name = String(decoding: nameBytes, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")
                let isDirectory = name.hasSuffix("/")
                guard isSafeName(isDirectory ? String(name.dropLast()) : name) else { throw .unsafePath(name) }
                // The game writes every entry as a plain file; a Unix symbolic link would point anywhere.
                let madeOnUnix = raw[at + 5] == 3
                if madeOnUnix, (u32(at + 38) >> 16) & 0o170000 == 0o120000 { throw .unsafePath(name) }
                let size = u32(at + 24)
                expanded += UInt64(size)
                if expanded > maxBytes { throw .tooLarge }
                entries.append(Entry(name: name, method: UInt16(method), crc: UInt32(u32(at + 16)), compressedSize: u32(at + 20),
                                     size: size, localOffset: u32(at + 42), isDirectory: isDirectory))
                at += 46 + nameLength + extraLength + commentLength
            }
            return entries
        }
    }

    /// extract_zip: every entry's data, inflated when needed, its CRC checked, written under `folder`.
    static func extract(_ bytes: Data, _ entries: [Entry], to folder: URL) throws(Failure) {
        let fm = FileManager.default
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { throw .writeFailed(error.localizedDescription) }
        for entry in entries {
            let output = folder.appending(path: entry.name)
            if entry.isDirectory {
                do { try fm.createDirectory(at: output, withIntermediateDirectories: true) } catch { throw .writeFailed(error.localizedDescription) }
                continue
            }
            let data = try payload(of: entry, in: bytes)
            guard crc32(data) == entry.crc else { throw .checksumFailed(entry.name) }
            do {
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output)
            } catch {
                throw .writeFailed(error.localizedDescription)
            }
        }
    }

    private static func payload(of entry: Entry, in bytes: Data) throws(Failure) -> Data {
        let start = bytes.startIndex
        func u16(_ at: Int) -> Int { Int(bytes[start + at]) | Int(bytes[start + at + 1]) << 8 }
        guard entry.localOffset + 30 <= bytes.count,
              u16(entry.localOffset) | u16(entry.localOffset + 2) << 16 == 0x04034b50 else { throw .damaged }
        let dataAt = entry.localOffset + 30 + u16(entry.localOffset + 26) + u16(entry.localOffset + 28)
        guard dataAt + entry.compressedSize <= bytes.count else { throw .damaged }
        let compressed = bytes.subdata(in: (start + dataAt)..<(start + dataAt + entry.compressedSize))
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw .damaged }
            return compressed
        }
        if entry.size == 0 { return Data() }
        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), what ZIP method 8 stores.
        guard let inflated = try? (compressed as NSData).decompressed(using: .zlib) as Data, inflated.count == entry.size
        else { throw .checksumFailed(entry.name) }
        return inflated
    }

    /// safe_archive_name.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 512, !name.hasPrefix("/"), !name.hasPrefix("\\") else { return false }
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", CharacterSet.letters.contains(scalars[0]) { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// valid_id: lowercase letters, digits, ".", "-", "_", at most 96, not starting or ending with ".".
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 96, !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
