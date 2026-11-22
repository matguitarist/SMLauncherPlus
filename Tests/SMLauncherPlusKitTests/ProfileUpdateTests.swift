import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-031: Update keeps the player's saves, settings, mod choices, packages and logs; Roll Back returns.
@Suite struct ProfileUpdateTests {
    typealias Helper = ProfileBuilderTests

    static let oldConfig = """
    [General]
    # Window scale
    Scale = 3
    Fullscreen = false

    [Sound]
    EnableAudio = false

    """

    static let newConfig = """
    [General]
    # Window scale, 1 to 6
    Scale = 2
    Fullscreen = false
    # New in 0.4.7
    Vsync = true

    [Sound]
    EnableAudio = true
    Volume = 100

    """

    /// A profile on 0.4.6 that the player has used: saves, logs, settings, a mod package of theirs.
    static func playedProfile(in folder: URL) throws -> URL {
        let zip = try Helper.makeZip(in: folder, files: [
            "VERSION": "0.4.6\n",
            "config.ini": oldConfig,
            "README.md": "old readme",
            "mods/preloaded/packages/super-metroid.combat/1.0.0/manifest.toml": "old combat",
        ])
        let profile = folder.appending(path: "Profiles/ABC", directoryHint: .isDirectory)
        let game = try ProfileBuilder.build(zip: zip, profile: profile, info: .init(version: "0.4.6", romSHA256: "rom"))
        try FileManager.default.removeItem(at: zip)
        let fm = FileManager.default
        let files: [String: String] = [
            "saves/save.srm": "samus",
            "logs/sm-replay-1.replay": "replay",
            "keybinds.ini": "[KeyMap]\na = X\n",
            "sm-video.ini": "[SuperMetroidVideo]\nWidescreen=16:9\n",
            "mods/preloaded/state.toml": "format_version = 1\n# mine\n",
            "mods/preloaded/packages/fan.hud/1.2.0/manifest.toml": "fan hud",
            "assets/shaders/crt-soft.glslp": "launcher filter",
        ]
        for (path, text) in files {
            let file = game.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return profile
    }

    static func newRelease(in folder: URL) throws -> URL {
        try Helper.makeZip(in: folder, top: "supermetroid-0.4.7-macos-arm64", files: [
            "VERSION": "0.4.7\n",
            "config.ini": newConfig,
            "README.md": "new readme",
            "sm-video.ini": "[SuperMetroidVideo]\nWidescreen=Fit\n",
            "mods/preloaded/packages/super-metroid.combat/1.1.0/manifest.toml": "new combat",
        ])
    }

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func updateKeepsWhatThePlayerMadeAndTakesTheRest() throws {
        let folder = try Helper.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try Self.playedProfile(in: folder)
        let zip = try Self.newRelease(in: folder)
        let info = try ProfileUpdate.update(zip: zip, profile: profile, info: .init(version: "0.4.7", installedAt: Date(timeIntervalSince1970: 1_800_000_000), romSHA256: "rom"),
                                            keepingPackages: ["fan.hud"])
        let game = profile.appending(path: "game")
        let fm = FileManager.default

        #expect(info.version == "0.4.7" && info.previousVersion == "0.4.6")
        #expect(ProfileBuilder.Info.read(from: profile) == info)
        #expect(Self.read(game.appending(path: "VERSION")) == "0.4.7\n")
        #expect(Self.read(game.appending(path: "README.md")) == "new readme")
        #expect(fm.isExecutableFile(atPath: game.appending(path: ProfileBuilder.executable).path))
        // The player's files
        #expect(Self.read(game.appending(path: "saves/save.srm")) == "samus")
        #expect(Self.read(game.appending(path: "logs/sm-replay-1.replay")) == "replay")
        #expect(Self.read(game.appending(path: "keybinds.ini")) == "[KeyMap]\na = X\n")
        #expect(Self.read(game.appending(path: "sm-video.ini")) == "[SuperMetroidVideo]\nWidescreen=16:9\n")
        #expect(Self.read(game.appending(path: "mods/preloaded/state.toml")) == "format_version = 1\n# mine\n")
        #expect(Self.read(game.appending(path: "mods/preloaded/packages/fan.hud/1.2.0/manifest.toml")) == "fan hud")
        #expect(Self.read(game.appending(path: "assets/shaders/crt-soft.glslp")) == "launcher filter")
        // The game's own packages come from the release only.
        #expect(Self.read(game.appending(path: "mods/preloaded/packages/super-metroid.combat/1.1.0/manifest.toml")) == "new combat")
        #expect(!fm.fileExists(atPath: game.appending(path: "mods/preloaded/packages/super-metroid.combat/1.0.0").path))
        // config.ini: the new keys and comments, with the player's values.
        let config = IniFile(text: Self.read(game.appending(path: "config.ini")) ?? "")
        #expect(config.value("Scale", in: "General") == "3")
        #expect(config.value("Vsync", in: "General") == "true")
        #expect(config.value("EnableAudio", in: "Sound") == "false")
        #expect(config.value("Volume", in: "Sound") == "100")
        #expect(config.text.contains("# New in 0.4.7"))
        // The old build is kept, untouched; no staging is left.
        #expect(Self.read(profile.appending(path: "previous/VERSION")) == "0.4.6\n")
        #expect(try fm.contentsOfDirectory(atPath: profile.path).sorted() == ["game", "previous", "profile.json"])
    }

    @Test func rollBackBringsThePreviousBuildWithTheNewSaves() throws {
        let folder = try Helper.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try Self.playedProfile(in: folder)
        try ProfileUpdate.update(zip: try Self.newRelease(in: folder), profile: profile,
                                 info: .init(version: "0.4.7", romSHA256: "rom"), keepingPackages: ["fan.hud"])
        let game = profile.appending(path: "game")
        try Data("samus after 0.4.7".utf8).write(to: game.appending(path: "saves/save.srm"))

        let info = try #require(try ProfileUpdate.rollBack(profile: profile, keepingPackages: ["fan.hud"]))
        #expect(info.version == "0.4.6" && info.previousVersion == nil)
        #expect(Self.read(game.appending(path: "VERSION")) == "0.4.6\n")
        #expect(Self.read(game.appending(path: "saves/save.srm")) == "samus after 0.4.7")
        #expect(Self.read(game.appending(path: "mods/preloaded/packages/fan.hud/1.2.0/manifest.toml")) == "fan hud")
        #expect(!FileManager.default.fileExists(atPath: game.appending(path: "mods/preloaded/packages/super-metroid.combat/1.1.0").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted() == ["game", "profile.json"])
        #expect(try ProfileUpdate.rollBack(profile: profile, keepingPackages: []) == nil)
    }

    @Test func aBrokenReleaseLeavesTheProfileAsItWas() throws {
        let folder = try Helper.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try Self.playedProfile(in: folder)
        let broken = try Helper.makeZip(in: folder, files: ["README.md": "no game"], executable: false)
        #expect(throws: ProfileBuilder.Failure.missingExecutable) {
            try ProfileUpdate.update(zip: broken, profile: profile, info: .init(version: "0.4.7", romSHA256: "rom"), keepingPackages: [])
        }
        #expect(Self.read(profile.appending(path: "game/VERSION")) == "0.4.6\n")
        #expect(Self.read(profile.appending(path: "game/saves/save.srm")) == "samus")
        #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted() == ["game", "profile.json"])
    }

    @Test func mergingKeepsTheReleaseLinesThePlayerDidntChange() {
        let release = "[KeyMap]\nLoad =      F1,     F2\nPause = p\n"
        let player = "[KeyMap]\nLoad = F1, F2\nPause = q\n"
        // "F1,     F2" differs from "F1, F2" as text, so the player's line wins; Pause too.
        #expect(IniFile.merge(player: player, release: release) == "[KeyMap]\nLoad = F1, F2\nPause = q\n")
        #expect(IniFile.merge(player: release, release: release) == release)
        #expect(IniFile.merge(player: "[New]\nKey = 1\n", release: "[A]\nB = 2\n") == "[A]\nB = 2\n\n[New]\nKey = 1\n")
    }
}
