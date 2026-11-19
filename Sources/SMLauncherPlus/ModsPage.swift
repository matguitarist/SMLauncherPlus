import SMLauncherPlusKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// S-020: the game's own mod packages, one switch per feature, grouped as the game groups them,
/// with each feature's options under it while it's on. Saved straight to the profile's
/// mods/preloaded/state.toml; the game reads it the next time it starts.
struct ModsPage: View {
    @Environment(AppModel.self) private var model
    @Query private var profiles: [Profile]

    var body: some View {
        Group {
            if !profiles.isEmpty, let profile = model.currentProfile {
                ModList(profile: profile)
                    .id(profile.uuid)
            } else {
                ContentUnavailableView {
                    Label("No Game Installed", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install the game on the Play page, then choose its mods here.")
                } actions: {
                    Button("Go to Play") { model.sidebar = .play }
                }
            }
        }
        .navigationTitle("Mods")
    }
}

/// What the Mods page edits: the catalog and the choices of one profile.
@Observable
final class ModsModel {
    let root: URL
    private(set) var packages: [ModPackage] = []
    private(set) var state = ModState()
    /// "Also turned on: …" after a switch changed others.
    var notice: String?
    var error: String?

    init(game: URL) {
        root = ModCatalog.root(game: game)
        reload()
    }

    /// Reads the packages and the choices again, after an install or a removal.
    func reload() {
        packages = ModCatalog.packages(in: root)
        state = ModState.read(from: root)
    }

    /// S-022: what each chosen file was found to be, by resource and path. Filled by `checkResource`.
    private(set) var resourceStatus: [String: ModResource.Status] = [:]

    private func statusKey(_ resource: ModResource, _ path: String) -> String {
        "\(resource.normalizedSHA256)|\(resource.size)|\(resource.format)|\(path)"
    }

    func path(of resource: ModResource, in feature: ModFeature) -> String {
        state.path(of: resource, in: feature, catalog: packages)
    }

    /// The last check of the resource's current file, or nil while it's being checked.
    func status(of resource: ModResource, in feature: ModFeature) -> ModResource.Status? {
        let path = path(of: resource, in: feature)
        return path.isEmpty ? .notChosen : resourceStatus[statusKey(resource, path)]
    }

    /// Checks the chosen file off the main thread (an 8 MB ROM is hashed).
    func checkResource(_ resource: ModResource, in feature: ModFeature) async {
        let path = path(of: resource, in: feature)
        let status = await Task.detached(priority: .userInitiated) { resource.status(of: path) }.value
        resourceStatus[statusKey(resource, path)] = status
    }

    /// A feature can't be turned on while a required file is missing or wrong (the game would refuse to start it).
    func isBlocked(_ feature: ModFeature) -> Bool {
        feature.resources.contains { $0.required && !(status(of: $0, in: feature)?.isUsable(required: true) ?? false) }
    }

    /// Chooses or clears ("") the file for a resource. Clearing a required one turns its feature off.
    func setPath(_ path: String, of resource: ModResource, in feature: ModFeature, log: (String) -> Void) {
        var next = state
        next.setPath(path, of: resource, in: feature)
        if path.isEmpty, resource.required, next.isEnabled(feature) { next.setEnabled(false, feature, in: packages) }
        if save(next) { log("\(feature.key) \(resource.id) = \(path.isEmpty ? "(none)" : path)") }
    }

    /// The packages the player installed in `profile`, by name.
    func installed(in profile: Profile) -> [ModPackage] {
        let ids = Set(profile.installedMods.map { String($0.split(separator: "/", maxSplits: 1)[0]) })
        return packages.filter { ids.contains($0.id) }
    }

    /// Features by group, groups in the order they first appear.
    func groups(matching search: String) -> [(name: String, features: [ModFeature])] {
        let all = packages.flatMap(\.features).filter { feature in
            search.isEmpty || feature.name.localizedCaseInsensitiveContains(search)
                || feature.description.localizedCaseInsensitiveContains(search)
                || feature.group.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        for feature in all where !order.contains(feature.group) { order.append(feature.group) }
        return order.map { group in (group, all.filter { $0.group == group }) }
    }

    func package(of feature: ModFeature) -> ModPackage? { packages.first { $0.id == feature.packageID } }

    func setEnabled(_ enabled: Bool, _ feature: ModFeature, log: (String) -> Void) {
        var next = state
        let others = next.setEnabled(enabled, feature, in: packages)
        guard save(next) else { return }
        log("\(feature.key) \(enabled ? "on" : "off")\(others.isEmpty ? "" : ", also changed: \(others.map(\.key).joined(separator: ", "))")")
        let on = others.filter { state.isEnabled($0) }.map(\.name)
        let off = others.filter { !state.isEnabled($0) }.map(\.name)
        var parts: [String] = []
        if !on.isEmpty { parts.append(String(localized: "Also turned on: \(on.formatted(.list(type: .and)))")) }
        if !off.isEmpty { parts.append(String(localized: "Turned off: \(off.formatted(.list(type: .and)))")) }
        notice = parts.isEmpty ? nil : parts.joined(separator: " ")
        if let notice { AccessibilityNotification.Announcement(notice).post() }
    }

    func setValue(_ value: String, of option: ModOption, in feature: ModFeature, log: (String) -> Void) {
        var next = state
        next.setValue(value, of: option, in: feature)
        if save(next) { log("\(feature.key) \(option.id) = \(value)") }
    }

    private func save(_ next: ModState) -> Bool {
        do {
            try next.write(to: root)
            state = next
            error = nil
            return true
        } catch {
            self.error = String(localized: "Unable to save your choice: \(error.localizedDescription)")
            return false
        }
    }
}

/// What the Mods page says after an install or a removal (S-021).
enum ModMessage: Equatable {
    case installed(name: String, version: String)
    case removed(name: String)
    case failed(String)

    var text: String {
        switch self {
        case .installed(let name, let version):
            String(localized: "Installed “\(name)” \(version). Its features are below, off until you turn them on.")
        case .removed(let name): String(localized: "Removed “\(name)”.")
        case .failed(let reason): reason
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }
}

extension ModArchive.Failure {
    /// Why a .snesmod wasn't installed, in the player's words.
    var message: String {
        switch self {
        case .notSnesmod: String(localized: "Only .snesmod files can be installed here.")
        case .damaged: String(localized: "This file is damaged or isn't a mod package.")
        case .encrypted: String(localized: "This package is password-protected. The game can't read encrypted packages.")
        case .unsupportedCompression:
            String(localized: "This package uses a compression the game can't read. Its author can zip it again with standard compression.")
        case .unsafePath(let path): String(localized: "This package has an unsafe file path (\(path)), so it wasn't installed.")
        case .tooManyFiles: String(localized: "This package has more than 4096 files, the game's limit.")
        case .tooLarge: String(localized: "This package is larger than 256 MB unpacked, the game's limit.")
        case .checksumFailed(let file): String(localized: "The file \(file) in this package is damaged. Download the package again.")
        case .noManifest: String(localized: "This isn't a mod package: it has no manifest.toml at its top level.")
        case .invalidManifest: String(localized: "This package's manifest.toml is incomplete or invalid, so the game can't load it.")
        case .wrongGame(let name, let games):
            String(localized: "“\(name)” is made for another game (\(games.formatted(.list(type: .and)))), not Super Metroid.")
        case .wrongROM(let name): String(localized: "“\(name)” is made for another version of Super Metroid than the one the game plays.")
        case .alreadyInstalled(let name, let version): String(localized: "“\(name)” \(version) is already installed.")
        case .writeFailed(let reason): String(localized: "Unable to install the package: \(reason)")
        }
    }
}

extension AppModel {
    /// Installs a .snesmod into `profile`'s game (S-021) and remembers it as the player's.
    func installMod(_ archive: URL, in profile: Profile, mods: ModsModel) async {
        guard game == nil else { return }
        let root = mods.root
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ModPackage, ModArchive.Failure> in
            let scoped = archive.startAccessingSecurityScopedResource()
            defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
            return Result { () throws(ModArchive.Failure) in try ModArchive.install(archive, into: root) }
        }.value
        switch result {
        case .success(let package):
            profile.installedMods.append("\(package.id)/\(package.version)")
            try? context.save()
            mods.reload()
            log.post(.info, "Installed \(package.id) \(package.version) from \(archive.lastPathComponent)", source: "Mods")
            modMessage = .installed(name: package.name, version: package.version)
        case .failure(let failure):
            log.post(.warning, "Refused \(archive.lastPathComponent): \(failure)", source: "Mods")
            modMessage = .failed(failure.message)
        }
        if let modMessage { AccessibilityNotification.Announcement(modMessage.text).post() }
    }

    /// Removes a package the player installed: every version they added, and its choices in state.toml.
    func removeMod(_ package: ModPackage, from profile: Profile, mods: ModsModel) {
        let mine = profile.installedMods.filter { $0.hasPrefix(package.id + "/") }
        do {
            for entry in mine {
                try ModArchive.remove(id: package.id, version: String(entry.dropFirst(package.id.count + 1)), from: mods.root)
            }
            profile.installedMods.removeAll { mine.contains($0) }
            try? context.save()
            log.post(.info, "Removed \(package.id) (\(mine.joined(separator: ", ")))", source: "Mods")
            modMessage = .removed(name: package.name)
        } catch {
            log.post(.error, "Unable to remove \(package.id): \(error)", source: "Mods")
            modMessage = .failed(String(localized: "Unable to remove “\(package.name)”. Quit the game and try again."))
        }
        mods.reload()
    }
}

private struct ModList: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var mods: ModsModel
    @State private var search = ""
    @State private var choosing = false
    @State private var dropTargeted = false
    @State private var removing: ModPackage?

    static let snesmod = UTType(filenameExtension: "snesmod", conformingTo: .zip) ?? .zip

    init(profile: Profile) {
        self.profile = profile
        _mods = State(initialValue: ModsModel(game: profile.gameFolder))
    }

    var body: some View {
        Form {
            Section {
                Text(model.isPlaying
                     ? String(localized: "The game is running. Changes apply the next time you play.")
                     : String(localized: "Changes apply the next time you play \(profile.name)."))
                    .foregroundStyle(.secondary)
                if let notice = mods.notice {
                    Label(notice, systemImage: "info.circle")
                }
                if let error = mods.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let message = model.modMessage {
                    if message.isFailure {
                        Label(message.text, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    } else {
                        Label(message.text, systemImage: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
            Section {
                let installed = mods.installed(in: profile)
                if installed.isEmpty {
                    Text("Drop a .snesmod file here, or choose Install Mod…, to add a package made for this game.")
                        .foregroundStyle(.secondary)
                }
                ForEach(installed) { package in
                    InstalledPackageRow(package: package) { removing = package }
                }
            } header: {
                Text("Your Packages")
            }
            if mods.packages.isEmpty {
                Section {
                    Text("This version of the game has no mods.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(mods.groups(matching: search), id: \.name) { group in
                Section(group.name) {
                    ForEach(group.features) { feature in
                        FeatureRow(feature: feature, mods: mods)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isPlaying)
        .searchable(text: $search, prompt: Text("Search Mods"))
        .toolbar {
            Button("Install Mod…", systemImage: "plus") { choosing = true }
                .disabled(model.isPlaying)
                .help(model.isPlaying ? String(localized: "Quit the game to install a mod") : String(localized: "Install a .snesmod package into \(profile.name)"))
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [Self.snesmod]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.installMod(url, in: profile, mods: mods) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isPlaying, let url = urls.first else { return false }
            Task { await model.installMod(url, in: profile, mods: mods) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(Palette.accent, lineWidth: Space.xs)
                    .padding(Space.sm)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { model.modMessage = nil }
        .confirmationDialog(Text("Remove “\(removing?.name ?? "")”?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { model.removeMod(removing, from: profile, mods: mods) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its features are turned off and its files deleted. Your saves are kept. You can install it again from its .snesmod file.")
        }
        .overlay {
            if !search.isEmpty, mods.groups(matching: search).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}

/// A package the player installed: name, version and author, and Remove (S-021).
private struct InstalledPackageRow: View {
    let package: ModPackage
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(package.name)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove…", action: remove)
                .help(String(localized: "Remove \(package.name) and its choices"))
        }
    }

    private var details: String {
        package.author.isEmpty
            ? String(localized: "Version \(package.version)")
            : String(localized: "Version \(package.version), by \(package.author)")
    }
}

private struct FeatureRow: View {
    @Environment(AppModel.self) private var model
    let feature: ModFeature
    let mods: ModsModel

    var body: some View {
        let enabled = mods.state.isEnabled(feature)
        let blocked = mods.isBlocked(feature)
        Toggle(isOn: Binding(get: { enabled }, set: { mods.setEnabled($0, feature, log: log) })) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(feature.name)
                    if feature.experimental {
                        Tag(text: String(localized: "Experimental"), symbol: "flask")
                    }
                }
                if !feature.description.isEmpty {
                    Text(feature.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(credit)
        .disabled(blocked && !enabled)
        if enabled || blocked {
            ForEach(feature.resources) { resource in
                ResourceRow(resource: resource, feature: feature, mods: mods)
                    .padding(.leading, Space.xl)
            }
        }
        if enabled {
            ForEach(feature.options) { option in
                OptionRow(option: option, feature: feature, mods: mods)
                    .padding(.leading, Space.xl)
            }
        }
    }

    private var credit: String {
        let package = mods.package(of: feature)?.name ?? feature.packageID
        let author = feature.author.isEmpty ? mods.package(of: feature)?.author ?? "" : feature.author
        return author.isEmpty ? String(localized: "From \(package)") : String(localized: "From \(package), by \(author)")
    }

    private func log(_ line: String) { model.log.post(.info, line, source: "Mods") }
}

/// A file a feature asks for (S-022): what's chosen and whether it's the right one, Choose… and Clear.
/// The game reads the file where it is; it's never copied.
private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    let resource: ModResource
    let feature: ModFeature
    let mods: ModsModel
    @State private var choosing = false

    var body: some View {
        let path = mods.path(of: resource, in: feature)
        let status = mods.status(of: resource, in: feature)
        LabeledContent {
            HStack(spacing: Space.sm) {
                if !path.isEmpty {
                    Button("Clear") { mods.setPath("", of: resource, in: feature, log: log) }
                        .help(resource.required ? String(localized: "Forget this file. The feature turns off until you choose another.") : String(localized: "Forget this file"))
                }
                Button(path.isEmpty ? String(localized: "Choose…") : String(localized: "Change…")) { choosing = true }
                    .help(resource.isFolder ? String(localized: "Choose a folder for \(resource.label)") : String(localized: "Choose a file for \(resource.label)"))
            }
        } label: {
            Text(resource.label)
            Label(statusText(status, path: path), systemImage: symbol(status))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(isProblem(status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .help(resource.description)
        .task(id: path) { await mods.checkResource(resource, in: feature) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: contentTypes) { result in
            guard case .success(let url) = result else { return }
            mods.setPath(url.path, of: resource, in: feature, log: log)
        }
        .fileDialogMessage(Text(resource.description.isEmpty ? resource.label : resource.description))
        .fileDialogConfirmationLabel(Text("Choose"))
    }

    private var contentTypes: [UTType] {
        if resource.isFolder { return [.folder] }
        let types = resource.extensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }

    private func isProblem(_ status: ModResource.Status?) -> Bool {
        switch status {
        case .notFound, .wrongSize, .wrongFile: true
        case .notChosen: resource.required
        default: false
        }
    }

    private func symbol(_ status: ModResource.Status?) -> String {
        switch status {
        case nil: "clock"
        case .notChosen: resource.required ? "exclamationmark.triangle.fill" : "circle.dashed"
        case .notFound, .wrongSize, .wrongFile: "exclamationmark.triangle.fill"
        case .verified: "checkmark.seal.fill"
        case .chosen: "doc"
        }
    }

    private func statusText(_ status: ModResource.Status?, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let expected = resource.fileDescription
        switch status {
        case nil: return String(localized: "Checking \(name)…")
        case .notChosen:
            if resource.required {
                return resource.isFolder ? String(localized: "Required: choose a folder to turn this on.")
                                         : String(localized: "Required: choose a file to turn this on.")
            }
            return expected.isEmpty ? String(localized: "Optional. Nothing chosen.") : String(localized: "Optional. Choose your copy of \(expected).")
        case .notFound: return String(localized: "\(name) wasn't found. It may have been moved or deleted.")
        case .wrongSize, .wrongFile:
            return expected.isEmpty ? String(localized: "\(name) isn't the file this feature needs.") : String(localized: "\(name) isn't \(expected).")
        case .verified: return String(localized: "\(name), checked")
        case .chosen: return name
        }
    }

    private func log(_ line: String) { model.log.post(.info, line, source: "Mods") }
}

private struct OptionRow: View {
    @Environment(AppModel.self) private var model
    let option: ModOption
    let feature: ModFeature
    let mods: ModsModel

    var body: some View {
        let value = mods.state.value(of: option, in: feature)
        Group {
            switch option.kind {
            case .boolean:
                Toggle(option.label, isOn: Binding(get: { value == "true" }, set: { set($0 ? "true" : "false") }))
            case .choice(let choices):
                Picker(option.label, selection: Binding(get: { value }, set: { set($0) })) {
                    ForEach(choices, id: \.value) { choice in
                        Text(choice.label.isEmpty ? choice.value : choice.label).tag(choice.value)
                    }
                }
            case .integer(let min, let max, let step):
                let number = Int(value) ?? min
                LabeledContent(option.label) {
                    HStack(spacing: Space.sm) {
                        Text(verbatim: "\(number)")
                            .monospacedDigit()
                        Stepper(option.label, value: Binding(get: { number }, set: { set(String($0)) }), in: min...max, step: step)
                            .labelsHidden()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(option.label))
                    .accessibilityValue(Text("\(number), from \(min) to \(max)"))
                }
                .help(String(localized: "From \(min) to \(max)"))
            }
        }
        .help(option.description)
    }

    private func set(_ value: String) {
        mods.setValue(value, of: option, in: feature) { model.log.post(.info, $0, source: "Mods") }
    }
}
