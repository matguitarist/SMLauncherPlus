import CryptoKit
import Foundation
import Testing
@testable import SMLauncherPlusKit

/// S-002. GitHub is replaced by StubProtocol: no test touches the network.
@Suite(.serialized) struct GameReleaseTests {
    static let zip = Data((0..<200_000).map { UInt8($0 % 251) })
    static var zipHash: String { SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined() }

    static let releaseJSON = """
    {"tag_name": "v0.4.6", "published_at": "2026-11-13T23:38:04Z", "assets": [
      {"name": "SHA256SUMS", "size": 400, "browser_download_url": "https://example.test/SHA256SUMS"},
      {"name": "supermetroid-0.4.6-linux-x64.zip", "size": 1, "browser_download_url": "https://example.test/linux.zip"},
      {"name": "supermetroid-0.4.6-macos-arm64.zip", "size": 200000, "browser_download_url": "https://example.test/arm64.zip"},
      {"name": "supermetroid-0.4.6-macos-x64.zip", "size": 200000, "browser_download_url": "https://example.test/x64.zip"}
    ]}
    """

    static var sums: String {
        """
        026848df0ec061cea67ac18114aa873163edcb13247f162474197363b29db0f5  supermetroid-0.4.6-linux-x64.zip
        \(zipHash)  supermetroid-0.4.6-macos-arm64.zip
        \(zipHash) *supermetroid-0.4.6-macos-x64.zip
        """
    }

    static func session(_ routes: [String: (Int, Data)]) -> URLSession {
        StubProtocol.routes = routes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var github: [String: (Int, Data)] {
        ["https://api.github.com/repos/mstan/SuperMetroidRecomp/releases/latest": (200, Data(releaseJSON.utf8)),
         "https://example.test/SHA256SUMS": (200, Data(sums.utf8)),
         "https://example.test/arm64.zip": (200, zip),
         "https://example.test/x64.zip": (200, zip)]
    }

    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GameReleaseTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theMacZipForThisProcessorIsChosen() async throws {
        let session = Self.session(Self.github)
        let arm = try await GameRelease.latest(architecture: "arm64", session: session)
        #expect(arm.version == "0.4.6")
        #expect(arm.zipName == "supermetroid-0.4.6-macos-arm64.zip")
        #expect(arm.zipURL.absoluteString == "https://example.test/arm64.zip")
        #expect(arm.sha256 == Self.zipHash)
        let intel = try await GameRelease.latest(architecture: "x64", session: session)
        #expect(intel.zipName == "supermetroid-0.4.6-macos-x64.zip")
    }

    @Test func aReleaseWithoutAMacBuildOrChecksumIsRefused() {
        let noMac = Data(#"{"tag_name":"v1","assets":[{"name":"SHA256SUMS","size":1,"browser_download_url":"https://example.test/s"}]}"#.utf8)
        #expect(throws: GameRelease.Failure.noMacBuild) { try GameRelease.parse(noMac, architecture: "arm64") }
        let noSums = Data(#"{"tag_name":"v1","assets":[{"name":"supermetroid-1-macos-arm64.zip","size":1,"browser_download_url":"https://example.test/z"}]}"#.utf8)
        #expect(throws: GameRelease.Failure.noChecksum) { try GameRelease.parse(noSums, architecture: "arm64") }
        #expect(throws: GameRelease.Failure.badResponse) { try GameRelease.parse(Data("<html>".utf8), architecture: "arm64") }
    }

    @Test func checksumsAreReadFromEitherSHA256SUMSForm() {
        #expect(GameRelease.checksum(for: "supermetroid-0.4.6-macos-arm64.zip", in: Self.sums) == Self.zipHash)
        #expect(GameRelease.checksum(for: "supermetroid-0.4.6-macos-x64.zip", in: Self.sums) == Self.zipHash)
        #expect(GameRelease.checksum(for: "missing.zip", in: Self.sums) == nil)
    }

    @Test func gitHubErrorsAndNoConnectionAreTold() async {
        await #expect(throws: GameRelease.Failure.github(403)) {
            try await GameRelease.latest(session: Self.session(["https://api.github.com/repos/mstan/SuperMetroidRecomp/releases/latest": (403, Data())]))
        }
        await #expect(throws: GameRelease.Failure.offline) {
            try await GameRelease.latest(session: Self.session([:]))
        }
    }

    @Test func aMatchingDownloadIsKeptWithProgress() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = try await GameRelease.latest(architecture: "arm64", session: Self.session(Self.github))
        let seen = Seen()
        let file = try await release.download(into: folder, session: Self.session(Self.github)) { done, total in seen.add(done, total) }
        #expect(file == folder.appending(path: "0.4.6/supermetroid-0.4.6-macos-arm64.zip"))
        #expect(try Data(contentsOf: file) == Self.zip)
        #expect(seen.last?.0 == Self.zip.count && seen.last?.1 == Self.zip.count)
        #expect(seen.count > 1)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".partial"))
    }

    @Test func aDamagedDownloadIsDeletedAndTold() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var routes = Self.github
        routes["https://example.test/arm64.zip"] = (200, Data(Self.zip.dropLast()) + Data([0]))
        let release = try await GameRelease.latest(architecture: "arm64", session: Self.session(routes))
        await #expect(throws: GameRelease.Failure.damaged) { try await release.download(into: folder, session: Self.session(routes)) }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "0.4.6").path)
        #expect(left.isEmpty)
    }

    @Test func aVerifiedZipAlreadyDownloadedIsReused() async throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = try await GameRelease.latest(architecture: "arm64", session: Self.session(Self.github))
        let file = release.zipFile(in: folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.zip.write(to: file)
        #expect(release.isDownloaded(in: folder))
        // With no zip on the "network", only the copy on disk can be returned.
        var routes = Self.github
        routes["https://example.test/arm64.zip"] = nil
        #expect(try await release.download(into: folder, session: Self.session(routes)) == file)
        // A different file in its place is not reused.
        try Data("old".utf8).write(to: file)
        #expect(!release.isDownloaded(in: folder))
    }
}

/// Progress callbacks, collected from any thread.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { lock.withLock { values.append((done, total)) } }
    var count: Int { lock.withLock { values.count } }
    var last: (Int, Int)? { lock.withLock { values.last } }
}

/// Answers requests from a table of URL -> (status, body). A URL not in the table fails like no connection.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.routes[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, so progress is reported more than once.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 70_000, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
