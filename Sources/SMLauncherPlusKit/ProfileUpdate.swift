import Foundation

/// Update installs a newer SuperMetroidRecomp into the same profile (S-031): the new build is
/// unpacked beside the old one, what the player made is carried over, and the old build is kept
/// in `previous/` so Roll Back can bring it back. Ported from AM2R Launcher Plus's in-place update.
///
/// What the player made, carried from the old build into the new one:
/// - files the release doesn't ship (saves, logs, keybinds, the launcher's filters, ...);
/// - `playerPaths`, which win over the release's copy even when it ships one;
/// - `config.ini`, merged: the release's file with every key the player had set;
/// - packages the player installed from .snesmod files; the game's own packages come from the release.
public enum ProfileUpdate {
    /// Written by the game or the launcher for this player: never replaced by the release's copy.
    static let playerPaths = ["saves", "logs", "keybinds.ini", "sm-video.ini", "rom.cfg", "last_run_report.json",
                              "mods/preloaded/state.toml"]
    static let packages = "mods/preloaded/packages"
    static let config = "config.ini"

    /// `<profile>/previous/`: the build before the last update.
    public static func previousFolder(of profile: URL) -> URL {
        profile.appending(path: "previous", directoryHint: .isDirectory)
    }

    /// Unpacks `zip` as the profile's new game, carries the player's files over, keeps the old build
    /// in `previous/` (replacing an older one), and writes `info` with the old version as `previousVersion`.
    /// On failure the profile is as it was.
    @discardableResult
    public static func update(zip: URL, profile: URL, info: ProfileBuilder.Info,
                              keepingPackages: Set<String>) async throws(ProfileBuilder.Failure) -> ProfileBuilder.Info {
        let fm = FileManager.default
        let game = profile.appending(path: "game", directoryHint: .isDirectory)
        let staging = profile.appending(path: "update.partial", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        let fresh = try await ProfileBuilder.unpack(zip, into: staging)
        var info = info
        info.previousVersion = ProfileBuilder.Info.read(from: profile)?.version ?? version(of: game)
        do {
            try carryOver(from: game, to: fresh, keepingPackages: keepingPackages)
            let previous = previousFolder(of: profile)
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: game, to: previous)
            do {
                try fm.moveItem(at: fresh, to: game)
            } catch {
                try? fm.moveItem(at: previous, to: game)
                throw error
            }
            try info.write(to: profile)
        } catch let failure as ProfileBuilder.Failure {
            throw failure
        } catch {
            throw .copyFailed("\(error)")
        }
        return info
    }

    /// Brings back the build kept by the last update, with the player's files carried back into it.
    /// The newer build is deleted; Update installs it again. Returns the new info, or nil when there
    /// is no previous build.
    public static func rollBack(profile: URL, keepingPackages: Set<String>) throws(ProfileBuilder.Failure) -> ProfileBuilder.Info? {
        let fm = FileManager.default
        let game = profile.appending(path: "game", directoryHint: .isDirectory)
        let previous = previousFolder(of: profile)
        guard fm.fileExists(atPath: previous.path) else { return nil }
        guard var info = ProfileBuilder.Info.read(from: profile),
              let version = info.previousVersion ?? version(of: previous) else { return nil }
        let discard = profile.appending(path: "rollback.partial", directoryHint: .isDirectory)
        try? fm.removeItem(at: discard)
        do {
            try carryOver(from: game, to: previous, keepingPackages: keepingPackages)
            try fm.moveItem(at: game, to: discard)
            do {
                try fm.moveItem(at: previous, to: game)
            } catch {
                try? fm.moveItem(at: discard, to: game)
                throw error
            }
            try? fm.removeItem(at: discard)
            info.version = version
            info.previousVersion = nil
            try info.write(to: profile)
        } catch {
            throw .copyFailed("\(error)")
        }
        return info
    }

    /// The VERSION file a release ships ("0.4.6").
    public static func version(of game: URL) -> String? {
        let text = (try? String(contentsOf: game.appending(path: "VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// Copies the player's files from `old` into `new` (see the type's comment).
    static func carryOver(from old: URL, to new: URL, keepingPackages: Set<String>) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: old.path) else { return }
        for case let path as String in walker {
            let source = old.appending(path: path)
            let target = new.appending(path: path)
            let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
            if path == config, !isFolder {
                try mergeConfig(from: source, into: target)
                continue
            }
            // Under packages/: only the player's own; the game's come from the release.
            if path.hasPrefix(packages + "/") {
                let id = path.dropFirst(packages.count + 1).split(separator: "/").first.map(String.init) ?? ""
                if !keepingPackages.contains(id) {
                    if isFolder { walker.skipDescendants() }
                    continue
                }
            }
            let exists = fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            if isFolder {
                // A folder the release doesn't have comes whole; one it has is walked for missing files.
                if !exists {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: target)
                    walker.skipDescendants()
                }
                continue
            }
            let players = playerPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            if exists {
                guard players else { continue }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
    }

    /// config.ini: the release's file, with every key the player's file sets given the player's value.
    static func mergeConfig(from old: URL, into new: URL) throws {
        let player = try String(contentsOf: old, encoding: .utf8)
        guard let release = try? String(contentsOf: new, encoding: .utf8) else {
            try FileManager.default.copyItem(at: old, to: new)
            return
        }
        try IniFile.merge(player: player, release: release).write(to: new, atomically: true, encoding: .utf8)
    }
}

extension IniFile {
    /// Every `Key = value` line under a section, in order (comments and keys before any section skipped).
    public var entries: [(section: String, key: String, value: String)] {
        var section: String?
        var found: [(String, String, String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard let section, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { found.append((section, key, value)) }
        }
        return found
    }

    /// A new release's file with the player's settings: the release's layout, comments and new keys,
    /// and the player's value for every key they had. Lines whose value didn't change stay as the release wrote them.
    public static func merge(player: String, release: String) -> String {
        var merged = IniFile(text: release)
        for (section, key, value) in IniFile(text: player).entries where merged.value(key, in: section) != value {
            merged.set(key, to: value, in: section)
        }
        return merged.text
    }
}
