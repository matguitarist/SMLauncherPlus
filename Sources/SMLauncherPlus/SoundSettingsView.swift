import SMLauncherPlusKit
import SwiftUI

/// Settings > Sound (S-011): the current profile's sound on or off and its volume, written to its
/// config.ini. The game reads them when it starts, so they're locked while it runs.
struct SoundSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = SoundSettings()
    @State private var loadedFor: UUID?
    @State private var saveError: String?

    var body: some View {
        if let profile = model.currentProfile {
            form
                .task(id: LoadKey(profile: profile.uuid, playing: model.isPlaying)) { load(profile) }
                .onChange(of: settings) { old, new in
                    guard loadedFor == profile.uuid, old != new else { return }
                    save(profile)
                }
        } else {
            Section {
                Text("Install the game to choose how it sounds.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var form: some View {
        Section {
            Toggle("Play sound", isOn: $settings.enabled)
            LabeledContent("Volume") {
                HStack(spacing: Space.sm) {
                    // No step: its 21 tick marks would crowd the row; the binding moves in fives like the game's keys.
                    Slider(value: volume, in: 0...100) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .labelsHidden()
                    .accessibilityValue(Text(percent(settings.volume)))
                    // The widest value holds the place, so the slider keeps its length as the number changes.
                    ZStack(alignment: .trailing) {
                        Text(percent(100)).hidden()
                        Text(percent(settings.volume))
                    }
                    .monospacedDigit()
                    .accessibilityHidden(true)
                }
            }
            .disabled(!settings.enabled)
        } header: {
            Text("Sound")
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
            Text("Changes apply the next time you play \(model.currentProfile?.name ?? ""). While you play, Keypad + and Keypad − change the volume.")
        }
    }

    private var volume: Binding<Double> {
        Binding { Double(settings.volume) } set: { settings.volume = SoundSettings.clamp(Int(($0 / 5).rounded()) * 5) }
    }

    private func percent(_ volume: Int) -> String {
        (Double(volume) / 100).formatted(.percent)
    }

    // MARK: Files

    private func load(_ profile: Profile) {
        loadedFor = nil
        settings = SoundSettings.read(game: profile.gameFolder)
        saveError = nil
        loadedFor = profile.uuid
    }

    private func save(_ profile: Profile) {
        guard !model.isPlaying else { return }
        do {
            try settings.write(game: profile.gameFolder)
            saveError = nil
        } catch {
            saveError = String(localized: "Unable to save the sound settings: \(error.localizedDescription)")
            model.log.post(.error, "Unable to save the sound settings: \(error.localizedDescription)", source: "Settings")
        }
    }
}
