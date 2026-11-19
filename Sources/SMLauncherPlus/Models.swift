import Foundation
import SwiftData

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

    init(name: String, gameVersion: String) {
        self.name = name
        self.gameVersion = gameVersion
    }
}

/// The player's own ROM, checked and remembered where it is (S-001). Never copied.
@Model
final class RomSource {
    var path: String
    /// Bookmark so the ROM is found again after it's renamed or moved on the same disk.
    var bookmark: Data?
    var sha256: String
    var checkedAt: Date = Date.now

    init(url: URL, sha256: String) {
        path = url.path
        bookmark = try? url.bookmarkData(options: .minimalBookmark)
        self.sha256 = sha256
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
