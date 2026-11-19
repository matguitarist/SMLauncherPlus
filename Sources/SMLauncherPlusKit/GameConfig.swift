import Foundation

/// Reads and edits an .ini file ([Section] then Key = value), changing only the keys asked for and keeping
/// every other line, comment and blank line as it was (S-010 to S-012). Ported from AM2R Launcher Plus,
/// with the game's own layout: `Key = value` in config.ini, `Key=value` in sm-video.ini, no quotes,
/// and `#` or `;` comment lines, which may themselves hold an "=".
public struct IniFile: Equatable, Sendable {
    public private(set) var lines: [String]
    /// What sits between a key and its value in lines the launcher writes.
    private let separator: String
    /// Kept from the file, so an edit doesn't rewrite every line ending.
    private let newline: String
    /// Keys the launcher writes are padded to this width, as keybinds.ini lines up "a       = X".
    private let keyWidth: Int

    public init(text: String, separator: String = " = ", keyWidth: Int = 0) {
        self.separator = separator
        self.keyWidth = keyWidth
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n").map {
            // "\r\n" is one Character in Swift, so trim the code unit, not the Character.
            $0.utf16.last == 13 ? String($0.utf16.dropLast())! : $0
        }
        while lines.last == "" { lines.removeLast() }
    }

    public var text: String { lines.joined(separator: newline) + newline }

    /// The value of the last line with this key in the section: the game reads every line in turn, so the last one wins.
    public func value(_ key: String, in section: String) -> String? {
        guard let range = range(of: section) else { return nil }
        var found: String?
        for line in lines[range] {
            if let (k, v) = Self.split(line), k.caseInsensitiveCompare(key) == .orderedSame { found = v }
        }
        return found
    }

    /// Sets every line with this key in the section (a later duplicate would otherwise win),
    /// or adds one after the section's last key.
    public mutating func set(_ key: String, to value: String, in section: String) {
        let padded = key.count < keyWidth ? key.padding(toLength: keyWidth, withPad: " ", startingAt: 0) : key
        let line = "\(padded)\(separator)\(value)"
        guard let range = range(of: section) else {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append(line)
            return
        }
        var replaced = false
        for index in range {
            if let (k, _) = Self.split(lines[index]), k.caseInsensitiveCompare(key) == .orderedSame {
                lines[index] = line
                replaced = true
            }
        }
        guard !replaced else { return }
        // Add after the section's last key, before any blank lines that separate it from the next one.
        var insertAt = range.upperBound
        while insertAt > range.lowerBound, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(line, at: insertAt)
    }

    /// The lines after "[section]" up to the next section header.
    private func range(of section: String) -> Range<Int>? {
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("[\(section)]") == .orderedSame }) else { return nil }
        var end = header + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        return (header + 1)..<end
    }

    private static func split(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }
}

/// The game's widescreen choice, from sm-video.ini: off draws the original 4:3 picture.
public enum Widescreen: String, CaseIterable, Codable, Sendable {
    case off
    /// Fills the window, whatever its shape (the game's default).
    case fit = "Fit"
    case wide = "16:9"
    case ultrawide = "21:9"
    case superUltrawide = "32:9"
}

/// A filter preset in the profile's `assets/shaders/`, such as `crt-strong.glslp`.
public struct ShaderPreset: Equatable, Hashable, Sendable, Identifiable {
    /// What config.ini's Shader holds: `assets/shaders/crt-strong.glslp`. The game resolves it next to itself.
    public var path: String
    /// "crt", "scanlines", or the name of a preset the player added.
    public var look: String
    /// "light", "", "strong"; empty when the name has no strength.
    public var strength: String

    public var id: String { path }

    public static let folder = "assets/shaders"

    public init(file: String) {
        path = "\(Self.folder)/\(file)"
        let name = (file as NSString).deletingPathExtension.lowercased()
        if let dash = name.lastIndex(of: "-"), ["light", "strong"].contains(String(name[name.index(after: dash)...])) {
            look = String(name[..<dash])
            strength = String(name[name.index(after: dash)...])
        } else {
            look = name
            strength = ""
        }
    }

    /// Every .glslp preset in the profile's game folder: scanlines first, then CRT, then the launcher's,
    /// then any others, each from light to strong.
    public static func list(game: URL) -> [ShaderPreset] {
        let folder = game.appending(path: Self.folder, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func lookOrder(_ look: String) -> Int {
            ["scanlines": 0, "crt": 1, "crt-soft": 2, "sharp": 3, "lcd-grid": 4, "warm-composite": 5][look] ?? 6
        }
        func strengthOrder(_ strength: String) -> Int { ["light": 0, "": 1, "strong": 2][strength] ?? 3 }
        return files.filter { $0.lowercased().hasSuffix(".glslp") && !$0.hasPrefix(".") }
            .map(ShaderPreset.init(file:))
            .sorted {
                (lookOrder($0.look), $0.look, strengthOrder($0.strength)) < (lookOrder($1.look), $1.look, strengthOrder($1.strength))
            }
    }
}

extension ShaderPreset {
    /// Copies the launcher's presets (a folder holding .glslp files and their `_passes/`) into the
    /// profile's `assets/shaders/`, adding missing files and refreshing changed ones. The game's own
    /// presets and any the player added stay as they are. Returns the files it wrote.
    @discardableResult
    public static func installBundled(from source: URL, game: URL) throws -> [String] {
        let target = game.appending(path: folder, directoryHint: .isDirectory)
        let manager = FileManager.default
        var written: [String] = []
        for relative in (manager.subpaths(atPath: source.path) ?? []).sorted() {
            guard relative.hasSuffix(".glslp") || relative.hasSuffix(".glsl") else { continue }
            let from = source.appending(path: relative)
            let to = target.appending(path: relative)
            let data = try Data(contentsOf: from)
            if (try? Data(contentsOf: to)) == data { continue }
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: to, options: .atomic)
            written.append(relative)
        }
        return written
    }
}

/// The display settings the launcher shows for a profile (S-010): fullscreen, VSync and the filter
/// in config.ini's [Graphics], widescreen and the HUD's place in sm-video.ini's [SuperMetroidVideo].
/// Both files sit in the profile's game folder, where the game reads them.
public struct DisplaySettings: Equatable, Sendable {
    public var fullscreen = false
    public var vsync = true
    /// config.ini's Shader: a preset's path, or "" for none.
    public var shader = ""
    public var widescreen = Widescreen.fit
    /// The energy and minimap at the window's edges; false keeps them over the original picture.
    public var hudAtEdges = true

    public init() {}

    public init(config: IniFile, video: IniFile) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            config.value(key, in: "Graphics").map { ["1", "true", "on", "yes"].contains($0.lowercased()) } ?? fallback
        }
        fullscreen = flag("Fullscreen", false)
        vsync = flag("VSync", true)
        shader = config.value("Shader", in: "Graphics") ?? ""
        let enhanced = video.value("EnhancedRenderer", in: Self.videoSection).map { $0 != "0" } ?? true
        let aspect = video.value("Aspect", in: Self.videoSection).flatMap { value in
            Widescreen.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame && $0 != .off }
        } ?? .fit
        widescreen = enhanced ? aspect : .off
        hudAtEdges = video.value("HudAnchored", in: Self.videoSection).map { $0 != "0" } ?? true
    }

    static let videoSection = "SuperMetroidVideo"

    public func apply(config: inout IniFile, video: inout IniFile) {
        config.set("Fullscreen", to: fullscreen ? "1" : "0", in: "Graphics")
        config.set("VSync", to: vsync ? "1" : "0", in: "Graphics")
        config.set("Shader", to: shader, in: "Graphics")
        // Filters draw only in the game's OpenGL presenter, which Auto picks; an SDL driver (metal, software) has none.
        if !shader.isEmpty, let renderer = config.value("Renderer", in: "Graphics")?.lowercased(),
           !["", "auto", "opengl"].contains(renderer) {
            config.set("Renderer", to: "auto", in: "Graphics")
        }
        video.set("EnhancedRenderer", to: widescreen == .off ? "0" : "1", in: Self.videoSection)
        // Off keeps the last shape, so turning widescreen back on finds it.
        if widescreen != .off { video.set("Aspect", to: widescreen.rawValue, in: Self.videoSection) }
        video.set("HudAnchored", to: hudAtEdges ? "1" : "0", in: Self.videoSection)
    }

    // MARK: Files

    public static func configFile(game: URL) -> URL { game.appending(path: "config.ini") }
    public static func videoFile(game: URL) -> URL { game.appending(path: "sm-video.ini") }

    private static func read(_ file: URL, separator: String) -> IniFile {
        IniFile(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "", separator: separator)
    }

    /// The settings in a profile's game folder; the game's defaults for a file it hasn't written yet.
    public static func read(game: URL) -> DisplaySettings {
        DisplaySettings(config: read(configFile(game: game), separator: " = "), video: read(videoFile(game: game), separator: "="))
    }

    /// Writes only the launcher's keys; every other line of both files stays as it was.
    public func write(game: URL) throws {
        var config = Self.read(Self.configFile(game: game), separator: " = ")
        var video = Self.read(Self.videoFile(game: game), separator: "=")
        apply(config: &config, video: &video)
        try config.text.write(to: Self.configFile(game: game), atomically: true, encoding: .utf8)
        try video.text.write(to: Self.videoFile(game: game), atomically: true, encoding: .utf8)
    }
}


/// The sound settings the launcher shows for a profile (S-011): config.ini's [Sound] EnableAudio and
/// Volume, 0 to 100. In the game, Keypad + and Keypad - move the volume too, in steps of 5.
public struct SoundSettings: Equatable, Sendable {
    public var enabled = true
    /// Kept within 0 to 100 when read and when written.
    public var volume = 100

    public static let volumeRange = 0...100

    public init() {}

    public init(config: IniFile) {
        enabled = config.value("EnableAudio", in: Self.section).map { ["1", "true", "on", "yes"].contains($0.lowercased()) } ?? true
        volume = config.value("Volume", in: Self.section).flatMap { Double($0) }.map { Self.clamp(Int($0.rounded())) } ?? 100
    }

    static let section = "Sound"

    public static func clamp(_ volume: Int) -> Int {
        min(max(volume, volumeRange.lowerBound), volumeRange.upperBound)
    }

    public func apply(config: inout IniFile) {
        config.set("EnableAudio", to: enabled ? "1" : "0", in: Self.section)
        config.set("Volume", to: String(Self.clamp(volume)), in: Self.section)
    }

    /// The settings in a profile's game folder; the game's defaults for a file it hasn't written yet.
    public static func read(game: URL) -> SoundSettings {
        let file = DisplaySettings.configFile(game: game)
        return SoundSettings(config: IniFile(text: (try? String(contentsOf: file, encoding: .utf8)) ?? ""))
    }

    /// Writes only these two keys; every other line of config.ini stays as it was.
    public func write(game: URL) throws {
        let file = DisplaySettings.configFile(game: game)
        var config = IniFile(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        apply(config: &config)
        try config.text.write(to: file, atomically: true, encoding: .utf8)
    }
}
