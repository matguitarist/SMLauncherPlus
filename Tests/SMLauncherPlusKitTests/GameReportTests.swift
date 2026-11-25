import Foundation
import ProcessKit
import LogKit
import Testing
@testable import SMLauncherPlusKit

/// S-005. A made-up game folder with the files the game leaves after a run.
@Suite struct GameReportTests {
    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GameReportTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "logs"), withIntermediateDirectories: true)
        return folder
    }

    @Test func aFailureIsAnExitCodeOrANewCrashFile() {
        #expect(!GameReport.isFailure(status: 0, stoppedByUser: false, crashFilesBefore: [], after: []))
        #expect(GameReport.isFailure(status: 6, stoppedByUser: false, crashFilesBefore: [], after: []))
        #expect(GameReport.isFailure(status: 0, stoppedByUser: false, crashFilesBefore: ["crash_report_1.json"],
                                     after: ["crash_report_1.json", "crash_report_2.json"]))
        #expect(!GameReport.isFailure(status: 0, stoppedByUser: false, crashFilesBefore: ["crash_report_1.json"], after: ["crash_report_1.json"]),
                "an old crash file isn't this run's")
        #expect(!GameReport.isFailure(status: 15, stoppedByUser: true, crashFilesBefore: [], after: ["crash_report_2.json"]),
                "Stop is never a failure")
    }

    @Test func crashFilesAreFound() throws {
        let game = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: game) }
        for name in ["crash_report_20261119.json", "crash_minidump_1.dmp", "config.ini", "crash_report.txt"] {
            try Data().write(to: game.appending(path: name))
        }
        #expect(GameReport.crashFiles(in: game) == ["crash_report_20261119.json", "crash_minidump_1.dmp"])
    }

    @Test func theReportHoldsWhatTheReadmeAsksForAndNeverTheROM() throws {
        let game = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: game) }
        let names = ["logs/sm-replay-20261119-093119-8519-000001.replay", "logs/sm-replay-20261119-093119-8519-000001.replay.sav",
                     "logs/sm-replay-20261119-093119-8519-000001.replay.config.ini", "logs/sm-replay-20261119-093119-8519-000001.replay.mods.txt",
                     "logs/sm-replay-20261118-120000-77-000001.replay", "last_run_report.json", "crash_report_1.json",
                     "crash_minidump_1.dmp", "config.ini", "Super Metroid.sfc", "logs/sm-replay-x-8519-rom.sfc"]
        for name in names { try Data("x".utf8).write(to: game.appending(path: name)) }
        let session = game.appending(path: "session.log")
        try Data("[mods] intro skip: 1/1 hooks\n".utf8).write(to: session)

        let files = GameReport.files(game: game, sessionLog: session, pid: 8519).map(\.lastPathComponent)
        #expect(files == ["session.log",
                          "sm-replay-20261119-093119-8519-000001.replay", "sm-replay-20261119-093119-8519-000001.replay.config.ini",
                          "sm-replay-20261119-093119-8519-000001.replay.mods.txt", "sm-replay-20261119-093119-8519-000001.replay.sav",
                          "crash_minidump_1.dmp", "crash_report_1.json", "last_run_report.json"])

        let out = game.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try GameReport.makeZip(files: GameReport.files(game: game, sessionLog: session, pid: 8519), about: "SM Launcher Plus 0.1.0", in: out)
        let inZip = try Shell.runSync("/usr/bin/zipinfo", ["-1", zip.path]).check().lines
        #expect(inZip.contains("about.txt") && inZip.contains("last_run_report.json") && inZip.count == 9)
        #expect(!inZip.contains { $0.hasSuffix(".sfc") })
        #expect(throws: GameReport.Failure.nothingToReport) { try GameReport.makeZip(files: [], about: "", in: out) }
    }

    @Test func theGamesLinesAreRead() {
        let host = GameReport.parseLine("[host +0.083s] renderer initialized: sdl")
        #expect(host == ParsedLine(time: "00:00:00", level: .info, source: "host", message: "renderer initialized: sdl"))
        #expect(GameReport.parseLine("[host +812.410s] fatal: x")?.time == "00:13:32")
        let document = GameReport.parser.parse("[sm] session\n[host +61.5s] a\n[mods] b\n\n")
        #expect(document.entries.map(\.time) == ["00:00:00", "00:01:01", "00:01:01"])
        #expect(GameReport.parseLine("[mods] intro skip: 1/1 hooks")?.source == "mods")
        #expect(GameReport.parseLine("[Launcher] ROM unreadable: '/x.sfc'")?.level == .error)
        #expect(GameReport.parseLine("[Launcher] Warning: continuing anyway")?.level == .warning)
        #expect(GameReport.parseLine("SM renderer: native=0")?.source == "")
        #expect(GameReport.parseLine("   ") == nil)
    }
}
