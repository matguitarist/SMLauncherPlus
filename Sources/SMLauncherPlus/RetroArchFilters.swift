import SMLauncherPlusKit
import SwiftData
import SwiftUI

extension DataFolder {
    /// `RetroArch Filters/`: the downloaded files, as in the repo (S-014). Copied into each profile.
    static var retroArchFilters: URL { url.appending(path: "RetroArch Filters", directoryHint: .isDirectory) }
}

extension RetroArchFilter.Failure {
    var message: String {
        switch self {
        case .offline: String(localized: "Unable to reach GitHub. Check your internet connection and try again.")
        case .github(let status): String(localized: "GitHub answered with an error (\(status)). Try again later.")
        case .damaged(let path): String(localized: "A file didn't match its checksum, so nothing was added: \(path)")
        case .failed(let reason): String(localized: "Unable to save the filters: \(reason)")
        }
    }
}

/// S-014: download the RetroArch filters the launcher offers, and add them to every profile.
extension AppModel {
    var hasRetroArchFilters: Bool { RetroArchFilter.isDownloaded(in: DataFolder.retroArchFilters) }

    func downloadRetroArchFilters() async {
        guard retroArchProgress == nil else { return }
        retroArchProgress = 0
        retroArchError = nil
        defer { retroArchProgress = nil }
        do {
            try await RetroArchFilter.download(into: DataFolder.retroArchFilters) { value in
                Task { @MainActor in if self.retroArchProgress != nil { self.retroArchProgress = value } }
            }
            log.post(.info, "Downloaded \(RetroArchFilter.all.count) RetroArch filters at \(RetroArchFilter.commit.prefix(7))", source: "Display")
            for profile in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] { installFilters(in: profile.gameFolder) }
            retroArchChanges += 1
        } catch {
            log.post(.error, "Unable to download the RetroArch filters: \(error)", source: "Display")
            retroArchError = error.message
        }
    }

    /// Removes them from the data folder and every profile; a profile using one goes back to no filter.
    func removeRetroArchFilters() {
        let fm = FileManager.default
        for profile in (try? context.fetch(FetchDescriptor<Profile>())) ?? [] {
            let game = profile.gameFolder
            var settings = DisplaySettings.read(game: game)
            if settings.shader.hasPrefix("\(ShaderPreset.folder)/\(RetroArchFilter.folder)/") {
                settings.shader = ""
                try? settings.write(game: game)
            }
            RetroArchFilter.uninstall(game: game)
        }
        try? fm.removeItem(at: DataFolder.retroArchFilters)
        retroArchError = nil
        retroArchChanges += 1
        log.post(.info, "Removed the RetroArch filters", source: "Display")
    }
}

/// The row under Filter in Settings › Display: download, progress, or what's there.
struct RetroArchFiltersRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        let names = ["crt-lottes", "crt-geom", "hq4x"].compactMap { RetroArchFilter.named($0)?.name }.formatted(.list(type: .and).locale(.app))
        LabeledContent {
            if let progress = model.retroArchProgress {
                ProgressView(value: progress)
                    .tint(Palette.accent)
                    .frame(width: 120)
            } else if model.hasRetroArchFilters {
                Button("Remove…") { confirmRemove = true }
                    .disabled(model.isPlaying)
            } else {
                Button("Download") { Task { await model.downloadRetroArchFilters() } }
                    .help("Download them from RetroArch's shader collection on GitHub")
            }
        } label: {
            Text("RetroArch Filters")
            if model.hasRetroArchFilters {
                Text("\(RetroArchFilter.all.count) filters from RetroArch's collection are in the Filter menu.")
            } else {
                Text("\(RetroArchFilter.all.count) filters from RetroArch's collection, tried with Super Metroid, such as \(names). About 100 KB.")
            }
        }
        .confirmationDialog("Remove the RetroArch filters?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeRetroArchFilters() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiles using one go back to no filter. You can download them again later.")
        }
        if let error = model.retroArchError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }
}
