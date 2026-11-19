import AppKit
import LogKitUI
import SMLauncherPlusKit
import SwiftUI

/// The game's own log of one run, in LogKit's viewer (S-005): levels, sources, search with ⌘F.
/// A sheet: a short look, then back to Play.
struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: LogSheetItem
    @State private var viewer: LogViewerModel

    init(item: LogSheetItem) {
        self.item = item
        _viewer = State(initialValue: LogViewerModel(file: LogFileSource(
            files: [.init(String(localized: "Game Log"), url: item.log)],
            folder: item.log.deletingLastPathComponent(),
            parser: GameReport.parser)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if Self.isEmpty(item.log) {
                    ContentUnavailableView("The game left no log.", systemImage: "doc.text",
                                           description: Text("It stopped before writing anything."))
                } else {
                    LogViewer(model: viewer, options: options)
                }
            }
            .navigationTitle(String(localized: "Log — \(item.profileName)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.log])
                    }
                    .help("Show the log file in Finder")
                }
            }
        }
        .frame(minWidth: 900, idealWidth: 900, minHeight: 420, idealHeight: 460)
        .onExitCommand { dismiss() }
        .noInitialFocus()
    }

    private var options: LogViewerOptions {
        var options = LogViewerOptions()
        options.emptyTitle = String(localized: "The game left no log.")
        options.emptyMessage = String(localized: "It stopped before writing anything.")
        return options
    }

    static func isEmpty(_ log: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) == 0
    }
}
