import Foundation
import ProcessKit
import Testing
@testable import SMLauncherPlusKit

// S-033, ported from AM2R Launcher Plus with Super Metroid's save.srm.

private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

@Test func backupZipsTheSaveFolderWithADate() throws {
    let saves = try folder("Saves/one")
        try write("samus", saves.appending(path: "save.srm"))
    let backups = saves.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5))!
    let zip = try SaveBackup.backup(saves: saves, into: backups, profileName: "Super Metroid", date: date)
    #expect(zip.lastPathComponent == "Super Metroid – 2026-11-03 14-05.zip")
    let again = try SaveBackup.backup(saves: saves, into: backups, profileName: "Super Metroid", label: "before restore", date: date)
    #expect(again.lastPathComponent == "Super Metroid – 2026-11-03 14-05 (before restore).zip")
    let third = try SaveBackup.backup(saves: saves, into: backups, profileName: "Super Metroid", date: date)
    #expect(third.lastPathComponent == "Super Metroid – 2026-11-03 14-05 2.zip")
    #expect(SaveBackup.list(in: backups).count == 3)
    #expect(SaveBackup.list(in: backups).allSatisfy { $0.size > 0 })
}

@Test func restoreReplacesTheSaves() throws {
    let saves = try folder("Saves/one")
        try write("samus", saves.appending(path: "save.srm"))
    let backups = saves.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    let zip = try SaveBackup.backup(saves: saves, into: backups, profileName: "Super Metroid")
    try write("samus later", saves.appending(path: "save.srm"))
    try write("older", saves.appending(path: "save.srm.bak"))
    try SaveBackup.restore(zip, into: saves)
    #expect(read(saves.appending(path: "save.srm")) == "samus")
    #expect(!FileManager.default.fileExists(atPath: saves.appending(path: "save.srm.bak").path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: saves.deletingLastPathComponent().path).filter { $0.hasPrefix("one.") }
    #expect(leftovers.isEmpty)
}

@Test func restoreAcceptsAZippedSaveFolder() throws {
    let dir = try folder("zipped")
    let original = dir.appending(path: "saves", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try write("from another Mac", original.appending(path: "save.srm"))
    let zip = dir.appending(path: "saves.zip")
    try Shell.runSync("/usr/bin/ditto", ["-c", "-k", "--keepParent", original.path, zip.path]).check()
    let saves = try folder("Saves/two")
    try SaveBackup.restore(zip, into: saves)
    #expect(read(saves.appending(path: "save.srm")) == "from another Mac")
}

@Test func aZipWithoutSavesChangesNothing() throws {
    let dir = try folder("other")
    try write("hello", dir.appending(path: "notes.txt"))
    let zip = dir.deletingLastPathComponent().appending(path: "notes.zip")
    try Shell.runSync("/usr/bin/ditto", ["-c", "-k", dir.path, zip.path]).check()
    let saves = try folder("Saves/three")
    try write("keep", saves.appending(path: "save.srm"))
    #expect(throws: SaveBackup.Failure.notABackup) { try SaveBackup.restore(zip, into: saves) }
    #expect(read(saves.appending(path: "save.srm")) == "keep")
    let empty = try folder("Saves/empty")
    #expect(throws: SaveBackup.Failure.noSaves) { try SaveBackup.backup(saves: empty, into: dir, profileName: "x") }
}
