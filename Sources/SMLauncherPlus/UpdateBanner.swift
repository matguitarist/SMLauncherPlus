import SMLauncherPlusKit
import SwiftData
import SwiftUI

/// S-030: whether a newer SuperMetroidRecomp exists. Ported from AM2R Launcher Plus: checked at most
/// once a day, the answer kept in the data folder so the banner shows offline too.
extension AppModel {
    func checkForGameUpdate(force: Bool = false) async {
        guard !checkingForUpdates, force || UpdateCheck.isDue(lastCheck: latestUpdate?.checkedAt) else { return }
        guard ((try? context.fetchCount(FetchDescriptor<Profile>())) ?? 0) > 0 else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        updateCheckMessage = nil
        do {
            let latest = try await UpdateCheck.fetch(session: Self.installSession)
            log.post(.info, "Latest SuperMetroidRecomp: \(latest.version)", source: "Updates")
            latestUpdate = latest
            try? UpdateCheck.write(latest, to: DataFolder.latestUpdate)
            if force, let profile = currentProfile, availableUpdate(for: profile) == nil {
                updateCheckMessage = String(localized: "\(profile.name) has the latest version, \(profile.gameVersion).")
            }
        } catch {
            log.post(.warning, "Update check failed: \(error)", source: "Updates")
            if force { updateCheckMessage = error.message }
        }
    }

    /// The newer release for `profile`, or nil when it has the latest one (or nothing was checked yet).
    func availableUpdate(for profile: Profile) -> UpdateCheck.Latest? {
        guard let latestUpdate, UpdateCheck.isNewer(latestUpdate.version, than: profile.gameVersion) else { return nil }
        return latestUpdate
    }
}

/// "SuperMetroidRecomp 0.4.7 is available" with What's New, on the Play page.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    let latest: UpdateCheck.Latest
    let profile: Profile

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Space.lg) {
            Label(String(localized: "SuperMetroidRecomp \(latest.version) is available"), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Palette.accentText)
                .gridProbe("update-message", area: "update-banner")
            Spacer(minLength: Space.lg)
            Button("What's New") { model.showWhatsNew = true }
                .help(String(localized: "Read what changed since \(profile.gameVersion)"))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(width: 480)
        .cardBackground(Radius.banner)
        .gridArea("update-banner", inset: Space.md)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $model.showWhatsNew) {
            WhatsNewSheet(notes: latest.notes(since: profile.gameVersion), latest: latest.version, installed: profile.gameVersion)
        }
    }
}

/// The release notes of every version newer than the profile's, newest first.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let notes: [UpdateCheck.Notes]
    let latest: String
    let installed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("What's New in SuperMetroidRecomp \(latest)")
                    .font(.title2.bold())
                Text("You have \(installed).")
                    .foregroundStyle(.secondary)
            }
            .padding(Space.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if notes.isEmpty {
                        Text("This release has no notes.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notes, id: \.version) { release in
                        ReleaseNotesView(notes: release)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.xl)
            }
            .fitsContent(max: 420)
            Divider()
            HStack {
                if let page = notes.first?.page {
                    Link("View on GitHub", destination: page)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .frame(width: 560)
        .noInitialFocus()
    }
}

/// One release: its version and date, then its notes laid out as headings, paragraphs and bullets.
private struct ReleaseNotesView: View {
    let notes: UpdateCheck.Notes

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: notes.version)
                    .font(.headline)
                if let published = notes.published {
                    Text(published.formatted(.dateTime.day().month(.wide).year().locale(.app)))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(ReleaseNotes.blocks(notes.body).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    // The release's own title repeats the version; the others are section headings.
                    if !text.contains(notes.version) {
                        Text(inline(text)).font(.subheadline.bold())
                    }
                case .paragraph(let text):
                    Text(inline(text))
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(verbatim: "•")
                        Text(inline(text))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// **bold**, *italic*, `code` and links inside a line.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
