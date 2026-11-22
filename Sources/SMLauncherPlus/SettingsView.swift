import AppKit
import SMLauncherPlusKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic, at most about
/// six. Each tab is a grouped Form that sizes to its content, so the
/// window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .display: DisplaySettingsView()
            case .sound: SoundSettingsView()
            case .controls: ControlsSettingsView()
            case .appearance: AppearanceSettings()
            case .updates: UpdateSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, display, sound, controls, appearance, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .display: String(localized: "Display")
        case .sound: String(localized: "Sound")
        case .controls: String(localized: "Controls")
        case .appearance: String(localized: "Appearance")
        case .updates: String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "display"
        case .sound: "speaker.wave.2"
        case .controls: "gamecontroller"
        case .appearance: "paintpalette"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Language") {
            Picker("Language", selection: $model.language) {
                Text("System (\(AppLanguage.systemName))").tag(AppLanguage.system)
                // Every language the app is translated into, each named in itself.
                ForEach(AppLanguage.available, id: \.self) { language in
                    Text(verbatim: language.name).tag(language)
                }
            }
            if model.language != AppLanguage.atLaunch {
                HStack {
                    Text("The new language applies after a restart.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                }
            }
        }
        DataFolderSection()
        AboutSection()
    }
}

/// Settings › General's Data Folder (S-013): where profiles, downloads and logs live, and Move… to another drive.
/// Ported from AM2R Launcher Plus. The database stays in Application Support.
struct DataFolderSection: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var size: Int64?

    var body: some View {
        let folder = DataFolder.url
        Section {
            LabeledContent("Location") {
                Text(verbatim: folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(folder.path(percentEncoded: false))
            }
            LabeledContent("Size") {
                Text(size.map { $0.formatted(.byteCount(style: .file).locale(.app)) } ?? String(localized: "Calculating…"))
            }
            if let move = model.dataMove {
                ProgressView(value: Double(move.done), total: Double(max(move.total, 1))) {
                    Text("Moving the data folder…")
                }
            }
            if DataFolder.isMissing {
                Label("The disk with the data folder isn't connected. Connect it, then reopen SM Launcher Plus.", systemImage: "externaldrive.badge.exclamationmark")
                    .symbolRenderingMode(.multicolor)
            }
            if let error = model.dataMoveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            HStack {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .help("Show the data folder in Finder")
                    .disabled(DataFolder.isMissing)
                Button("Move…") { choosing = true }
                    .help("Move profiles, saves and downloads to another folder, such as an external drive")
                    .disabled(model.game != nil || model.install != nil || model.dataMove != nil || DataFolder.isMissing)
            }
        } header: {
            Text("Data Folder")
        } footer: {
            Text(footer)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let parent) = result else { return }
            Task {
                await model.moveDataFolder(into: parent)
                await measure()
            }
        }
        .task { await measure() }
    }

    private var footer: String {
        if model.game != nil { return String(localized: "Quit the game to move the data folder.") }
        if model.install != nil { return String(localized: "Wait for the install to finish to move the data folder.") }
        return String(localized: "Profiles with their saves, downloads and logs. Moving copies them, checks the copy, then deletes the old folder.")
    }

    private func measure() async {
        size = await Task.detached(priority: .utility) { DataFolder.size() }.value
    }
}

/// Settings > General's About (S-006): both versions, and credit for the game with its license.
struct AboutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("SM Launcher Plus", value: UpdateSettings.version)
            LabeledContent(Credits.gameName) {
                Text(model.currentProfile?.gameVersion ?? String(localized: "Not installed"))
            }
            LabeledContent("Made by") {
                Text(verbatim: Credits.gameAuthor)
            }
            LabeledContent("License") {
                Link(Credits.licenseName, destination: Credits.license)
            }
            HStack {
                Link("Game Project", destination: Credits.project)
                Spacer()
                Link("Extra Permissions", destination: Credits.permissions)
                Spacer()
                Link("snesrecomp Framework", destination: Credits.framework)
            }
        } header: {
            Text("About")
        } footer: {
            Text("SM Launcher Plus ships no game files. It downloads SuperMetroidRecomp from its own releases, and your ROM stays where it is. Unofficial: not affiliated with Nintendo or the game's authors.")
        }
    }
}

/// The About panel's credits (S-006), with links to the game, its license and its framework.
enum AboutCredits {
    static func make(gameVersion: String?) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        func add(_ string: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let installed = gameVersion.map { String(localized: "\(Credits.gameName) \($0) installed") } ?? String(localized: "\(Credits.gameName) not installed yet")
        add(installed + "\n")
        add(String(localized: "The game is by \(Credits.gameAuthor), built on ") )
        add("snesrecomp", link: Credits.framework)
        add(".\n")
        add(Credits.gameName, link: Credits.project)
        add(" · ")
        add(Credits.licenseName, link: Credits.license)
        add("\n\n")
        add(String(localized: "SM Launcher Plus ships no game files. Your ROM stays where it is."))
        return text
    }

    @MainActor static func show(gameVersion: String?) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: make(gameVersion: gameVersion)])
        NSApp.activate()
    }
}

/// Settings > Updates: Sparkle's automatic checks.
struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Automatic Updates") {
            Toggle(isOn: $model.checksForUpdates) {
                Text("Check for updates automatically")
                Text(updatesNote)
            }
            .disabled(!Updater.shared.isAvailable)
            LabeledContent("Version \(Self.version)") {
                Button("Check Now") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.isAvailable)
            }
        }
        GameUpdateSection()
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    private var updatesNote: String {
        guard Updater.shared.isAvailable else { return String(localized: "Updates are off in this build.") }
        guard let last = Updater.shared.lastCheck else { return String(localized: "Looks once a day for a new version on GitHub.") }
        return String(localized: "Looks once a day for a new version on GitHub. Last checked \(last.formatted(.relative(presentation: .named))).")
    }
}

/// Settings › Updates: SuperMetroidRecomp's releases (S-030), checked once a day; Update and Roll Back (S-031).
struct GameUpdateSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRollBack = false

    var body: some View {
        let profile = model.currentProfile
        let update = profile.flatMap { model.availableUpdate(for: $0) }
        Section {
            LabeledContent {
                HStack(spacing: Space.sm) {
                    if model.checkingForUpdates || model.install?.updating != nil { ProgressView().controlSize(.small) }
                    if let profile, update != nil, model.install?.updating == nil {
                        Button("Update") { model.update(profile) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canUpdate)
                            .help(model.isPlaying ? String(localized: "Quit the game to update")
                                                  : String(localized: "Your saves, settings and mods stay. (⇧⌘U)"))
                    } else {
                        Button("Check Now") { Task { await model.checkForGameUpdate(force: true) } }
                            .disabled(model.checkingForUpdates || profile == nil || model.install != nil)
                    }
                }
            } label: {
                Text(Credits.gameName)
                Text(status(profile: profile, update: update))
            }
            if let profile, let previous = model.previousVersion(of: profile) {
                LabeledContent {
                    Button("Roll Back…") { confirmRollBack = true }
                        .disabled(model.isPlaying || model.install != nil)
                } label: {
                    Text("Version \(previous) is kept")
                    Text("Go back to it if \(profile.gameVersion) gives you trouble. Your saves come along.")
                }
                .confirmationDialog("Go back to \(previous)?", isPresented: $confirmRollBack) {
                    Button("Roll Back") { Task { await model.rollBack(profile) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your saves, settings and mods come along. \(profile.gameVersion) is removed; Update installs it again.")
                }
            }
            if let message = model.updateCheckMessage {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Game")
        } footer: {
            Text("SM Launcher Plus looks for a new version of the game on GitHub once a day. Updating keeps your saves, settings and mods.")
        }
    }

    private func status(profile: Profile?, update: UpdateCheck.Latest?) -> String {
        if let updating = model.install, updating.updating != nil {
            return updating.version.map { String(localized: "Updating to \($0)…") } ?? String(localized: "Updating…")
        }
        guard let profile else { return String(localized: "Not installed yet.") }
        guard let latest = model.latestUpdate else { return String(localized: "You have \(profile.gameVersion). Not checked yet.") }
        if let update { return String(localized: "Version \(update.version) is available. You have \(profile.gameVersion).") }
        let when = latest.checkedAt.formatted(.relative(presentation: .named).locale(.app))
        return String(localized: "You have the latest version, \(profile.gameVersion). Checked \(when).")
    }
}

/// The app's own language, independent of macOS's. Stored as the app's
/// AppleLanguages default, which macOS reads at launch. The choices come
/// from the bundle, so adding a translation adds it here.
struct AppLanguage: Hashable {
    /// A localization code ("fr", "pt-BR"), or nil to follow macOS.
    let code: String?

    static let system = AppLanguage(code: nil)
    private static let key = "AppleLanguages"

    /// The app's translations, sorted by their own names.
    static let available: [AppLanguage] = Set(Bundle.main.localizations)  // can list one twice
        .subtracting(["Base"])
        .map { AppLanguage(code: $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// "Français", "English".
    var name: String {
        guard let code else { return "" }
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let stored = (domain?[key] as? [String])?.first else { return .system }
        // "fr-CA" set elsewhere still selects "fr".
        let codes = available.compactMap(\.code)
        guard let match = Bundle.preferredLocalizations(from: codes, forPreferences: [stored]).first,
              codes.contains(match) else { return .system }
        return AppLanguage(code: match)
    }

    /// What this run of the app uses (the setting can change after launch).
    static let atLaunch = current

    /// The language macOS would pick for the app, by name ("Français").
    static var systemName: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? Locale.preferredLanguages
        let code = Bundle.preferredLocalizations(from: available.compactMap(\.code), forPreferences: global).first ?? "en"
        return AppLanguage(code: code).name
    }

    /// Test and snapshot runs never change the real setting.
    func apply() {
        guard !Store.isOverridden else { return }
        if let code {
            UserDefaults.standard.set([code], forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
