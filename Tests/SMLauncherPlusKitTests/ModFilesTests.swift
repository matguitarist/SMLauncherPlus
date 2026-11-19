import Foundation
import Testing
@testable import SMLauncherPlusKit

struct ModFilesTests {
    let fm = FileManager.default

    func makeWork() throws -> URL {
        let work = fm.temporaryDirectory.appending(path: "modfiles-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    @discardableResult
    func run(_ tool: String, _ arguments: [String], in folder: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A folder with `files`, packed as .zip (zip), .7z (bsdtar) or .7z (7-Zip).
    func pack(_ files: [String: Data], as kind: String, in work: URL) throws -> URL? {
        let source = work.appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (name, data) in files {
            let url = source.appending(path: name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let archive = work.appending(path: "\(UUID().uuidString).\(kind == "zip" ? "zip" : "7z")")
        switch kind {
        case "zip": try run("/usr/bin/zip", ["-q", "-r", archive.path, "."], in: source)
        case "7z": try run("/usr/bin/tar", ["--format", "7zip", "-cf", archive.path, "."], in: source)
        default:
            guard fm.isExecutableFile(atPath: "/opt/homebrew/bin/7zz") else { return nil }
            try run("/opt/homebrew/bin/7zz", ["a", "-bd", archive.path, "."], in: source)
        }
        return archive
    }

    func resource(for body: Data) -> ModResource {
        var resource = ModResource()
        resource.id = "zero-mission"
        resource.filePatterns = "*.gba"
        resource.size = body.count
        resource.normalizedSHA256 = ModResource.normalizedSHA256(of: body)
        resource.required = false
        return resource
    }

    @Test(arguments: ["zip", "7z", "7zz"])
    func aFileInsideAnArchiveIsCheckedLikeTheFileItself(kind: String) throws {
        let work = try makeWork()
        defer { try? fm.removeItem(at: work) }
        let body = Data((0..<70_000).map { UInt8($0 % 253) })
        let resource = resource(for: body)
        guard let good = try pack(["Metroid [Zero] (USA).gba": body, "readme.txt": Data("hi".utf8)], as: kind, in: work) else { return }
        #expect(resource.isArchive(good.path))
        #expect(resource.status(of: good.path) == .verified)
        #expect(try pack(["Metroid (USA).gba": Data(body.reversed())], as: kind, in: work).map { resource.status(of: $0.path) } == .wrongFile)
        #expect(try pack(["readme.txt": Data("hi".utf8)], as: kind, in: work).map { resource.status(of: $0.path) } == .noFileInArchive)
        #expect(try pack(["a.gba": body, "b/c.gba": body], as: kind, in: work).map { resource.status(of: $0.path) } == .severalFilesInArchive)
    }

    @Test func aZipMadeByFinderIgnoresItsExtras() throws {
        let work = try makeWork()
        defer { try? fm.removeItem(at: work) }
        let body = Data(repeating: 3, count: 1000)
        let archive = try #require(try pack(["zm.gba": body, "__MACOSX/._zm.gba": Data([0])], as: "zip", in: work))
        #expect(resource(for: body).status(of: archive.path) == .verified)
    }

    @Test func anArchiveTheResourceAsksForIsNotUnpacked() {
        var resource = ModResource()
        resource.filePatterns = "*.zip"
        #expect(!resource.isArchive("/x/pack.zip"))
        resource.filePatterns = "*.gba"
        #expect(resource.isArchive("/x/pack.ZIP") && resource.isArchive("/x/pack.7z") && !resource.isArchive("/x/zm.gba"))
    }

    /// The game's map-hud setup: two features sharing the Zero Mission file, one turned on.
    func makeGame(in work: URL, path: String) throws -> URL {
        let root = work.appending(path: "game/mods/preloaded", directoryHint: .isDirectory)
        let folder = root.appending(path: "packages/super-metroid.map-hud/1.0.0", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModResourceTests.manifest(hash: String(repeating: "a", count: 64), size: 0)
            .write(to: folder.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
        try """
        format_version = 1

        [[shared_resource]]
        id = "metroid.zero-mission-us"
        path = "\(path)"

        [[feature]]
        package_id = "super-metroid.map-hud"
        id = "pause-map"
        enabled = true

        """.write(to: root.appending(path: "state.toml"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func aRunGetsAPrivateCopyAndStateTomlGetsTheArchiveBack() throws {
        let work = try makeWork()
        defer { try? fm.removeItem(at: work) }
        let body = Data(repeating: 5, count: 4096)
        let archive = try #require(try pack(["Metroid - Zero Mission (USA).gba": body], as: "7z", in: work))
        let root = try makeGame(in: work, path: archive.path)
        let runRoot = work.appending(path: "RunROM", directoryHint: .isDirectory)
        try fm.createDirectory(at: runRoot, withIntermediateDirectories: true)

        let run = ModFiles.prepare(root: root, runRoot: runRoot)
        let folder = try #require(run.folder)
        let during = ModState.read(from: root).sharedResources["metroid.zero-mission-us"] ?? ""
        #expect(during.hasPrefix(folder.path) && during.hasSuffix("/Metroid - Zero Mission (USA).gba"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: during)) == body)
        let mode = try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // The game rewrites state.toml while it runs; the archive still comes back.
        var rewritten = ModState.read(from: root)
        rewritten.packages["super-metroid.map-hud"] = "1.0.0"
        try rewritten.write(to: root)
        run.restore()
        #expect(ModState.read(from: root).sharedResources["metroid.zero-mission-us"] == archive.path)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func aCrashIsPutRightAtTheNextLaunch() throws {
        let work = try makeWork()
        defer { try? fm.removeItem(at: work) }
        let archive = try #require(try pack(["zm.gba": Data(repeating: 5, count: 64)], as: "zip", in: work))
        let root = try makeGame(in: work, path: archive.path)
        let runRoot = work.appending(path: "RunROM", directoryHint: .isDirectory)
        let folder = try #require(ModFiles.prepare(root: root, runRoot: runRoot).folder)
        ModFiles.restoreLeftovers(in: runRoot)
        #expect(ModState.read(from: root).sharedResources["metroid.zero-mission-us"] == archive.path)
        #expect(!fm.fileExists(atPath: folder.path))
    }

    @Test func aPlainFileOrATurnedOffFeatureNeedsNoCopy() throws {
        let work = try makeWork()
        defer { try? fm.removeItem(at: work) }
        let root = try makeGame(in: work, path: "/ROMs/zm.gba")
        #expect(ModFiles.prepare(root: root, runRoot: work.appending(path: "RunROM")).folder == nil)
        let archive = try #require(try pack(["zm.gba": Data([1])], as: "zip", in: work))
        let off = try makeGame(in: work, path: archive.path)
        var state = ModState.read(from: off)
        state.features["super-metroid.map-hud/pause-map"]?.enabled = false
        try state.write(to: off)
        #expect(ModFiles.prepare(root: off, runRoot: work.appending(path: "RunROM")).folder == nil)
    }

    /// The owner's Zero Mission zip, read in place. SM_GBA_ZIP=<path> runs it.
    @Test func theRealZeroMissionZipIsVerified() throws {
        guard let path = ProcessInfo.processInfo.environment["SM_GBA_ZIP"] else { return }
        var resource = ModResource()
        resource.filePatterns = "*.gba"
        resource.size = 8_388_608
        resource.normalizedSHA256 = "fc94f65380b65b870a30b9b04b39cca1dc63d6e46a4a373d3904adc0912ebc37"
        #expect(resource.status(of: path) == .verified)
    }
}
