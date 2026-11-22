import Foundation

/// Whether a newer SuperMetroidRecomp release exists (S-030). Ported from AM2R Launcher Plus's
/// UpdateCheck: GitHub is asked at most once a day, and the answer is kept in a small file so the
/// Play page can say so offline until the next check.
public enum UpdateCheck {
    public static let interval: TimeInterval = 24 * 3600

    /// One release's notes, for What's New.
    public struct Notes: Codable, Equatable, Sendable {
        public var version: String
        public var published: Date?
        public var body: String
        public var page: URL?

        public init(version: String, published: Date?, body: String, page: URL?) {
            self.version = version
            self.published = published
            self.body = body
            self.page = page
        }
    }

    /// The newest release when GitHub was last asked, with the notes of recent releases, newest first.
    public struct Latest: Codable, Equatable, Sendable {
        public var release: GameRelease
        public var notes: [Notes]
        public var checkedAt: Date

        public init(release: GameRelease, notes: [Notes], checkedAt: Date) {
            self.release = release
            self.notes = notes
            self.checkedAt = checkedAt
        }

        public var version: String { release.version }

        /// The notes of every release newer than `installed`, newest first.
        public func notes(since installed: String) -> [Notes] {
            notes.filter { UpdateCheck.isNewer($0.version, than: installed) }
        }
    }

    /// True when there was no check yet, or the last one is a day old (or in the future: the clock moved).
    public static func isDue(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < 0
    }

    /// Semantic versions: "0.4.10" is newer than "0.4.9", "0.5.0" newer than "0.5.0-rc.1"; a leading "v"
    /// and build metadata ("+abc") are ignored.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ version: String) -> (core: [Int], pre: [String]) {
            var text = version.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
            let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            return (core, pre)
        }
        let (x, y) = (split(a), split(b))
        for i in 0..<max(x.core.count, y.core.count) {
            let (p, q) = (i < x.core.count ? x.core[i] : 0, i < y.core.count ? y.core[i] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        // A release outranks its pre-releases.
        if x.pre.isEmpty != y.pre.isEmpty { return x.pre.isEmpty ? .orderedDescending : .orderedAscending }
        for i in 0..<max(x.pre.count, y.pre.count) {
            guard i < x.pre.count else { return .orderedAscending }
            guard i < y.pre.count else { return .orderedDescending }
            let (p, q) = (x.pre[i], y.pre[i])
            if p == q { continue }
            switch (Int(p), Int(q)) {
            case let (m?, n?): return m < n ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            default: return p < q ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    /// Asks GitHub for the latest release (with its checksum, as an install would) and recent notes.
    public static func fetch(session: URLSession = .shared, now: Date = .now) async throws(GameRelease.Failure) -> Latest {
        let release = try await GameRelease.latest(session: session)
        let notes = (try? await GameRelease.recentNotes(session: session)) ?? []
        // Whole seconds: the saved file keeps no fractions, so the answer in memory matches the one read back.
        return Latest(release: release, notes: notes, checkedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
    }

    public static func read(from file: URL) -> Latest? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Latest.self, from: data)
    }

    public static func write(_ latest: Latest, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(latest).write(to: file, options: .atomic)
    }
}

extension GameRelease {
    /// The notes of the last 10 published releases, newest first (one API call).
    static func recentNotes(session: URLSession = .shared) async throws(Failure) -> [UpdateCheck.Notes] {
        let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10")!
        return try parseNotes(try await get(api, accept: "application/vnd.github+json", session: session))
    }

    static func parseNotes(_ json: Data) throws(Failure) -> [UpdateCheck.Notes] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let releases = try? decoder.decode([ReleaseResponse].self, from: json) else { throw .badResponse }
        return releases.filter { $0.draft != true && $0.prerelease != true }.map { response in
            let version = response.tag_name.hasPrefix("v") ? String(response.tag_name.dropFirst()) : response.tag_name
            return UpdateCheck.Notes(version: version, published: response.published_at, body: response.body ?? "", page: response.html_url)
        }
        .sorted { UpdateCheck.isNewer($0.version, than: $1.version) }
    }
}

/// Release notes as GitHub writes them, in blocks the app can lay out: headings, paragraphs whose
/// lines were wrapped by hand, and bullet lists with indented continuation lines.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        func flush() { if let current { blocks.append(current) }; current = nil }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                current = .bullet(String(line.dropFirst(2)))
            } else {
                switch current {
                case .bullet(let text) where raw.first == " " || raw.first == "\t": current = .bullet(text + " " + line)
                case .paragraph(let text): current = .paragraph(text + " " + line)
                default:
                    flush()
                    current = .paragraph(line)
                }
            }
        }
        flush()
        return blocks
    }
}
