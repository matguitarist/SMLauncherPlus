import AppKit
import GameController
import SMLauncherPlusKit
import SwiftUI

/// Settings > Controls (S-012): the connected controller, and player 1's key and controller button for
/// each SNES button, written to the profile's keybinds.ini and config.ini. Locked while the game runs.
struct ControlsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = ControlSettings()
    /// config.ini, read for the game's shortcuts that a key would also start.
    @State private var config = IniFile(text: "")
    @State private var loadedFor: UUID?
    @State private var saveError: String?
    @State private var controllers = ControllerMonitor()
    /// The button waiting for a key press.
    @State private var listening: SNESButton?
    @State private var monitor: Any?

    var body: some View {
        if let profile = model.currentProfile {
            form
                .task(id: LoadKey(profile: profile.uuid, playing: model.isPlaying)) { load(profile) }
                .onChange(of: settings) { old, new in
                    guard loadedFor == profile.uuid, old != new else { return }
                    save(profile)
                }
                .onChange(of: listening) { _, button in button == nil ? stopListening() : startListening() }
                .onDisappear { listening = nil }
        } else {
            Section {
                Text("Install the game to choose its controls.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var form: some View {
        Section {
            // Neutral controls: a column of accent-colored keys and buttons would shout.
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.xs) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Button")
                    Text("Keyboard")
                    VStack(alignment: .leading) {
                        Text("Controller")
                        Text(connected)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(connected)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ForEach(SNESButton.display) { button in
                    GridRow {
                        HStack(spacing: Space.xs) {
                            Text(button.title)
                            if let action = button.action {
                                Text(action).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        keyCell(button)
                        Picker(button.title, selection: padBinding(button)) {
                            ForEach(PadButton.all, id: \.self) { name in
                                Text(PadButton.title(name)).tag(name)
                            }
                            if let value = settings.buttons[button], PadButton.match(value) == nil {
                                Text("Other (\(value))").tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .tint(.primary)
            HStack {
                Spacer()
                Button("Restore Defaults") { settings = ControlSettings() }
                    .disabled(settings == ControlSettings())
            }
        } header: {
            Text("Player 1")
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
            Text("Click a key, then press the new one. The keyboard and a controller work at the same time. Changes apply the next time you play \(model.currentProfile?.name ?? "").")
        }
    }

    /// The Controller column's heading names what's connected now.
    private var connected: String {
        controllers.names.isEmpty ? String(localized: "None connected") : controllers.names.formatted(.list(type: .and))
    }

    // MARK: Keyboard

    private func keyCell(_ button: SNESButton) -> some View {
        let warning = conflict(button)
        return HStack(spacing: Space.xs) {
            Button {
                listening = listening == button ? nil : button
            } label: {
                Text(listening == button ? String(localized: "Press a key…") : KeyTitle.title(settings.keys[button] ?? "None"))
                    .foregroundStyle(listening == button ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.primary))
                    .frame(minWidth: 112)
            }
            .buttonStyle(.bordered)
            .contextMenu {
                Button("Clear Key") { settings.keys[button] = "None" }
                Button("Restore Default Key") { settings.keys[button] = ControlSettings.defaultKeys[button] }
            }
            .accessibilityLabel(Text("Key for \(button.title)"))
            .accessibilityValue(Text(KeyTitle.title(settings.keys[button] ?? "None")))
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .opacity(warning == nil ? 0 : 1)
                .help(warning ?? "")
                .accessibilityHidden(warning == nil)
                .accessibilityLabel(Text(warning ?? ""))
        }
    }

    /// Why a key may surprise the player: another button, or one of the game's shortcuts, uses it too.
    private func conflict(_ button: SNESButton) -> String? {
        let others = settings.buttons(sharingKeyOf: button)
        if !others.isEmpty {
            return String(localized: "Also used for \(others.map(\.title).formatted(.list(type: .and))).")
        }
        let hotkeys = ControlSettings.hotkeys(using: settings.keys[button] ?? "None", in: config)
        if !hotkeys.isEmpty {
            return String(localized: "Also starts a game shortcut: \(hotkeys.formatted(.list(type: .and))). Change it in config.ini.")
        }
        return nil
    }

    private func startListening() {
        stopListening()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let button = listening else { return event }
            if event.type == .keyDown, event.keyCode == 53 {  // Escape cancels, as in any Mac field.
                listening = nil
                return nil
            }
            if event.type == .flagsChanged {
                // A modifier counts when it goes down, not when it's released.
                guard SDLKeyName.modifierKeyCodes.contains(event.keyCode), Self.isDown(event) else { return nil }
            }
            if let name = SDLKeyName.name(macKeyCode: event.keyCode) {
                settings.keys[button] = name
                listening = nil
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func isDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return flags.contains(.shift)
        case 59, 62: return flags.contains(.control)
        case 58, 61: return flags.contains(.option)
        case 55, 54: return flags.contains(.command)
        case 57: return flags.contains(.capsLock)
        default: return false
        }
    }

    // MARK: Controller

    private func padBinding(_ button: SNESButton) -> Binding<String> {
        Binding {
            let value = settings.buttons[button] ?? ""
            return PadButton.match(value) ?? value
        } set: { name in
            // Picking the same button again keeps the spelling in the file (L1 stays L1).
            if PadButton.match(settings.buttons[button] ?? "") != name { settings.buttons[button] = name }
        }
    }

    // MARK: Files

    private func load(_ profile: Profile) {
        loadedFor = nil
        listening = nil
        settings = ControlSettings.read(game: profile.gameFolder)
        config = IniFile(text: (try? String(contentsOf: DisplaySettings.configFile(game: profile.gameFolder), encoding: .utf8)) ?? "")
        saveError = nil
        loadedFor = profile.uuid
    }

    private func save(_ profile: Profile) {
        guard !model.isPlaying else { return }
        do {
            try settings.write(game: profile.gameFolder)
            saveError = nil
        } catch {
            saveError = String(localized: "Unable to save the controls: \(error.localizedDescription)")
            model.log.post(.error, "Unable to save the controls: \(error.localizedDescription)", source: "Settings")
        }
    }
}

extension SNESButton {
    var title: String {
        switch self {
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .start: String(localized: "Start")
        case .select: String(localized: "Select")
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l: "L"
        case .r: "R"
        }
    }

    /// What the button does in Super Metroid with its default controller setup.
    var action: String? {
        switch self {
        case .b: String(localized: "Jump")
        case .y: String(localized: "Shoot")
        case .a: String(localized: "Run")
        case .x: String(localized: "Cancel item")
        case .l: String(localized: "Aim down")
        case .r: String(localized: "Aim up")
        case .start: String(localized: "Pause")
        case .select: String(localized: "Switch item")
        default: nil
        }
    }
}

/// The controller buttons the game knows, named by where they sit so the names fit any controller.
enum PadButton {
    static let all = ["DpadUp", "DpadDown", "DpadLeft", "DpadRight", "A", "B", "X", "Y",
                      "Lb", "Rb", "L2", "R2", "L3", "R3", "Back", "Start", "Guide"]

    /// The list's name for a value in the file, with the game's aliases (L1 is Lb); nil for a combination.
    static func match(_ value: String) -> String? {
        let alias = ["l1": "Lb", "r1": "Rb"][value.lowercased()]
        return alias ?? all.first { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    static func title(_ name: String) -> String {
        switch name {
        case "DpadUp": String(localized: "D-pad Up")
        case "DpadDown": String(localized: "D-pad Down")
        case "DpadLeft": String(localized: "D-pad Left")
        case "DpadRight": String(localized: "D-pad Right")
        case "A": String(localized: "Bottom Button")
        case "B": String(localized: "Right Button")
        case "X": String(localized: "Left Button")
        case "Y": String(localized: "Top Button")
        case "Lb": String(localized: "Left Shoulder")
        case "Rb": String(localized: "Right Shoulder")
        case "L2": String(localized: "Left Trigger")
        case "R2": String(localized: "Right Trigger")
        case "L3": String(localized: "Left Stick Press")
        case "R3": String(localized: "Right Stick Press")
        case "Back": String(localized: "Back (View)")
        case "Start": String(localized: "Start (Menu)")
        case "Guide": String(localized: "Home")
        default: name
        }
    }
}

/// Mac names for SDL's key names.
enum KeyTitle {
    static func title(_ name: String) -> String {
        switch name.lowercased() {
        case "none", "": String(localized: "Not set")
        case "up": String(localized: "Up Arrow")
        case "down": String(localized: "Down Arrow")
        case "left": String(localized: "Left Arrow")
        case "right": String(localized: "Right Arrow")
        case "return", "enter": String(localized: "Return")
        case "space": String(localized: "Space")
        case "tab": String(localized: "Tab")
        case "escape": String(localized: "Escape")
        case "backspace": String(localized: "Delete")
        case "delete": String(localized: "Forward Delete")
        case "capslock": String(localized: "Caps Lock")
        case "left shift", "lshift": String(localized: "Left Shift")
        case "right shift", "rshift": String(localized: "Right Shift")
        case "left ctrl", "lctrl": String(localized: "Left Control")
        case "right ctrl", "rctrl": String(localized: "Right Control")
        case "left alt": String(localized: "Left Option")
        case "right alt": String(localized: "Right Option")
        case "left gui": String(localized: "Left Command")
        case "right gui": String(localized: "Right Command")
        default: name.hasPrefix("Keypad") ? name.replacingOccurrences(of: "Keypad", with: String(localized: "Keypad")) : name
        }
    }
}

/// Names of the connected game controllers, kept current as they connect and disconnect.
/// Ported from AM2R Launcher Plus.
@MainActor @Observable
final class ControllerMonitor {
    private(set) var names: [String] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        names = Self.connected()
    }

    static func connected() -> [String] {
        GCController.controllers().map { $0.vendorName ?? String(localized: "Controller") }
    }
}
