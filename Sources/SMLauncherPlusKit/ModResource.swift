import CryptoKit
import Foundation

/// A file a feature asks the player for (S-022), from a `[[resource]]` in manifest.toml, like the
/// Zero Mission map art. The game reads the path from state.toml; the file is never copied.
/// The rules follow snesrecomp's mod_runtime.cpp (`read_manifest`, `resource_path`, `validate_resource_file`).
public struct ModResource: Identifiable, Equatable, Sendable {
    public var featureID = ""
    public var id = ""
    public var label = ""
    public var description = ""
    /// "file" (or empty), "directory"/"folder", "n64".
    public var format = ""
    /// Resources with the same key share one path across features and packages.
    public var sharedKey = ""
    /// The file's SHA-256, a 512-byte copier header left out.
    public var normalizedSHA256 = ""
    /// Expected size in bytes, 0 for any.
    public var size = 0
    /// "*.gba" or "*.z64,*.v64,*.n64".
    public var filePatterns = ""
    public var fileDescription = ""
    /// The game's default: a resource is required unless it says otherwise.
    public var required = true

    public init() {}

    public var isFolder: Bool { format == "directory" || format == "folder" }

    /// The extensions in `filePatterns` ("gba"), or empty for any file.
    public var extensions: [String] {
        filePatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { $0.hasPrefix("*.") ? String($0.dropFirst(2)).lowercased() : nil }
            .filter { !$0.isEmpty && $0 != "*" }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// read_manifest's defaults.
    func withDefaults() -> ModResource {
        var out = self
        if format == "n64" {
            if out.filePatterns.isEmpty { out.filePatterns = "*.z64,*.v64,*.n64" }
            if out.fileDescription.isEmpty { out.fileDescription = "Nintendo 64 ROM" }
        }
        if out.filePatterns.isEmpty && !isFolder { out.filePatterns = "*" }
        return out
    }

    public enum Status: Equatable, Sendable {
        case notChosen
        case notFound
        case wrongSize
        /// The file isn't the one the manifest names (its SHA-256 differs).
        case wrongFile
        /// Chosen and matches the expected SHA-256.
        case verified
        /// Chosen; the manifest gives nothing to check it against.
        case chosen

        /// Whether the game accepts it on Play (validate_resource_file).
        public func isUsable(required: Bool) -> Bool {
            switch self {
            case .verified, .chosen: true
            case .notChosen: !required
            case .notFound, .wrongSize, .wrongFile: false
            }
        }
    }

    /// validate_resource_file: the path exists, its size and its SHA-256 match.
    public func status(of path: String) -> Status {
        guard !path.isEmpty else { return .notChosen }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue == isFolder else { return .notFound }
        if isFolder { return .chosen }
        let actual = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? -1
        if size != 0, actual != size { return .wrongSize }
        guard !normalizedSHA256.isEmpty else { return .chosen }
        guard actual >= 0, actual <= 64 * 1024 * 1024 else { return .wrongSize }
        guard let hash = Self.normalizedSHA256(of: URL(fileURLWithPath: path)) else { return .notFound }
        return hash == normalizedSHA256 ? .verified : .wrongFile
    }

    /// SHA-256 of a file, leaving out a 512-byte copier header (length % 32768 == 512).
    public static func normalizedSHA256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let body = data.count % 32768 == 512 ? data.dropFirst(512) : data[...]
        return SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

extension ModState {
    /// resource_path: the shared path for a shared key (migrating an older per-feature choice once),
    /// else this feature's own.
    public func path(of resource: ModResource, in feature: ModFeature, catalog: [ModPackage]) -> String {
        if !resource.sharedKey.isEmpty {
            if let shared = sharedResources[resource.sharedKey] { return shared }
            for other in catalog.flatMap(\.features) {
                for candidate in other.resources where candidate.sharedKey == resource.sharedKey {
                    if let old = features[other.key]?.resources[candidate.id], !old.isEmpty { return old }
                }
            }
            return ""
        }
        return features[feature.key]?.resources[resource.id] ?? ""
    }

    /// Chooses (or clears, with "") the path for a resource. A shared key keeps one path for every
    /// feature that names it, stored as a `[[shared_resource]]`, an empty value included.
    public mutating func setPath(_ path: String, of resource: ModResource, in feature: ModFeature) {
        packages[feature.packageID] = packages[feature.packageID] ?? ""
        if !resource.sharedKey.isEmpty {
            sharedResources[resource.sharedKey] = path
        } else {
            features[feature.key, default: .init()].resources[resource.id] = path
        }
    }
}
