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
    case general, display, sound, appearance, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .display: String(localized: "Display")
        case .sound: String(localized: "Sound")
        case .appearance: String(localized: "Appearance")
        case .updates: String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "display"
        case .sound: "speaker.wave.2"
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
        AboutSection()
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
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    private var updatesNote: String {
        guard Updater.shared.isAvailable else { return String(localized: "Updates are off in this build.") }
        guard let last = Updater.shared.lastCheck else { return String(localized: "Looks once a day for a new version on GitHub.") }
        return String(localized: "Looks once a day for a new version on GitHub. Last checked \(last.formatted(.relative(presentation: .named))).")
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
