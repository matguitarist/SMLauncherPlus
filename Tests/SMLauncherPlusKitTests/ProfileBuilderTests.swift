import Foundation
import ProcessKit
import Testing
@testable import SMLauncherPlusKit

/// S-003. A made-up release zip stands in for the real one: a top folder with a shell script
/// named like the game, its libs and a config.ini.
@Suite struct ProfileBuilderTests {
    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ProfileBuilderTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Zips `files` (path -> contents) under `top/` with /usr/bin/zip, keeping links as links.
    static func makeZip(in folder: URL, top: String = "supermetroid-0.4.6-macos-arm64", files: [String: String],
                        executable: Bool = true, links: [String: String] = [:]) throws -> URL {
        let source = folder.appending(path: "source", directoryHint: .isDirectory)
        let base = source.appending(path: top, directoryHint: .isDirectory)
        for (path, contents) in files {
            let file = base.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        if executable {
            let game = base.appending(path: ProfileBuilder.executable)
            try Data("#!/bin/sh\necho game\n".utf8).write(to: game)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: game.path)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(atPath: base.appending(path: path).path, withDestinationPath: target)
        }
        let zip = folder.appending(path: "release.zip")
        try Shell.runSync("/usr/bin/zip", ["-q", "-r", "-y", zip.path, top], in: source).check()
        try FileManager.default.removeItem(at: source)
        return zip
    }

    @Test func theZipUnpacksIntoTheProfilesGameFolder() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder, files: ["config.ini": "[General]\n", "libs/libpng16.16.dylib": "png"])
        let profile = folder.appending(path: "Profiles/ABC", directoryHint: .isDirectory)
        let info = ProfileBuilder.Info(version: "0.4.6", installedAt: Date(timeIntervalSince1970: 1_800_000_000), romSHA256: SupportedROM.sha256)
        let game = try ProfileBuilder.build(zip: zip, profile: profile, info: info)

        #expect(game == profile.appending(path: "game", directoryHint: .isDirectory))
        #expect(FileManager.default.isExecutableFile(atPath: game.appending(path: "SuperMetroidSNESRecomp").path))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "libs/libpng16.16.dylib").path))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "config.ini").path))
        #expect(ProfileBuilder.Info.read(from: profile) == info)
        #expect(!ProfileBuilder.isQuarantined(game.appending(path: "SuperMetroidSNESRecomp")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Profiles").path) == ["ABC"])
    }

    @Test func pathsThatEscapeTheFolderAreRefused() throws {
        #expect(throws: ProfileBuilder.Failure.unsafePath("a/../../evil")) { try ProfileBuilder.commonRoot(of: ["a/", "a/../../evil"]) }
        #expect(throws: ProfileBuilder.Failure.unsafePath("/etc/passwd")) { try ProfileBuilder.commonRoot(of: ["/etc/passwd"]) }
        #expect(throws: ProfileBuilder.Failure.unsafePath("..\\evil")) { try ProfileBuilder.commonRoot(of: ["..\\evil"]) }
        #expect(try ProfileBuilder.commonRoot(of: ["sm/", "sm/game", "sm/libs/a.dylib"]) == "sm/")
        #expect(try ProfileBuilder.commonRoot(of: ["game", "libs/a.dylib"]) == "")
    }

    @Test func aLinkPointingOutsideIsRefusedAndNothingIsKept() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder, files: ["config.ini": ""], links: ["escape": "/etc"])
        let profile = folder.appending(path: "Profiles/ABC", directoryHint: .isDirectory)
        #expect(throws: ProfileBuilder.Failure.unsafePath("supermetroid-0.4.6-macos-arm64/escape")) {
            try ProfileBuilder.build(zip: zip, profile: profile, info: .init(version: "0.4.6", romSHA256: ""))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Profiles/ABC").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Profiles/ABC.partial").path))
    }

    @Test func aZipWithoutTheGameIsRefused() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder, files: ["README.md": "hi"], executable: false)
        #expect(throws: ProfileBuilder.Failure.missingExecutable) {
            try ProfileBuilder.build(zip: zip, profile: folder.appending(path: "P"), info: .init(version: "1", romSHA256: ""))
        }
        let notZip = folder.appending(path: "not.zip")
        try Data("nope".utf8).write(to: notZip)
        #expect(throws: ProfileBuilder.Failure.unreadableZip) {
            try ProfileBuilder.build(zip: notZip, profile: folder.appending(path: "P"), info: .init(version: "1", romSHA256: ""))
        }
    }

    @Test func aQuarantineFlagIsCleared() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "game")
        try Data().write(to: file)
        let flag = "0081;00000000;Safari;"
        _ = flag.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
        #expect(ProfileBuilder.isQuarantined(file))
        ProfileBuilder.clearQuarantine(in: folder)
        #expect(!ProfileBuilder.isQuarantined(file))
    }
}
