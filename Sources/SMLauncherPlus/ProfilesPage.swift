import AppKit
import SMLauncherPlusKit
import SwiftData
import SwiftUI

extension DataFolder {
    /// Saves kept when a profile was deleted: `Kept Saves/<name – date>/` (S-032).
    static var keptSaves: URL { url.appending(path: "Kept Saves", directoryHint: .isDirectory) }
}

/// S-032: rename, duplicate, show in Finder and delete profiles. Ported from AM2R Launcher Plus.
extension AppModel {
    /// Another profile can't be managed while the game runs from it or an install is going.
    func isBusy(_ profile: Profile) -> Bool {
        install != nil || game?.profileID == profile.uuid
    }

    func rename(_ profile: Profile, to name: String) {
        let clean = ProfileName.clean(name, fallback: String(localized: "Super Metroid"))
        guard clean != profile.name else { return }
        log.post(.info, "Renamed \(profile.name) to \(clean)", source: "Profiles")
        profile.name = clean
        try? context.save()
    }

    func startDuplicate(_ profile: Profile) {
        Task { _ = await duplicate(profile) }
    }

    /// Copies the game, saves, settings and mods into a new profile, which becomes the one on the Play page.
    @discardableResult
    func duplicate(_ profile: Profile) async -> Profile? {
        guard !duplicating, !isBusy(profile) else { return nil }
        duplicating = true
        defer { duplicating = false }
        profileMessage = nil
        let uuid = UUID()
        let from = profile.folder
        let to = DataFolder.profiles.appending(path: uuid.uuidString, directoryHint: .isDirectory)
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try ProfileFiles.duplicate(from, to: to); return nil } catch { return error.localizedDescription }
        }.value
        if let failure {
            log.post(.error, "Unable to duplicate \(profile.name): \(failure)", source: "Profiles")
            profileMessage = .failed(String(localized: "Unable to duplicate \(profile.name). \(failure)"))
            return nil
        }
        let copy = Profile(name: ProfileName.copy(of: profile.name, existing: profiles.map(\.name), suffix: String(localized: "Copy")),
                           gameVersion: profile.gameVersion)
        copy.uuid = uuid
        copy.installedMods = profile.installedMods
        context.insert(copy)
        try? context.save()
        selection = uuid
        log.post(.info, "Duplicated \(profile.name) as \(copy.name)", source: "Profiles")
        return copy
    }

    func reveal(_ profile: Profile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.folder])
    }

    /// Deletes the profile's game, logs and record. `keepSaves` first moves its saves, with its settings,
    /// to Kept Saves/<name – date>/; if that fails, nothing is deleted.
    func delete(_ profile: Profile, keepSaves: Bool) {
        guard !isBusy(profile) else { return }
        let fm = FileManager.default
        profileMessage = nil
        let name = profile.name
        if keepSaves, ProfileFiles.hasSaves(game: profile.gameFolder) {
            let kept = DataFolder.keptSaves.appending(path: ProfileName.dated(name, date: .now), directoryHint: .isDirectory)
            do {
                try? fm.removeItem(at: kept)
                try ProfileFiles.keepSaves(game: profile.gameFolder, in: kept)
                // Its backups go with the kept saves (S-033).
                let backups = DataFolder.backups(for: profile.uuid)
                if fm.fileExists(atPath: backups.path) { try? fm.moveItem(at: backups, to: kept.appending(path: "Backups", directoryHint: .isDirectory)) }
                profileMessage = .kept(name: name, folder: kept)
            } catch {
                log.post(.error, "Unable to keep the saves of \(name): \(error.localizedDescription)", source: "Profiles")
                profileMessage = .failed(String(localized: "Unable to keep the saves of \(name). Nothing was deleted."))
                return
            }
        }
        try? fm.removeItem(at: profile.folder)
        try? fm.removeItem(at: GameRunner.logFolder(for: profile))
        try? fm.removeItem(at: DataFolder.backups(for: profile.uuid))
        if lastGameFailure?.profile == profile.uuid { lastGameFailure = nil }
        log.post(.info, keepSaves ? "Deleted \(name), saves kept" : "Deleted \(name) and its saves", source: "Profiles")
        let wasSelected = currentProfile?.uuid == profile.uuid
        context.delete(profile)
        try? context.save()
        if wasSelected { selection = currentProfile?.uuid }
    }
}

/// What the last profile action did, shown under the Profiles list.
enum ProfileMessage: Equatable {
    case kept(name: String, folder: URL)
    case failed(String)
}

/// Every profile with its version and play stats (S-032). Double-click plays it.
struct ProfilesPage: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Profile.installedAt, order: .reverse) private var profiles: [Profile]
    @State private var selected: PersistentIdentifier?

    var body: some View {
        @Bindable var model = model
        let current = model.currentProfile?.uuid
        Table(profiles, selection: $selected) {
            TableColumn("Name") { profile in
                Text(profile.name)
                    .fontWeight(profile.uuid == current ? .semibold : .regular)
                    .help(profile.uuid == current ? String(localized: "On the Play page") : "")
            }
            TableColumn("Version") { Text(verbatim: $0.gameVersion) }
                .width(min: 56, ideal: 64)
            TableColumn("Last Played") { Text(PlayStats.lastPlayed($0.lastPlayedAt)) }
                .width(min: 88, ideal: 140)
            TableColumn("Play Time") { Text($0.playTime > 0 ? PlayStats.playTime($0.playTime) : "—") }
                .width(min: 72, ideal: 96)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let profile = profiles.first(where: { ids.contains($0.id) }) {
                ProfileActions(profile: profile)
            }
        } primaryAction: { ids in
            if let profile = profiles.first(where: { ids.contains($0.id) }) {
                model.selection = profile.uuid
                model.sidebar = .play
            }
        }
        .onChange(of: selected) { _, id in
            if let profile = profiles.first(where: { $0.id == id }) { model.selection = profile.uuid }
        }
        .onAppear { selected = model.currentProfile?.id }
        .overlay {
            if profiles.isEmpty {
                ContentUnavailableView("No Profiles", systemImage: SidebarItem.profiles.symbol,
                                       description: Text("Install the game from the Play page."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { notice }
        .navigationTitle("Profiles")
    }

    @ViewBuilder private var notice: some View {
        switch model.profileMessage {
        case .kept(let name, let folder):
            HStack(spacing: Space.md) {
                Label("The saves of \(name) are in Kept Saves, with its settings.", systemImage: "tray.full")
                Spacer(minLength: Space.lg)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("Done") { model.profileMessage = nil }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .background(.bar)
        case .failed(let text):
            HStack(spacing: Space.md) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Spacer(minLength: Space.lg)
                Button("Done") { model.profileMessage = nil }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .background(.bar)
        case nil:
            EmptyView()
        }
    }
}

/// The Profile menu and the Profiles page's context menu share these.
struct ProfileActions: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let busy = model.isBusy(profile)
        Button("Rename…") { model.renameTarget = profile }
        Button("Duplicate") { model.startDuplicate(profile) }
            .disabled(busy || model.duplicating)
        Button("Show in Finder") { model.reveal(profile) }
        Divider()
        Button("Back Up Saves") { model.startBackup(profile) }
            .disabled(model.backingUp)
        Button("Saves…") { model.backupsFor = profile }
        Divider()
        Button("Delete…", role: .destructive) { model.deleteTarget = profile }
            .disabled(busy)
    }
}

/// Rename and Delete ask here, so the menu bar and the Profiles page share them.
struct ProfileDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .sheet(item: $model.backupsFor, onDismiss: { model.backupMessage = nil; model.backupError = nil }) { profile in
                SavesSheet(profile: profile)
            }
            .alert("Rename Profile", isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let profile = model.renameTarget { model.rename(profile, to: newName) } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.renameTarget?.uuid) { newName = model.renameTarget?.name ?? "" }
            .confirmationDialog(model.deleteTarget.map { String(localized: "Delete \($0.name)?") } ?? "",
                                isPresented: Binding(get: { model.deleteTarget != nil }, set: { if !$0 { model.deleteTarget = nil } })) {
                Button("Delete, Keep Saves") { if let profile = model.deleteTarget { model.delete(profile, keepSaves: true) } }
                    .keyboardShortcut(.defaultAction)
                Button("Delete Profile and Saves", role: .destructive) { if let profile = model.deleteTarget { model.delete(profile, keepSaves: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The game files are removed. Kept saves go to Kept Saves in the data folder with the profile's settings, so you can bring them back later.")
            }
    }
}
