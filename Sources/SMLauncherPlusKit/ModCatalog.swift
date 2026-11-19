import Foundation

/// The game's mod packages and the player's choices (S-020), in SuperMetroidRecomp's own formats:
/// `mods/preloaded/packages/<id>/<version>/manifest.toml` (read only) and
/// `mods/preloaded/state.toml` (which features are on, with which option values).
/// The rules follow snesrecomp's runner/src/mod_runtime.cpp, so the game reads what this writes.
public struct ModPackage: Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var name: String
    public var author: String
    public var description: String
    public var gameIDs: [String]
    public var features: [ModFeature]
    /// `[[target]]` ROM hashes, in the same order as `gameIDs`.
    public var targetROMs: [String] = []
    /// `format_version`; the game reads 1 only.
    public var formatVersion = 0
}

public struct ModFeature: Identifiable, Equatable, Sendable {
    public var id: String
    public var packageID: String
    public var name: String
    public var author: String
    public var description: String
    public var group: String
    public var defaultEnabled: Bool
    public var experimental: Bool
    /// Features claiming the same plugin can't run together: turning one on turns the others off.
    public var plugins: [String]
    /// "package/feature" ids this one can't run without.
    public var requires: [String]
    public var options: [ModOption]

    /// "package/feature", unique across packages.
    public var key: String { packageID + "/" + id }
}

public struct ModOption: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case boolean
        case choice([Choice])
        case integer(min: Int, max: Int, step: Int)
    }

    public struct Choice: Equatable, Sendable {
        public var value: String
        public var label: String
    }

    public var id: String
    public var label: String
    public var description: String
    public var kind: Kind
    /// As the game stores it: "true", "3x", "8".
    public var defaultValue: String

    /// The game's validate_option_value: an unknown choice or an out-of-range integer is refused.
    public func accepts(_ value: String) -> Bool {
        switch kind {
        case .boolean: value == "true" || value == "false"
        case .choice(let choices): choices.contains { $0.value == value }
        case .integer(let min, let max, let step):
            if let number = Int(value), number >= min, number <= max, step > 0, (number - min) % step == 0 { true } else { false }
        }
    }
}

public enum ModCatalog {
    /// The game this launcher plays, as manifests name it.
    public static let gameID = "supermetroid-jpn"

    /// `<game>/mods/preloaded`.
    public static func root(game: URL) -> URL {
        game.appending(path: "mods/preloaded", directoryHint: .isDirectory)
    }

    /// Every package for this game, newest version of each, by name. Unreadable manifests are skipped.
    public static func packages(in root: URL) -> [ModPackage] {
        let fm = FileManager.default
        let base = root.appending(path: "packages", directoryHint: .isDirectory)
        var found: [ModPackage] = []
        for id in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !id.hasPrefix(".") {
            let versions = ((try? fm.contentsOfDirectory(atPath: base.appending(path: id).path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in versions {
                let file = base.appending(path: "\(id)/\(version)/manifest.toml")
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let package = parseManifest(text), package.id == id,
                      package.gameIDs.isEmpty || package.gameIDs.contains(gameID) else { continue }
                found.append(package)
                break
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads a manifest.toml (format 1). Nil when it has no id or version.
    public static func parseManifest(_ text: String) -> ModPackage? {
        var package = ModPackage(id: "", version: "", name: "", author: "", description: "", gameIDs: [], features: [])
        var options: [(feature: String, option: ModOption, choices: [ModOption.Choice], type: String, min: Int, max: Int, step: Int)] = []
        var plugins: [(feature: String, id: String)] = []
        enum Section { case root, target, feature, option, choice, plugin, other }
        var section = Section.root

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = TOMLLine.stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                switch line {
                case "[[target]]": section = .target; package.gameIDs.append(""); package.targetROMs.append("")
                case "[[feature]]":
                    section = .feature
                    package.features.append(ModFeature(id: "", packageID: "", name: "", author: "", description: "", group: "General",
                                                       defaultEnabled: false, experimental: false, plugins: [], requires: [], options: []))
                case "[[option]]":
                    section = .option
                    options.append(("", ModOption(id: "", label: "", description: "", kind: .boolean, defaultValue: "false"), [], "boolean", 0, 1, 1))
                case "[[option.choice]]":
                    section = .choice
                    if !options.isEmpty { options[options.count - 1].choices.append(.init(value: "", label: "")) }
                case "[[plugin]]": section = .plugin; plugins.append(("", ""))
                default: section = .other
                }
                continue
            }
            guard let (key, value) = TOMLLine.keyValue(line) else { continue }
            switch section {
            case .root:
                switch key {
                case "id": package.id = value.string ?? ""
                case "version": package.version = value.string ?? ""
                case "name": package.name = value.string ?? ""
                case "author": package.author = value.string ?? ""
                case "description": package.description = value.string ?? ""
                case "format_version": package.formatVersion = value.int ?? 0
                default: break
                }
            case .target:
                if key == "game_id", let id = value.string { package.gameIDs[package.gameIDs.count - 1] = id }
                if key == "rom_sha256", let hash = value.string { package.targetROMs[package.targetROMs.count - 1] = hash.lowercased() }
            case .feature:
                let i = package.features.count - 1
                switch key {
                case "id": package.features[i].id = value.string ?? ""
                case "name": package.features[i].name = value.string ?? ""
                case "author": package.features[i].author = value.string ?? ""
                case "description": package.features[i].description = value.string ?? ""
                case "group": package.features[i].group = value.string ?? "General"
                case "default_enabled": package.features[i].defaultEnabled = value.bool ?? false
                case "experimental": package.features[i].experimental = value.bool ?? false
                case "requires":
                    package.features[i].requires = (value.string ?? "").split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                default: break
                }
            case .option:
                let i = options.count - 1
                switch key {
                case "feature": options[i].feature = value.string ?? ""
                case "id": options[i].option.id = value.string ?? ""
                case "label": options[i].option.label = value.string ?? ""
                case "description": options[i].option.description = value.string ?? ""
                case "type": options[i].type = value.string ?? "boolean"
                case "default":
                    if let bool = value.bool { options[i].option.defaultValue = bool ? "true" : "false" }
                    else if let int = value.int { options[i].option.defaultValue = String(int) }
                    else { options[i].option.defaultValue = value.string ?? "" }
                case "min": options[i].min = value.int ?? 0
                case "max": options[i].max = value.int ?? 1
                case "step": options[i].step = value.int ?? 1
                default: break
                }
            case .choice:
                guard let i = options.indices.last, let c = options[i].choices.indices.last else { continue }
                if key == "value" { options[i].choices[c].value = value.string ?? "" }
                if key == "label" { options[i].choices[c].label = value.string ?? "" }
            case .plugin:
                let i = plugins.count - 1
                if key == "feature" { plugins[i].feature = value.string ?? "" }
                if key == "id" { plugins[i].id = value.string ?? "" }
            case .other: break
            }
        }
        guard !package.id.isEmpty, !package.version.isEmpty else { return nil }
        let targets = zip(package.gameIDs, package.targetROMs).filter { !$0.0.isEmpty }
        package.gameIDs = targets.map(\.0)
        package.targetROMs = targets.map(\.1)
        for i in package.features.indices {
            package.features[i].packageID = package.id
            let id = package.features[i].id
            package.features[i].plugins = plugins.filter { $0.feature == id }.map(\.id)
            package.features[i].options = options.filter { $0.feature == id }.map { entry in
                var option = entry.option
                switch entry.type {
                case "choice": option.kind = .choice(entry.choices)
                case "integer": option.kind = .integer(min: entry.min, max: entry.max, step: entry.step)
                default: option.kind = .boolean
                }
                return option
            }
        }
        package.features.removeAll { $0.id.isEmpty }
        return package
    }
}

/// state.toml: what the player chose. Entries the launcher doesn't show (resources, shared resources,
/// packages that are gone) are kept as they are.
public struct ModState: Equatable, Sendable {
    public struct Selection: Equatable, Sendable {
        public var enabled: Bool?
        public var values: [String: String] = [:]
        public var resources: [String: String] = [:]
    }

    /// package id -> version
    public var packages: [String: String] = [:]
    /// "package/feature" -> selection
    public var features: [String: Selection] = [:]
    /// shared_resource id -> path
    public var sharedResources: [String: String] = [:]

    public init() {}

    public static func read(from root: URL) -> ModState {
        guard let text = try? String(contentsOf: root.appending(path: "state.toml"), encoding: .utf8) else { return ModState() }
        return parse(text)
    }

    /// The game's load_state.
    public static func parse(_ text: String) -> ModState {
        var state = ModState()
        enum Section { case root, package, feature, values, resource, shared }
        var section = Section.root
        var package = "", feature = "", resource = ""
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = TOMLLine.stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            switch line {
            case "[[shared_resource]]": section = .shared; resource = ""; continue
            case "[[package]]": section = .package; package = ""; feature = ""; resource = ""; continue
            case "[[feature]]": section = .feature; package = ""; feature = ""; resource = ""; continue
            case "[[resource]]": section = .resource; package = ""; feature = ""; resource = ""; continue
            case "[feature.values]": section = .values; continue
            default: break
            }
            guard let (key, value) = TOMLLine.keyValue(line) else { continue }
            switch section {
            case .root: break
            case .package:
                if key == "id", let id = value.string { package = id; state.packages[id] = state.packages[id] ?? "" }
                else if key == "version", !package.isEmpty, let version = value.string { state.packages[package] = version }
            case .feature:
                if key == "package_id", let id = value.string { package = id }
                else if key == "id", let id = value.string {
                    feature = id
                    if !package.isEmpty, state.features["\(package)/\(id)"] == nil { state.features["\(package)/\(id)"] = .init() }
                }
                else if key == "enabled", !package.isEmpty, !feature.isEmpty, let enabled = value.bool { state.features["\(package)/\(feature)", default: .init()].enabled = enabled }
            case .values:
                if !package.isEmpty, !feature.isEmpty, let text = value.string { state.features["\(package)/\(feature)", default: .init()].values[key] = text }
            case .resource:
                if key == "package_id", let id = value.string { package = id }
                else if key == "feature_id", let id = value.string { feature = id }
                else if key == "id", let id = value.string { resource = id }
                else if key == "path", !package.isEmpty, !feature.isEmpty, !resource.isEmpty, let path = value.string {
                    state.features["\(package)/\(feature)", default: .init()].resources[resource] = path
                }
            case .shared:
                if key == "id", let id = value.string { resource = id }
                else if key == "path", !resource.isEmpty, let path = value.string { state.sharedResources[resource] = path }
            }
        }
        return state
    }

    /// The game's save_state, byte for byte: maps in id order, values always quoted.
    public func text() -> String {
        var out = "format_version = 1\n"
        for (id, path) in sharedResources.sorted(by: { $0.key < $1.key }) {
            out += "\n[[shared_resource]]\nid = \(TOMLLine.quote(id))\npath = \(TOMLLine.quote(path))\n"
        }
        let packageIDs = Set(packages.keys).union(features.keys.map { String($0.split(separator: "/", maxSplits: 1)[0]) })
        for id in packageIDs.sorted() {
            out += "\n[[package]]\nid = \(TOMLLine.quote(id))\nversion = \(TOMLLine.quote(packages[id] ?? ""))\n"
        }
        // std::map<package, std::map<feature, ...>>: package id first, then feature id.
        let sorted = features.sorted { a, b in
            let (pa, fa) = Self.split(a.key), (pb, fb) = Self.split(b.key)
            return pa == pb ? fa < fb : pa < pb
        }
        for (key, selection) in sorted {
            let (package, feature) = Self.split(key)
            out += "\n[[feature]]\npackage_id = \(TOMLLine.quote(package))\nid = \(TOMLLine.quote(feature))\nenabled = \(selection.enabled == true ? "true" : "false")\n"
            if !selection.values.isEmpty {
                out += "\n[feature.values]\n"
                for (name, value) in selection.values.sorted(by: { $0.key < $1.key }) { out += "\(name) = \(TOMLLine.quote(value))\n" }
            }
            for (id, path) in selection.resources.sorted(by: { $0.key < $1.key }) where !path.isEmpty {
                out += "\n[[resource]]\npackage_id = \(TOMLLine.quote(package))\nfeature_id = \(TOMLLine.quote(feature))\nid = \(TOMLLine.quote(id))\npath = \(TOMLLine.quote(path))\n"
            }
        }
        return out
    }

    /// Writes state.toml through a temporary file, like the game.
    public func write(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text().utf8).write(to: root.appending(path: "state.toml"), options: .atomic)
    }

    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: Choices

    public func isEnabled(_ feature: ModFeature) -> Bool {
        features[feature.key]?.enabled ?? feature.defaultEnabled
    }

    /// The stored value when the game would accept it, else the default.
    public func value(of option: ModOption, in feature: ModFeature) -> String {
        if let stored = features[feature.key]?.values[option.id], option.accepts(stored) { return stored }
        return option.defaultValue
    }

    public mutating func setValue(_ value: String, of option: ModOption, in feature: ModFeature) {
        guard option.accepts(value) else { return }
        features[feature.key, default: .init()].values[option.id] = value
        packages[feature.packageID] = packages[feature.packageID] ?? ""
    }

    /// Turns a feature on or off with the game's rules: on also turns on what it requires and turns off
    /// rivals claiming one of its plugins; anything left without a requirement is turned off.
    /// Returns the features that changed besides `feature`, so the page can say so.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, _ feature: ModFeature, in catalog: [ModPackage]) -> [ModFeature] {
        let all = catalog.flatMap(\.features)
        let before = Dictionary(uniqueKeysWithValues: all.map { ($0.key, isEnabled($0)) })
        for package in catalog { packages[package.id] = package.version }
        if enabled { enable(feature, all: all, depth: 0) } else { set(feature, false) }
        // drop_orphaned_dependents
        var changed = true
        while changed {
            changed = false
            for candidate in all where isEnabled(candidate) {
                for requirement in candidate.requires {
                    guard let needed = all.first(where: { $0.key == requirement }), !isEnabled(needed) else { continue }
                    set(candidate, false)
                    changed = true
                    break
                }
            }
        }
        return all.filter { $0.key != feature.key && before[$0.key] != isEnabled($0) }
    }

    private mutating func set(_ feature: ModFeature, _ enabled: Bool) {
        features[feature.key, default: .init()].enabled = enabled
    }

    private mutating func enable(_ feature: ModFeature, all: [ModFeature], depth: Int) {
        set(feature, true)
        for rival in all where rival.key != feature.key && isEnabled(rival) && !Set(rival.plugins).isDisjoint(with: feature.plugins) {
            set(rival, false)
        }
        guard depth <= 16 else { return }
        for requirement in feature.requires {
            if let needed = all.first(where: { $0.key == requirement }), !isEnabled(needed) {
                enable(needed, all: all, depth: depth + 1)
            }
        }
    }
}

/// The small part of TOML the game's own parser reads: one `key = value` per line, strings with
/// \\ \" \n \r \t escapes, true/false, integers.
enum TOMLLine {
    enum Value {
        case string(String), bool(Bool), int(Int)
        var string: String? { if case .string(let s) = self { s } else { nil } }
        var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
        var int: Int? { if case .int(let i) = self { i } else { nil } }
    }

    static func keyValue(_ line: String) -> (String, Value)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let text = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if text == "true" { return (key, .bool(true)) }
        if text == "false" { return (key, .bool(false)) }
        if let int = Int(text) { return (key, .int(int)) }
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return nil }
        var out = ""
        var escaped = false
        for c in text.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\", "\"": out.append(c)
                default: return nil
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return escaped ? nil : (key, .string(out))
    }

    static func quote(_ value: String) -> String {
        var out = "\""
        for c in value {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// Drops a # comment outside quotes.
    static func stripComment(_ line: String) -> String {
        var quoted = false, escaped = false
        for (i, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == "#", !quoted { return String(line.prefix(i)) }
        }
        return line
    }
}
