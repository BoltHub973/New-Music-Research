import AppKit
import WebKit

private final class MainWindowEntry: NSObject, NSWindowDelegate {
    let window: NSWindow
    let webVC: WebViewController
    var onCloseEntry: ((MainWindowEntry) -> Void)?

    init(window: NSWindow, webVC: WebViewController) {
        self.window = window
        self.webVC = webVC
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOcclusionChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleOcclusionChange() {
        let visible = window.occlusionState.contains(.visible)
        webVC.setOccluded(!visible)
    }

    func windowWillClose(_ notification: Notification) {
        onCloseEntry?(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindows: [MainWindowEntry] = []
    private let pipeline = Pipeline()
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private weak var helpWebView: WKWebView?
    private var keyMonitor: Any?
    private var worktreeController: WorktreeMenuController?
    private lazy var settingsController: SettingsWindowController = {
        let ctrl = SettingsWindowController(
            projectDirProvider: { [weak self] in self?.pipeline.projectDir ?? (NSHomeDirectory() + "/Development/New Music Research") },
            worktreeShownProvider: { [weak self] in self?.worktreeController?.isShown ?? true }
        )
        ctrl.onSetWorktreeMenu = { [weak self] show in
            self?.worktreeController?.setShown(show)
        }
        ctrl.onZoomAction = { [weak self] action in
            switch action {
            case "in": self?.zoomIn()
            case "out": self?.zoomOut()
            default: self?.zoomActual()
            }
        }
        ctrl.onRunURL = { [weak self] urlString in
            if let url = URL(string: urlString) {
                self?.handleURL(url)
            }
        }
        ctrl.onRunScrape = { [weak self] mode, presetId in
            self?.runScrapeWithPreset(mode: mode, presetId: presetId)
        }
        return ctrl
    }()

    // Dynamic menu items refreshed when SharedStore / shortcuts / zoom change
    private var settingsMenuItem: NSMenuItem?
    private var newWindowMenuItem: NSMenuItem?
    private var runAgainMenuItem: NSMenuItem?
    private var toggleLogMenuItem: NSMenuItem?
    private var toggleAppearanceMenuItem: NSMenuItem?
    private var themesMenu: NSMenu?
    private var zoomStatusMenuItem: NSMenuItem?
    private var zoomInMenuItem: NSMenuItem?
    private var zoomOutMenuItem: NSMenuItem?
    private var zoomResetMenuItem: NSMenuItem?
    private var scrapeThisWeekMenuItem: NSMenuItem?
    private var scrapeLastWeekMenuItem: NSMenuItem?
    private var scrapePlaylistOrderMenuItem: NSMenuItem?

    private var isLaunchComplete = false
    private var pendingURLs: [URL] = []
    private var lastProgressPayload: String?

    private var currentBackgroundColor: NSColor {
        ThemeManager.shared.activePalette().bgColor
    }

    private var activeEntry: MainWindowEntry? {
        if let key = NSApp.keyWindow,
           let match = mainWindows.first(where: { $0.window === key }) {
            return match
        }
        if let main = NSApp.mainWindow,
           let match = mainWindows.first(where: { $0.window === main }) {
            return match
        }
        return mainWindows.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = ThemeManager.shared

        setupWorktreeMenu()
        buildMenu()

        let bgLaunch = ProcessInfo.processInfo.environment["NMR_BACKGROUND_LAUNCH"] == "1"
        let skipAutoRun = ProcessInfo.processInfo.environment["NMR_SKIP_AUTO_RUN"] == "1"

        let primary = createMainWindow(background: bgLaunch)
        primary.webVC.onReady = { [weak self] in
            self?.drainPendingURLsIfReady()
        }

        pipeline.onUpdate = { [weak self] json in
            guard let self = self else { return }
            self.lastProgressPayload = json
            var windowTitle: String?
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mode = obj["mode"] as? String {
                windowTitle = (mode == ScrapeMode.lastWeek.rawValue) ? "Last Week" : "This Week"
            }
            for entry in self.mainWindows {
                entry.webVC.setPayload(json)
                if let t = windowTitle {
                    entry.window.title = t
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSharedStoreChanged),
            name: SharedStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemesChanged),
            name: ThemeManager.themesChangedNotification,
            object: nil
        )

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleLocalKeyDown(event) ?? event
        }

        isLaunchComplete = true
        updateMenusFromRegistry()

        if !skipAutoRun && pendingURLs.isEmpty {
            decideLaunchRun(in: primary)
        } else if !bgLaunch {
            primary.webVC.focusWebView()
        }

        if !bgLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || mainWindows.isEmpty {
            let entry = createMainWindow(background: false)
            if let last = lastProgressPayload {
                entry.webVC.setPayload(last)
            }
        } else {
            activeEntry?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard (url.scheme ?? "").lowercased() == URLRoutes.scheme else { continue }
            if !isLaunchComplete || (mainWindows.first?.webVC.isReady == false && url.host?.lowercased() != "snapshot") {
                pendingURLs.append(url)
            } else {
                handleURL(url)
            }
        }
        drainPendingURLsIfReady()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline.stop()
    }

    // MARK: - Multi-window Management

    @discardableResult
    private func createMainWindow(background: Bool) -> MainWindowEntry {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "This Week"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.appearance = NSAppearance(named: SharedStore.shared.appearance == .light ? .aqua : .darkAqua)
        win.backgroundColor = currentBackgroundColor
        win.minSize = NSSize(width: 760, height: 540)
        win.collectionBehavior = [.managed]
        win.isReleasedWhenClosed = false

        let webVC = WebViewController()
        webVC.projectDirProvider = { [weak self] in self?.pipeline.projectDir ?? (NSHomeDirectory() + "/Development/New Music Research") }
        webVC.onOpenSettings = { [weak self] in self?.openSettings() }
        webVC.onToggleAppearance = { ThemeManager.shared.toggleAppearance() }
        win.contentView = webVC.view

        let entry = MainWindowEntry(window: win, webVC: webVC)
        webVC.onClose = { [weak win] in win?.performClose(nil) }
        entry.onCloseEntry = { [weak self] closed in
            self?.mainWindows.removeAll { $0 === closed }
        }
        mainWindows.append(entry)

        win.maximizeToVisibleFrame()
        if background {
            win.orderBack(nil)
        } else {
            win.makeKeyAndOrderFront(nil)
            webVC.focusWebView()
        }

        webVC.loadProgressUI()
        if let last = lastProgressPayload {
            webVC.setPayload(last)
        }
        return entry
    }

    @objc private func newWindowAction() {
        let entry = createMainWindow(background: false)
        NSApp.activate(ignoringOtherApps: true)
        entry.webVC.focusWebView()
    }

    @objc private func maximizeActiveWindow() {
        let target = NSApp.keyWindow ?? activeEntry?.window
        target?.maximizeToVisibleFrame()
    }

    // MARK: - Keyboard Dispatch

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if ShortcutRegistry.shared.isRecording {
            return event
        }
        guard let act = ShortcutRegistry.shared.matchingAction(for: event) else {
            return event
        }

        let isPlainKey = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if isPlainKey {
            // Allow normal typing when focus isn't blocked on modifiers.
            return event
        }

        let inSettings = NSApp.keyWindow === settingsController.window
        if act.id.hasPrefix("settingsSection") {
            guard inSettings else { return event }
        }

        performShortcutAction(act.id)
        return nil
    }

    private func performShortcutAction(_ actionId: String) {
        switch actionId {
        case "openLog":
            toggleLogAction()
        case "toggleAppearance":
            toggleAppearanceAction()
        case "scrapeThisWeek":
            scrapeThisWeek()
        case "scrapeLastWeek":
            scrapeLastWeek()
        case "runAgain":
            runAgain()
        case "newWindow":
            newWindowAction()
        case "openSettings":
            openSettings()
        case "toggleSettings":
            toggleSettings()
        case "zoomIn":
            zoomIn()
        case "zoomOut":
            zoomOut()
        case "zoomReset":
            zoomActual()
        case "settingsSectionGeneral":
            settingsController.selectSection("general")
        case "settingsSectionAppearance":
            settingsController.selectSection("appearance")
        case "settingsSectionPlaylists":
            settingsController.selectSection("playlists")
        case "settingsSectionShortcuts":
            settingsController.selectSection("shortcuts")
        case "settingsSectionURLs":
            settingsController.selectSection("urls")
        default:
            break
        }
    }

    // MARK: - Actions

    private func run(mode: ScrapeMode, timestamped: Bool = false, in targetEntry: MainWindowEntry? = nil) {
        let entry = targetEntry ?? activeEntry ?? createMainWindow(background: false)
        entry.window.title = (mode == .lastWeek) ? "Last Week" : "This Week"
        entry.window.makeKeyAndOrderFront(nil)
        entry.webVC.openHUD()
        entry.webVC.loadProgressUI()
        pipeline.start(mode: mode, timestamped: timestamped)
    }

    private func runScrapeWithPreset(mode: ScrapeMode, presetId: String) {
        PlaylistOrderStore.shared.selectPreset(id: presetId, projectDir: pipeline.projectDir)
        let entry = activeEntry ?? createMainWindow(background: false)
        settingsController.closeWindow()
        checkExistingAndRun(in: entry, mode: mode, askLastWeekOnCancel: false)
    }

    @objc private func runAgain() {
        let entry = activeEntry ?? createMainWindow(background: false)
        checkExistingAndRun(in: entry, mode: pipeline.lastMode, askLastWeekOnCancel: false)
    }

    @objc private func scrapeThisWeek() {
        let entry = activeEntry ?? createMainWindow(background: false)
        checkExistingAndRun(in: entry, mode: .thisWeek, askLastWeekOnCancel: false)
    }

    @objc private func scrapeLastWeek() {
        let entry = activeEntry ?? createMainWindow(background: false)
        checkExistingAndRun(in: entry, mode: .lastWeek, askLastWeekOnCancel: false)
    }
    @objc private func openSettings()           { settingsController.show(anchor: activeEntry?.window, section: nil, background: false) }
    @objc private func toggleSettings()         { settingsController.toggle(anchor: activeEntry?.window) }
    @objc private func toggleAppearanceAction() { ThemeManager.shared.toggleAppearance() }
    @objc private func manageThemesAction()     { settingsController.show(anchor: activeEntry?.window, section: "appearance", background: false) }
    @objc private func openPlaylistOrderAction(){ settingsController.show(anchor: activeEntry?.window, section: "playlists", background: false) }

    @objc private func selectThemeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ThemeManager.shared.selectTheme(id: id)
    }

    @objc private func openThemesFolderFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogAction() {
        let entry = activeEntry ?? createMainWindow(background: false)
        entry.webVC.pushHistory()
        entry.webVC.toggleLog(tab: nil)
    }

    @objc private func zoomIn() {
        let next = min(SharedStore.shared.pageZoom + 0.1, 3.0)
        SharedStore.shared.setPageZoom(next)
    }

    @objc private func zoomOut() {
        let next = max(SharedStore.shared.pageZoom - 0.1, 0.5)
        SharedStore.shared.setPageZoom(next)
    }

    @objc private func zoomActual() {
        SharedStore.shared.setPageZoom(1.0)
    }

    // MARK: - Launch Flow (NAGA Confirmation Modal)

    private static let checkingFrame = #"{"busy":true,"busyLabel":"CHECKING SPOTIFY","busyDetail":"Looking for an existing playlist created today…"}"#
    private static let deletingFrame = #"{"busy":true,"busyLabel":"OVERWRITING PLAYLIST","busyDetail":"Removing the existing Spotify playlist before re-scraping…"}"#
    private static let idleFrame = #"{"busy":false}"#

    private func decideLaunchRun(in entry: MainWindowEntry) {
        checkExistingAndRun(in: entry, mode: .thisWeek, askLastWeekOnCancel: true)
    }

    private func checkExistingAndRun(in entry: MainWindowEntry, mode: ScrapeMode, askLastWeekOnCancel: Bool) {
        if ProcessInfo.processInfo.environment["NMR_BACKGROUND_LAUNCH"] != "1" {
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        entry.webVC.openHUD()
        entry.webVC.setPayload(Self.checkingFrame)

        pipeline.runHelper(["check", "--mode", mode.rawValue]) { [weak self, weak entry] output in
            guard let self = self, let entry = entry else { return }
            let verdict = output.split(separator: "\n").map(String.init)
                .first { $0.hasPrefix("EXISTS:") || $0 == "NONE" || $0.hasPrefix("CHECK_ERROR:") }
                ?? ""
            guard verdict.hasPrefix("EXISTS:") else {
                if verdict != "NONE" {
                    NSLog("New Music Research: launch check fell through — %@",
                          verdict.isEmpty ? "no verdict (helper failed?)" : verdict)
                }
                self.run(mode: mode, timestamped: false, in: entry)
                return
            }
            let ids = verdict.dropFirst("EXISTS:".count).split(separator: ",").map(String.init)
            let baseTitle = Self.playlistTitlePreview(mode: mode, timestamped: false)
            let stampedTitle = Self.playlistTitlePreview(mode: mode, timestamped: true)
            let modeLabel = (mode == .lastWeek) ? "Last Week" : "This Week"
            let presetPayload = PlaylistOrderStore.shared.exportPayload(projectDir: self.pipeline.projectDir)
            let activePresetId = (presetPayload["activePresetId"] as? String) ?? "default"
            let presets = (presetPayload["presets"] as? [[String: Any]]) ?? []
            let activePresetName: String = {
                if activePresetId == "default" { return "Default" }
                return presets.first(where: { ($0["id"] as? String) == activePresetId })?["name"] as? String ?? "Default"
            }()

            entry.webVC.askChoice(
                title: "Existing \(modeLabel) Playlist Found",
                subtitle: "A playlist for today already exists on Spotify. Create a timestamped playlist or overwrite the existing one?",
                tile: "music",
                kind: "accent",
                facts: [
                    ["Existing Playlist", baseTitle],
                    ["New Playlist Name", stampedTitle],
                    ["Playlist Preset", activePresetName],
                    ["Matched IDs", ids.joined(separator: ", ")]
                ],
                buttons: [
                    ["value": "cancel", "label": askLastWeekOnCancel ? "Skip (Esc)" : "Cancel (Esc)", "keys": ["n", "esc"]],
                    ["value": "overwrite", "label": "Overwrite Existing (O)", "danger": true, "keys": ["o"]],
                    ["value": "create", "label": "Create New (\(stampedTitle)) (↩)", "primary": true, "keys": ["c", "y"]]
                ]
            ) { [weak self, weak entry] choice in
                guard let self = self, let entry = entry else { return }
                if choice == "create" {
                    self.run(mode: mode, timestamped: true, in: entry)
                    return
                }
                if choice == "overwrite" {
                    entry.webVC.setPayload(Self.deletingFrame)
                    self.pipeline.runHelper(["delete"] + ids) { _ in
                        self.run(mode: mode, timestamped: false, in: entry)
                    }
                    return
                }
                if askLastWeekOnCancel {
                    entry.webVC.askConfirm(
                        title: "Run Last Week Instead?",
                        subtitle: "Scrape tracks added to the Tidal playlists last calendar week.",
                        tile: "lastweek",
                        kind: "warn",
                        facts: [
                            ["Window", "Last Calendar Week (Mon → Mon)"],
                            ["Playlist", "🟠 DX LAST WEEK"],
                            ["If No", "Restores your previous run's results without scraping."]
                        ],
                        yesLabel: "Yes, Last Week",
                        noLabel: "No"
                    ) { [weak self] yesLastWeek in
                        guard let self = self else { return }
                        if yesLastWeek {
                            self.checkExistingAndRun(in: entry, mode: .lastWeek, askLastWeekOnCancel: false)
                        } else {
                            self.showPreviousResults()
                        }
                    }
                } else {
                    entry.webVC.setPayload(Self.idleFrame)
                }
            }
        }
    }

    private static func playlistTitlePreview(mode: ScrapeMode, timestamped: Bool, date: Date = Date()) -> String {
        let dfDate = DateFormatter()
        dfDate.locale = Locale(identifier: "en_US_POSIX")
        dfDate.dateFormat = "MM-dd-yy"
        let prefix = (mode == .lastWeek) ? "🟠 DX LAST WEEK" : "🪁 DX"
        let base = "\(prefix) \(dfDate.string(from: date))"
        guard timestamped else { return base }
        let dfTime = DateFormatter()
        dfTime.locale = Locale(identifier: "en_US_POSIX")
        dfTime.dateFormat = "h:mma"
        return "\(base) at \(dfTime.string(from: date).lowercased())"
    }

    private func showPreviousResults() {
        guard var payload = try? String(contentsOf: Pipeline.progressURL, encoding: .utf8),
              !payload.isEmpty else {
            activeEntry?.webVC.setPayload(Self.idleFrame)
            return
        }
        let uuid = pipeline.previousResultsMacroUUID
        if !uuid.isEmpty {
            pipeline.fireMacro(uuid: uuid)
            payload = Self.appendKMMacro(pipeline.previousResultsMacroName, uuid: uuid, to: payload)
        }
        pipeline.onUpdate?(payload)
    }

    private static func appendKMMacro(_ name: String, uuid: String, to payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return payload }
        var fired = obj["kmMacros"] as? [Any] ?? []
        fired.append(["name": name, "uuid": uuid])
        obj["kmMacros"] = fired
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: out, encoding: .utf8)
        else { return payload }
        return text
    }

    @objc private func toggleInspector() {
        guard let webView = activeEntry?.webVC.webView,
              let inspector = webView.value(forKey: "_inspector") as AnyObject? else { return }
        let isVisible = (inspector.value(forKey: "isVisible") as? Bool) ?? false
        _ = inspector.perform(NSSelectorFromString(isVisible ? "hide:" : "show:"), with: nil)
    }

    // MARK: - Help Window

    @objc private func showFiringRules() {
        openHelpWindow(background: false)
    }

    private func openHelpWindow(background: Bool) {
        if helpWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Keyboard Maestro Firing Rules"
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 760, height: 480)
            win.collectionBehavior = [.managed]

            let config = WKWebViewConfiguration()
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
            let web = WKWebView(frame: .zero, configuration: config)
            web.setValue(false, forKey: "drawsBackground")
            if #available(macOS 13.3, *) { web.isInspectable = true }
            win.contentView = web
            helpWebView = web
            helpWindow = win
        }
        applyAppearanceToHelpWindow()
        helpWebView?.pageZoom = CGFloat(SharedStore.shared.pageZoom)
        helpWindow?.placeOver(activeEntry?.window, defaultRatio: 0.75, minSize: NSSize(width: 900, height: 620))
        if background {
            helpWindow?.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            helpWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func applyAppearanceToHelpWindow() {
        guard let win = helpWindow else { return }
        let isLight = ThemeManager.shared.currentSide == .light
        win.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        win.backgroundColor = currentBackgroundColor
        helpWebView?.loadHTMLString(firingRulesHTML(light: isLight), baseURL: nil)
    }

    private func firingRulesHTML(light: Bool) -> String {
        let resultName = pipeline.resultMacroName
        let resultUUID = pipeline.resultMacroUUID
        let prevName = pipeline.previousResultsMacroName
        let prevUUID = pipeline.previousResultsMacroUUID
        let noneNote = "⌨ No Keyboard Maestro macros were fired — no playlist was created"
        let palette = ThemeManager.shared.activePalette()
        let bg = palette.bgHex
        let fg = palette.textHex
        let muted = palette.mutedHex
        let accent = palette.accentHex
        let violet = palette.accentHex
        let line = light ? "rgba(15,23,42,.12)" : "rgba(255,255,255,.12)"
        return #"""
        <!doctype html><html><head><meta charset="utf-8"><style>
          body{margin:0;padding:38px 44px;background:\#(bg);color:\#(fg);
               font:17px/1.6 -apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased;}
          h1{font-size:25px;letter-spacing:.14em;text-transform:uppercase;color:\#(accent);margin:0 0 24px;}
          table{border-collapse:collapse;width:100%;}
          th{font-size:14px;letter-spacing:.14em;text-transform:uppercase;color:\#(muted);text-align:left;
             padding:10px 16px;border-bottom:1px solid \#(line);}
          td{padding:15px 16px;border-bottom:1px solid \#(line);vertical-align:top;overflow-wrap:anywhere;}
          td.outcome{font-weight:600;min-width:200px;}
          td.outcome .why{display:block;font-weight:400;color:\#(muted);font-size:15px;margin-top:3px;}
          td.macro{color:\#(violet);}
          td.uuid{font-family:ui-monospace,Menlo,monospace;font-size:14px;color:\#(muted);
                  max-width:220px;word-break:break-all;}
          td.card{font-family:ui-monospace,Menlo,monospace;font-size:15px;color:\#(accent);}
          td.card.none{color:\#(muted);font-style:italic;}
          .dash{color:\#(muted);}
        </style></head><body>
        <h1>Keyboard Maestro Firing Rules</h1>
        <table>
          <tr><th>Outcome</th><th>Macro fired</th><th>Macro UUID</th><th>Completion card shows</th></tr>
          <tr>
            <td class="outcome">Run creates a playlist</td>
            <td class="macro">\#(resultName)</td>
            <td class="uuid">\#(resultUUID)</td>
            <td class="card">⌨ Keyboard Maestro ▸ \#(resultName)</td>
          </tr>
          <tr>
            <td class="outcome">Export to Spotify fails
              <span class="why">Scrape succeeded, but no playlist was created</span></td>
            <td class="macro"><span class="dash">— nothing —</span></td>
            <td class="uuid"><span class="dash">—</span></td>
            <td class="card none">\#(noneNote)</td>
          </tr>
          <tr>
            <td class="outcome">Scrape finds zero new tracks
              <span class="why">Nothing was added to the Tidal playlists in the scraped window,
              so the export never runs and no playlist is created</span></td>
            <td class="macro"><span class="dash">— nothing —</span></td>
            <td class="uuid"><span class="dash">—</span></td>
            <td class="card none">\#(noneNote)</td>
          </tr>
          <tr>
            <td class="outcome">Run aborts early
              <span class="why">Tidal login required, or playlists.json missing</span></td>
            <td class="macro"><span class="dash">— nothing —</span></td>
            <td class="uuid"><span class="dash">—</span></td>
            <td class="card none">⌨ No Keyboard Maestro macros were fired — the run aborted</td>
          </tr>
          <tr>
            <td class="outcome">No scrape — previous results shown
              <span class="why">Both launch prompts declined (N, then N)</span></td>
            <td class="macro">\#(prevName)</td>
            <td class="uuid">\#(prevUUID)</td>
            <td class="card">⌨ Keyboard Maestro ▸ \#(prevName)</td>
          </tr>
        </table>
        </body></html>
        """#
    }

    // MARK: - About

    @objc private func showAbout() {
        aboutWindow?.close()
        let info = Bundle.main.infoDictionary ?? [:]
        let semver = info["CFBundleShortVersionString"] as? String ?? "—"
        let display = (info["NewMusicResearchVersionDisplay"] as? String)
            ?? (info["CFBundleVersion"] as? String ?? "")

        let isLight = ThemeManager.shared.currentSide == .light
        let palette = ThemeManager.shared.activePalette()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About New Music Research"
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        win.backgroundColor = palette.bgColor
        win.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 168).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let titleColor = palette.accentColor
        let primaryText = palette.textColor

        let name = label("New Music Research", size: 30, weight: .bold, color: titleColor)
        let version = label("Version \(semver)", size: 15, weight: .semibold, color: primaryText)
        let build = buildLine(display, commitURL: info["NewMusicResearchVersionCommitURL"] as? String, accent: titleColor)
        let tag = label("Tidal → Spotify pipeline", size: 12.5, weight: .regular, color: palette.mutedColor)

        let stack = NSStackView(views: [icon, name, tag, version, build])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(22, after: icon)
        stack.setCustomSpacing(20, after: tag)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        win.contentView = content
        win.center()
        win.makeKeyAndOrderFront(nil)
        aboutWindow = win
    }

    private func buildLine(_ display: String, commitURL: String?, accent: NSColor) -> NSTextField {
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let attr = NSMutableAttributedString(
            string: display,
            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        if let s = commitURL, let url = URL(string: s),
           let sep = display.range(of: " · ", options: .backwards) {
            let shaRange = NSRange(sep.upperBound..<display.endIndex, in: display)
            attr.addAttributes([
                .link: url,
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: shaRange)
        }
        let f = NSTextField(labelWithAttributedString: attr)
        f.alignment = .center
        f.isSelectable = true
        f.allowsEditingTextAttributes = true
        return f
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        return f
    }

    // MARK: - Worktree Menu Setup

    private func setupWorktreeMenu() {
        let info = Bundle.main.infoDictionary ?? [:]
        let root = (info["NMRProjectRoot"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pipeline.projectDir
        var cfg = WorktreeMenuController.Config(
            watchedPaths: [
                "app/Sources",
                "app/Resources",
                "keyboard-maestro/progress_window.html",
                "keyboard-maestro/km_progress.py",
                "track_playlists.py",
                "export_to_spotify.py",
                "launch_check.py",
            ],
            nativeSourceDir: "app/Sources",
            storeFolder: "New Music Research"
        )
        cfg.buildCommand = "cd app && ./build.sh --relaunch"
        cfg.switchCommand = ["app/build.sh", "--relaunch"]
        let wt = WorktreeMenuController(projectRoot: root, config: cfg)
        wt.onVisibilityChange = { [weak self] _ in
            self?.settingsController.hydrate()
        }
        worktreeController = wt
    }

    // MARK: - Menu Bar

    private func buildMenu() {
        let menubar = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        addItem(appMenu, "About New Music Research", #selector(showAbout))
        appMenu.addItem(.separator())
        settingsMenuItem = addItem(appMenu, "Settings…", #selector(openSettings), key: ",")
        appMenu.addItem(.separator())
        runAgainMenuItem = addItem(appMenu, "Run Again", #selector(runAgain), key: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide New Music Research", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit New Music Research", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem()
        menubar.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let nw = addItem(fileMenu, "New Window", #selector(newWindowAction), key: "n")
        nw.keyEquivalentModifierMask = [.command, .shift]
        newWindowMenuItem = nw
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Edit menu
        let editItem = NSMenuItem()
        menubar.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // View menu
        let viewItem = NSMenuItem()
        menubar.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        toggleLogMenuItem = addItem(viewMenu, "Toggle Scrape & Missed Log", #selector(toggleLogAction), key: "l")
        viewMenu.addItem(.separator())

        let zStatus = NSMenuItem(title: "Zoom: 100%", action: nil, keyEquivalent: "")
        zStatus.isEnabled = false
        viewMenu.addItem(zStatus)
        zoomStatusMenuItem = zStatus

        zoomInMenuItem = addItem(viewMenu, "Zoom In", #selector(zoomIn), key: "=")
        zoomOutMenuItem = addItem(viewMenu, "Zoom Out", #selector(zoomOut), key: "-")
        zoomResetMenuItem = addItem(viewMenu, "Actual Size", #selector(zoomActual), key: "0")
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Maximize", #selector(maximizeActiveWindow))
        if let wt = worktreeController {
            viewMenu.addItem(wt.toggleMenuItem)
        }
        viewMenu.addItem(.separator())
        let inspect = addItem(viewMenu, "Inspect Element", #selector(toggleInspector), key: "i")
        inspect.keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = viewMenu

        // Themes menu (built via shared ThemesMenu.build master)
        let themesItem = NSMenuItem()
        menubar.addItem(themesItem)
        let themesSubmenu = NSMenu(title: "Themes")
        themesItem.submenu = themesSubmenu
        themesMenu = themesSubmenu
        rebuildThemesMenu()

        // Scrape menu
        let scrapeItem = NSMenuItem()
        menubar.addItem(scrapeItem)
        let scrapeMenu = NSMenu(title: "Scrape")
        scrapeThisWeekMenuItem = addItem(scrapeMenu, "This Week", #selector(scrapeThisWeek), key: "1")
        scrapeLastWeekMenuItem = addItem(scrapeMenu, "Last Week", #selector(scrapeLastWeek), key: "2")
        scrapeMenu.addItem(.separator())
        scrapePlaylistOrderMenuItem = addItem(scrapeMenu, "Playlist Order…", #selector(openPlaylistOrderAction))
        scrapeItem.submenu = scrapeMenu

        // Window menu
        let windowItem = NSMenuItem()
        menubar.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpItem = NSMenuItem()
        menubar.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        addItem(helpMenu, "Keyboard Maestro Firing Rules", #selector(showFiringRules))
        helpItem.submenu = helpMenu
        NSApp.helpMenu = NSMenu(title: "Help")

        // Worktree menu ALWAYS last in menu bar
        if let wt = worktreeController {
            menubar.addItem(wt.menuItem)
        }

        NSApp.mainMenu = menubar
    }

    @objc private func handleSharedStoreChanged() {
        applyThemesAndStoreChanges()
    }

    @objc private func handleThemesChanged() {
        applyThemesAndStoreChanges()
    }

    private func applyThemesAndStoreChanges() {
        rebuildThemesMenu()
        updateMenusFromRegistry()
        let isLight = ThemeManager.shared.currentSide == .light
        for entry in mainWindows {
            entry.window.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
            entry.window.backgroundColor = currentBackgroundColor
            entry.webVC.applyAppearance()
            entry.webVC.applyStoredZoom()
        }
        applyAppearanceToHelpWindow()
        helpWebView?.pageZoom = CGFloat(SharedStore.shared.pageZoom)
    }

    private func rebuildThemesMenu() {
        guard let themesMenu else { return }
        let eq = ShortcutRegistry.shared.menuEquivalent(for: "toggleAppearance")
        let spec = ThemeManager.shared.themesMenuSpec(
            target: self,
            selectTheme: #selector(selectThemeFromMenu(_:)),
            switchAppearance: #selector(toggleAppearanceAction),
            openFolder: #selector(openThemesFolderFromMenu(_:)),
            manageThemes: #selector(manageThemesAction),
            switchKey: eq?.key ?? "l",
            switchModifiers: eq?.modifiers ?? [.command, .shift]
        )
        toggleAppearanceMenuItem = ThemesMenu.build(themesMenu, spec)
    }

    private func updateMenusFromRegistry() {
        let zoomPct = Int(round(SharedStore.shared.pageZoom * 100))
        zoomStatusMenuItem?.title = "Zoom: \(zoomPct)%"
        let toLight = ThemeManager.shared.currentSide == .dark
        toggleAppearanceMenuItem?.title = "Switch to \(toLight ? "Light" : "Dark") Appearance"

        let map: [(NSMenuItem?, String)] = [
            (settingsMenuItem, "openSettings"),
            (newWindowMenuItem, "newWindow"),
            (runAgainMenuItem, "runAgain"),
            (toggleLogMenuItem, "openLog"),
            (toggleAppearanceMenuItem, "toggleAppearance"),
            (zoomInMenuItem, "zoomIn"),
            (zoomOutMenuItem, "zoomOut"),
            (zoomResetMenuItem, "zoomReset"),
            (scrapeThisWeekMenuItem, "scrapeThisWeek"),
            (scrapeLastWeekMenuItem, "scrapeLastWeek"),
            (scrapePlaylistOrderMenuItem, "settingsSectionPlaylists"),
        ]
        for (item, actionId) in map {
            guard let item = item else { continue }
            if let eq = ShortcutRegistry.shared.menuEquivalent(for: actionId) {
                item.keyEquivalent = eq.key
                item.keyEquivalentModifierMask = eq.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - URL Scheme Router (nmr://)

    private func drainPendingURLsIfReady() {
        guard isLaunchComplete else { return }
        if pendingURLs.isEmpty { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let route = (comps.host ?? comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            q[item.name.lowercased()] = item.value ?? ""
        }

        switch route {
        case "log":
            let entry = activeEntry ?? createMainWindow(background: false)
            entry.webVC.pushHistory()
            let tab = q["tab"]
            if q["mode"] == "open" {
                entry.webVC.openLog(tab: tab)
            } else {
                entry.webVC.toggleLog(tab: tab)
            }

        case "hud":
            activeEntry?.webVC.openHUD()

        case "settings":
            if q["close"] == "1" {
                settingsController.closeWindow()
            } else {
                let bg = q["background"] == "1"
                settingsController.show(anchor: activeEntry?.window, section: q["section"], background: bg)
            }

        case "appearance":
            let mode = q["mode"] ?? "toggle"
            if mode == "dark" {
                ThemeManager.shared.switchAppearance(to: .dark)
            } else if mode == "light" {
                ThemeManager.shared.switchAppearance(to: .light)
            } else {
                ThemeManager.shared.toggleAppearance()
            }

        case "theme":
            if let qName = q["name"], let theme = ThemeManager.shared.resolve(nameOrID: qName) {
                ThemeManager.shared.selectTheme(id: theme.id)
            }

        case "preset":
            if let qName = q["name"] {
                _ = PlaylistOrderStore.shared.selectPreset(named: qName, projectDir: pipeline.projectDir)
            }

        case "worktree-menu":
            if q["show"] == "1" {
                worktreeController?.setShown(true)
            } else if q["show"] == "0" {
                worktreeController?.setShown(false)
            }

        case "shortcuts":
            if let resetId = q["reset"] {
                if resetId == "all" {
                    SharedStore.shared.setShortcuts([:])
                } else {
                    ShortcutRegistry.shared.resetCombos(for: resetId)
                }
            } else if let actionId = q["action"], let combosRaw = q["combos"] {
                let list = combosRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                ShortcutRegistry.shared.setCombos(list, for: actionId)
            }

        case "action":
            if let actionId = q["id"],
               let act = ShortcutRegistry.shared.action(for: actionId),
               act.safeForExternalURL {
                performShortcutAction(actionId)
            }

        case "switch":
            if let target = q["to"], !target.isEmpty {
                _ = worktreeController?.switchTo(checkoutAt: target)
            }

        case "newwindow":
            let bg = q["background"] == "1"
            _ = createMainWindow(background: bg)

        case "closewindow":
            if let win = NSApp.keyWindow ?? activeEntry?.window {
                win.close()
            }

        case "state":
            guard let outPath = q["out"], !outPath.isEmpty else { return }
            dumpStateJSON(to: outPath)

        case "snapshot":
            guard let path = q["path"], !path.isEmpty else { return }
            let target = (q["window"] ?? "main").lowercased()
            if target == "settings" {
                if settingsController.window?.isVisible != true {
                    settingsController.show(anchor: activeEntry?.window, section: q["section"], background: true)
                } else if let sec = q["section"] {
                    settingsController.selectSection(sec)
                }
                settingsController.takeSnapshot(to: path) { _ in }
            } else if target == "help" {
                openHelpWindow(background: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    let cfg = WKSnapshotConfiguration()
                    self?.helpWebView?.takeSnapshot(with: cfg) { image, _ in
                        guard let image = image,
                              let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else { return }
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            } else {
                let entry = activeEntry ?? createMainWindow(background: true)
                entry.webVC.takeSnapshot(to: path) { _ in }
            }

        default:
            break
        }
    }

    private func dumpStateJSON(to path: String) {
        let group = DispatchGroup()
        var mainState: Any = [:]
        var settingsState: Any = [:]

        if let entry = activeEntry {
            group.enter()
            entry.webVC.evalJS("window.NMRApp ? window.NMRApp.getState() : {}") { res in
                if let res = res { mainState = res }
                group.leave()
            }
        }
        if settingsController.window != nil {
            group.enter()
            settingsController.evalJS("window.NMRSettings ? window.NMRSettings.getState() : {}") { res in
                if let res = res { settingsState = res }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let runs = HistoryStore.shared.loadRuns(projectDir: self.pipeline.projectDir)
            let playlistPayload = PlaylistOrderStore.shared.exportPayload(projectDir: self.pipeline.projectDir)
            let state: [String: Any] = [
                "appearance": ThemeManager.shared.activeModeString(),
                "themes": ThemeManager.shared.exportSettingsPayload(),
                "themesMenuTitles": self.themesMenu.map { ThemesMenu.titles($0) } ?? [],
                "activePreset": playlistPayload["activePresetId"] ?? "default",
                "pageZoom": SharedStore.shared.pageZoom,
                "showWorktreeMenu": self.worktreeController?.isShown ?? true,
                "shortcuts": ShortcutRegistry.shared.exportPayload(),
                "urlRoutes": URLRoutes.exportPayload(),
                "mainWindowCount": self.mainWindows.count,
                "mainWindows": self.mainWindows.map { [
                    "title": $0.window.title,
                    "frame": NSStringFromRect($0.window.frame),
                    "visible": $0.window.isVisible,
                ] },
                "mainUI": mainState,
                "settingsUI": settingsState,
                "settingsWindowVisible": self.settingsController.window?.isVisible ?? false,
                "helpWindowVisible": self.helpWindow?.isVisible ?? false,
                "historyRunCount": runs.count,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }
}
