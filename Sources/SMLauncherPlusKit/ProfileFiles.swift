import Foundation

/// Rules for profile names (S-032). Ported from AM2R Launcher Plus's ProfileName; the words the
/// player sees ("Copy", the default name) come from the app, which has the translations.
public enum ProfileName {
    /// Trims spaces and line breaks and collapses inner runs of spaces; an empty name becomes `fallback`.
    public static func clean(_ text: String, fallback: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? fallback : words.joined(separator: " ")
    }

    /// "Super Metroid Copy", then "… Copy 2", "… Copy 3" when those are taken.
    public static func copy(of name: String, existing: [String], suffix: String) -> String {
        let taken = Set(existing)
        let first = "\(name) \(suffix)"
        if !taken.contains(first) { return first }
        var number = 2
        while taken.contains("\(first) \(number)") { number += 1 }
        return "\(first) \(number)"
    }

    /// "Super Metroid – 2026-11-22 14-05", safe as a folder name: slashes and colons become dashes.
    public static func dated(_ name: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) – \(stamp)"
    }
}

/// Copying a profile and keeping its saves when it's deleted (S-032).
public enum ProfileFiles {
    /// Left out of a copy: the build kept for Roll Back, and an update or roll back still in progress.
    static let notCopied: Set<String> = ["previous", "update.partial", "rollback.partial"]
    /// The player's settings kept beside the saves, relative to the game folder.
    public static let settings = ["config.ini", "keybinds.ini", "sm-video.ini", "mods/preloaded/state.toml"]

    /// Copies `profile` to `copy` (which must not exist): the game with its saves, settings and mods.
    /// On failure nothing is left at `copy`.
    public static func duplicate(_ profile: URL, to copy: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) where !notCopied.contains(item.lastPathComponent) {
                try fm.copyItem(at: item, to: copy.appending(path: item.lastPathComponent))
            }
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
    }

    /// True when the game folder holds a save.
    public static func hasSaves(game: URL) -> Bool {
        let saves = game.appending(path: "saves", directoryHint: .isDirectory)
        return !((try? FileManager.default.contentsOfDirectory(atPath: saves.path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
    }

    /// Moves the game's `saves/` into `kept` and copies the settings beside it
    /// (`kept/saves/`, `kept/config.ini`, ..., `kept/mods/preloaded/state.toml`). On failure `kept` is removed
    /// and the saves are where they were.
    public static func keepSaves(game: URL, in kept: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: kept, withIntermediateDirectories: true)
        do {
            for path in settings where fm.fileExists(atPath: game.appending(path: path).path) {
                let target = kept.appending(path: path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: game.appending(path: path), to: target)
            }
            try fm.moveItem(at: game.appending(path: "saves", directoryHint: .isDirectory), to: kept.appending(path: "saves", directoryHint: .isDirectory))
        } catch {
            try? fm.removeItem(at: kept)
            throw error
        }
    }
}
