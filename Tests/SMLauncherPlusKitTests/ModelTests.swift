import Foundation
import Testing
@testable import SMLauncherPlusKit

@Suite struct ModelTests {
    @Test func theSupportedROMMatchesOnlyItsSizeAndHash() {
        #expect(SupportedROM.matches(size: 3_145_728, sha256: SupportedROM.sha256.uppercased()))
        #expect(!SupportedROM.matches(size: 3_145_728 + 512, sha256: SupportedROM.sha256))
        #expect(!SupportedROM.matches(size: 3_145_728, sha256: String(repeating: "0", count: 64)))
    }

    @Test func aLibraryRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SMLauncherPlus-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Library.load(from: url) == Library())
        try Library().save(to: url)
        #expect(try Library.load(from: url) == Library())
    }
}
