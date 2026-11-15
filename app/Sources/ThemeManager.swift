import AppKit
import CoreServices
import Foundation
import WebKit

struct ThemePalette: Equatable {
    let bgHex: String
    let surfaceHex: String
    let textHex: String
    let mutedHex: String
    let accentHex: String

    var bgColor: NSColor { NSColor(nmrHex: bgHex) ?? .windowBackgroundColor }
    var surfaceColor: NSColor { NSColor(nmrHex: surfaceHex) ?? .controlBackgroundColor }
    var textColor: NSColor { NSColor(nmrHex: textHex) ?? .labelColor }
    var mutedColor: NSColor { NSColor(nmrHex: mutedHex) ?? .secondaryLabelColor }
    var accentColor: NSColor { NSColor(nmrHex: accentHex) ?? .controlAccentColor }
}

struct AppTheme: Identifiable {
    let id: String
    let fileName: String
    let fileURL: URL
    let mode: AppearanceMode
    let pairID: String?
    let group: String?
    let customName: String
    let officialName: String
    let displayName: String
    let rawCSS: String
    let palette: ThemePalette
}

/// Manages shared NAGA CSS themes (`~/Development/Themes/New Music Research` + `BundledThemes`),
/// live FSEvents reloading, light/dark pairing via `naga-pair` headers, and WKWebView CSS injection.
final class ThemeManager {
    static let shared = ThemeManager()
    static let themesChangedNotification = Notification.Name("NMRThemesChanged")

    static let appFolderName = "New Music Research"
    static let defaultDarkThemeID = "dracula"
    static let defaultLightThemeID = "gruvbox-light"

    private(set) var themes: [AppTheme] = []
    private(set) var activeTheme: AppTheme?
    private(set) var lastErrorMessage: String?

    private var lastGoodCSS: [String: String] = [:]
    private var lastGoodThemes: [String: AppTheme] = [:]
    private var watcher: ThemesFolderWatcher?
    private var watchedRootPath: String = ""
    private var isReloading = false

    private init() {
        seedBundledThemesIfNeeded()
        reloadThemes(notify: false)
        startWatcherIfNeeded()
    }

    // MARK: - Folders & Seeding

    var defaultThemesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    var effectiveThemesRoot: URL {
        if let custom = SharedStore.shared.themesRootPath, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultThemesRoot
    }

    var isUsingCustomFolder: Bool {
        guard let custom = SharedStore.shared.themesRootPath, !custom.isEmpty else { return false }
        let expanded = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
        return expanded != defaultThemesRoot.standardizedFileURL.path
    }

    var appThemesFolder: URL {
        let root = effectiveThemesRoot
        let nested = root.appendingPathComponent(Self.appFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: nested.path) {
            return nested
        }
        if isUsingCustomFolder {
            let directCSS = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .contains(where: { $0.pathExtension.lowercased() == "css" && !$0.lastPathComponent.hasPrefix(".") }) ?? false
            if directCSS {
                return root
            }
        }
        return nested
    }

    var nameTableURL: URL {
        let candidate = effectiveThemesRoot.appendingPathComponent(ThemeMarkers.namesFileName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return defaultThemesRoot.appendingPathComponent(ThemeMarkers.namesFileName)
    }

    private func bundledThemesDirectory() -> URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("BundledThemes", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        // Fallback when running unbundled from app/.build
        let cwdThemes = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
        if FileManager.default.fileExists(atPath: cwdThemes.path) {
            return cwdThemes
        }
        return nil
    }

    func seedBundledThemesIfNeeded() {
        let fm = FileManager.default
        let targetDir = appThemesFolder
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        guard let sourceDir = bundledThemesDirectory(),
              let files = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension.lowercased() == "css" && !file.lastPathComponent.hasPrefix(".") {
            let dest = targetDir.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: file, to: dest)
            }
        }
    }

    // MARK: - Current Side & Listed Themes

    var currentSide: AppearanceMode {
        if let active = activeTheme {
            return active.mode
        }
        return SharedStore.shared.appearance == .light ? .light : .dark
    }

    /// Returns ONLY themes on the current light/dark side, never mixing both sides.
    var listedThemes: [AppTheme] {
        let side = currentSide
        return themes.filter { $0.mode == side }
    }

    func preferredThemeID(for side: AppearanceMode) -> String {
        switch side {
        case .dark: return SharedStore.shared.preferredDarkThemeID
        case .light: return SharedStore.shared.preferredLightThemeID
        }
    }

    // MARK: - Loading & Validation

    func reloadThemes(notify: Bool = true) {
        if isReloading { return }
        isReloading = true
        defer { isReloading = false }

        let folder = appThemesFolder
        let nameRoot = nameTableURL.deletingLastPathComponent()
        let nameTable = ThemeMarkers.loadFullNameTable(root: nameRoot)
        let displayMode = SharedStore.shared.themeNameDisplay

        var candidateURLs: [URL] = []
        if let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            candidateURLs = items.filter { $0.pathExtension.lowercased() == "css" }
        }
        if candidateURLs.isEmpty, let bundled = bundledThemesDirectory(),
           let items = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            candidateURLs = items.filter { $0.pathExtension.lowercased() == "css" && !$0.lastPathComponent.hasPrefix(".") }
        }

        var loaded: [AppTheme] = []
        var firstError: String?

        for url in candidateURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileBase = url.deletingPathExtension().lastPathComponent
            let fileName = url.lastPathComponent
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                if firstError == nil {
                    firstError = "Could not read theme file \(fileName) — keeping working colors."
                }
                continue
            }

            let provisionalID = ThemeMarkers.id(in: raw) ?? ThemeMarkers.slug(fileBase)
            if let syntaxIssue = validateCSSSyntax(raw) {
                if firstError == nil {
                    firstError = "\(fileName): \(syntaxIssue) Keeping previous working colors."
                }
                if let cached = lastGoodThemes[provisionalID] {
                    loaded.append(cached)
                }
                continue
            }

            let palette = Self.extractPalette(from: raw)
            let fallbackMode = ThemeMarkers.mode(fallbackLuma: Self.relativeLuminance(hex: palette.bgHex))
            let mode = ThemeMarkers.mode(in: raw) ?? fallbackMode ?? .dark
            let pairID = ThemeMarkers.pair(in: raw)
            let group = Self.groupMarker(in: raw)

            let entry = nameTable[provisionalID]
            let customName = entry?.name ?? fileBase
            let officialName = entry?.official ?? fileBase
            let displayName: String
            switch displayMode {
            case .custom:
                displayName = customName
            case .official:
                displayName = officialName
            case .both:
                displayName = customName == officialName ? customName : "\(customName) (\(officialName))"
            }

            let theme = AppTheme(
                id: provisionalID,
                fileName: fileName,
                fileURL: url,
                mode: mode,
                pairID: pairID,
                group: group,
                customName: customName,
                officialName: officialName,
                displayName: displayName,
                rawCSS: raw,
                palette: palette
            )
            lastGoodCSS[provisionalID] = raw
            lastGoodThemes[provisionalID] = theme
            loaded.append(theme)
        }

        loaded.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        themes = loaded
        lastErrorMessage = firstError
        syncActiveThemeSelection()
        startWatcherIfNeeded()

        if notify {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.themesChangedNotification, object: self)
            }
        }
    }

    private func syncActiveThemeSelection() {
        guard !themes.isEmpty else {
            activeTheme = nil
            return
        }

        let targetID: String
        if let savedID = SharedStore.shared.activeThemeID,
           themes.contains(where: { $0.id == savedID }) {
            targetID = savedID
        } else {
            let systemMode = detectSystemAppearanceMode()
            let preferred = systemMode == .light ? SharedStore.shared.preferredLightThemeID : SharedStore.shared.preferredDarkThemeID
            if themes.contains(where: { $0.id == preferred && $0.mode == systemMode }) {
                targetID = preferred
            } else if let firstOnSide = themes.first(where: { $0.mode == systemMode }) {
                targetID = firstOnSide.id
            } else {
                targetID = themes[0].id
            }
        }

        activeTheme = themes.first(where: { $0.id == targetID }) ?? themes.first
        if let active = activeTheme {
            let appMode: AppAppearance = active.mode == .light ? .light : .dark
            SharedStore.shared.updateThemePreferences(
                activeThemeID: active.id,
                preferredDarkThemeID: active.mode == .dark ? active.id : nil,
                preferredLightThemeID: active.mode == .light ? active.id : nil,
                listedAppearance: active.mode.rawValue,
                appearance: appMode,
                notify: false
            )
        }
    }

    private func detectSystemAppearanceMode() -> AppearanceMode {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        if style?.lowercased() == "dark" {
            return .dark
        }
        if let effective = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return effective == .darkAqua ? .dark : .light
        }
        return style == nil ? .light : .dark
    }

    // MARK: - Selection & Mode Switching

    @discardableResult
    func selectTheme(id: String) -> Bool {
        guard let theme = themes.first(where: { $0.id == id }) else { return false }
        activeTheme = theme
        let appMode: AppAppearance = theme.mode == .light ? .light : .dark
        SharedStore.shared.updateThemePreferences(
            activeThemeID: theme.id,
            preferredDarkThemeID: theme.mode == .dark ? theme.id : nil,
            preferredLightThemeID: theme.mode == .light ? theme.id : nil,
            listedAppearance: theme.mode.rawValue,
            appearance: appMode,
            notify: false
        )
        NotificationCenter.default.post(name: Self.themesChangedNotification, object: self)
        NotificationCenter.default.post(name: SharedStore.changedNotification, object: SharedStore.shared)
        return true
    }

    func switchAppearance(to requestedSide: AppearanceMode? = nil) {
        let nextSide = requestedSide ?? currentSide.opposite
        guard nextSide != currentSide else { return }

        if let pairID = activeTheme?.pairID,
           let paired = themes.first(where: { $0.id == pairID && $0.mode == nextSide }) ?? themes.first(where: { $0.id == pairID }) {
            selectTheme(id: paired.id)
            return
        }

        let prefID = preferredThemeID(for: nextSide)
        if let preferred = themes.first(where: { $0.id == prefID && $0.mode == nextSide }) {
            selectTheme(id: preferred.id)
            return
        }

        let defaultID = nextSide == .dark ? Self.defaultDarkThemeID : Self.defaultLightThemeID
        if let fallback = themes.first(where: { $0.id == defaultID }) ?? themes.first(where: { $0.mode == nextSide }) {
            selectTheme(id: fallback.id)
        }
    }

    func toggleAppearance() {
        switchAppearance(to: nil)
    }

    func resolve(nameOrID query: String) -> AppTheme? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let querySlug = ThemeMarkers.slug(trimmed)

        if let exact = themes.first(where: { $0.id == trimmed || $0.id == querySlug }) {
            return exact
        }
        return themes.first(where: {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.customName.caseInsensitiveCompare(trimmed) == .orderedSame ||
            $0.officialName.caseInsensitiveCompare(trimmed) == .orderedSame ||
            ThemeMarkers.slug($0.customName) == querySlug ||
            ThemeMarkers.slug($0.officialName) == querySlug ||
            ThemeMarkers.slug($0.fileURL.deletingPathExtension().lastPathComponent) == querySlug
        })
    }

    // MARK: - Folders & Watcher

    func setThemesFolder(_ url: URL) {
        let normalized = url.standardizedFileURL
        SharedStore.shared.setThemesRootPath(normalized.path)
        seedBundledThemesIfNeeded()
        reloadThemes(notify: true)
    }

    func resetThemesFolder() {
        SharedStore.shared.setThemesRootPath(nil)
        seedBundledThemesIfNeeded()
        reloadThemes(notify: true)
    }

    func setThemeNameDisplay(_ mode: ThemeNameDisplay) {
        SharedStore.shared.setThemeNameDisplay(mode)
        reloadThemes(notify: true)
    }

    private func startWatcherIfNeeded() {
        let folderPath = appThemesFolder.standardizedFileURL.path + "|" + nameTableURL.standardizedFileURL.path
        if folderPath == watchedRootPath, watcher != nil { return }
        watcher?.stop()
        watchedRootPath = folderPath
        let newWatcher = ThemesFolderWatcher(appFolder: appThemesFolder, nameTable: nameTableURL) { [weak self] in
            self?.reloadThemes(notify: true)
        }
        newWatcher.start()
        watcher = newWatcher
    }

    // MARK: - Menus & Settings Payload

    func themesMenuSpec(target: AnyObject?, selectTheme: Selector, switchAppearance: Selector, openFolder: Selector, manageThemes: Selector? = nil, switchKey: String = "l", switchModifiers: NSEvent.ModifierFlags = [.command, .shift]) -> ThemesMenu.Spec {
        let side: ThemesMenu.Side = currentSide == .light ? .light : .dark
        let rows: [ThemesMenu.Row] = listedThemes.map { theme in
            ThemesMenu.Row(
                id: theme.id,
                title: theme.displayName,
                side: theme.mode == .light ? .light : .dark,
                isActive: theme.id == activeTheme?.id,
                group: theme.group
            )
        }
        return ThemesMenu.Spec(
            target: target,
            currentSide: side,
            themes: rows,
            selectTheme: selectTheme,
            switchAppearance: switchAppearance,
            switchEnabled: !themes.isEmpty,
            switchKey: switchKey,
            switchModifiers: switchModifiers,
            appItems: [],
            watchesFolder: true,
            reload: nil,
            manageThemes: manageThemes,
            folders: [
                ThemesMenu.Folder(
                    title: "Open New Music Research Themes Folder",
                    url: appThemesFolder
                )
            ],
            openFolder: openFolder,
            emptyTitle: "No themes found"
        )
    }

    func activePalette() -> ThemePalette {
        activeTheme?.palette ?? ThemePalette(
            bgHex: "#1e1f29",
            surfaceHex: "#282a36",
            textHex: "#f8f8f2",
            mutedHex: "#a7b1d4",
            accentHex: "#bd93f9"
        )
    }

    func activeModeString() -> String {
        currentSide.rawValue
    }

    func activeCSS() -> String {
        guard let active = activeTheme else { return "" }
        let raw = lastGoodCSS[active.id] ?? active.rawCSS
        return Self.scopeRootSelectorsForInjection(raw)
    }

    func activeInjectionScript() -> String {
        let css = activeCSS()
        let mode = currentSide.rawValue
        let id = activeTheme?.id ?? ""
        let cssLiteral = Self.jsStringLiteral(css)
        let modeLiteral = Self.jsStringLiteral(mode)
        let idLiteral = Self.jsStringLiteral(id)
        return """
        (() => {
          const css = \(cssLiteral);
          const mode = \(modeLiteral);
          const id = \(idLiteral);
          const root = document.documentElement;
          if (root) {
            root.setAttribute('data-theme', mode);
            root.setAttribute('data-theme-id', id);
          }
          const parent = document.head || root;
          if (parent && css) {
            let style = document.getElementById('nmr-active-theme');
            if (!style) {
              style = document.createElement('style');
              style.id = 'nmr-active-theme';
              parent.appendChild(style);
            }
            if (style.textContent !== css) {
              style.textContent = css;
            }
          }
          if (window.__nmrOnThemeApplied) {
            try { window.__nmrOnThemeApplied({ id, mode }); } catch (_) {}
          }
        })();
        """
    }

    func applyLiveTheme(to webView: WKWebView) {
        webView.evaluateJavaScript(activeInjectionScript(), completionHandler: nil)
    }

    func exportSettingsPayload() -> [String: Any] {
        let swatches: [[String: Any]] = listedThemes.map { theme in
            [
                "id": theme.id,
                "name": theme.displayName,
                "customName": theme.customName,
                "officialName": theme.officialName,
                "mode": theme.mode.rawValue,
                "active": theme.id == activeTheme?.id,
                "pair": theme.pairID ?? "",
                "group": theme.group ?? "",
                "palette": [
                    "bg": theme.palette.bgHex,
                    "surface": theme.palette.surfaceHex,
                    "text": theme.palette.textHex,
                    "muted": theme.palette.mutedHex,
                    "accent": theme.palette.accentHex,
                ],
            ]
        }
        return [
            "activeThemeId": activeTheme?.id ?? "",
            "activeThemeName": activeTheme?.displayName ?? "",
            "currentSide": currentSide.rawValue,
            "nameDisplay": SharedStore.shared.themeNameDisplay.rawValue,
            "folderPath": appThemesFolder.path,
            "rootPath": effectiveThemesRoot.path,
            "isCustomFolder": isUsingCustomFolder,
            "error": lastErrorMessage ?? "",
            "listedThemes": swatches,
            "totalCount": themes.count,
        ]
    }

    // MARK: - CSS Syntax & Palette Helpers

    private func validateCSSSyntax(_ css: String) -> String? {
        var depth = 0
        var inComment = false
        var quote: Character? = nil
        var escaped = false
        let chars = Array(css)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            if inComment {
                if ch == "*" && next == "/" {
                    inComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if let q = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
                i += 1
                continue
            }
            if ch == "/" && next == "*" {
                inComment = true
                i += 2
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                i += 1
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth < 0 {
                    return "extra closing `}`."
                }
            }
            i += 1
        }
        if inComment { return "unclosed `/* ... */` comment." }
        if quote != nil { return "unclosed string literal." }
        if depth != 0 { return "unclosed `{` bracket." }
        if !css.contains("{") || !css.contains("--") {
            return "missing CSS variable block."
        }
        return nil
    }

    private static func groupMarker(in raw: String) -> String? {
        let head = String(raw.prefix(900))
        guard let r = head.range(of: #"naga-group\s*:\s*[^\r\n*]+"#, options: .regularExpression) else {
            return nil
        }
        let val = head[r].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (val?.isEmpty == false) ? val : nil
    }

    private static func scopeRootSelectorsForInjection(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"(?m)^(\s*):root(\s*\{)"#,
            with: "$1:root, html[data-theme=\"dark\"], html[data-theme=\"light\"]$2",
            options: .regularExpression
        )
    }

    private static func extractPalette(from css: String) -> ThemePalette {
        var vars: [String: String] = [:]
        if let regex = try? NSRegularExpression(pattern: #"(--[A-Za-z0-9_-]+)\s*:\s*([^;}{]+);"#) {
            let ns = css as NSString
            let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 3 {
                let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if vars[key] == nil || !val.isEmpty {
                    vars[key] = val
                }
            }
        }

        func resolve(_ keys: [String], fallback: String) -> String {
            for k in keys {
                if var val = vars[k] {
                    for _ in 0..<5 {
                        if let m = val.range(of: #"var\(\s*(--[A-Za-z0-9_-]+)\s*\)"#, options: .regularExpression) {
                            let inner = String(val[m])
                                .replacingOccurrences(of: "var(", with: "")
                                .replacingOccurrences(of: ")", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            if let resolved = vars[inner] {
                                val = val.replacingCharacters(in: m, with: resolved)
                                continue
                            }
                        }
                        break
                    }
                    if let hex = normalizeColorToHex(val) {
                        return hex
                    }
                }
            }
            return fallback
        }

        let markerAccent = ThemeMarkers.accent(in: css)
        let bg = resolve(["--bg", "--abyss", "--void"], fallback: "#1e1f29")
        let surface = resolve(["--surface", "--elevated", "--panel-bg"], fallback: bg)
        let text = resolve(["--text", "--text-2"], fallback: "#f8f8f2")
        let muted = resolve(["--muted", "--ghost", "--text-2"], fallback: text)
        let accent = resolve(["--accent", "--cyan"], fallback: markerAccent ?? "#bd93f9")

        return ThemePalette(
            bgHex: bg,
            surfaceHex: surface,
            textHex: text,
            mutedHex: muted,
            accentHex: accent
        )
    }

    private static func normalizeColorToHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 6 || hex.count == 3 || hex.count == 8 {
                return "#" + String(hex.prefix(6)).lowercased()
            }
        }
        if trimmed.lowercased().hasPrefix("rgb"),
           let open = trimmed.firstIndex(of: "("),
           let close = trimmed.firstIndex(of: ")") {
            let inside = trimmed[trimmed.index(after: open)..<close]
            let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3,
               let r = Double(parts[0]),
               let g = Double(parts[1]),
               let b = Double(parts[2]) {
                let ri = max(0, min(255, Int(r.rounded())))
                let gi = max(0, min(255, Int(g.rounded())))
                let bi = max(0, min(255, Int(b.rounded())))
                return String(format: "#%02x%02x%02x", ri, gi, bi)
            }
        }
        return nil
    }

    private static func relativeLuminance(hex: String) -> Double? {
        guard let color = NSColor(nmrHex: hex)?.usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent) + 0.0722 * Double(color.blueComponent)
    }

    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrStr = String(data: data, encoding: .utf8),
              arrStr.count >= 2 else {
            return "\"\""
        }
        return String(arrStr.dropFirst().dropLast())
    }
}

private extension NSColor {
    convenience init?(nmrHex hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var expanded = cleaned
        if expanded.count == 3 {
            expanded = expanded.map { "\($0)\($0)" }.joined()
        }
        guard expanded.count >= 6, let val = UInt64(String(expanded.prefix(6)), radix: 16) else {
            return nil
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
