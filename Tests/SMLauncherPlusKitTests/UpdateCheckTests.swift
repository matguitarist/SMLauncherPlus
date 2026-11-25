import DownloadKit
import Foundation
import Testing
@testable import SMLauncherPlusKit

struct UpdateCheckTests {
    @Test func checksAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "a clock set back checks again")
    }

    func latest(_ versions: [String]) -> UpdateCheck.Latest {
        let release = GameRelease(version: versions[0], tag: "v" + versions[0], zipName: "z.zip", zipURL: URL(string: "https://example.com/z.zip")!, size: 1, sha256: "")
        return UpdateCheck.Latest(release: release, notes: versions.map { .init(version: $0, published: nil, body: "Notes \($0)", page: nil) }, checkedAt: .now)
    }

    @Test func whatsNewListsEveryVersionSinceTheInstalledOne() {
        #expect(latest(["0.4.8", "0.4.7", "0.4.6", "0.4.5"]).notes(since: "0.4.6").map(\.version) == ["0.4.8", "0.4.7"])
        #expect(latest(["0.4.6"]).notes(since: "0.4.6").isEmpty)
    }

    @Test func theAnswerIsKeptForOfflineUse() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "latest-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var saved = latest(["0.4.7", "0.4.6"])
        saved.checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try UpdateCheck.write(saved, to: file)
        #expect(UpdateCheck.read(from: file) == saved)
    }

    @Test func readsReleaseNotesFromGitHub() throws {
        let json = """
        [{"id": 3, "tag_name": "v0.4.7", "published_at": "2026-11-20T10:00:00Z", "assets": [], "body": "# 0.4.7\\nFixes.", "html_url": "https://github.com/mstan/SuperMetroidRecomp/releases/tag/v0.4.7"},
         {"id": 2, "tag_name": "v0.5.0-rc.1", "published_at": null, "assets": [], "body": "rc", "prerelease": true},
         {"id": 1, "tag_name": "v0.4.6", "published_at": "2026-11-13T23:38:04Z", "assets": [], "body": null}]
        """
        let notes = GameRelease.notes(from: try GitHubRelease.decodeList(Data(json.utf8)))
        #expect(notes.map(\.version) == ["0.4.7", "0.4.6"])
        #expect(notes[0].body == "# 0.4.7\nFixes." && notes[0].page?.lastPathComponent == "v0.4.7" && notes[1].body.isEmpty)
    }

    @Test func releaseNotesBecomeHeadingsParagraphsAndBullets() {
        let text = """
        # Super Metroid 0.4.6

        Widescreen rendering now preserves the native ownership of cinematic sprites,
        Mother Brain's tank head.

        Optional quality-of-life features:

        - **Low-health alarm:** choose Shortened or Muted, or leave the mod disabled for
          the original warning.
        - **One-missile red doors:** open red doors with one standard missile.

        Elective enhancements remain disabled by default.
        """
        #expect(ReleaseNotes.blocks(text) == [
            .heading("Super Metroid 0.4.6"),
            .paragraph("Widescreen rendering now preserves the native ownership of cinematic sprites, Mother Brain's tank head."),
            .paragraph("Optional quality-of-life features:"),
            .bullet("**Low-health alarm:** choose Shortened or Muted, or leave the mod disabled for the original warning."),
            .bullet("**One-missile red doors:** open red doors with one standard missile."),
            .paragraph("Elective enhancements remain disabled by default."),
        ])
    }
}
