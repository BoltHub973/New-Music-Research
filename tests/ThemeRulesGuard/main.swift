import Foundation

@discardableResult
func check(_ cond: Bool, _ msg: String) -> Bool {
    if !cond {
        fputs("❌ ThemeRulesGuard failed: \(msg)\n", stderr)
        exit(1)
    }
    return true
}

let args = CommandLine.arguments
let repoRoot = args.count > 1 ? URL(fileURLWithPath: args[1], isDirectory: true) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

// 1. Marker & luma fallback contracts (never infer from names)
let paradoxLight = """
/* naga-theme: midnight-paradox
   naga-mode: light
   naga-pair: bright-paradox
   naga-accent: #123456 */
"""
let paradoxDark = """
/* naga-theme: daylight-paradox
   naga-mode: dark
   naga-pair: dim-paradox
   naga-accent: #abcdef */
"""
check(ThemeMarkers.id(in: paradoxLight) == "midnight-paradox", "naga-theme parse")
check(ThemeMarkers.mode(in: paradoxLight) == .light, "explicit naga-mode: light must win over any name")
check(ThemeMarkers.mode(in: paradoxDark) == .dark, "explicit naga-mode: dark must win over any name")
check(ThemeMarkers.pair(in: paradoxLight) == "bright-paradox", "naga-pair parse")
check(ThemeMarkers.accent(in: paradoxDark) == "#abcdef", "naga-accent parse")
check(ThemeMarkers.mode(fallbackLuma: 0.85) == .light, "luma > 0.5 must resolve to light")
check(ThemeMarkers.mode(fallbackLuma: 0.12) == .dark, "luma <= 0.5 must resolve to dark")
check(ThemeMarkers.slug("Brown Espresso") == "brown-espresso", "slug folding")

// 2. Bundled Themes/*.css headers, pairs, and required tokens
let bundledDir = repoRoot.appendingPathComponent("Themes", isDirectory: true)
let cssURLs = ((try? FileManager.default.contentsOfDirectory(at: bundledDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "css" && !$0.lastPathComponent.hasPrefix(".") }
check(cssURLs.count >= 15, "expected at least 15 bundled themes in Themes/, found \(cssURLs.count)")

var byID: [String: (mode: AppearanceMode, pair: String?)] = [:]
for url in cssURLs {
    let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    guard let id = ThemeMarkers.id(in: raw) else {
        check(false, "\(url.lastPathComponent) missing naga-theme marker")
        exit(1)
    }
    guard let mode = ThemeMarkers.mode(in: raw) else {
        check(false, "\(url.lastPathComponent) missing naga-mode marker")
        exit(1)
    }
    let pair = ThemeMarkers.pair(in: raw)
    check(ThemeMarkers.accent(in: raw) != nil, "\(url.lastPathComponent) missing naga-accent marker")
    for token in ["--bg:", "--surface:", "--text:", "--muted:", "--accent:"] {
        check(raw.contains(token), "\(url.lastPathComponent) missing CSS token \(token)")
    }
    byID[id] = (mode, pair)
}

for (id, info) in byID {
    guard let pair = info.pair else { continue }
    check(byID[pair] != nil, "theme '\(id)' points naga-pair to missing id '\(pair)'")
    if let paired = byID[pair] {
        check(paired.mode != info.mode, "theme '\(id)' (\(info.mode.rawValue)) pairs with '\(pair)' on same side")
    }
}

// 3. Static source guards across app/Sources & app/Resources/settings.html
let sourcesDir = repoRoot.appendingPathComponent("app/Sources", isDirectory: true)
let themeMgrSource = (try? String(contentsOf: sourcesDir.appendingPathComponent("ThemeManager.swift"), encoding: .utf8)) ?? ""
let markersSource = (try? String(contentsOf: sourcesDir.appendingPathComponent("ThemeMarkers.swift"), encoding: .utf8)) ?? ""
let delegateSource = (try? String(contentsOf: sourcesDir.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)) ?? ""
let settingsHTML = (try? String(contentsOf: repoRoot.appendingPathComponent("app/Resources/settings.html"), encoding: .utf8)) ?? ""

let forbiddenNameHeuristics = ["latte", "mocha", "dawn", "daylight", "night", "counterpart", "family"]
for fileSource in [markersSource, themeMgrSource] {
    let lowered = fileSource.lowercased()
    for word in forbiddenNameHeuristics {
        check(!lowered.contains("\"\(word)\""), "forbidden theme-name heuristic string '\(word)' in Swift theme logic")
    }
}

check(themeMgrSource.contains("ThemesFolderWatcher("), "ThemeManager must watch folders with ThemesFolderWatcher")
check(themeMgrSource.contains("ThemeMarkers.namesFileName"), "ThemeManager must watch theme-names.json")
check(themeMgrSource.contains("lastGoodCSS") && themeMgrSource.contains("lastErrorMessage"), "ThemeManager must keep last good CSS on bad syntax and expose error")
check(themeMgrSource.contains("listedThemes") && themeMgrSource.contains("themes.filter { $0.mode == side }"), "listedThemes must filter strictly to currentSide")
check(delegateSource.contains("ThemesMenu.build("), "AppDelegate must build Themes menu with shared ThemesMenu.build master")
check(!delegateSource.contains("\"Reload Themes\""), "AppDelegate must not add manual Reload Themes item when watching folder")
check(settingsHTML.contains("th.listedThemes") && settingsHTML.contains("data-select-theme"), "Settings swatch grid must render single-side listedThemes")

print("✅ ThemeRulesGuard passed (\(cssURLs.count) themes, single-side & marker-only rules verified)")
