import SMLauncherPlusKit
import SwiftUI

/// Settings > Display (S-010): the current profile's window, widescreen and filter, written to its
/// config.ini and sm-video.ini. The game reads them when it starts, so they're locked while it runs.
struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = DisplaySettings()
    @State private var presets: [ShaderPreset] = []
    @State private var loadedFor: UUID?
    @State private var saveError: String?

    var body: some View {
        if let profile = model.currentProfile {
            form(profile)
                .task(id: LoadKey(profile: profile.uuid, playing: model.isPlaying)) { load(profile) }
                .onChange(of: settings) { old, new in
                    guard loadedFor == profile.uuid, old != new else { return }
                    save(profile)
                }
        } else {
            Section {
                Text("Install the game to choose how it looks.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func form(_ profile: Profile) -> some View {
        Section {
            Toggle("Fullscreen", isOn: $settings.fullscreen)
            Toggle(isOn: $settings.vsync) {
                Text("VSync")
                Text("Smooth motion with no tearing. Off lowers input lag a little.")
            }
        } header: {
            Text("Window")
        }
        .disabled(model.isPlaying)
        Section {
            Picker("Widescreen", selection: $settings.widescreen) {
                Text("Off (original 4:3)").tag(Widescreen.off)
                Text("Fit to window").tag(Widescreen.fit)
                Text(verbatim: "16:9").tag(Widescreen.wide)
                Text(verbatim: "21:9").tag(Widescreen.ultrawide)
                Text(verbatim: "32:9").tag(Widescreen.superUltrawide)
            }
            .help("Show more of each room on a wide window")
            Picker("Energy and Map", selection: $settings.hudAtEdges) {
                Text("At the window's edges").tag(true)
                Text("Over the original picture").tag(false)
            }
            .disabled(settings.widescreen == .off)
            Picker("Filter", selection: filterLook) {
                Text("None").tag("")
                ForEach(looks, id: \.self) { look in
                    Text(Self.title(look: look)).tag(look)
                }
                if isCustomShader {
                    Text("Other (\((settings.shader as NSString).lastPathComponent))").tag(customLook)
                }
            }
            .help("Draw scanlines or an old CRT screen over the game")
            if strengths.count > 1 {
                Picker("Strength", selection: filterStrength) {
                    ForEach(strengths, id: \.self) { strength in
                        Text(Self.title(strength: strength)).tag(strength)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Picture")
        } footer: {
            footer
        }
        .disabled(model.isPlaying)
        if let saveError {
            Section {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isPlaying {
            Text("Quit the game to change these settings.")
        } else {
            Text("Changes apply the next time you play \(model.currentProfile?.name ?? "").")
        }
    }

    // MARK: Filter

    /// Kinds of filter in the profile, in the folder's order: "scanlines", "crt", then any the player added.
    private var looks: [String] {
        presets.map(\.look).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var current: ShaderPreset? { presets.first { $0.path == settings.shader } }
    private var isCustomShader: Bool { !settings.shader.isEmpty && current == nil }
    private let customLook = "\u{1}custom"

    private var strengths: [String] {
        guard let look = current?.look else { return [] }
        return presets.filter { $0.look == look }.map(\.strength)
    }

    /// Picking a kind keeps the strength when that kind has it, else takes its middle one.
    private var filterLook: Binding<String> {
        Binding {
            current?.look ?? (isCustomShader ? customLook : "")
        } set: { look in
            guard look != customLook else { return }
            guard !look.isEmpty else { settings.shader = ""; return }
            let options = presets.filter { $0.look == look }
            let pick = options.first { $0.strength == (current?.strength ?? "") }
                ?? options.first { $0.strength.isEmpty } ?? options.first
            if let pick { settings.shader = pick.path }
        }
    }

    private var filterStrength: Binding<String> {
        Binding {
            current?.strength ?? ""
        } set: { strength in
            if let pick = presets.first(where: { $0.look == current?.look && $0.strength == strength }) { settings.shader = pick.path }
        }
    }

    static func title(look: String) -> String {
        switch look {
        case "scanlines": String(localized: "Scanlines")
        case "crt": String(localized: "CRT")
        case "crt-soft": String(localized: "CRT Soft")
        case "sharp": String(localized: "Sharp")
        case "lcd-grid": String(localized: "LCD Grid")
        case "warm-composite": String(localized: "Warm Composite")
        default: look.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func title(strength: String) -> String {
        switch strength {
        case "light": String(localized: "Light")
        case "strong": String(localized: "Strong")
        case "": String(localized: "Medium")
        default: strength.capitalized
        }
    }

    // MARK: Files

    private func load(_ profile: Profile) {
        loadedFor = nil
        settings = DisplaySettings.read(game: profile.gameFolder)
        presets = ShaderPreset.list(game: profile.gameFolder)
        saveError = nil
        loadedFor = profile.uuid
    }

    private func save(_ profile: Profile) {
        guard !model.isPlaying else { return }
        do {
            try settings.write(game: profile.gameFolder)
            saveError = nil
        } catch {
            saveError = String(localized: "Unable to save the display settings: \(error.localizedDescription)")
            model.log.post(.error, "Unable to save the display settings: \(error.localizedDescription)", source: "Settings")
        }
    }
}

/// Reloads the settings when the profile changes or a game ends.
struct LoadKey: Equatable {
    var profile: UUID
    var playing: Bool
}
