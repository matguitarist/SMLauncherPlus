import Foundation
import LogKit

/// Why the game stopped, and the bug report the game's README asks for (S-005).
/// README, "Reporting a gameplay problem": the session log, every matching `logs/sm-replay-*` file,
/// `last_run_report.json`, and any `crash_report_*.json` or `crash_minidump_*.dmp`. Never the ROM.
public enum GameReport {
    /// The crash files in the game folder now. Compared before and after a run.
    public static func crashFiles(in game: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: game.path)) ?? []
        return Set(names.filter(isCrashFile))
    }

    static func isCrashFile(_ name: String) -> Bool {
        (name.hasPrefix("crash_report_") && name.hasSuffix(".json")) || (name.hasPrefix("crash_minidump_") && name.hasSuffix(".dmp"))
    }

    /// An exit code other than 0, or a crash file the run left, is a failure. Stop is never one:
    /// the player asked for it, whatever code the game quit with.
    public static func isFailure(status: Int32, stoppedByUser: Bool, crashFilesBefore: Set<String>, after: Set<String>) -> Bool {
        if stoppedByUser { return false }
        return status != 0 || !after.subtracting(crashFilesBefore).isEmpty
    }

    /// What goes in the report for one run: the launcher's capture of the session log, the replay files of
    /// that process (their names carry its pid), any `logs/sm-*.log` of that process, the run report and crash files.
    public static func files(game: URL, sessionLog: URL?, pid: Int32) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        if let sessionLog, fm.fileExists(atPath: sessionLog.path) { files.append(sessionLog) }
        let logs = game.appending(path: "logs", directoryHint: .isDirectory)
        let marker = "-\(pid)-"
        for name in ((try? fm.contentsOfDirectory(atPath: logs.path)) ?? []).sorted()
        where name.hasPrefix("sm-") && name.contains(marker) {
            files.append(logs.appending(path: name))
        }
        for name in ((try? fm.contentsOfDirectory(atPath: game.path)) ?? []).sorted()
        where name == "last_run_report.json" || isCrashFile(name) {
            files.append(game.appending(path: name))
        }
        return files.filter { !isROM($0) }
    }

    /// A ROM never goes in a report, whatever it's called.
    static func isROM(_ url: URL) -> Bool {
        ["sfc", "smc", "swc", "fig", "zip", "7z"].contains(url.pathExtension.lowercased())
    }

    public enum Failure: Error, Equatable, Sendable {
        case nothingToReport
        case zipFailed
    }

    /// Zips `files` with `about` as about.txt into `folder`, named "SuperMetroidRecomp report <date>.zip".
    public static func makeZip(files: [URL], about: String, in folder: URL, date: Date = .now) throws(Failure) -> URL {
        let fm = FileManager.default
        guard !files.isEmpty else { throw .nothingToReport }
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        var zip = folder.appending(path: "SuperMetroidRecomp report \(stamp).zip")
        var n = 2
        while fm.fileExists(atPath: zip.path) {
            zip = folder.appending(path: "SuperMetroidRecomp report \(stamp) \(n).zip")
            n += 1
        }
        let staging = fm.temporaryDirectory.appending(path: "SMLauncherPlus-report-\(UUID())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data(about.utf8).write(to: staging.appending(path: "about.txt"))
        } catch { throw .zipFailed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -j: the files side by side, without the player's folder names. -q quiet.
        process.arguments = ["-q", "-j", zip.path, staging.appending(path: "about.txt").path] + files.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw .zipFailed }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: zip)
            throw .zipFailed
        }
        return zip
    }

    /// Reads the game's own output: "[host +0.083s] renderer initialized", "[mods] intro skip: 1/1 hooks",
    /// "[Launcher] ROM unreadable: …", or a plain line. Every line is an entry.
    /// Lines without a time take the last one seen, so the columns line up.
    public static let parser = GameLogParser()

    public static func parseLine(_ line: Substring) -> ParsedLine? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var source = ""
        var time: String?
        var message = Substring(text)
        if text.first == "[", let close = text.firstIndex(of: "]") {
            let tag = text[text.index(after: text.startIndex)..<close]
            let parts = tag.split(separator: " ", maxSplits: 1)
            source = String(parts.first ?? "")
            if parts.count == 2, parts[1].hasPrefix("+"), parts[1].hasSuffix("s"), let seconds = Double(parts[1].dropFirst().dropLast()) {
                time = elapsed(seconds)
            } else if parts.count == 2 {
                source = String(tag)
            }
            message = text[text.index(after: close)...].drop { $0 == " " }
        }
        return ParsedLine(time: time, level: level(of: message), source: source, message: String(message))
    }

    /// "+812.410s" → "00:13:32": one width for every line.
    static func elapsed(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    static func level(of message: Substring) -> LogLevel {
        let lower = message.lowercased()
        if ["error", "failed", "fatal", "crash", "unreadable", "cannot ", "can't "].contains(where: lower.contains) { return .error }
        if ["warning", "warn:"].contains(where: lower.contains) { return .warning }
        return .info
    }
}

/// The game's log as entries, every one with a time: lines the game wrote without one take the
/// last time seen (00:00:00 before the first).
public struct GameLogParser: LogParser {
    public func parse(_ text: String) -> LogDocument {
        var entries: [LogEntry] = []
        var last = GameReport.elapsed(0)
        LogLines.forEach(in: text) { line in
            guard let parsed = GameReport.parseLine(line) else { return }
            let time = parsed.time ?? last
            last = time
            entries.append(LogEntry(id: entries.count, time: time, level: parsed.level, source: parsed.source, message: parsed.message))
        }
        return LogDocument(entries: entries)
    }
}
