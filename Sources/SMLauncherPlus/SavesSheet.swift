import AppKit
import SMLauncherPlusKit
import SwiftUI

extension DataFolder {
    /// `Backups/<profile id>/`: zipped copies of a profile's saves (S-033).
    static func backups(for profile: UUID) -> URL {
        url.appending(path: "Backups/\(profile.uuidString)", directoryHint: .isDirectory)
    }
}

extension SaveBackup.Failure {
    var message: String {
        switch self {
        case .noSaves: String(localized: "This profile has no saves yet. Play and save once, then back up.")
        case .notABackup: String(localized: "This zip has no Super Metroid saves in it.")
        case .failed(let reason): String(localized: "Unable to finish: \(reason)")
        }
    }
}

/// S-033: back up a profile's saves, restore one, and a backup before each update.
/// Ported from AM2R Launcher Plus.
extension AppModel {
    /// Profile › Back Up Saves (⌘B): opens the Saves sheet and makes a backup there.
    func startBackup(_ profile: Profile) {
        backupsFor = profile
        Task { _ = await backUpSaves(profile) }
    }

    /// Zips the profile's `saves/` into Backups/<id>/. `label` marks automatic ones ("before update to 0.4.11").
    @discardableResult
    func backUpSaves(_ profile: Profile, label: String? = nil) async -> URL? {
        guard !backingUp else { return nil }
        backingUp = true
        defer { backingUp = false }
        backupError = nil
        backupMessage = nil
        let saves = SaveBackup.saves(game: profile.gameFolder), folder = DataFolder.backups(for: profile.uuid), name = profile.name
        let result = await Task.detached(priority: .userInitiated) { () async -> Result<URL, SaveBackup.Failure> in
            do throws(SaveBackup.Failure) { return .success(try await SaveBackup.backup(saves: saves, into: folder, profileName: name, label: label)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let zip):
            log.post(.info, "Backed up the saves of \(name) to \(zip.path)", source: "Backups")
            if label == nil { backupMessage = String(localized: "Backed up as \(zip.deletingPathExtension().lastPathComponent).") }
            return zip
        case .failure(let failure):
            log.post(.error, "Back up \(name): \(failure)", source: "Backups")
            backupError = failure.message
            return nil
        }
    }

    /// Puts a backup back. The current saves are backed up first ("before restore"), so a restore can be undone.
    @discardableResult
    func restoreSaves(_ profile: Profile, from zip: URL) async -> Bool {
        guard game?.profileID != profile.uuid, !backingUp else { return false }
        let saves = SaveBackup.saves(game: profile.gameFolder)
        let hasSaves = ProfileFiles.hasSaves(game: profile.gameFolder)
        if hasSaves, await backUpSaves(profile, label: String(localized: "before restore")) == nil { return false }
        backingUp = true
        defer { backingUp = false }
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        let result = await Task.detached(priority: .userInitiated) { () async -> Result<Void, SaveBackup.Failure> in
            do throws(SaveBackup.Failure) { return .success(try await SaveBackup.restore(zip, into: saves)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success:
            log.post(.info, "Restored the saves of \(profile.name) from \(zip.path)", source: "Backups")
            backupMessage = hasSaves
                ? String(localized: "Restored \(zip.deletingPathExtension().lastPathComponent). The saves from before are in the list, marked “before restore”.")
                : String(localized: "Restored \(zip.deletingPathExtension().lastPathComponent).")
            return true
        case .failure(let failure):
            log.post(.error, "Restore \(profile.name) from \(zip.lastPathComponent): \(failure)", source: "Backups")
            backupError = failure.message
            return false
        }
    }
}

/// The save backups of one profile (S-033): back up now, restore one (asks first), restore from a zip.
struct SavesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var backups: [SaveBackup.Backup] = []
    @State private var selection: URL?
    @State private var confirmRestore: URL?
    @State private var choosingFile = false

    private var playingThis: Bool { model.game?.profileID == profile.uuid }

    var body: some View {
        VStack(spacing: 0) {
            Text("Saves of \(profile.name)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .accessibilityAddTraits(.isHeader)
            Divider()
            List(backups, selection: $selection) { backup in
                HStack(spacing: Space.md) {
                    Label(backup.name, systemImage: "doc.zipper")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.lg)
                    Text(backup.size.formatted(.byteCount(style: .file).locale(.app)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(backup.url)
                .contextMenu {
                    Button("Restore…") { confirmRestore = backup.url }
                        .disabled(playingThis)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                    Divider()
                    Button("Move to Trash") {
                        try? FileManager.default.trashItem(at: backup.url, resultingItemURL: nil)
                        reload()
                    }
                }
            }
            .overlay {
                if backups.isEmpty {
                    ContentUnavailableView("No Backups", systemImage: "archivebox",
                                           description: Text("Back up this profile's saves to keep a copy you can restore. Updates make one first, too."))
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, minHeight: 280, maxHeight: 280)
            if let message = model.backupError ?? model.backupMessage {
                Divider()
                Label(message, systemImage: model.backupError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
            }
            Divider()
            HStack(spacing: Space.md) {
                Button("Back Up Now") { Task { await model.backUpSaves(profile); reload() } }
                    .help("Zip this profile's saves (⌘B)")
                Button("Restore from File…") { choosingFile = true }
                    .help("Restore saves from a zip, such as a backup from another Mac")
                    .disabled(playingThis)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DataFolder.backups(for: profile.uuid)]) }
                    .disabled(backups.isEmpty)
                Spacer()
                if model.backingUp { ProgressView().controlSize(.small) }
                Button("Restore…") { confirmRestore = selection }
                    .disabled(selection == nil || playingThis)
                    .help(playingThis ? String(localized: "Quit the game to restore saves") : String(localized: "Replace this profile's saves with the selected backup"))
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.backingUp)
            .padding(Space.lg)
            .fixedSize(horizontal: true, vertical: false)
        }
        .confirmationDialog("Restore these saves?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore") {
                if let zip = confirmRestore { Task { await model.restoreSaves(profile, from: zip); reload() } }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current saves of \(profile.name) are replaced. They're backed up first, so you can go back.")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { confirmRestore = url }
        }
        .onExitCommand { dismiss() }
        .task { reload() }
        .onChange(of: model.backingUp) { if !model.backingUp { reload() } }
        .noInitialFocus()
    }

    private func reload() {
        backups = SaveBackup.list(in: DataFolder.backups(for: profile.uuid))
        if let selection, !backups.contains(where: { $0.url == selection }) { self.selection = nil }
    }
}
