import ArchiveKit
import Foundation

/// Zipped copies of a profile's `saves/` folder, and putting one back (S-033), through ArchiveKit's `BackupFolder`.
/// A backup is a plain zip with the save files at its root, named "<profile> – 2026-11-22 14-05.zip".
public enum SaveBackup {
    public typealias Backup = BackupFolder.Backup

    /// The app turns each into a sentence.
    public enum Failure: Error, Equatable, Sendable {
        case noSaves
        case notABackup
        case failed(String)
    }

    /// The profile's save folder, inside its game folder.
    public static func saves(game: URL) -> URL { game.appending(path: "saves", directoryHint: .isDirectory) }

    /// The backups of one profile. A restore deletes the saves it replaces: they were backed up first ("before restore").
    static func backups(in folder: URL) -> BackupFolder { BackupFolder(root: folder, disposal: .delete) }

    /// Zips the contents of `saves` into `folder`. `label` is added to the name, e.g. "before restore".
    @discardableResult
    public static func backup(saves: URL, into folder: URL, profileName: String, label: String? = nil, date: Date = .now) async throws(Failure) -> URL {
        var name = ProfileName.dated(profileName, date: date)
        if let label { name += " (\(label))" }
        do {
            // Without keepParent the files sit at the root of the zip; a plain zip, without macOS metadata.
            return try await backups(in: folder).backUp(from: saves, name: name, date: date, macMetadata: false).url
        } catch ArchiveError.nothingToBackUp {
            throw .noSaves
        } catch {
            throw .failed("\(error)")
        }
    }

    /// The backups in `folder`, newest first.
    public static func list(in folder: URL) -> [Backup] {
        backups(in: folder).list()
    }

    /// Replaces the contents of `saves` with the backup. The zip is unpacked beside the save folder first
    /// and swapped in only when complete. A zip holding one folder (a zipped `saves` folder) works too.
    public static func restore(_ zip: URL, into saves: URL) async throws(Failure) {
        let backups = backups(in: zip.deletingLastPathComponent())
        guard let backup = try? backups.backup(at: zip) else { throw .notABackup }
        do {
            try await backups.restore(backup, into: saves, accept: { isSaveFolder($0) })
        } catch ArchiveError.notABackup, ArchiveError.unsafeEntry {
            throw .notABackup
        } catch {
            throw .failed("\(error)")
        }
    }

    /// The game writes its battery save as save.srm (and keeps save.srm.bak) in `saves/`.
    static func isSaveFolder(_ folder: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }
        return names.contains { $0.hasSuffix(".srm") || $0.hasSuffix(".srm.bak") }
    }
}
