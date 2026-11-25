import ArchiveKit
import Foundation

/// The files mods ask for, around one run of the game (S-022). The game reads only a plain file, so a
/// file chosen inside a .zip or .7z is unpacked into a private folder (mode 700) for the run and
/// state.toml points at it; when the game quits, state.toml gets the archive back and the copy is
/// deleted. The owner's rule (CLAUDE.md): never a lasting copy.
public enum ModFiles {
    /// What `prepare` unpacked: `restore()` puts state.toml back and deletes the copies.
    public struct Run: Sendable, Equatable {
        public var folder: URL?
        public func restore() { if let folder { ModFiles.restore(folder) } }
    }

    struct Record: Codable {
        /// `<game>/mods/preloaded`
        var root: String
        /// unpacked path -> the archive the player chose
        var paths: [String: String]
    }

    /// Unpacks the files that turned-on features use from a .zip or .7z into a "mods-" folder under
    /// `runRoot` and points state.toml at them. Nothing to unpack leaves everything as it is.
    public static func prepare(root: URL, runRoot: URL) async -> Run {
        let fm = FileManager.default
        let catalog = ModCatalog.packages(in: root)
        var state = ModState.read(from: root)
        let folder = runRoot.appending(path: "mods-\(UUID().uuidString)", directoryHint: .isDirectory)
        var unpacked: [String: String] = [:]  // archive -> unpacked path
        var record = Record(root: root.path, paths: [:])
        for feature in catalog.flatMap(\.features) where state.isEnabled(feature) {
            for resource in feature.resources {
                let path = state.path(of: resource, in: feature, catalog: catalog)
                guard resource.isArchive(path) else { continue }
                if let done = unpacked[path] {
                    state.setPath(done, of: resource, in: feature)
                    continue
                }
                let archive = URL(fileURLWithPath: path)
                guard case .success(let member) = await resource.member(in: archive),
                      let data = try? await AnyArchive.read(member, from: archive, limit: ModResource.maxBytes) else { continue }
                let file = folder.appending(path: "\(unpacked.count + 1)", directoryHint: .isDirectory)
                    .appending(path: (member as NSString).lastPathComponent)
                do {
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { continue }
                } catch { continue }
                unpacked[path] = file.path
                record.paths[file.path] = path
                state.setPath(file.path, of: resource, in: feature)
            }
        }
        guard !unpacked.isEmpty else {
            try? fm.removeItem(at: folder)
            return Run(folder: nil)
        }
        // The record first: a crash after this still finds what to put back.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? JSONEncoder().encode(record).write(to: folder.appending(path: "restore.json"))
        try? state.write(to: root)
        return Run(folder: folder)
    }

    /// Puts the archives back in state.toml (the game may have rewritten it) and deletes the copies.
    public static func restore(_ folder: URL) {
        if let data = try? Data(contentsOf: folder.appending(path: "restore.json")),
           let record = try? JSONDecoder().decode(Record.self, from: data) {
            let root = URL(fileURLWithPath: record.root, isDirectory: true)
            var state = ModState.read(from: root)
            for (key, path) in state.sharedResources { if let original = record.paths[path] { state.sharedResources[key] = original } }
            for (key, selection) in state.features {
                for (id, path) in selection.resources {
                    if let original = record.paths[path] { state.features[key]?.resources[id] = original }
                }
            }
            if FileManager.default.fileExists(atPath: root.path) { try? state.write(to: root) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Restores and deletes what a crash or a forced quit left behind. Called at launch.
    public static func restoreLeftovers(in runRoot: URL) {
        for folder in (try? FileManager.default.contentsOfDirectory(at: runRoot, includingPropertiesForKeys: nil)) ?? []
        where folder.lastPathComponent.hasPrefix("mods-") {
            restore(folder)
        }
    }
}
