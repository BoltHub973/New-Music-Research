import AppKit

// ┌──────────────────────────────────────────────────────────────────────────────────────┐
// │ MASTER COPY — Adrian's standard Themes menu (11-06-26, every Mac app).                 │
// │ Lives at ~/Development/Themes/_Themes Menu MASTER/ThemesMenu.swift. Each app keeps a COPY in   │
// │ its own repo, refreshed by _Themes Menu MASTER/sync.sh at the start of its build.sh, so the    │
// │ app still builds anywhere. EDIT THE MASTER ONLY: a hand edit to a copy is replaced on  │
// │ the next build on Adrian's Mac.                                                        │
// └──────────────────────────────────────────────────────────────────────────────────────┘
//
// The layout, top to bottom (from Notion (NAGA), Adrian 11-06-26):
//   1. Switch to Light/Dark Appearance (⇧⌘L) — ALWAYS first, naming the side you GET
//   2. the CURRENT side's themes only (named groups first, under a header), ✓ on the active
//   3. the app's own items (Turn Off Theme, a banner toggle) — skipped when there are none
//   4. housekeeping LAST: Reload Themes (ONLY when the app does not watch its themes
//      folder), Manage Themes… (when the app has it), Open … Themes Folder
//
// An app customises only through `Spec`: its themes, its own items, its labels, its actions.
// It cannot reorder the blocks or list the other side's themes — that is what keeps every
// app's menu the same. Generic on purpose: no paths, names or folders of Adrian's in here.
enum ThemesMenu {
    /// Bumped on every change to the layout; `sync.sh` and the guard print it.
    static let layoutVersion = 1

    enum Side { case dark, light }

    struct Row {
        var id: String            // handed back as the item's representedObject
        var title: String         // the shown name (a label only)
        var side: Side            // from the file's naga-mode marker, never the name
        var isActive: Bool
        var group: String? = nil  // a naga-group, e.g. "Inspiration" — listed first
    }

    struct Folder {
        var title: String         // "Open Markdown DX Themes Folder"
        var url: URL              // handed back as the item's representedObject
    }

    struct Spec {
        var target: AnyObject?
        /// The side being shown. Only rows on this side are listed.
        var currentSide: Side
        var themes: [Row]
        var selectTheme: Selector
        var switchAppearance: Selector
        var switchEnabled = true
        var switchKey = ""
        var switchModifiers: NSEvent.ModifierFlags = []
        /// Block 3: the app's own items, already built (title, action, target, state).
        var appItems: [NSMenuItem] = []
        /// True when the app watches its themes folder and applies edits on save: then
        /// there is no Reload Themes item.
        var watchesFolder: Bool
        var reload: Selector? = nil
        var manageThemes: Selector? = nil
        var folders: [Folder]
        var openFolder: Selector
        /// Shown in block 2 when the current side has no themes.
        var emptyTitle: String? = nil
    }

    /// Fill `menu` (cleared first) in the standard order. Returns the Switch item so the
    /// app can retitle it live.
    @discardableResult
    static func build(_ menu: NSMenu, _ spec: Spec) -> NSMenuItem {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, symbol: String?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = spec.target
            item.isEnabled = action != nil
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
            menu.addItem(item)
            return item
        }

        // 1. Switch — names the side you GET.
        let toLight = spec.currentSide == .dark
        let switchItem = add("Switch to \(toLight ? "Light" : "Dark") Appearance", spec.switchAppearance,
                             symbol: toLight ? "sun.max.fill" : "moon.fill")
        switchItem.isEnabled = spec.switchEnabled
        switchItem.keyEquivalent = spec.switchKey
        switchItem.keyEquivalentModifierMask = spec.switchModifiers
        menu.addItem(.separator())

        // 2. The current side's themes: named groups first (alphabetical), then the rest.
        let shown = spec.themes.filter { $0.side == spec.currentSide }
        func row(_ theme: Row) {
            let item = add(theme.title, spec.selectTheme, symbol: theme.side == .light ? "sun.max" : "moon")
            item.representedObject = theme.id
            item.state = theme.isActive ? .on : .off
            item.toolTip = "\(theme.title) — \(theme.side == .light ? "light" : "dark") theme"
        }
        let groups = Set(shown.compactMap { $0.group }).sorted()
        for group in groups {
            menu.addItem(sectionHeader(group))
            shown.filter { $0.group == group }.forEach(row)
        }
        let plain = shown.filter { $0.group == nil }
        if !groups.isEmpty, !plain.isEmpty { menu.addItem(.separator()) }
        plain.forEach(row)
        if shown.isEmpty {
            _ = add(spec.emptyTitle ?? "No \(spec.currentSide == .dark ? "Dark" : "Light") Themes", nil, symbol: nil)
        }

        // 3. The app's own items.
        if !spec.appItems.isEmpty {
            menu.addItem(.separator())
            for item in spec.appItems {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }

        // 4. Housekeeping, last.
        menu.addItem(.separator())
        if !spec.watchesFolder, let reload = spec.reload {
            _ = add("Reload Themes", reload, symbol: "arrow.clockwise")
        }
        if let manage = spec.manageThemes {
            _ = add("Manage Themes…", manage, symbol: "slider.horizontal.3")
        }
        for folder in spec.folders {
            add(folder.title, spec.openFolder, symbol: "folder").representedObject = folder.url
        }
        return switchItem
    }

    /// Row titles in order, separators as "—" (state dumps, guards).
    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
