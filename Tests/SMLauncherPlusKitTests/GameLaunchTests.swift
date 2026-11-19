import CryptoKit
import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-004. Made-up ROM bytes; the real one is never written by a test.
@Suite struct GameLaunchTests {
    static let bytes = Data((0..<(64 * 1024)).map { UInt8($0 % 253) })
    static var hash: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GameLaunchTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theCommandPassesTheROMAndTheProfilesConfig() {
        let args = GameLaunch.arguments(rom: URL(fileURLWithPath: "/ROMs/Super Metroid.sfc"),
                                        config: URL(fileURLWithPath: "/Data/Profiles/A/game/config.ini"))
        #expect(args == ["--rom", "/ROMs/Super Metroid.sfc", "--no-launcher", "--config", "/Data/Profiles/A/game/config.ini"])
    }

    @Test func aPlainROMIsPassedInPlace() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "sm.sfc")
        try Self.bytes.write(to: file)
        let rom = ROMCheck.ROM(url: file, kind: .file, member: "", headered: false, sha256: Self.hash)
        let prepared = try GameLaunch.prepareROM(rom, root: folder.appending(path: "tmp"))
        #expect(prepared.url == file)
        #expect(prepared.temporaryFolder == nil)
        prepared.discard()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aZippedROMIsUnpackedPrivatelyAndDiscarded() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.bytes.write(to: folder.appending(path: "sm.sfc"))
        let zip = folder.appending(path: "sm.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q", zip.path, "sm.sfc"]
        try process.run()
        process.waitUntilExit()
        let root = folder.appending(path: "tmp", directoryHint: .isDirectory)
        let rom = ROMCheck.ROM(url: zip, kind: .zip, member: "sm.sfc", headered: false, sha256: Self.hash)

        let prepared = try GameLaunch.prepareROM(rom, root: root)
        let temp = try #require(prepared.temporaryFolder)
        #expect(try Data(contentsOf: prepared.url) == Self.bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        prepared.discard()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func a7zROMIsUnpackedPrivatelyAndDiscarded() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.bytes.write(to: folder.appending(path: "sm.sfc"))
        let archive = try ROMCheckTests.sevenZip(folder, ["sm.sfc"], as: "sm.7z")
        let rom = ROMCheck.ROM(url: archive, kind: .sevenZip, member: "sm.sfc", headered: false, sha256: Self.hash)
        let prepared = try GameLaunch.prepareROM(rom, root: folder.appending(path: "tmp", directoryHint: .isDirectory))
        let temp = try #require(prepared.temporaryFolder)
        #expect(try Data(contentsOf: prepared.url) == Self.bytes)
        prepared.discard()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func aHeaderedROMIsPassedWithoutItsHeader() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "sm.smc")
        try (Data(repeating: 0xAA, count: 512) + Self.bytes).write(to: file)
        let rom = ROMCheck.ROM(url: file, kind: .file, member: "", headered: true, sha256: Self.hash)
        let prepared = try GameLaunch.prepareROM(rom, root: folder.appending(path: "tmp"))
        defer { prepared.discard() }
        #expect(prepared.temporaryFolder != nil)
        #expect(try Data(contentsOf: prepared.url) == Self.bytes)
    }

    @Test func aMovedOrChangedROMIsTold() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = ROMCheck.ROM(url: folder.appending(path: "gone.zip"), kind: .zip, member: "sm.sfc", headered: false, sha256: Self.hash)
        #expect(throws: GameLaunch.ROMProblem.missing) { try GameLaunch.prepareROM(gone, root: folder) }
        let file = folder.appending(path: "sm.smc")
        try (Data(repeating: 0, count: 512) + Self.bytes.dropLast() + Data([1])).write(to: file)
        let changed = ROMCheck.ROM(url: file, kind: .file, member: "", headered: true, sha256: Self.hash)
        #expect(throws: GameLaunch.ROMProblem.changed) { try GameLaunch.prepareROM(changed, root: folder.appending(path: "tmp")) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "tmp").path)) ?? [] == [])
    }

    @Test func leftoverCopiesAreRemovedAtLaunch() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "rom-OLD"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "keep.txt"))
        GameLaunch.removeLeftoverROMs(in: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.txt"])
    }
}
