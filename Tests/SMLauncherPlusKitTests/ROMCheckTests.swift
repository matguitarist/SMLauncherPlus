import CryptoKit
import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-001. Made-up ROMs stand in for the real one: the bytes are never in the repo.
/// Set SM_ROM_PATH to the player's own ROM (a .sfc, .smc or .zip) to check it too.
@Suite struct ROMCheckTests {
    /// A 3 MB LoROM with a valid header: zeros, then a title, a country and a checksum pair.
    static func fakeROM(title: String = "Super Metroid", country: UInt8 = 0, size: Int = SupportedROM.size, fill: UInt8 = 0) -> Data {
        var data = Data(repeating: fill, count: size)
        let header = 0x7FC0
        let padded = Array((title + String(repeating: " ", count: 21)).utf8.prefix(21))
        data.replaceSubrange(header..<header + 21, with: padded)
        data[header + 0x19] = country
        data[header + 0x1C] = 0x20; data[header + 0x1D] = 0x07  // complement
        data[header + 0x1E] = 0xDF; data[header + 0x1F] = 0xF8  // checksum
        return data
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func expect(_ data: Data, toFailWith problem: ROMCheck.Problem, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: problem, sourceLocation: sourceLocation) { try ROMCheck.identify(data) }
    }

    @Test func theSupportedROMIsAccepted() throws {
        let rom = Self.fakeROM()
        let result = try ROMCheck.identify(rom, supported: Self.sha(rom))
        #expect(result.headered == false)
        #expect(result.sha256 == Self.sha(rom))
    }

    @Test func aCopierHeaderIsSkipped() throws {
        let rom = Self.fakeROM()
        let result = try ROMCheck.identify(Data(repeating: 0xAA, count: 512) + rom, supported: Self.sha(rom))
        #expect(result.headered)
        #expect(result.sha256 == Self.sha(rom))
    }

    @Test func eachWrongFileGetsItsReason() {
        Self.expect(Self.fakeROM(fill: 1), toFailWith: .patched)
        Self.expect(Self.fakeROM(size: 4 * 1024 * 1024), toFailWith: .patched)  // an expanded hack
        Self.expect(Self.fakeROM(country: 2), toFailWith: .otherVersion)
        Self.expect(Self.fakeROM(title: "ZELDA"), toFailWith: .otherGame("ZELDA"))
        Self.expect(Data(repeating: 0, count: SupportedROM.size), toFailWith: .notROM)
        Self.expect(Data("not a rom".utf8), toFailWith: .wrongSize)
        Self.expect(Data(repeating: 0, count: SupportedROM.size + 100), toFailWith: .wrongSize)
    }

    @Test func otherFileTypesAreRefused() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        #expect(throws: ROMCheck.Problem.notROM) { try ROMCheck.check(text) }
    }

    @Test func aZipIsReadWithoutUnpacking() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.fakeROM(title: "ZELDA").write(to: folder.appending(path: "Zelda [!].sfc"))
        let zip = try Self.zip(folder, ["Zelda [!].sfc"], as: "one.zip")
        try FileManager.default.removeItem(at: folder.appending(path: "Zelda [!].sfc"))
        // The ROM inside is read: its header names the game.
        #expect(throws: ROMCheck.Problem.otherGame("ZELDA")) { try ROMCheck.check(zip) }
        // And nothing was unpacked next to the zip.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["one.zip"])
    }

    @Test func aZipMustHoldExactlyOneROM() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appending(path: "readme.txt"))
        try Self.fakeROM().write(to: folder.appending(path: "a.sfc"))
        try Self.fakeROM().write(to: folder.appending(path: "b.smc"))
        let none = try Self.zip(folder, ["readme.txt"], as: "none.zip")
        let two = try Self.zip(folder, ["a.sfc", "b.smc"], as: "two.zip")
        #expect(throws: ROMCheck.Problem.zipWithoutROM) { try ROMCheck.check(none) }
        #expect(throws: ROMCheck.Problem.zipWithSeveralROMs) { try ROMCheck.check(two) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SM_ROM_PATH"] != nil))
    func thePlayersOwnROMIsAccepted() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SM_ROM_PATH"]!)
        let rom = try ROMCheck.check(url)
        #expect(rom.sha256 == SupportedROM.sha256)
    }

    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ROMCheckTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func zip(_ folder: URL, _ files: [String], as name: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q", name] + files
        try process.run()
        process.waitUntilExit()
        return folder.appending(path: name)
    }
}

extension ROMCheckTests {
    @Test func onlyPatchedAndOtherRegionCountAsSuperMetroid() {
        #expect(ROMCheck.Problem.patched.isSuperMetroid)
        #expect(ROMCheck.Problem.otherVersion.isSuperMetroid)
        for problem: ROMCheck.Problem in [.notROM, .unreadable, .zipWithoutROM, .zipWithSeveralROMs, .wrongSize, .otherGame("ZELDA")] {
            #expect(!problem.isSuperMetroid)
        }
    }
}
