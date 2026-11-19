import Foundation

/// A button of the SNES pad. The cases are in the order of the game's [GamepadMap] Controls line;
/// the raw values are keybinds.ini's keys.
public enum SNESButton: String, CaseIterable, Sendable, Identifiable {
    case up, down, left, right, select, start, a, b, x, y, l, r

    public var id: String { rawValue }

    /// The order the Controls tab lists them: the pad, the face buttons, the shoulders, then Start and Select.
    public static let display: [SNESButton] = [.up, .down, .left, .right, .b, .y, .a, .x, .l, .r, .start, .select]
}

/// Player 1's keyboard keys and controller buttons (S-012). The keys live in keybinds.ini's [player1]
/// as SDL key names; the buttons in config.ini's [GamepadMap] Controls as SDL controller button names,
/// where a value can also be a combination such as "Back+Start". Both files sit next to the game.
public struct ControlSettings: Equatable, Sendable {
    /// SDL key names ("X", "Right Shift", "Keypad 4"); "None" leaves the button unbound.
    public var keys: [SNESButton: String]
    /// SDL controller button names ("A", "Lb", "DpadUp"), kept as written.
    public var buttons: [SNESButton: String]

    public init() {
        keys = Self.defaultKeys
        buttons = Self.defaultButtons
    }

    public static let defaultKeys: [SNESButton: String] = [
        .a: "X", .b: "Z", .x: "S", .y: "A", .l: "C", .r: "V", .start: "Return", .select: "Right Shift",
        .up: "Up", .down: "Down", .left: "Left", .right: "Right",
    ]

    /// The game's Xbox-style layout: the buttons sit where the SNES pad has them, so the bottom one is B.
    public static let defaultButtons: [SNESButton: String] = [
        .up: "DpadUp", .down: "DpadDown", .left: "DpadLeft", .right: "DpadRight", .select: "Back", .start: "Start",
        .a: "B", .b: "A", .x: "Y", .y: "X", .l: "Lb", .r: "Rb",
    ]

    static let keySection = "player1"
    static let padSection = "GamepadMap"
    static let padKey = "Controls"

    public init(config: IniFile, keybinds: IniFile) {
        self.init()
        for button in SNESButton.allCases {
            if let key = keybinds.value(button.rawValue, in: Self.keySection) { keys[button] = key }
        }
        // The game reads the line in order and leaves the buttons it doesn't name as they were.
        for (button, value) in zip(SNESButton.allCases, Self.split(config.value(Self.padKey, in: Self.padSection))) {
            buttons[button] = value
        }
    }

    private static func split(_ line: String?) -> [String] {
        guard let line else { return [] }
        return line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Writes only what differs from the files, so an untouched line keeps its spacing and its spelling.
    public func apply(config: inout IniFile, keybinds: inout IniFile) {
        let before = ControlSettings(config: config, keybinds: keybinds)
        for button in SNESButton.allCases {
            let key = keys[button] ?? "None"
            if key.caseInsensitiveCompare(before.keys[button] ?? "") != .orderedSame {
                keybinds.set(button.rawValue, to: key, in: Self.keySection)
            }
        }
        if buttons != before.buttons {
            let line = SNESButton.allCases.map { buttons[$0] ?? Self.defaultButtons[$0]! }.joined(separator: ", ")
            config.set(Self.padKey, to: line, in: Self.padSection)
        }
    }

    // MARK: Conflicts

    /// Other buttons that use the same key.
    public func buttons(sharingKeyOf button: SNESButton) -> [SNESButton] {
        guard let key = keys[button], key.caseInsensitiveCompare("None") != .orderedSame else { return [] }
        return SNESButton.display.filter { $0 != button && keys[$0]?.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The game's shortcuts in config.ini's [KeyMap] that a key without Shift, Ctrl or Alt also starts,
    /// such as DisplayPerf for "f". The game would do both.
    public static func hotkeys(using key: String, in config: IniFile) -> [String] {
        guard key.caseInsensitiveCompare("None") != .orderedSame else { return [] }
        return config.entries(in: "KeyMap").filter { _, value in
            split(value).contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }.map(\.key)
    }

    // MARK: Files

    public static func keybindsFile(game: URL) -> URL { game.appending(path: "keybinds.ini") }

    /// keybinds.ini pads its keys to 7 characters ("select  = Right Shift").
    static let keyColumn = 7

    /// What the game writes when keybinds.ini is missing, so a file the launcher creates first looks the same.
    public static let defaultKeybinds: String = {
        var text = """
        # SNES Controller Keybinds
        # Edit values to customize. Restart the game to apply.
        # Use SDL key names. Common: A B C ... Z, 0-9, F1-F12, Up Down Left Right,
        # Return, Tab, Space, Left Shift, Right Shift, Left Ctrl, Right Ctrl,
        # Backspace, Escape, Backslash. Use "None" to leave a button unbound.
        #
        # Both players default to the same keys. Only a player whose Input
        # source is Keyboard reads them, so this is not a conflict unless you
        # put BOTH players on the keyboard -- rebind one if you do.


        """
        for player in ["player1", "player2"] {
            text += "[\(player)]\n"
            for button in [SNESButton.a, .b, .x, .y, .l, .r, .start, .select, .up, .down, .left, .right] {
                text += button.rawValue.padding(toLength: keyColumn, withPad: " ", startingAt: 0) + " = " + defaultKeys[button]! + "\n"
            }
            text += "\n"
        }
        return text
    }()

    private static func read(_ file: URL, separator: String = " = ", keyWidth: Int = 0, fallback: String = "") -> IniFile {
        IniFile(text: (try? String(contentsOf: file, encoding: .utf8)) ?? fallback, separator: separator, keyWidth: keyWidth)
    }

    public static func read(game: URL) -> ControlSettings {
        ControlSettings(config: read(DisplaySettings.configFile(game: game)), keybinds: read(keybindsFile(game: game)))
    }

    /// Writes only the keys and buttons that changed; every other line of both files stays as it was.
    public func write(game: URL) throws {
        var config = Self.read(DisplaySettings.configFile(game: game))
        var keybinds = Self.read(Self.keybindsFile(game: game), keyWidth: Self.keyColumn, fallback: Self.defaultKeybinds)
        let oldConfig = config.text, oldKeybinds = keybinds.text
        apply(config: &config, keybinds: &keybinds)
        if config.text != oldConfig { try config.text.write(to: DisplaySettings.configFile(game: game), atomically: true, encoding: .utf8) }
        let keybindsMissing = !FileManager.default.fileExists(atPath: Self.keybindsFile(game: game).path)
        if keybinds.text != oldKeybinds || keybindsMissing {
            try keybinds.text.write(to: Self.keybindsFile(game: game), atomically: true, encoding: .utf8)
        }
    }
}

extension IniFile {
    /// Every key and value in a section, in file order.
    public func entries(in section: String) -> [(key: String, value: String)] {
        var inside = false
        var result: [(key: String, value: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inside = trimmed.caseInsensitiveCompare("[\(section)]") == .orderedSame
                continue
            }
            guard inside, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result.append((key, trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces))) }
        }
        return result
    }
}
