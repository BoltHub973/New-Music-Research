import Foundation

/// Which side of the light/dark pair a theme belongs to.
enum AppearanceMode: String {
    case light
    case dark

    var opposite: AppearanceMode { self == .dark ? .light : .dark }
}

/// Metadata parsed from a theme CSS header comment.
/// Behavior comes strictly from these markers (or background brightness fallback)
/// and NEVER from a theme's display name.
enum ThemeMarkers {
    static let namesFileName = "theme-names.json"

    static func id(in raw: String) -> String? {
        marker("naga-theme", in: String(raw.prefix(600)))
    }

    static func pair(in raw: String) -> String? {
        marker("naga-pair", in: String(raw.prefix(800)))
    }

    static func accent(in raw: String) -> String? {
        marker("naga-accent", in: String(raw.prefix(800)), allowHash: true)
    }

    static func mode(in raw: String) -> AppearanceMode? {
        guard let r = raw.range(
            of: #"naga-mode\s*:\s*(dark|light)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return raw[r].lowercased().hasSuffix("dark") ? .dark : .light
    }

    static func mode(fallbackLuma luma: Double?) -> AppearanceMode? {
        guard let luma else { return nil }
        return luma > 0.5 ? .light : .dark
    }

    private static func marker(_ name: String, in head: String, allowHash: Bool = false) -> String? {
        let chars = allowHash ? #"[#A-Za-z0-9-]+"# : #"[a-z0-9-]+"#
        guard let r = head.range(of: name + #"\s*:\s*"# + chars, options: .regularExpression) else { return nil }
        return head[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    struct NameEntry {
        let name: String
        let official: String
    }

    static func loadNameTable(root: URL) -> [String: String] {
        loadFullNameTable(root: root).mapValues(\.name)
    }

    static func loadFullNameTable(root: URL) -> [String: NameEntry] {
        let url = root.appendingPathComponent(namesFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let themes = json["themes"] as? [String: [String: Any]] else { return [:] }
        var out: [String: NameEntry] = [:]
        for (id, row) in themes {
            guard let custom = row["name"] as? String else { continue }
            let official = (row["official"] as? String) ?? custom
            out[id] = NameEntry(name: custom, official: official)
        }
        return out
    }
}
