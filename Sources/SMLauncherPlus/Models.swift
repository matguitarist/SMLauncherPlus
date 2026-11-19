import Foundation
import SwiftData
import SMLauncherPlusKit

/// One installed, playable copy of SuperMetroidRecomp with its own saves and settings (S-003).
/// Same shape as AM2R Launcher Plus's Profile.
@Model
final class Profile {
    var name: String
    /// SuperMetroidRecomp release, e.g. "0.4.6".
    var gameVersion: String
    var installedAt: Date = Date.now
    var lastPlayedAt: Date?
    /// Total play time in seconds.
    var playTime: Double = 0
    /// A stable id for folders and links.
    var uuid: UUID = UUID()
    /// Packages the player installed from .snesmod files (S-021), as "id/version". The game's own
    /// packages aren't listed: only these can be removed.
    var installedMods: [String] = []

    init(name: String, gameVersion: String) {
        self.name = name
        self.gameVersion = gameVersion
    }

    /// `<data folder>/Profiles/<uuid>/`: the game in `game/`, and `profile.json`.
    var folder: URL { DataFolder.profiles.appending(path: uuid.uuidString, directoryHint: .isDirectory) }
    var gameFolder: URL { folder.appending(path: "game", directoryHint: .isDirectory) }
    var executable: URL { gameFolder.appending(path: ProfileBuilder.executable) }
}

/// The player's own ROM, checked and remembered where it is (S-001). Never copied.
@Model
final class RomSource {
    var path: String
    /// Bookmark so the ROM is found again after it's renamed or moved on the same disk.
    var bookmark: Data?
    var kindRaw: String
    /// The ROM's name inside the zip, or "" for a plain .sfc or .smc.
    var member: String
    /// The file starts with a 512-byte copier header.
    var headered: Bool
    var sha256: String
    var checkedAt: Date = Date.now

    init(rom: ROMCheck.ROM) {
        path = rom.url.path
        bookmark = try? rom.url.bookmarkData(options: .minimalBookmark)
        kindRaw = rom.kind.rawValue
        member = rom.member
        headered = rom.headered
        sha256 = rom.sha256
    }

    /// The current location: follows the bookmark, falls back to the saved path.
    var url: URL {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) { return resolved }
        }
        return URL(fileURLWithPath: path)
    }

    var name: String { url.lastPathComponent }
}

extension FolderMove.Failure {
    /// What Settings › General says when the data folder couldn't move (S-013).
    @MainActor var message: String {
        switch self {
        case .destinationExists(let name):
            String(localized: "That folder already has an item named “\(name)”. Choose another folder.")
        case .insideItself:
            String(localized: "Choose a folder outside the current data folder.")
        case .notEnoughSpace(let needed, let available):
            String(localized: "Not enough space: the data needs \(needed.formatted(.byteCount(style: .file).locale(.app))), the disk has \(available.formatted(.byteCount(style: .file).locale(.app))) free.")
        case .copyFailed:
            String(localized: "Unable to move the data. The old folder is unchanged.")
        case .verifyFailed(let path):
            String(localized: "The copy doesn't match the original (\(path)). The old folder is unchanged.")
        }
    }
}

/// The welcome page's state while the player picks their ROM (S-001).
enum WelcomeState: Equatable {
    case empty
    /// The file's name.
    case checking(String)
    case failed(ROMCheck.Problem, String)
    case ready
}

extension ROMCheck.Problem {
    /// What the welcome page says about a file that isn't the supported ROM.
    var message: String {
        switch self {
        case .notROM: String(localized: "This isn't a SNES ROM. Choose a .sfc, .smc, .zip or .7z file.")
        case .unreadable: String(localized: "Unable to read this file. It may be damaged.")
        case .zipWithoutROM: String(localized: "This archive has no .sfc or .smc file in it.")
        case .zipWithSeveralROMs: String(localized: "This archive holds more than one ROM. Choose the Super Metroid one on its own.")
        case .wrongSize: String(localized: "This file is the wrong size for a SNES ROM.")
        case .otherGame(let title): String(localized: "This is the ROM of “\(title)”, not Super Metroid.")
        case .otherVersion: String(localized: "This ROM isn't the supported version. SM Launcher Plus needs Super Metroid (Japan, USA).")
        case .patched: String(localized: "This ROM has been patched. Use an unmodified copy; mods are added in SM Launcher Plus.")
        }
    }
}
