import Foundation
import ProcessKit
import Testing
@testable import SMLauncherPlusKit

struct ModArchiveTests {
    let fm = FileManager.default
    let rom = SupportedROM.sha256

    func manifest(id: String = "example.better-hud", version: String = "1.2.0", game: String = ModCatalog.gameID, romHash: String? = nil) -> String {
        """
        format_version = 1
        id = "\(id)"
        version = "\(version)"
        name = "Better HUD"
        author = "Someone"

        [[target]]
        game_id = "\(game)"
        rom_sha256 = "\(romHash ?? rom)"

        [[feature]]
        id = "clock"
        name = "Clock"
        group = "HUD"

        [[plugin]]
        feature = "clock"
        id = "super-metroid.map-hud.pause-stats"
        """
    }

    struct Member {
        var name: String
        var data = Data()
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var size: UInt32?
        var crc: UInt32?
        var symlink = false
    }

    /// A stored ZIP, with each field overridable to make a broken one.
    func zip(_ members: [Member], count: Int? = nil) -> Data {
        var out = Data(), central = Data()
        func put16(_ v: UInt16, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func put32(_ v: UInt32, _ d: inout Data) { put16(UInt16(v & 0xFFFF), &d); put16(UInt16(v >> 16), &d) }
        for m in members {
            let offset = UInt32(out.count), name = Data(m.name.utf8)
            let crc = m.crc ?? ModArchive.crc32(m.data), size = m.size ?? UInt32(m.data.count)
            put32(0x04034b50, &out); put16(20, &out); put16(m.flags, &out); put16(m.method, &out); put32(0, &out)
            put32(crc, &out); put32(UInt32(m.data.count), &out); put32(size, &out)
            put16(UInt16(name.count), &out); put16(0, &out); out.append(name); out.append(m.data)
            put32(0x02014b50, &central); put16(m.symlink ? 0x031E : 20, &central); put16(20, &central); put16(m.flags, &central)
            put16(m.method, &central); put32(0, &central); put32(crc, &central); put32(UInt32(m.data.count), &central)
            put32(size, &central); put16(UInt16(name.count), &central); put16(0, &central); put16(0, &central)
            put16(0, &central); put16(0, &central); put32(m.symlink ? 0o120777 << 16 : 0, &central); put32(offset, &central)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        put32(0x06054b50, &out); put16(0, &out); put16(0, &out)
        put16(UInt16(count ?? members.count), &out); put16(UInt16(count ?? members.count), &out)
        put32(UInt32(central.count), &out); put32(centralOffset, &out); put16(0, &out)
        return out
    }

    func makeRoot() throws -> (URL, URL) {
        let base = fm.temporaryDirectory.appending(path: "snesmod-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "game/mods/preloaded", directoryHint: .isDirectory)
        try fm.createDirectory(at: root.appending(path: "packages"), withIntermediateDirectories: true)
        return (base, root)
    }

    func write(_ data: Data, in base: URL, name: String = "Better HUD.snesmod") throws -> URL {
        let url = base.appending(path: name)
        try data.write(to: url)
        return url
    }

    func refusal(_ data: Data, name: String = "Better HUD.snesmod") throws -> ModArchive.Failure? {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let archive = try write(data, in: base, name: name)
        do throws(ModArchive.Failure) {
            try ModArchive.install(archive, into: root)
            return nil
        } catch {
            // Nothing is left behind: no package, no staging folder.
            #expect(try fm.contentsOfDirectory(atPath: root.appending(path: "packages").path).isEmpty)
            #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging") }.isEmpty)
            return error
        }
    }

    @Test func installsAStoredPackageAndRecordsItsVersion() throws {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let archive = try write(zip([Member(name: "manifest.toml", data: Data(manifest().utf8)),
                                     Member(name: "art/"), Member(name: "art/clock.png", data: Data([1, 2, 3]))]), in: base)
        let package = try ModArchive.install(archive, into: root)
        #expect(package.id == "example.better-hud" && package.version == "1.2.0")
        let folder = root.appending(path: "packages/example.better-hud/1.2.0")
        #expect(try Data(contentsOf: folder.appending(path: "art/clock.png")) == Data([1, 2, 3]))
        #expect(ModCatalog.packages(in: root).map(\.id) == ["example.better-hud"])
        #expect(ModState.read(from: root).packages["example.better-hud"] == "1.2.0")
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging") }.isEmpty)
    }

    @Test func installsADeflatedPackageMadeByZip() throws {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let source = base.appending(path: "src", directoryHint: .isDirectory)
        try fm.createDirectory(at: source.appending(path: "data"), withIntermediateDirectories: true)
        try Data(manifest().utf8).write(to: source.appending(path: "manifest.toml"))
        try Data(repeating: 7, count: 100_000).write(to: source.appending(path: "data/big.bin"))
        try Data().write(to: source.appending(path: "data/empty.txt"))
        let archive = base.appending(path: "pack.snesmod")
        try Shell.runSync("/usr/bin/zip", ["-q", "-r", "-X", archive.path, "."], in: source).check()
        try ModArchive.install(archive, into: root)
        let folder = root.appending(path: "packages/example.better-hud/1.2.0/data")
        #expect(try Data(contentsOf: folder.appending(path: "big.bin")) == Data(repeating: 7, count: 100_000))
        #expect(try Data(contentsOf: folder.appending(path: "empty.txt")).isEmpty)
    }

    @Test func refusesWhatTheGameRefuses() throws {
        let good = Member(name: "manifest.toml", data: Data(manifest().utf8))
        #expect(try refusal(zip([good]), name: "Better HUD.zip") == .notSnesmod)
        #expect(try refusal(Data("not a zip at all, just some text".utf8)) == .damaged)
        #expect(try refusal(zip([Member(name: "readme.txt", data: Data("hi".utf8))])) == .noManifest)
        #expect(try refusal(zip([Member(name: "pack/manifest.toml", data: Data(manifest().utf8))])) == .noManifest)
        #expect(try refusal(zip([good, Member(name: "secret.bin", data: Data([1]), flags: 1)])) == .encrypted)
        #expect(try refusal(zip([good, Member(name: "x.bin", data: Data([1]), method: 12)])) == .unsupportedCompression)
        for name in ["../escape.txt", "/etc/passwd", "a/../../b", "C:/x", "a//b", "./x"] {
            #expect(try refusal(zip([good, Member(name: name, data: Data([1]))])) == .unsafePath(name))
        }
        #expect(try refusal(zip([good, Member(name: "link", data: Data("/etc".utf8), symlink: true)])) == .unsafePath("link"))
        #expect(try refusal(zip([good, Member(name: "bad.bin", data: Data([1, 2]), crc: 1234)])) == .checksumFailed("bad.bin"))
        #expect(try refusal(zip([Member(name: "manifest.toml", data: Data("id = \"x\"".utf8))])) == .invalidManifest)
        #expect(try refusal(zip([Member(name: "manifest.toml", data: Data(manifest(id: "Bad ID").utf8))])) == .invalidManifest)
        #expect(try refusal(zip([Member(name: "manifest.toml", data: Data(manifest(version: "../1").utf8))])) == .invalidManifest)
    }

    @Test func atMost4096FilesAnd256MiB() throws {
        let good = Member(name: "manifest.toml", data: Data(manifest().utf8))
        let many = [good] + (1...4096).map { Member(name: "f\($0)") }
        #expect(try refusal(zip(many)) == .tooManyFiles)
        // Exactly 4096 files is fine.
        #expect(try refusal(zip(Array(many.prefix(4096)))) == nil)
        // The size limit is the expanded size the archive declares, checked before anything is written.
        #expect(try refusal(zip([good, Member(name: "huge.bin", data: Data([0]), method: 8, size: 257 * 1024 * 1024)])) == .tooLarge)
    }

    @Test func refusesAPackageForAnotherGameWithTheReason() throws {
        let other = zip([Member(name: "manifest.toml", data: Data(manifest(game: "smw-usa").utf8))])
        #expect(try refusal(other) == .wrongGame(name: "Better HUD", games: ["smw-usa"]))
        let otherROM = zip([Member(name: "manifest.toml", data: Data(manifest(romHash: String(repeating: "0", count: 64)).utf8))])
        #expect(try refusal(otherROM) == .wrongROM(name: "Better HUD"))
    }

    @Test func refusesAVersionAlreadyInstalled() throws {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let archive = try write(zip([Member(name: "manifest.toml", data: Data(manifest().utf8))]), in: base)
        try ModArchive.install(archive, into: root)
        #expect(throws: ModArchive.Failure.alreadyInstalled(name: "Better HUD", version: "1.2.0")) { try ModArchive.install(archive, into: root) }
    }

    @Test func removingAPackageDeletesItsFolderAndItsStateEntries() throws {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let archive = try write(zip([Member(name: "manifest.toml", data: Data(manifest().utf8))]), in: base)
        let package = try ModArchive.install(archive, into: root)
        var state = ModState.read(from: root)
        state.packages["super-metroid.pacing"] = "1.0.0"
        state.features["super-metroid.pacing/intro-skip"] = .init(enabled: true)
        state.features["example.better-hud/clock"] = .init(enabled: true, values: ["style": "digital"], resources: ["font": "/x.png"])
        try state.write(to: root)

        try ModArchive.remove(id: package.id, version: package.version, from: root)
        #expect(!fm.fileExists(atPath: root.appending(path: "packages/example.better-hud").path))
        let after = ModState.read(from: root)
        #expect(after.packages["example.better-hud"] == nil)
        #expect(after.features["example.better-hud/clock"] == nil)
        #expect(after.features["super-metroid.pacing/intro-skip"]?.enabled == true)
        #expect(!after.text().contains("example.better-hud"))
    }

    @Test func removingANewerVersionFallsBackToTheOneLeft() throws {
        let (base, root) = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        try ModArchive.install(try write(zip([Member(name: "manifest.toml", data: Data(manifest(version: "1.0.0").utf8))]), in: base, name: "a.snesmod"), into: root)
        try ModArchive.install(try write(zip([Member(name: "manifest.toml", data: Data(manifest(version: "1.10.0").utf8))]), in: base, name: "b.snesmod"), into: root)
        #expect(ModCatalog.packages(in: root).first?.version == "1.10.0")
        var state = ModState.read(from: root)
        state.features["example.better-hud/clock"] = .init(enabled: true)
        try state.write(to: root)
        try ModArchive.remove(id: "example.better-hud", version: "1.10.0", from: root)
        let after = ModState.read(from: root)
        #expect(after.packages["example.better-hud"] == "1.0.0")
        #expect(after.features["example.better-hud/clock"]?.enabled == true)
    }

    @Test func crcMatchesTheStandard() {
        #expect(ModArchive.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }
}
