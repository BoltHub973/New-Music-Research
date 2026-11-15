import Foundation

/// Manages Tidal playlist scrape order and user presets (`playlist-presets.json`),
/// keeping the canonical `playlists.json` untouched as the immutable Default preset.
final class PlaylistOrderStore {
    static let shared = PlaylistOrderStore()
    static let changedNotification = Notification.Name("NMRPlaylistOrderChanged")

    struct PlaylistEntry: Equatable {
        let name: String
        let url: String

        func toDict() -> [String: String] {
            ["name": name, "url": url]
        }
    }

    struct Preset: Equatable {
        let id: String
        var name: String
        var playlists: [PlaylistEntry]

        func toDict() -> [String: Any] {
            [
                "id": id,
                "name": name,
                "playlists": playlists.map { $0.toDict() },
            ]
        }
    }

    var presetsURL: URL {
        SharedStore.shared.storeDir.appendingPathComponent("playlist-presets.json")
    }

    private init() {}

    func loadDefaultPlaylists(projectDir: String) -> [PlaylistEntry] {
        let url = URL(fileURLWithPath: projectDir).appendingPathComponent("playlists.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { row in
            guard let name = row["name"] as? String,
                  let plURL = row["url"] as? String,
                  !plURL.isEmpty else { return nil }
            return PlaylistEntry(name: name, url: plURL)
        }
    }

    private func reconciled(_ saved: [PlaylistEntry], canonical: [PlaylistEntry]) -> [PlaylistEntry] {
        guard !canonical.isEmpty else { return saved }
        var byURL: [String: PlaylistEntry] = [:]
        for item in canonical {
            byURL[item.url.trimmingCharacters(in: .whitespacesAndNewlines)] = item
        }
        var seen = Set<String>()
        var result: [PlaylistEntry] = []
        for item in saved {
            let key = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if let canon = byURL[key], !seen.contains(key) {
                seen.insert(key)
                result.append(canon)
            }
        }
        for item in canonical {
            let key = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }
        return result
    }

    private func loadRawStore(projectDir: String) -> (activePresetId: String, presets: [Preset]) {
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        guard let data = try? Data(contentsOf: presetsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("default", [])
        }
        let rawPresets = obj["presets"] as? [[String: Any]] ?? []
        var parsed: [Preset] = []
        for row in rawPresets {
            guard let id = row["id"] as? String, !id.isEmpty, id != "default",
                  let name = row["name"] as? String, !name.isEmpty else { continue }
            let rawItems = row["playlists"] as? [[String: Any]] ?? []
            let entries: [PlaylistEntry] = rawItems.compactMap { p in
                guard let n = p["name"] as? String, let u = p["url"] as? String else { return nil }
                return PlaylistEntry(name: n, url: u)
            }
            parsed.append(Preset(id: id, name: name, playlists: reconciled(entries, canonical: canonical)))
        }
        let requestedActive = (obj["activePresetId"] as? String) ?? "default"
        let active = (requestedActive == "default" || parsed.contains(where: { $0.id == requestedActive }))
            ? requestedActive
            : "default"
        return (active, parsed)
    }

    private func saveStore(activePresetId: String, presets: [Preset], canonical: [PlaylistEntry]) {
        try? FileManager.default.createDirectory(at: SharedStore.shared.storeDir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "activePresetId": activePresetId,
            "defaultPlaylists": canonical.map { $0.toDict() },
            "presets": presets.map { $0.toDict() },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: presetsURL, options: .atomic)
        notifyChanged()
    }

    private func notifyChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changedNotification, object: self)
            }
        }
    }

    func exportPayload(projectDir: String) -> [String: Any] {
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        let store = loadRawStore(projectDir: projectDir)
        return [
            "activePresetId": store.activePresetId,
            "defaultPlaylists": canonical.map { $0.toDict() },
            "presets": store.presets.map { $0.toDict() },
            "presetsPath": presetsURL.path,
        ]
    }

    func selectPreset(id: String, projectDir: String) {
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        let store = loadRawStore(projectDir: projectDir)
        let target = (id == "default" || store.presets.contains(where: { $0.id == id })) ? id : "default"
        saveStore(activePresetId: target, presets: store.presets, canonical: canonical)
    }

    @discardableResult
    func selectPreset(named name: String, projectDir: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("default") == .orderedSame {
            selectPreset(id: "default", projectDir: projectDir)
            return true
        }
        let store = loadRawStore(projectDir: projectDir)
        if let match = store.presets.first(where: {
            $0.id == trimmed || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            selectPreset(id: match.id, projectDir: projectDir)
            return true
        }
        return false
    }

    @discardableResult
    func createPreset(name: String, urlsOrdered: [String], projectDir: String) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        var store = loadRawStore(projectDir: projectDir)

        let byURL = Dictionary(uniqueKeysWithValues: canonical.map { ($0.url, $0) })
        let orderedEntries = urlsOrdered.compactMap { byURL[$0] }
        let entries = reconciled(orderedEntries, canonical: canonical)

        let newID = "preset-" + UUID().uuidString.lowercased()
        store.presets.append(Preset(id: newID, name: cleanName, playlists: entries))
        saveStore(activePresetId: newID, presets: store.presets, canonical: canonical)
        return newID
    }

    func updatePresetOrder(id: String, urlsOrdered: [String], projectDir: String) {
        guard id != "default" else { return }
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        var store = loadRawStore(projectDir: projectDir)
        guard let idx = store.presets.firstIndex(where: { $0.id == id }) else { return }
        let byURL = Dictionary(uniqueKeysWithValues: canonical.map { ($0.url, $0) })
        let orderedEntries = urlsOrdered.compactMap { byURL[$0] }
        store.presets[idx].playlists = reconciled(orderedEntries, canonical: canonical)
        saveStore(activePresetId: store.activePresetId, presets: store.presets, canonical: canonical)
    }

    func renamePreset(id: String, name: String, projectDir: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != "default", !cleanName.isEmpty else { return }
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        var store = loadRawStore(projectDir: projectDir)
        guard let idx = store.presets.firstIndex(where: { $0.id == id }) else { return }
        store.presets[idx].name = cleanName
        saveStore(activePresetId: store.activePresetId, presets: store.presets, canonical: canonical)
    }

    func deletePreset(id: String, projectDir: String) {
        guard id != "default" else { return }
        let canonical = loadDefaultPlaylists(projectDir: projectDir)
        var store = loadRawStore(projectDir: projectDir)
        store.presets.removeAll { $0.id == id }
        let nextActive = (store.activePresetId == id) ? "default" : store.activePresetId
        saveStore(activePresetId: nextActive, presets: store.presets, canonical: canonical)
    }
}
