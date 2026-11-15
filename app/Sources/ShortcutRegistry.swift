import AppKit
import Carbon.HIToolbox

struct ShortcutAction {
    let id: String
    let title: String
    let section: String
    let defaultCombos: [String]
    /// Outward actions (like starting a live Spotify scrape) must never run via external nmr://action links.
    let safeForExternalURL: Bool
}

/// Central registry of all user-customizable multi-combo shortcuts.
/// Uses physical key codes so Option chords match physical keys, never Option-mapped symbols.
final class ShortcutRegistry {
    static let shared = ShortcutRegistry()

    /// True while a recorder UI in Settings is actively listening so shortcuts don't fire mid-record.
    var isRecording = false

    let actions: [ShortcutAction] = [
        ShortcutAction(id: "openLog", title: "Toggle Scrape & Missed Log", section: "Navigation", defaultCombos: ["cmd+l"], safeForExternalURL: true),
        ShortcutAction(id: "toggleAppearance", title: "Toggle Appearance", section: "View", defaultCombos: ["cmd+shift+l"], safeForExternalURL: true),
        ShortcutAction(id: "scrapeThisWeek", title: "Scrape This Week", section: "Scrape", defaultCombos: ["cmd+1"], safeForExternalURL: false),
        ShortcutAction(id: "scrapeLastWeek", title: "Scrape Last Week", section: "Scrape", defaultCombos: ["cmd+2"], safeForExternalURL: false),
        ShortcutAction(id: "runAgain", title: "Run Again", section: "Scrape", defaultCombos: ["cmd+r"], safeForExternalURL: false),
        ShortcutAction(id: "newWindow", title: "New Window", section: "Window", defaultCombos: ["cmd+shift+n"], safeForExternalURL: true),
        ShortcutAction(id: "openSettings", title: "Open Settings", section: "Settings", defaultCombos: ["cmd+,"], safeForExternalURL: true),
        ShortcutAction(id: "toggleSettings", title: "Toggle Settings", section: "Settings", defaultCombos: ["cmd+opt+,"], safeForExternalURL: true),
        ShortcutAction(id: "zoomIn", title: "Zoom In", section: "View", defaultCombos: ["cmd+="], safeForExternalURL: true),
        ShortcutAction(id: "zoomOut", title: "Zoom Out", section: "View", defaultCombos: ["cmd+-"], safeForExternalURL: true),
        ShortcutAction(id: "zoomReset", title: "Actual Size", section: "View", defaultCombos: ["cmd+0"], safeForExternalURL: true),
        ShortcutAction(id: "settingsSectionGeneral", title: "Settings › General", section: "Settings Sections", defaultCombos: ["ctrl+g"], safeForExternalURL: true),
        ShortcutAction(id: "settingsSectionAppearance", title: "Settings › Appearance", section: "Settings Sections", defaultCombos: ["ctrl+a"], safeForExternalURL: true),
        ShortcutAction(id: "settingsSectionPlaylists", title: "Settings › Playlist Order", section: "Settings Sections", defaultCombos: ["ctrl+p"], safeForExternalURL: true),
        ShortcutAction(id: "settingsSectionShortcuts", title: "Settings › Shortcuts", section: "Settings Sections", defaultCombos: ["ctrl+h"], safeForExternalURL: true),
        ShortcutAction(id: "settingsSectionURLs", title: "Settings › URL Commands", section: "Settings Sections", defaultCombos: ["ctrl+u"], safeForExternalURL: true),
    ]

    private init() {}

    func action(for id: String) -> ShortcutAction? {
        actions.first { $0.id == id }
    }

    func combos(for actionId: String) -> [String] {
        if let custom = SharedStore.shared.shortcuts[actionId] {
            return custom
        }
        return action(for: actionId)?.defaultCombos ?? []
    }

    func setCombos(_ rawCombos: [String], for actionId: String) {
        let normalized = Array(NSOrderedSet(array: rawCombos.compactMap(normalizeCombo)).compactMap { $0 as? String })
        guard let act = action(for: actionId) else { return }
        if normalized == act.defaultCombos {
            SharedStore.shared.removeCustomShortcuts(for: actionId)
        } else {
            SharedStore.shared.setCombos(normalized, for: actionId)
        }
    }

    func resetCombos(for actionId: String) {
        SharedStore.shared.removeCustomShortcuts(for: actionId)
    }

    func isCustomized(_ actionId: String) -> Bool {
        guard let act = action(for: actionId) else { return false }
        return combos(for: actionId) != act.defaultCombos
    }

    func normalizeCombo(_ raw: String) -> String? {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = parts.last else { return nil }
        let modSet = Set(parts.dropLast())
        var orderedMods: [String] = []
        if modSet.contains("ctrl") || modSet.contains("control") { orderedMods.append("ctrl") }
        if modSet.contains("opt") || modSet.contains("alt") || modSet.contains("option") { orderedMods.append("opt") }
        if modSet.contains("shift") { orderedMods.append("shift") }
        if modSet.contains("cmd") || modSet.contains("command") || modSet.contains("meta") { orderedMods.append("cmd") }
        let canonKey = canonicalKeyName(key)
        if canonKey.isEmpty { return nil }
        return (orderedMods + [canonKey]).joined(separator: "+")
    }

    private func canonicalKeyName(_ raw: String) -> String {
        switch raw {
        case "plus": return "="
        case "minus": return "-"
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "semicolon": return ";"
        case "quote": return "'"
        case "bracketleft": return "["
        case "bracketright": return "]"
        case "backslash": return "\\"
        case "backquote": return "`"
        case "escape", "esc": return "esc"
        case "return", "enter": return "enter"
        case "space", " ": return "space"
        default: return raw
        }
    }

    /// Derive canonical combo string from an NSEvent using physical keyCode first so Option chords match cleanly.
    func comboString(from event: NSEvent) -> String? {
        guard let key = keyName(forKeyCode: event.keyCode) ?? fallbackKeyName(from: event) else {
            return nil
        }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var mods: [String] = []
        if flags.contains(.control) { mods.append("ctrl") }
        if flags.contains(.option) { mods.append("opt") }
        if flags.contains(.shift) { mods.append("shift") }
        if flags.contains(.command) { mods.append("cmd") }
        return (mods + [key]).joined(separator: "+")
    }

    func matchingAction(for event: NSEvent) -> ShortcutAction? {
        guard !isRecording, let pressed = comboString(from: event) else { return nil }
        // Accept Shift+= as cmd+= zoomIn convenience if user pressed cmd+shift+= (standard +)
        let altPressed: String? = (pressed == "cmd+shift+=") ? "cmd+=" : nil
        for act in actions {
            let list = combos(for: act.id)
            if list.contains(pressed) || (altPressed != nil && list.contains(altPressed!)) {
                return act
            }
        }
        return nil
    }

    func displayString(for combo: String) -> String {
        let parts = combo.split(separator: "+").map(String.init)
        guard let key = parts.last else { return combo }
        let mods = Set(parts.dropLast())
        var out = ""
        if mods.contains("ctrl") { out += "⌃" }
        if mods.contains("opt") { out += "⌥" }
        if mods.contains("shift") { out += "⇧" }
        if mods.contains("cmd") { out += "⌘" }
        out += displayKey(key)
        return out
    }

    func primaryDisplay(for actionId: String) -> String? {
        guard let first = combos(for: actionId).first else { return nil }
        return displayString(for: first)
    }

    /// Returns a menu-compatible keyEquivalent + modifier mask (first combo that has a modifier).
    func menuEquivalent(for actionId: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        for combo in combos(for: actionId) {
            let parts = combo.split(separator: "+").map(String.init)
            guard let key = parts.last else { continue }
            let mods = Set(parts.dropLast())
            guard !mods.isEmpty else { continue }
            var flags: NSEvent.ModifierFlags = []
            if mods.contains("ctrl") { flags.insert(.control) }
            if mods.contains("opt") { flags.insert(.option) }
            if mods.contains("shift") { flags.insert(.shift) }
            if mods.contains("cmd") { flags.insert(.command) }
            if let menuKey = menuKeyCharacter(key) {
                return (menuKey, flags)
            }
        }
        return nil
    }

    func exportPayload() -> [[String: Any]] {
        actions.map { act in
            let current = combos(for: act.id)
            return [
                "id": act.id,
                "title": act.title,
                "section": act.section,
                "combos": current,
                "displays": current.map { displayString(for: $0) },
                "defaults": act.defaultCombos,
                "isCustomized": current != act.defaultCombos,
            ]
        }
    }

    private func displayKey(_ k: String) -> String {
        switch k {
        case "enter": return "↩"
        case "esc": return "⎋"
        case "tab": return "⇥"
        case "space": return "Space"
        case "backspace": return "⌫"
        case "delete": return "⌦"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        default: return k.uppercased()
        }
    }

    private func menuKeyCharacter(_ k: String) -> String? {
        switch k {
        case "enter": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "esc": return "\u{1b}"
        case "backspace": return "\u{08}"
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: return k.count == 1 ? k : nil
        }
    }

    private func fallbackKeyName(from event: NSEvent) -> String? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        return canonicalKeyName(chars)
    }

    private func keyName(forKeyCode code: UInt16) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
            kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
            kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
            kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
            kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
            kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
            kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
            kVK_Return: "enter", kVK_Tab: "tab", kVK_Space: "space",
            kVK_Delete: "backspace", kVK_Escape: "esc", kVK_ForwardDelete: "delete",
            kVK_LeftArrow: "left", kVK_RightArrow: "right",
            kVK_DownArrow: "down", kVK_UpArrow: "up",
            kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4",
            kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7", kVK_F8: "f8",
            kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
        ]
        return map[Int(code)]
    }
}
