import Foundation
import Testing
@testable import SMLauncherPlusKit

// S-014: the RetroArch filters the launcher offers.

@Test func everyFilterListsItsPresetAndChecksums() {
    #expect(RetroArchFilter.all.count == 8)
    #expect(RetroArchFilter.commit.count == 40)
    for filter in RetroArchFilter.all {
        #expect(filter.files.contains { $0.path == filter.preset }, "\(filter.id)")
        #expect(filter.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 && !$0.path.hasPrefix("/") && !$0.path.contains("..") })
        #expect(filter.shaderPath == "assets/shaders/retroarch/\(filter.preset)")
    }
    #expect(Set(RetroArchFilter.all.map(\.id)).count == RetroArchFilter.all.count)
}

@Test func nothingIsDownloadedInAnEmptyFolder() throws {
    let cache = FileManager.default.temporaryDirectory.appending(path: "ra-\(UUID().uuidString)", directoryHint: .isDirectory)
    #expect(!RetroArchFilter.isDownloaded(in: cache))
    let game = FileManager.default.temporaryDirectory.appending(path: "ra-game-\(UUID().uuidString)", directoryHint: .isDirectory)
    #expect(try RetroArchFilter.install(from: cache, game: game).isEmpty)
}

@Test func aWrongFileIsNotCountedAsDownloaded() throws {
    let cache = FileManager.default.temporaryDirectory.appending(path: "ra-\(UUID().uuidString)", directoryHint: .isDirectory)
    let file = RetroArchFilter.all[0].files[0]
    let url = cache.appending(path: file.path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0, count: file.size).write(to: url)
    #expect(!RetroArchFilter.isValid(file, in: cache))
}

@Test func installedRetroArchFiltersComeAfterTheOthers() throws {
    let game = FileManager.default.temporaryDirectory.appending(path: "ra-game-\(UUID().uuidString)", directoryHint: .isDirectory)
    let shaders = game.appending(path: ShaderPreset.folder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
    try Data().write(to: shaders.appending(path: "crt.glslp"))
    let lottes = RetroArchFilter.named("crt-lottes")!, hq4x = RetroArchFilter.named("hq4x")!
    for filter in [hq4x, lottes] {
        let url = game.appending(path: filter.shaderPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    let list = ShaderPreset.list(game: game)
    #expect(list.map(\.path) == ["assets/shaders/crt.glslp", lottes.shaderPath, hq4x.shaderPath])
    #expect(list[1].retroArch == lottes)
    #expect(list[1].strength.isEmpty)
    #expect(list[0].retroArch == nil)
    RetroArchFilter.uninstall(game: game)
    #expect(ShaderPreset.list(game: game).count == 1)
}
