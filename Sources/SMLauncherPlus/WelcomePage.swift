import SMLauncherPlusKit
import SwiftUI
import UniformTypeIdentifiers

/// First run: pick the player's own Super Metroid ROM (S-001). Install starts from here (S-002).
/// Ported from AM2R Launcher Plus's WelcomePage.
struct WelcomePage: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    /// .sfc, .smc and .zip in the open panel.
    static let romTypes: [UTType] = [UTType(filenameExtension: "sfc"), UTType(filenameExtension: "smc"), .zip].compactMap { $0 }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Space.xxl) {
            VStack(spacing: Space.sm) {
                Text("Play Super Metroid on This Mac")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("SM Launcher Plus installs SuperMetroidRecomp, a native port of Super Metroid, from your own ROM and keeps it up to date.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            dropZone
            footer
            if model.forceWelcome, model.currentProfile != nil {
                Button("Back to Play") { model.forceWelcome = false }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $model.showChooser, allowedContentTypes: Self.romTypes) { result in
            if case .success(let url) = result { Task { await model.choose(url) } }
        }
        .onChange(of: model.welcome) {
            AccessibilityNotification.Announcement(title).post()
        }
    }

    private var dropZone: some View {
        Button { if !isChecking { model.showChooser = true } } label: {
            VStack(spacing: Space.md) {
                Group {
                    if isChecking {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 40))
                            .foregroundStyle(symbolStyle)
                    }
                }
                .frame(height: 48)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.rom?.path ?? detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gridProbe("drop-content", area: "drop-zone")
            .padding(Space.xxl)
            .frame(width: 440, height: 216)
            .cardBackground(highlighted: dropTargeted)
            .gridArea("drop-zone", inset: Space.xxl)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(dropTargeted ? Palette.accent : borderColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            }
            .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose your ROM")
        .accessibilityValue(title)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !isChecking else { return false }
            Task { await model.choose(url) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var footer: some View {
        switch model.welcome {
        case .ready:
            VStack(spacing: Space.sm) {
                Button("Install Game") { model.startInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("Choose Another…") { model.showChooser = true }
                    .buttonStyle(.borderless)
            }
        case .failed:
            Button("Choose Another…") { model.showChooser = true }
                .controlSize(.large)
        case .empty, .checking:
            VStack(spacing: Space.md) {
                Button("Choose…") { model.showChooser = true }
                    .controlSize(.large)
                    .disabled(isChecking)
                Text("Your ROM stays where it is. Nothing is uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isChecking: Bool { model.isCheckingROM }

    /// The result in three colors, each with its own symbol and words:
    /// green, the supported ROM; yellow, Super Metroid that fails the check; red, not Super Metroid.
    private enum Verdict { case match, wrongCopy, notSuperMetroid }

    private var verdict: Verdict? {
        switch model.welcome {
        case .ready: .match
        case .failed(let problem, _): problem.isSuperMetroid ? .wrongCopy : .notSuperMetroid
        case .empty, .checking: nil
        }
    }

    private var symbol: String {
        switch verdict {
        case .match: "checkmark.circle.fill"
        case .wrongCopy: "exclamationmark.triangle.fill"
        case .notSuperMetroid: "xmark.octagon.fill"
        case nil: "arrow.down.doc"
        }
    }

    private var verdictColor: Color? {
        switch verdict {
        case .match: .green
        case .wrongCopy: .yellow
        case .notSuperMetroid: .red
        case nil: nil
        }
    }

    private var symbolStyle: AnyShapeStyle {
        verdictColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    private var borderColor: Color {
        verdictColor?.opacity(0.7) ?? Color.secondary.opacity(0.4)
    }

    private var title: String {
        switch model.welcome {
        case .empty: String(localized: "Drop your ROM here, or choose it.")
        case .checking: String(localized: "Checking your ROM…")
        case .failed(let problem, _): problem.message
        case .ready: String(localized: "\(SupportedROM.name) found")
        }
    }

    private var detail: String? {
        switch model.welcome {
        case .empty: String(localized: ".sfc, .smc, or a .zip holding one")
        case .checking(let name), .failed(_, let name): name
        case .ready: model.rom?.name
        }
    }
}
