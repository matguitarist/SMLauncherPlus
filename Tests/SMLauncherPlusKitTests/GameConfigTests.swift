import Foundation
import Testing
@testable import SMLauncherPlusKit

@Suite struct GameConfigTests {
    static let config = """
    [General]
    # Run-ahead: frames (0 = off, 1 = usual).
    RunAhead = 0

    [Graphics]
    # FrameBlend: average each presented frame.
    FrameBlend = 0
    VSync = 1
    # Renderer: auto (SDL's pick), opengl (the native GL presenter with GLSL
    Renderer = auto
    # OpenGL GLSL preset path, edited by the launcher's shader dropdown.
    Shader =
    Fullscreen = 0
    NewRenderer = 1

    [KeyMap]
    # Leave a value empty to unbind (e.g. "DisplayPerf =").
    DisplayPerf = f

    """

    @Test func changesOnlyTheKeysAskedForAndKeepsCommentsAndOrder() {
        var ini = IniFile(text: Self.config)
        ini.set("Shader", to: "assets/shaders/crt.glslp", in: "Graphics")
        ini.set("VSync", to: "0", in: "Graphics")
        let expected = Self.config
            .replacingOccurrences(of: "Shader =\n", with: "Shader = assets/shaders/crt.glslp\n")
            .replacingOccurrences(of: "VSync = 1", with: "VSync = 0")
        #expect(ini.text == expected)
    }

    @Test func commentLinesWithAnEqualsSignAreNotKeys() {
        let ini = IniFile(text: Self.config)
        #expect(ini.value("Leave a value empty to unbind (e.g. \"DisplayPerf", in: "KeyMap") == nil)
        #expect(ini.value("DisplayPerf", in: "KeyMap") == "f")
        #expect(ini.value("Shader", in: "Graphics") == "")
    }

    @Test func aDuplicateKeyIsSetEverywhereSoTheLastOneDoesNotWin() {
        var ini = IniFile(text: "[Graphics]\nShader = a\nVSync = 1\nShader =\n")
        #expect(ini.value("Shader", in: "Graphics") == "")
        ini.set("Shader", to: "b", in: "Graphics")
        #expect(ini.text == "[Graphics]\nShader = b\nVSync = 1\nShader = b\n")
    }

    @Test func aMissingKeyGoesAfterTheSectionsLastKey() {
        var ini = IniFile(text: "[A]\nX = 1\n\n[B]\nY = 2\n")
        ini.set("Z", to: "3", in: "A")
        #expect(ini.text == "[A]\nX = 1\nZ = 3\n\n[B]\nY = 2\n")
    }

    @Test func aFreshProfileReadsAsTheGamesDefaults() {
        let settings = DisplaySettings(config: IniFile(text: Self.config), video: IniFile(text: ""))
        #expect(settings == DisplaySettings())
        #expect(settings.widescreen == .fit && settings.hudAtEdges && settings.vsync && !settings.fullscreen && settings.shader.isEmpty)
    }

    @Test func settingsRoundTripThroughBothFiles() {
        var config = IniFile(text: Self.config)
        var video = IniFile(text: "", separator: "=")
        var settings = DisplaySettings()
        settings.fullscreen = true
        settings.vsync = false
        settings.shader = "assets/shaders/scanlines-strong.glslp"
        settings.widescreen = .ultrawide
        settings.hudAtEdges = false
        settings.apply(config: &config, video: &video)
        #expect(video.text == "[SuperMetroidVideo]\nEnhancedRenderer=1\nAspect=21:9\nHudAnchored=0\n")
        #expect(DisplaySettings(config: config, video: video) == settings)
    }

    @Test func widescreenOffKeepsTheLastShape() {
        var config = IniFile(text: Self.config)
        var video = IniFile(text: "[SuperMetroidVideo]\nEnhancedRenderer=1\nAspect=32:9\nPresentationFPS=Auto\n", separator: "=")
        var settings = DisplaySettings(config: config, video: video)
        #expect(settings.widescreen == .superUltrawide)
        settings.widescreen = .off
        settings.apply(config: &config, video: &video)
        #expect(video.text == "[SuperMetroidVideo]\nEnhancedRenderer=0\nAspect=32:9\nPresentationFPS=Auto\nHudAnchored=1\n")
        #expect(DisplaySettings(config: config, video: video).widescreen == .off)
    }

    @Test func aFilterMovesAnSDLRendererBackToAuto() {
        var config = IniFile(text: Self.config.replacingOccurrences(of: "Renderer = auto", with: "Renderer = metal"))
        var video = IniFile(text: "", separator: "=")
        var settings = DisplaySettings()
        settings.apply(config: &config, video: &video)
        #expect(config.value("Renderer", in: "Graphics") == "metal")
        settings.shader = "assets/shaders/crt.glslp"
        settings.apply(config: &config, video: &video)
        #expect(config.value("Renderer", in: "Graphics") == "auto")
    }

    @Test func theFilterListComesFromTheProfilesShaderFolder() throws {
        let game = FileManager.default.temporaryDirectory.appending(path: "SMLauncherPlus-shaders-\(UUID())", directoryHint: .isDirectory)
        let folder = game.appending(path: "assets/shaders/.src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: game) }
        for name in ["crt.glslp", "crt-strong.glslp", "scanlines.glslp", "scanlines-light.glslp", "crt-light.glslp", "warm.glslp", "notes.txt"] {
            try Data().write(to: game.appending(path: "assets/shaders/\(name)"))
        }
        try Data().write(to: folder.appending(path: "crt.glsl"))
        let list = ShaderPreset.list(game: game)
        #expect(list.map(\.path) == ["scanlines-light", "scanlines", "crt-light", "crt", "crt-strong", "warm"].map { "assets/shaders/\($0).glslp" })
        #expect(list[4].look == "crt" && list[4].strength == "strong")
        #expect(ShaderPreset.list(game: game.appending(path: "nothing")).isEmpty)
    }
}
