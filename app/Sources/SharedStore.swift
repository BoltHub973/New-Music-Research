import Foundation

enum AppAppearance: String {
    case dark
    case light

    var toggled: AppAppearance { self == .dark ? .light : .dark }
}

/// Shared user-owned state stored in ~/Library/Application Support/New Music Research/settings.json
/// so every checkout/worktree reads and writes the same preferences, synced live via a folder watcher.
final class SharedStore {
    static let shared = SharedStore()
    static let changedNotification = Notification.Name("NMRSharedStoreChanged")

    let storeDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("New Music Research", isDirectory: true)
    }()

    var settingsURL: URL { storeDir.appendingPathComponent("settings.json") }

    private(set) var appearance: AppAppearance = .dark
    private(set) var pageZoom: Double = 1.0
    private(set) var shortcuts: [String: [String]] = [:]
    private(set) var settingsSectionOrder: [String] = ["general", "appearance", "shortcuts", "urls"]
    private(set) var secondaryWindowFrame: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var lastLoadedData: Data?

    private init() {
        loadFromDisk(notify: false)
        watchStoreFolder()
    }

    deinit {
        watcher?.cancel()
    }

    func setAppearance(_ value: AppAppearance) {
        guard value != appearance else { return }
        appearance = value
        saveToDisk()
        notifyChanged()
    }

    func toggleAppearance() {
        setAppearance(appearance.toggled)
    }

    func setPageZoom(_ value: Double) {
        let clamped = min(max(value, 0.5), 3.0)
        guard abs(clamped - pageZoom) > 0.001 else { return }
        pageZoom = clamped
        saveToDisk()
        notifyChanged()
    }

    func setShortcuts(_ map: [String: [String]]) {
        shortcuts = map
        saveToDisk()
        notifyChanged()
    }

    func setCombos(_ combos: [String], for actionId: String) {
        shortcuts[actionId] = combos
        saveToDisk()
        notifyChanged()
    }

    func removeCustomShortcuts(for actionId: String) {
        shortcuts.removeValue(forKey: actionId)
        saveToDisk()
        notifyChanged()
    }

    func setSettingsSectionOrder(_ order: [String]) {
        settingsSectionOrder = order
        saveToDisk()
        notifyChanged()
    }

    func setSecondaryWindowFrame(_ frameString: String) {
        guard secondaryWindowFrame != frameString else { return }
        secondaryWindowFrame = frameString
        saveToDisk()
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

    private func loadFromDisk(notify: Bool) {
        guard let data = try? Data(contentsOf: settingsURL),
              data != lastLoadedData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        lastLoadedData = data

        if let rawApp = obj["appearance"] as? String,
           let parsed = AppAppearance(rawValue: rawApp) {
            appearance = parsed
        } else {
            appearance = .dark
        }

        if let z = obj["pageZoom"] as? Double, z >= 0.5, z <= 3.0 {
            pageZoom = z
        } else {
            // Migrate legacy UserDefaults zoom once if present
            let legacy = UserDefaults.standard.double(forKey: "pageZoom")
            pageZoom = (legacy >= 0.5 && legacy <= 3.0) ? legacy : 1.0
        }

        if let sc = obj["shortcuts"] as? [String: [String]] {
            shortcuts = sc
        } else {
            shortcuts = [:]
        }

        let defaultOrder = ["general", "appearance", "shortcuts", "urls"]
        if let order = obj["settingsSectionOrder"] as? [String], !order.isEmpty {
            var healed = order.filter { defaultOrder.contains($0) }
            for item in defaultOrder where !healed.contains(item) {
                healed.append(item)
            }
            settingsSectionOrder = healed
        } else {
            settingsSectionOrder = defaultOrder
        }

        secondaryWindowFrame = obj["secondaryWindowFrame"] as? String

        if notify { notifyChanged() }
    }

    private func saveToDisk() {
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "appearance": appearance.rawValue,
            "pageZoom": pageZoom,
            "shortcuts": shortcuts,
            "settingsSectionOrder": settingsSectionOrder,
        ]
        if let frame = secondaryWindowFrame {
            obj["secondaryWindowFrame"] = frame
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        lastLoadedData = data
        try? data.write(to: settingsURL, options: .atomic)
    }

    private func watchStoreFolder() {
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let fd = open(storeDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.loadFromDisk(notify: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

/// Persistent log of scraped & missed tracks stored in ~/Library/Application Support/New Music Research/history.json.
/// Replaces scraped-files/*.csv and missed-tracks/*.csv. Also performs a one-time read-only import of any
/// legacy CSVs on disk if history.json does not yet exist.
final class HistoryStore {
    static let shared = HistoryStore()
    static let changedNotification = Notification.Name("NMRHistoryStoreChanged")

    var historyURL: URL {
        SharedStore.shared.storeDir.appendingPathComponent("history.json")
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var lastDigest: Int = 0

    private init() {
        watchStoreFolder()
    }

    deinit {
        watcher?.cancel()
    }

    func loadRuns(projectDir: String) -> [[String: Any]] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyURL.path) {
            migrateLegacyCSVsIfNeeded(projectDir: projectDir)
        }
        guard let data = try? Data(contentsOf: historyURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    func loadJSONString(projectDir: String) -> String {
        let runs = loadRuns(projectDir: projectDir)
        guard let data = try? JSONSerialization.data(withJSONObject: runs),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    func deleteRun(id: String) {
        guard let data = try? Data(contentsOf: historyURL),
              var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        arr.removeAll { ($0["id"] as? String) == id }
        writeRuns(arr)
    }

    func clearAll() {
        writeRuns([])
    }

    private func writeRuns(_ runs: [[String: Any]]) {
        try? FileManager.default.createDirectory(at: SharedStore.shared.storeDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: runs, options: [.prettyPrinted]) else {
            return
        }
        lastDigest = data.hashValue
        try? data.write(to: historyURL, options: .atomic)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private func watchStoreFolder() {
        let dir = SharedStore.shared.storeDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self,
                  let data = try? Data(contentsOf: self.historyURL) else { return }
            let h = data.hashValue
            if h != self.lastDigest {
                self.lastDigest = h
                NotificationCenter.default.post(name: Self.changedNotification, object: self)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// One-time read-only import of existing SCRAPED / MISSED CSVs so historical logs appear immediately.
    private func migrateLegacyCSVsIfNeeded(projectDir: String) {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: projectDir)
        let scrapedDir = baseURL.appendingPathComponent("scraped-files")
        let missedDir = baseURL.appendingPathComponent("missed-tracks")

        struct ParsedCSV {
            let date: Date
            let rows: [[String: String]]
            let filename: String
        }

        func parseFiles(in dir: URL, prefix: String) -> [ParsedCSV] {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return []
            }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "MM-dd-yy__hh.mm.ss a"

            var out: [ParsedCSV] = []
            for file in files where file.pathExtension.lowercased() == "csv" && file.lastPathComponent.hasPrefix(prefix) {
                let stem = file.deletingPathExtension().lastPathComponent
                let stampStr = String(stem.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let date = df.date(from: stampStr) ?? modDate
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    let rows = Self.parseCSV(text)
                    out.append(ParsedCSV(date: date, rows: rows, filename: file.lastPathComponent))
                }
            }
            return out.sorted { $0.date > $1.date }
        }

        let scrapedFiles = parseFiles(in: scrapedDir, prefix: "SCRAPED ")
        var missedFiles = parseFiles(in: missedDir, prefix: "MISSED ")
        guard !scrapedFiles.isEmpty || !missedFiles.isEmpty else {
            writeRuns([])
            return
        }

        func mapRows(_ rows: [[String: String]]) -> [[String: Any]] {
            rows.map { r in
                [
                    "title": r["Title"] ?? "",
                    "artist": r["Artist"] ?? "",
                    "album": r["Album"] ?? "",
                    "source": r["Source Playlist"] ?? "",
                    "dateAdded": r["Date Added"] ?? "",
                    "art": r["Art"] ?? "",
                    "video": r["Video Art"] ?? "",
                    "playlistCount": Int(r["Playlist Count"] ?? "1") ?? 1,
                ]
            }
        }

        var runs: [[String: Any]] = []
        let dispFmt = DateFormatter()
        dispFmt.dateFormat = "MM-dd-yy"

        for sc in scrapedFiles {
            // Pair any missed CSV recorded within 45 minutes after this scraped CSV
            var pairedMissed: [[String: Any]] = []
            if let matchIdx = missedFiles.firstIndex(where: { abs($0.date.timeIntervalSince(sc.date)) <= 2700 }) {
                pairedMissed = mapRows(missedFiles[matchIdx].rows)
                missedFiles.remove(at: matchIdx)
            }
            let scMapped = mapRows(sc.rows)
            runs.append([
                "id": "legacy-\(Int(sc.date.timeIntervalSince1970))-\(runs.count)",
                "timestamp": sc.date.timeIntervalSince1970,
                "mode": "this-week",
                "ok": true,
                "message": "Imported from legacy CSV log",
                "playlistName": "🪁 DX \(dispFmt.string(from: sc.date))",
                "spotifyUri": "",
                "stats": [
                    "unique": scMapped.count,
                    "omitted": pairedMissed.count,
                    "matched": max(0, scMapped.count - pairedMissed.count),
                ],
                "scraped": scMapped,
                "missed": pairedMissed,
            ])
        }

        for ms in missedFiles {
            let msMapped = mapRows(ms.rows)
            runs.append([
                "id": "legacy-missed-\(Int(ms.date.timeIntervalSince1970))-\(runs.count)",
                "timestamp": ms.date.timeIntervalSince1970,
                "mode": "this-week",
                "ok": true,
                "message": "Imported missed tracks log",
                "playlistName": "🪁 DX \(dispFmt.string(from: ms.date))",
                "spotifyUri": "",
                "stats": ["omitted": msMapped.count],
                "scraped": [],
                "missed": msMapped,
            ])
        }

        runs.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
        writeRuns(runs)
    }

    static func parseCSV(_ content: String) -> [[String: String]] {
        let normalized = content
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        let chars = Array(normalized)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if c == "\n" {
                    currentRow.append(currentField)
                    rows.append(currentRow)
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(c)
                }
            }
            i += 1
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }
        guard let rawHeaders = rows.first, !rawHeaders.isEmpty else { return [] }
        let headers = rawHeaders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var dicts: [[String: String]] = []
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            var d: [String: String] = [:]
            for (idx, h) in headers.enumerated() {
                d[h] = idx < row.count ? row[idx] : ""
            }
            dicts.append(d)
        }
        return dicts
    }
}
