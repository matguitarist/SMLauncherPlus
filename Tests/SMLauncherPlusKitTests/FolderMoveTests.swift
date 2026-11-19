import Foundation
import Testing
@testable import SMLauncherPlusKit

struct FolderMoveTests {
    let fm = FileManager.default

    /// A data folder like the real one: profiles, downloads, logs, and the database beside them.
    func makeData() throws -> (root: URL, data: URL) {
        let root = fm.temporaryDirectory.appending(path: "move-\(UUID().uuidString)", directoryHint: .isDirectory)
        let data = root.appending(path: "SMLauncherPlus", directoryHint: .isDirectory)
        try fm.createDirectory(at: data.appending(path: "Profiles/A/game/saves"), withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appending(path: "Downloads/0.4.6"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: data.appending(path: "Profiles/A/game/supermetroid"))
        try Data("save".utf8).write(to: data.appending(path: "Profiles/A/game/saves/sram.srm"))
        try Data("zip".utf8).write(to: data.appending(path: "Downloads/0.4.6/game.zip"))
        try fm.createSymbolicLink(atPath: data.appending(path: "Profiles/A/game/current").path, withDestinationPath: "saves")
        try Data("db".utf8).write(to: data.appending(path: "SMLauncherPlus.store"))
        return (root, data)
    }

    static let database: Set<String> = ["SMLauncherPlus.store", "SMLauncherPlus.store-shm", "SMLauncherPlus.store-wal"]

    @Test func movesProfilesAndDownloadsAndRemovesTheOldFolder() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        try fm.removeItem(at: data.appending(path: "SMLauncherPlus.store"))
        let before = FolderMove.listFiles(in: data)
        let target = root.appending(path: "External", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let moved = try FolderMove.move(data, into: target)
        #expect(moved.lastPathComponent == "SMLauncherPlus")
        #expect(FolderMove.listFiles(in: moved) == before)
        #expect(!fm.fileExists(atPath: data.path))
        #expect(FolderMove.size(of: moved) == 5000 + 4 + 3)
    }

    @Test func leavesTheDatabaseWhereItIs() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let target = root.appending(path: "External", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let moved = try FolderMove.move(data, into: target, keeping: Self.database)
        #expect(fm.fileExists(atPath: moved.appending(path: "Profiles/A/game/saves/sram.srm").path))
        #expect(fm.fileExists(atPath: moved.appending(path: "Downloads/0.4.6/game.zip").path))
        #expect(!fm.fileExists(atPath: moved.appending(path: "SMLauncherPlus.store").path))
        #expect(try fm.contentsOfDirectory(atPath: data.path) == ["SMLauncherPlus.store"])
        #expect(FolderMove.size(of: data, excluding: Self.database) == 0)
    }

    @Test func movesBackIntoTheFolderThatKeptTheDatabase() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let before = FolderMove.listFiles(in: data)
        let target = root.appending(path: "External", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let moved = try FolderMove.move(data, into: target, keeping: Self.database)
        let back = try FolderMove.move(moved, into: root, keeping: Self.database)
        #expect(back.path == data.resolvingSymlinksInPath().path)
        #expect(FolderMove.listFiles(in: back) == before)
        #expect(!fm.fileExists(atPath: moved.path))
    }

    @Test func keepsSymbolicLinksAsLinks() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let moved = try FolderMove.move(data, into: root.appending(path: "Other"), keeping: Self.database)
        #expect(try fm.destinationOfSymbolicLink(atPath: moved.appending(path: "Profiles/A/game/current").path) == "saves")
    }

    @Test func refusesAFolderThatAlreadyHasProfiles() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let target = root.appending(path: "Busy", directoryHint: .isDirectory)
        try fm.createDirectory(at: target.appending(path: "SMLauncherPlus/Profiles"), withIntermediateDirectories: true)
        let before = FolderMove.listFiles(in: data)
        #expect(throws: FolderMove.Failure.destinationExists("SMLauncherPlus/Profiles")) { try FolderMove.move(data, into: target) }
        #expect(FolderMove.listFiles(in: data) == before)
    }

    @Test func refusesAFileWithTheFolderName() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let target = root.appending(path: "Busy", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appending(path: "SMLauncherPlus"))
        #expect(throws: FolderMove.Failure.destinationExists("SMLauncherPlus")) { try FolderMove.move(data, into: target) }
    }

    @Test func refusesToMoveIntoItself() throws {
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        #expect(throws: FolderMove.Failure.insideItself) { try FolderMove.move(data, into: data.appending(path: "Profiles")) }
    }

    /// A failed move leaves the old folder intact: an unreadable file stops the copy to another disk,
    /// or a rename that can't happen on the same disk is undone.
    @Test func aFailedMoveLeavesTheOldFolderIntact() throws {
        let (root, data) = try makeData()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.appending(path: "Profiles").path)
            try? fm.removeItem(at: root)
        }
        let before = FolderMove.listFiles(in: data)
        let target = root.appending(path: "Locked", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Profiles can't be renamed out of a folder we may not write to: lock the data folder itself.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: data.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path) }
        #expect(throws: FolderMove.Failure.self) { try FolderMove.move(data, into: target, keeping: Self.database) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        #expect(FolderMove.listFiles(in: data) == before)
        #expect(!fm.fileExists(atPath: target.appending(path: "SMLauncherPlus").path))
    }

    /// Another disk: set MOVE_VOLUME=/Volumes/<disk> to run the copy-verify-delete path for real.
    @Test func movesToAnotherDisk() throws {
        guard let volume = ProcessInfo.processInfo.environment["MOVE_VOLUME"] else { return }
        let (root, data) = try makeData()
        defer { try? fm.removeItem(at: root) }
        let target = URL(fileURLWithPath: volume).appending(path: "move-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: target) }
        let before = FolderMove.listFiles(in: data, excluding: Self.database)
        let moved = try FolderMove.move(data, into: target, keeping: Self.database)
        #expect(FolderMove.listFiles(in: moved) == before)
        #expect(try fm.contentsOfDirectory(atPath: data.path) == ["SMLauncherPlus.store"])
        #expect(!fm.fileExists(atPath: target.appending(path: "SMLauncherPlus.partial").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: moved.appending(path: "Profiles/A/game/current").path) == "saves")
        let back = try FolderMove.move(moved, into: root, keeping: Self.database)
        #expect(FolderMove.listFiles(in: back, excluding: Self.database) == before)
    }
}
