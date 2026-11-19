import Foundation
import Testing
@testable import SMLauncherPlusKit

@Suite struct ControlsTests {
    static let config = """
    [KeyMap]
    # Leave a value empty to unbind the hotkey entirely (e.g. "DisplayPerf =").
    Fullscreen = Alt+Return
    Pause = Shift+p
    PauseDimmed = p
    Turbo = Tab
    DisplayPerf = f
    Load =      F1,     F2,     F3

    [GamepadMap]
    EnableGamepad1 = true
    # Analog stick deadzone (raw axis units, range 1-32767).
    GamepadDeadzone = 3277
    Controls =   DpadUp, DpadDown, DpadLeft, DpadRight, Back, Start, B, A, Y, X, Lb, Rb
    ControlsP2 = DpadUp, DpadDown, DpadLeft, DpadRight, Back, Start, B, A, Y, X, Lb, Rb

    """

    static var keybinds: String { ControlSettings.defaultKeybinds }

    @Test func theGamesFilesReadAsTheDefaults() {
        let settings = ControlSettings(config: IniFile(text: Self.config), keybinds: IniFile(text: Self.keybinds))
        #expect(settings == ControlSettings())
        #expect(settings.keys[.select] == "Right Shift" && settings.buttons[.b] == "A")
    }

    @Test func untouchedFilesRoundTripWithoutLoss() {
        var config = IniFile(text: Self.config)
        var keybinds = IniFile(text: Self.keybinds, keyWidth: 7)
        ControlSettings(config: config, keybinds: keybinds).apply(config: &config, keybinds: &keybinds)
        #expect(config.text == Self.config)
        #expect(keybinds.text == IniFile(text: Self.keybinds).text)
    }

    @Test func aChangedKeyAndButtonRewriteOnlyTheirLines() {
        var config = IniFile(text: Self.config)
        var keybinds = IniFile(text: Self.keybinds, keyWidth: 7)
        var settings = ControlSettings(config: config, keybinds: keybinds)
        settings.keys[.a] = "D"
        settings.keys[.select] = "None"
        settings.buttons[.l] = "L2"
        settings.apply(config: &config, keybinds: &keybinds)
        #expect(config.text == Self.config.replacingOccurrences(
            of: "Controls =   DpadUp, DpadDown, DpadLeft, DpadRight, Back, Start, B, A, Y, X, Lb, Rb\nControlsP2",
            with: "Controls = DpadUp, DpadDown, DpadLeft, DpadRight, Back, Start, B, A, Y, X, L2, Rb\nControlsP2"))
        // Player 2 keeps its keys; player 1's lines keep the game's alignment.
        var expected = IniFile(text: Self.keybinds).text
        let p1 = expected.range(of: "[player2]")!.lowerBound
        expected.replaceSubrange(..<p1, with: expected[..<p1]
            .replacingOccurrences(of: "a       = X\n", with: "a       = D\n")
            .replacingOccurrences(of: "select  = Right Shift\n", with: "select  = None\n"))
        #expect(keybinds.text == expected)
        #expect(ControlSettings(config: config, keybinds: keybinds) == settings)
    }

    @Test func combinationsAndAliasesAreKeptAsWritten() {
        let text = Self.config.replacingOccurrences(of: "Back, Start, B, A, Y, X, Lb, Rb\nControlsP2", with: "Back+Start, Start, B, A, Y, X, L1, Rb\nControlsP2")
        var config = IniFile(text: text)
        var keybinds = IniFile(text: Self.keybinds, keyWidth: 7)
        var settings = ControlSettings(config: config, keybinds: keybinds)
        #expect(settings.buttons[.select] == "Back+Start" && settings.buttons[.l] == "L1")
        settings.buttons[.r] = "R2"
        settings.apply(config: &config, keybinds: &keybinds)
        #expect(config.value("Controls", in: "GamepadMap") == "DpadUp, DpadDown, DpadLeft, DpadRight, Back+Start, Start, B, A, Y, X, L1, R2")
    }

    @Test func aShortControlsLineLeavesTheRestAtTheirDefaults() {
        let config = IniFile(text: "[GamepadMap]\nControls = DpadUp, DpadDown\n")
        #expect(ControlSettings(config: config, keybinds: IniFile(text: "")) == ControlSettings())
    }

    @Test func keyNamesAreComparedWithoutCase() {
        var config = IniFile(text: Self.config)
        var keybinds = IniFile(text: Self.keybinds.replacingOccurrences(of: "start   = Return", with: "start   = return"), keyWidth: 7)
        let before = keybinds.text
        var settings = ControlSettings(config: config, keybinds: keybinds)
        settings.keys[.start] = "Return"
        settings.apply(config: &config, keybinds: &keybinds)
        #expect(keybinds.text == before)
    }

    @Test func sharedKeysAndHotkeysAreFound() {
        var settings = ControlSettings()
        settings.keys[.y] = "X"
        #expect(settings.buttons(sharingKeyOf: .a) == [.y])
        #expect(settings.buttons(sharingKeyOf: .b).isEmpty)
        settings.keys[.l] = "None"
        settings.keys[.r] = "None"
        #expect(settings.buttons(sharingKeyOf: .l).isEmpty)
        let config = IniFile(text: Self.config)
        #expect(ControlSettings.hotkeys(using: "f", in: config) == ["DisplayPerf"])
        #expect(ControlSettings.hotkeys(using: "P", in: config) == ["PauseDimmed"])
        #expect(ControlSettings.hotkeys(using: "F2", in: config) == ["Load"])
        #expect(ControlSettings.hotkeys(using: "Return", in: config).isEmpty)
    }

    @Test func macKeyCodesGiveSDLsNames() {
        #expect(SDLKeyName.name(macKeyCode: 7) == "X")
        #expect(SDLKeyName.name(macKeyCode: 60) == "Right Shift")
        #expect(SDLKeyName.name(macKeyCode: 36) == "Return")
        #expect(SDLKeyName.name(macKeyCode: 69) == "Keypad +")
        #expect(SDLKeyName.name(macKeyCode: 126) == "Up")
        #expect(SDLKeyName.name(macKeyCode: 63) == nil)
        // Every default key can be pressed again on a Mac keyboard.
        let names = Set((0...127).compactMap { SDLKeyName.name(macKeyCode: UInt16($0)) })
        #expect(Set(ControlSettings.defaultKeys.values).isSubset(of: names))
    }

    @Test func aProfileWithoutKeybindsGetsTheGamesFile() throws {
        let game = FileManager.default.temporaryDirectory.appending(path: "SMLauncherPlus-controls-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: game) }
        try Data(Self.config.utf8).write(to: game.appending(path: "config.ini"))
        var settings = ControlSettings.read(game: game)
        settings.keys[.b] = "Space"
        try settings.write(game: game)
        let written = try String(contentsOf: game.appending(path: "keybinds.ini"), encoding: .utf8)
        #expect(written.hasPrefix("# SNES Controller Keybinds\n"))
        #expect(written.contains("rebind one if you do.\n\n[player1]\n"))
        #expect(written.contains("[player1]\na       = X\nb       = Space\n"))
        #expect(written.contains("[player2]\na       = X\nb       = Z\n"))
        #expect(try String(contentsOf: game.appending(path: "config.ini"), encoding: .utf8) == Self.config)
        #expect(ControlSettings.read(game: game) == settings)
    }
}
