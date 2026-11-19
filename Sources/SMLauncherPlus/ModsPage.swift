import SMLauncherPlusKit
import SwiftData
import SwiftUI

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
        packages = ModCatalog.packages(in: root)
        state = ModState.read(from: root)
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

private struct ModList: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var mods: ModsModel
    @State private var search = ""

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
        .overlay {
            if !search.isEmpty, mods.groups(matching: search).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}

private struct FeatureRow: View {
    @Environment(AppModel.self) private var model
    let feature: ModFeature
    let mods: ModsModel

    var body: some View {
        let enabled = mods.state.isEnabled(feature)
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
