import Foundation

struct URLRouteDef {
    let route: String
    let summary: String
    let example: String
    let params: String
}

/// Single source of truth for all `nmr://` URL commands.
/// Read by the AppDelegate URL router, Settings ▸ URL Commands card, and verification checks.
enum URLRoutes {
    static let scheme = "nmr"

    static let all: [URLRouteDef] = [
        URLRouteDef(
            route: "log",
            summary: "Open or toggle the in-app Scrape & Missed Log view",
            example: "nmr://log?tab=missed",
            params: "tab=all|missed|scraped, mode=open|toggle"
        ),
        URLRouteDef(
            route: "hud",
            summary: "Switch the active window back to the live HUD / results view",
            example: "nmr://hud",
            params: "none"
        ),
        URLRouteDef(
            route: "settings",
            summary: "Open, focus a section, or close the Settings window",
            example: "nmr://settings?section=playlists",
            params: "section=general|appearance|playlists|shortcuts|urls, close=1, background=1"
        ),
        URLRouteDef(
            route: "appearance",
            summary: "Switch or toggle Dark / Light Appearance across all windows",
            example: "nmr://appearance?mode=toggle",
            params: "mode=dark|light|toggle"
        ),
        URLRouteDef(
            route: "theme",
            summary: "Select an installed NAGA theme by name or slug",
            example: "nmr://theme?name=Alucard",
            params: "name=<theme name or id>"
        ),
        URLRouteDef(
            route: "preset",
            summary: "Activate a Playlist Order preset by name or id",
            example: "nmr://preset?name=Default",
            params: "name=<preset name or id>"
        ),
        URLRouteDef(
            route: "worktree-menu",
            summary: "Show or hide the git worktree status item in the menu bar",
            example: "nmr://worktree-menu?show=1",
            params: "show=1|0"
        ),
        URLRouteDef(
            route: "shortcuts",
            summary: "Set or reset customizable keyboard shortcut bindings",
            example: "nmr://shortcuts?action=openLog&combos=cmd+l",
            params: "action=<id>&combos=<c1,c2>, reset=<id>"
        ),
        URLRouteDef(
            route: "action",
            summary: "Invoke a safe UI shortcut action by its registry id",
            example: "nmr://action?id=openLog",
            params: "id=<actionId>"
        ),
        URLRouteDef(
            route: "switch",
            summary: "Switch the running app to another git checkout via the worktree menu",
            example: "nmr://switch?to=/Users/adriangrant/Development/New%20Music%20Research",
            params: "to=<checkoutPath>"
        ),
        URLRouteDef(
            route: "newwindow",
            summary: "Open a new main window (optionally in the background)",
            example: "nmr://newwindow?background=1",
            params: "background=1"
        ),
        URLRouteDef(
            route: "closewindow",
            summary: "Close the key main window without quitting the app",
            example: "nmr://closewindow",
            params: "none"
        ),
        URLRouteDef(
            route: "state",
            summary: "Write a JSON diagnostics snapshot of windows and preferences to disk",
            example: "nmr://state?out=/tmp/nmr-state.json",
            params: "out=<path>"
        ),
        URLRouteDef(
            route: "snapshot",
            summary: "Render a window cleanly to a PNG file without stealing focus",
            example: "nmr://snapshot?window=main&path=/tmp/nmr.png",
            params: "window=main|settings|help, path=<png>"
        ),
    ]

    static func exportPayload() -> [[String: String]] {
        all.map {
            [
                "route": $0.route,
                "summary": $0.summary,
                "example": $0.example,
                "params": $0.params,
            ]
        }
    }

    static func matches(example: String) -> Bool {
        guard let url = URL(string: example),
              url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased() else { return false }
        return all.contains { $0.route == host }
    }
}
