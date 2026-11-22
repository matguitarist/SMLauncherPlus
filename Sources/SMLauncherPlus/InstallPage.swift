import SwiftUI

/// Install progress (S-002, S-003): download, check, set up, with Cancel and Try Again.
/// Ported from AM2R Launcher Plus's InstallPage.
struct InstallPage: View {
    @Environment(AppModel.self) private var model
    let state: InstallState

    var body: some View {
        VStack(spacing: Space.xxl) {
            Text(state.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(InstallState.Step.allCases, id: \.self) { step in
                    row(step)
                }
            }
            .frame(width: 440, alignment: .leading)
            .padding(Space.xxl)
            .cardBackground()
            .gridArea("install-steps", inset: Space.xxl)
            footer
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.step) {
            AccessibilityNotification.Announcement(state.title(of: state.step)).post()
        }
        .onChange(of: state.failure) {
            if let failure = state.failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }

    private func row(_ step: InstallState.Step) -> some View {
        let status = status(of: step)
        return HStack(alignment: .top, spacing: Space.md) {
            Group {
                switch status {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .active: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            // One body line tall, so a spinner doesn't make its row taller than a check mark.
            .frame(width: Space.xl, height: Space.lg)
            .gridProbe("icon-\(step)", area: "install-steps", edge: nil)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(state.title(of: step))
                    .foregroundStyle(status == .pending ? .secondary : .primary)
                if step == .download, status == .active, state.bytesTotal > 0 {
                    ProgressView(value: Double(min(state.bytesDone, state.bytesTotal)), total: Double(state.bytesTotal))
                        .tint(Palette.accent)
                        .accessibilityLabel("Download")
                        .accessibilityValue("\(megabytes(state.bytesDone)) of \(megabytes(state.bytesTotal))")
                    Text("\(megabytes(state.bytesDone)) of \(megabytes(state.bytesTotal))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if status == .failed, let failure = state.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridProbe("step-\(step)", area: "install-steps")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.spoken)
    }

    @ViewBuilder private var footer: some View {
        if state.finishedName != nil {
            EmptyView()
        } else if state.failure != nil {
            HStack(spacing: Space.md) {
                Button("Cancel") { model.cancelInstall() }
                    .keyboardShortcut(.cancelAction)
                if state.step == .setUp {
                    Button("Show Log") { model.sidebar = .log }
                }
                Button("Try Again") {
                    let target = state.updating.flatMap { id in model.profiles.first { $0.uuid == id } }
                    model.install = nil
                    model.startInstall(updating: target)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        } else {
            Button("Cancel") { model.cancelInstall() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }

    private enum Status: Equatable {
        case pending, active, done, failed

        var spoken: String {
            switch self {
            case .pending: String(localized: "Waiting")
            case .active: String(localized: "In progress")
            case .done: String(localized: "Done")
            case .failed: String(localized: "Failed")
            }
        }
    }

    private func status(of step: InstallState.Step) -> Status {
        if state.finishedName != nil { return .done }
        if step < state.step { return .done }
        if step > state.step { return .pending }
        return state.failure == nil ? .active : .failed
    }

    private func megabytes(_ bytes: Int) -> String {
        bytes.formatted(.byteCount(style: .file).locale(.app))
    }
}
