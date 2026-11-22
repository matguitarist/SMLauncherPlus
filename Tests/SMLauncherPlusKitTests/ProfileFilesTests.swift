import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-032: rename, duplicate, and delete keeping the saves.
@Suite struct ProfileFilesTests {
    @Test func namesAreCleanedAndCopiesNumbered() {
        #expect(ProfileName.clean("  My   Run \n", fallback: "Super Metroid") == "My Run")
        #expect(ProfileName.clean("   ", fallback: "Super Metroid") == "Super Metroid")
        #expect(ProfileName.copy(of: "Run", existing: ["Run"], suffix: "Copy") == "Run Copy")
        #expect(ProfileName.copy(of: "Run", existing: ["Run", "Run Copy", "Run Copy 2"], suffix: "Copy") == "Run Copy 3")
        let date = Date(timeIntervalSince1970: 1_795_800_000)
        #expect(ProfileName.dated("A/B: C", date: date, timeZone: TimeZone(identifier: "UTC")!) == "A-B- C – 2026-11-27 17-20")
    }

    @Test func aCopyHasTheGameSavesAndSettingsButNotTheRollBackBuild() throws {
        let folder = try ProfileBuilderTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appending(path: "A", directoryHint: .isDirectory)
        for path in ["game/SuperMetroidSNESRecomp", "game/saves/save.srm", "game/config.ini", "profile.json", "previous/VERSION", "update.partial/x"] {
            try FileManager.default.createDirectory(at: profile.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: profile.appending(path: path))
        }
        let copy = folder.appending(path: "B", directoryHint: .isDirectory)
        try ProfileFiles.duplicate(profile, to: copy)
        let files = Set(FileManager.default.subpaths(atPath: copy.path) ?? [])
        #expect(files.isSuperset(of: ["game/SuperMetroidSNESRecomp", "game/saves/save.srm", "game/config.ini", "profile.json"]))
        #expect(!files.contains { $0.hasPrefix("previous") || $0.hasPrefix("update.partial") })
        #expect(throws: (any Error).self) { try ProfileFiles.duplicate(profile, to: copy) }
    }

    @Test func keptSavesTakeTheSettingsAlong() throws {
        let folder = try ProfileBuilderTests.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let game = folder.appending(path: "game", directoryHint: .isDirectory)
        for path in ["saves/save.srm", "config.ini", "keybinds.ini", "mods/preloaded/state.toml"] {
            try FileManager.default.createDirectory(at: game.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: game.appending(path: path))
        }
        #expect(ProfileFiles.hasSaves(game: game))
        let kept = folder.appending(path: "Kept Saves/Run – 2026-11-22 14-05", directoryHint: .isDirectory)
        try ProfileFiles.keepSaves(game: game, in: kept)
        let files = Set(FileManager.default.subpaths(atPath: kept.path) ?? [])
        #expect(files.isSuperset(of: ["saves/save.srm", "config.ini", "keybinds.ini", "mods/preloaded/state.toml"]))
        #expect(!ProfileFiles.hasSaves(game: game))
    }
}
