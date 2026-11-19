import CryptoKit
import Foundation

/// How the launcher starts SuperMetroidRecomp (S-004).
public enum GameLaunch {
    /// Straight into the game with the player's ROM and the profile's config.ini,
    /// skipping the game's own launcher (checked in the self-test: it reaches the title screen).
    public static func arguments(rom: URL, config: URL, extra: [String] = []) -> [String] {
        ["--rom", rom.path, "--no-launcher", "--config", config.path] + extra
    }

    /// The game reads only a plain .sfc on disk (a pipe is refused: it checks the size first).
    /// A plain, unheadered ROM file is passed where it is. A zipped or headered one is unpacked into
    /// a private folder under `root` (mode 700) for this run only; `discard` deletes it when the game quits.
    /// The owner's rule: never a lasting copy (CLAUDE.md).
    public struct ROMFile: Sendable, Equatable {
        /// The path to pass with --rom.
        public var url: URL
        /// The private folder holding the temporary copy, nil when the ROM is passed in place.
        public var temporaryFolder: URL?

        public func discard() {
            if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
        }
    }

    public enum ROMProblem: Error, Equatable, Sendable {
        /// The ROM isn't where it was (moved, renamed, disk unplugged).
        case missing
        /// It's there but no longer the checked ROM.
        case changed
        /// The temporary copy couldn't be written.
        case unwritable
    }

    /// Prepares the ROM for one run. `sha256` is the hash it had when it was checked.
    public static func prepareROM(_ rom: ROMCheck.ROM, root: URL) throws(ROMProblem) -> ROMFile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rom.url.path) else { throw .missing }
        if rom.kind == .file, !rom.headered {
            return ROMFile(url: rom.url, temporaryFolder: nil)
        }
        let data: Data?
        switch rom.kind {
        case .file: data = try? Data(contentsOf: rom.url)
        case .zip, .sevenZip: data = ROMCheck.read(rom.member, in: rom.url, kind: rom.kind)
        }
        guard var bytes = data else { throw .missing }
        if rom.headered, bytes.count % 1024 == 512 { bytes = bytes.dropFirst(512) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard hash == rom.sha256 else { throw .changed }

        let folder = root.appending(path: "rom-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appending(path: "Super Metroid.sfc")
            guard fm.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw ROMProblem.unwritable }
            return ROMFile(url: file, temporaryFolder: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw .unwritable
        }
    }

    /// Removes temporary ROM folders a crash or a forced quit left behind. Called at launch.
    public static func removeLeftoverROMs(in root: URL) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where folder.lastPathComponent.hasPrefix("rom-") {
            try? fm.removeItem(at: folder)
        }
    }
}
