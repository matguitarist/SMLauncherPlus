import CryptoKit
import Foundation
import Testing
@testable import SMLauncherPlusKit

struct ModResourceTests {
    let fm = FileManager.default

    /// Two map features sharing the Zero Mission ROM, and one feature with a required file, like 0.4.6's map-hud.
    static func manifest(hash: String, size: Int) -> String {
        """
        format_version = 1
        id = "super-metroid.map-hud"
        version = "1.0.0"
        name = "Map and HUD"
        [[target]]
        game_id = "supermetroid-jpn"
        [[feature]]
        id = "pause-map"
        name = "Clearer pause map"
        group = "Map"
        [[resource]]
        feature = "pause-map"
        id = "zero-mission"
        label = "Zero Mission map art (optional)"
        description = "Select your Metroid: Zero Mission USA GBA ROM."
        shared_key = "metroid.zero-mission-us"
        normalized_sha256 = "\(hash)"
        size = \(size)
        file_patterns = "*.gba"
        file_description = "Metroid: Zero Mission (USA)"
        required = false
        [[feature]]
        id = "world-map"
        name = "Zoomable Zebes map"
        group = "Map"
        [[resource]]
        feature = "world-map"
        id = "zero-mission"
        label = "Zero Mission map art (optional)"
        shared_key = "metroid.zero-mission-us"
        normalized_sha256 = "\(hash)"
        file_patterns = "*.gba"
        required = false
        [[feature]]
        id = "custom-font"
        name = "Custom font"
        group = "HUD"
        [[resource]]
        feature = "custom-font"
        id = "font"
        label = "Font image"
        file_patterns = "*.png, *.PNG"
        """
    }

    func makeFile(_ bytes: Data) throws -> URL {
        let url = fm.temporaryDirectory.appending(path: "res-\(UUID().uuidString).gba")
        try bytes.write(to: url)
        return url
    }

    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func readsResourcesWithTheGamesDefaults() throws {
        let package = try #require(ModCatalog.parseManifest(Self.manifest(hash: String(repeating: "a", count: 64), size: 64)))
        let pauseMap = try #require(package.features.first { $0.id == "pause-map" }?.resources.first)
        #expect(pauseMap.label == "Zero Mission map art (optional)" && !pauseMap.required && pauseMap.sharedKey == "metroid.zero-mission-us")
        #expect(pauseMap.extensions == ["gba"] && pauseMap.size == 64 && pauseMap.fileDescription == "Metroid: Zero Mission (USA)")
        let font = try #require(package.features.first { $0.id == "custom-font" }?.resources.first)
        #expect(font.required, "required unless the manifest says false")
        #expect(font.extensions == ["png"])
        var bare = ModResource()
        bare.id = "x"
        #expect(bare.withDefaults().filePatterns == "*" && bare.withDefaults().extensions.isEmpty)
    }

    @Test func checksTheFileLikeTheGame() async throws {
        let body = Data((0..<65536).map { UInt8($0 % 251) })
        var resource = ModResource()
        resource.normalizedSHA256 = hash(body)
        #expect(await resource.status(of: "") == .notChosen)
        #expect(await resource.status(of: "/nonexistent/x.gba") == .notFound)
        let good = try makeFile(body)
        defer { try? fm.removeItem(at: good) }
        #expect(await resource.status(of: good.path) == .verified)
        // A 512-byte copier header is left out of the hash.
        let headered = try makeFile(Data(count: 512) + body)
        defer { try? fm.removeItem(at: headered) }
        #expect(await resource.status(of: headered.path) == .verified)
        let other = try makeFile(Data(body.reversed()))
        defer { try? fm.removeItem(at: other) }
        #expect(await resource.status(of: other.path) == .wrongFile)
        resource.size = 1000
        #expect(await resource.status(of: good.path) == .wrongSize)
        var any = ModResource()
        any.required = true
        #expect(await any.status(of: good.path) == .chosen)
        #expect(!ModResource.Status.notChosen.isUsable(required: true))
        #expect(ModResource.Status.notChosen.isUsable(required: false))
        #expect(!ModResource.Status.wrongFile.isUsable(required: false))
    }

    @Test func aSharedFileIsChosenOnceForEveryFeature() throws {
        let package = try #require(ModCatalog.parseManifest(Self.manifest(hash: String(repeating: "a", count: 64), size: 0)))
        let pauseMap = package.features[0], worldMap = package.features[1], font = package.features[2]
        var state = ModState()
        state.setPath("/ROMs/zm.gba", of: pauseMap.resources[0], in: pauseMap)
        #expect(state.path(of: worldMap.resources[0], in: worldMap, catalog: [package]) == "/ROMs/zm.gba")
        state.setPath("/fonts/a.png", of: font.resources[0], in: font)
        let text = state.text()
        #expect(text.contains("[[shared_resource]]\nid = \"metroid.zero-mission-us\"\npath = \"/ROMs/zm.gba\""))
        #expect(text.contains("[[resource]]\npackage_id = \"super-metroid.map-hud\"\nfeature_id = \"custom-font\"\nid = \"font\"\npath = \"/fonts/a.png\""))
        // Read back the way the game reads it.
        let reread = ModState.parse(text)
        #expect(reread.path(of: worldMap.resources[0], in: worldMap, catalog: [package]) == "/ROMs/zm.gba")
        #expect(reread.path(of: font.resources[0], in: font, catalog: [package]) == "/fonts/a.png")
        // Clearing a shared file keeps an explicit empty value, so an older per-feature one doesn't come back.
        var cleared = reread
        cleared.features[pauseMap.key, default: .init()].resources["zero-mission"] = "/old.gba"
        cleared.setPath("", of: worldMap.resources[0], in: worldMap)
        #expect(cleared.path(of: pauseMap.resources[0], in: pauseMap, catalog: [package]) == "")
        #expect(ModState.parse(cleared.text()).sharedResources["metroid.zero-mission-us"] == "")
    }

    @Test func anOlderPerFeatureChoiceIsMigrated() throws {
        let package = try #require(ModCatalog.parseManifest(Self.manifest(hash: String(repeating: "a", count: 64), size: 0)))
        var state = ModState()
        state.features[package.features[0].key, default: .init()].resources["zero-mission"] = "/ROMs/old.gba"
        #expect(state.path(of: package.features[1].resources[0], in: package.features[1], catalog: [package]) == "/ROMs/old.gba")
    }

    /// The owner's Zero Mission ROM, read in place. SM_GBA_ROM=<path to the .gba> runs it.
    @Test func theRealZeroMissionROMIsVerified() async throws {
        guard let path = ProcessInfo.processInfo.environment["SM_GBA_ROM"] else { return }
        var resource = ModResource()
        resource.size = 8_388_608
        resource.normalizedSHA256 = "fc94f65380b65b870a30b9b04b39cca1dc63d6e46a4a373d3904adc0912ebc37"
        #expect(await resource.status(of: path) == .verified)
    }
}
