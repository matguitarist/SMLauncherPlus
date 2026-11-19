import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-020. A made-up package in the game's manifest format 1.
@Suite struct ModCatalogTests {
    static let manifest = #"""
    format_version = 1
    id = "test.pacing"
    version = "1.2.0"
    name = "Test Pacing"
    author = "Someone"
    description = "Shorter \"waits\"." # a comment

    [[target]]
    game_id = "supermetroid-jpn"
    rom_sha256 = "abc"

    [[feature]]
    id = "elevators"
    name = "Faster elevators"
    description = "Elevators travel faster."
    group = "Pacing"
    default_enabled = false

    [[option]]
    feature = "elevators"
    id = "speed"
    label = "Speed"
    type = "choice"
    default = "2x"
    [[option.choice]]
    value = "2x"
    label = "2x"
    [[option.choice]]
    value = "3x"
    label = "3x"

    [[option]]
    feature = "elevators"
    id = "sound"
    label = "Keep the sound"
    type = "boolean"
    default = true

    [[plugin]]
    feature = "elevators"
    id = "test.pacing.elevators"

    [[feature]]
    id = "bombs"
    name = "More bombs"
    group = "Combat"
    default_enabled = true
    experimental = true
    requires = "test.pacing/elevators"

    [[option]]
    feature = "bombs"
    id = "limit"
    label = "Bombs at once"
    type = "integer"
    default = 8
    min = 5
    max = 10
    step = 1

    [[plugin]]
    feature = "bombs"
    id = "test.pacing.bombs"

    [[feature]]
    id = "classic-bombs"
    name = "Classic bombs"
    group = "Combat"
    default_enabled = false

    [[plugin]]
    feature = "classic-bombs"
    id = "test.pacing.bombs"
    """#

    static func catalog() throws -> [ModPackage] { [try #require(ModCatalog.parseManifest(manifest))] }

    @Test func aManifestIsReadWithEachKindOfOption() throws {
        let package = try #require(ModCatalog.parseManifest(Self.manifest))
        #expect(package.id == "test.pacing")
        #expect(package.version == "1.2.0")
        #expect(package.description == "Shorter \"waits\".")
        #expect(package.gameIDs == ["supermetroid-jpn"])
        #expect(package.features.map(\.id) == ["elevators", "bombs", "classic-bombs"])
        let elevators = package.features[0]
        #expect(elevators.group == "Pacing")
        #expect(elevators.plugins == ["test.pacing.elevators"])
        #expect(elevators.options.map(\.id) == ["speed", "sound"])
        #expect(elevators.options[0].kind == .choice([.init(value: "2x", label: "2x"), .init(value: "3x", label: "3x")]))
        #expect(elevators.options[0].defaultValue == "2x")
        #expect(elevators.options[1].kind == .boolean)
        #expect(elevators.options[1].defaultValue == "true")
        let bombs = package.features[1]
        #expect(bombs.defaultEnabled && bombs.experimental)
        #expect(bombs.requires == ["test.pacing/elevators"])
        #expect(bombs.options[0].kind == .integer(min: 5, max: 10, step: 1))
        #expect(bombs.options[0].defaultValue == "8")
    }

    @Test func optionValuesKeepToTheirBounds() throws {
        let bombs = try Self.catalog()[0].features[1]
        let limit = bombs.options[0]
        #expect(limit.accepts("5") && limit.accepts("10"))
        #expect(!limit.accepts("4") && !limit.accepts("11") && !limit.accepts("eight"))
        let speed = try Self.catalog()[0].features[0].options[0]
        #expect(speed.accepts("3x") && !speed.accepts("4x"))

        var state = ModState()
        state.setValue("11", of: limit, in: bombs)
        #expect(state.value(of: limit, in: bombs) == "8")
        state.features[bombs.key, default: .init()].values["limit"] = "99"
        #expect(state.value(of: limit, in: bombs) == "8", "a value the game would refuse reads as the default")
        state.setValue("6", of: limit, in: bombs)
        #expect(state.value(of: limit, in: bombs) == "6")
    }

    @Test func turningOnAFeatureFollowsTheGamesRules() throws {
        let catalog = try Self.catalog()
        let features = catalog[0].features
        let (elevators, bombs, classic) = (features[0], features[1], features[2])
        var state = ModState()
        state.setEnabled(false, elevators, in: catalog)
        // Bombs requires elevators: losing it turns bombs off.
        #expect(!state.isEnabled(bombs))
        // Turning bombs on turns on what it requires.
        let alsoChanged = state.setEnabled(true, bombs, in: catalog)
        #expect(state.isEnabled(elevators) && state.isEnabled(bombs))
        #expect(alsoChanged.map(\.id) == ["elevators"])
        // Classic bombs claims the same plugin: one turns the other off.
        state.setEnabled(true, classic, in: catalog)
        #expect(state.isEnabled(classic) && !state.isEnabled(bombs))
        state.setEnabled(true, bombs, in: catalog)
        #expect(!state.isEnabled(classic))
    }

    @Test func stateIsWrittenInTheGamesFormat() throws {
        let catalog = try Self.catalog()
        let elevators = catalog[0].features[0]
        var state = ModState.parse("""
        format_version = 1

        [[shared_resource]]
        id = "metroid.zero-mission-us"
        path = "/ROMs/zm.gba"

        [[package]]
        id = "test.pacing"
        version = "1.2.0"

        [[feature]]
        package_id = "test.pacing"
        id = "elevators"
        enabled = false

        [[feature]]
        package_id = "other.map"
        id = "pause-map"
        enabled = true

        [[resource]]
        package_id = "other.map"
        feature_id = "pause-map"
        id = "zero-mission"
        path = "/ROMs/zm.gba"
        """)
        state.setEnabled(true, elevators, in: catalog)
        state.setValue("3x", of: elevators.options[0], in: elevators)
        #expect(state.text() == """
        format_version = 1

        [[shared_resource]]
        id = "metroid.zero-mission-us"
        path = "/ROMs/zm.gba"

        [[package]]
        id = "other.map"
        version = ""

        [[package]]
        id = "test.pacing"
        version = "1.2.0"

        [[feature]]
        package_id = "other.map"
        id = "pause-map"
        enabled = true

        [[resource]]
        package_id = "other.map"
        feature_id = "pause-map"
        id = "zero-mission"
        path = "/ROMs/zm.gba"

        [[feature]]
        package_id = "test.pacing"
        id = "elevators"
        enabled = true

        [feature.values]
        speed = "3x"

        """)
        // What it writes reads back the same.
        #expect(ModState.parse(state.text()).text() == state.text())
    }

    @Test func packagesAreReadFromTheGameFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ModCatalogTests-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for (version, name) in [("1.2.0", "Test Pacing"), ("1.10.0", "Test Pacing New")] {
            let folder = root.appending(path: "packages/test.pacing/\(version)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.manifest.replacingOccurrences(of: "version = \"1.2.0\"", with: "version = \"\(version)\"")
                .replacingOccurrences(of: "name = \"Test Pacing\"", with: "name = \"\(name)\"")
                .write(to: folder.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
        }
        let other = root.appending(path: "packages/zelda.mod/1.0.0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Self.manifest.replacingOccurrences(of: "test.pacing", with: "zelda.mod").replacingOccurrences(of: "supermetroid-jpn", with: "zelda-usa")
            .write(to: other.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)

        let packages = ModCatalog.packages(in: root)
        #expect(packages.map(\.id) == ["test.pacing"], "another game's package is left out")
        #expect(packages.first?.version == "1.10.0", "the newest version wins")
    }
}
