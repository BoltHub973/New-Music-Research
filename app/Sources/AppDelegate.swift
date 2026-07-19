import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webVC: WebViewController!
    private let pipeline = Pipeline()
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var zoomEqMonitor: Any?

    // Near-black abyss from the HUD palette — matches the page so there's no flash.
    private let abyss = NSColor(srgbRed: 5.0/255, green: 5.0/255, blue: 8.0/255, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        webVC.onClose = { [weak self] in self?.window.performClose(nil) }
        pipeline.onUpdate = { [weak self] json in
            guard let self = self else { return }
            self.webVC.setPayload(json)
            // Mirror the run's scrape window into the native window title.
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mode = obj["mode"] as? String {
                self.window.title = (mode == ScrapeMode.lastWeek.rawValue) ? "Last Week" : "This Week"
            }
        }

        webVC.loadProgressUI()
        decideLaunchRun()

        // The ⌘+ / ⌘- / ⌘0 menu items cover Zoom In/Out/Actual Size. ⌘+ matches the
        // shifted "=" key; this local monitor also accepts a plain ⌘= for zoom-in.
        zoomEqMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "=" {
                self.webVC.zoomIn()
                return nil
            }
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline.stop()
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "This Week"          // updated live from the run's mode
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        // The HUD is permanently dark — force dark appearance so the title text
        // stays legible over the abyss titlebar even in system light mode.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = abyss
        window.minSize = NSSize(width: 760, height: 540)
        window.collectionBehavior = [.fullScreenPrimary]

        webVC = WebViewController()
        window.contentView = webVC.view

        // Per-display position + size memory: macOS restores the saved frame, and if
        // it lands off-screen (monitor unplugged) it constrains it back on-screen.
        let restored = window.setFrameUsingName("NMRMainWindow")
        window.setFrameAutosaveName("NMRMainWindow")
        if !restored { window.center() }

        window.makeKeyAndOrderFront(nil)
        webVC.focusWebView()
    }

    // MARK: - Actions

    private func run(mode: ScrapeMode) {
        window.title = (mode == .lastWeek) ? "Last Week" : "This Week"
        webVC.loadProgressUI()
        pipeline.start(mode: mode)
    }

    @objc private func runAgain()       { run(mode: pipeline.lastMode) }
    @objc private func scrapeThisWeek() { run(mode: .thisWeek) }
    @objc private func scrapeLastWeek() { run(mode: .lastWeek) }

    // MARK: - Launch flow

    /// Synthetic progress frames that drive the HUD's busy overlay during the
    /// launch check — same JSON shape the pipeline writes, minus the pipeline.
    private static let checkingFrame = #"{"busy":true,"busyLabel":"CHECKING SPOTIFY","busyDetail":"Looking for a This Week playlist created today…"}"#
    private static let deletingFrame = #"{"busy":true,"busyLabel":"CLEARING TODAY'S PLAYLIST","busyDetail":"Deleting the existing This Week playlist from Spotify…"}"#
    private static let idleFrame = #"{"busy":false}"#

    /// Decide what the launch run should be. If a This-Week playlist for today
    /// already exists in Spotify, offer to re-scrape (deleting it first); on
    /// decline, offer Last Week; on decline again, show the previous run's
    /// results. No duplicate — or the check itself failing — means the normal
    /// auto-run.
    private func decideLaunchRun() {
        webVC.setPayload(Self.checkingFrame)

        pipeline.runHelper(["check"]) { [weak self] output in
            guard let self = self else { return }
            let verdict = output.split(separator: "\n").map(String.init)
                .first { $0.hasPrefix("EXISTS:") || $0 == "NONE" || $0.hasPrefix("CHECK_ERROR:") }
                ?? ""
            guard verdict.hasPrefix("EXISTS:") else {
                if verdict != "NONE" {
                    // Console-visible breadcrumb for diagnosing skipped prompts.
                    NSLog("New Music Research: launch check fell through — %@",
                          verdict.isEmpty ? "no verdict (helper failed?)" : verdict)
                }
                self.run(mode: .thisWeek)
                return
            }
            let ids = verdict.dropFirst("EXISTS:".count)
                .split(separator: ",").map(String.init)

            if self.askYesNo("Re-scrape This Week?",
                             info: "Today's This Week playlist already exists in Spotify. "
                                 + "Delete it and scrape a fresh one?") {
                self.webVC.setPayload(Self.deletingFrame)
                self.pipeline.runHelper(["delete"] + ids) { _ in
                    self.run(mode: .thisWeek)
                }
            } else if self.askYesNo("Run Last Week instead?",
                                    info: "Scrape the tracks added to the Tidal playlists "
                                        + "last week (🟠 DX LAST WEEK)?") {
                self.run(mode: .lastWeek)
            } else {
                self.showPreviousResults()
            }
        }
    }

    /// Declined both prompts: bring back the last completed run from its
    /// progress file (results page, Open in Spotify, matching window title)
    /// instead of a dead "Standing by" screen. Since no scrape happened, the
    /// end-of-run macro doesn't fire — the previous-results macro does, and
    /// the firing is stamped into the payload so the HUD reports it.
    private func showPreviousResults() {
        guard var payload = try? String(contentsOf: Pipeline.progressURL, encoding: .utf8),
              !payload.isEmpty else {
            webVC.setPayload(Self.idleFrame)
            return
        }
        let uuid = pipeline.previousResultsMacroUUID
        if !uuid.isEmpty {
            pipeline.fireMacro(uuid: uuid)
            payload = Self.appendKMMacro(pipeline.previousResultsMacroName, uuid: uuid, to: payload)
        }
        pipeline.onUpdate?(payload)   // same path live frames take
    }

    /// Append a fired macro to a progress payload's `kmMacros` list. Entries are
    /// {name, uuid} dicts — the uuid makes the HUD entry clickable (opens the
    /// macro in the KM editor). Older payloads may hold plain strings; both
    /// shapes pass through JSONSerialization untouched.
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

    /// App-modal Yes/No alert. Pressing Y or N picks the matching button.
    private func askYesNo(_ message: String, info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Yes").keyEquivalent = "y"
        alert.addButton(withTitle: "No").keyEquivalent = "n"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func zoomIn()     { webVC.zoomIn() }
    @objc private func zoomOut()    { webVC.zoomOut() }
    @objc private func zoomActual() { webVC.zoomReset() }

    @objc private func toggleInspector() {
        // Toggle the Web Inspector (Web Inspector 3/3 — entitlement + isInspectable
        // are set elsewhere). Reading _inspector lets us toggle rather than only open.
        guard let webView = webVC?.webView,
              let inspector = webView.value(forKey: "_inspector") as AnyObject? else { return }
        let isVisible = (inspector.value(forKey: "isVisible") as? Bool) ?? false
        _ = inspector.perform(NSSelectorFromString(isVisible ? "hide:" : "show:"), with: nil)
    }

    // MARK: - Help

    /// The Help ▸ Keyboard Maestro Firing Rules window: a styled table of which
    /// macro fires for each run outcome, and what the completion card reports.
    @objc private func showFiringRules() {
        if helpWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1420, height: 910),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Keyboard Maestro Firing Rules"
            win.titlebarAppearsTransparent = true
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = abyss
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 760, height: 480)

            let web = WKWebView(frame: .zero)
            web.setValue(false, forKey: "drawsBackground")
            web.loadHTMLString(firingRulesHTML(), baseURL: nil)
            win.contentView = web
            win.center()
            helpWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    /// Built at show-time so overridden macro UUIDs/names (user defaults) are
    /// reflected truthfully.
    private func firingRulesHTML() -> String {
        let resultName = pipeline.resultMacroName
        let resultUUID = pipeline.resultMacroUUID
        let prevName = pipeline.previousResultsMacroName
        let prevUUID = pipeline.previousResultsMacroUUID
        let noneNote = "⌨ No Keyboard Maestro macros were fired — no playlist was created"
        return #"""
        <!doctype html><html><head><meta charset="utf-8"><style>
          body{margin:0;padding:38px 44px;background:#050508;color:#e8e8f0;
               font:17px/1.6 -apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased;}
          h1{font-size:25px;letter-spacing:.14em;text-transform:uppercase;color:#00f0ff;margin:0 0 24px;
             text-shadow:0 0 12px rgba(0,240,255,.25);}
          table{border-collapse:collapse;width:100%;}
          th{font-size:14px;letter-spacing:.14em;text-transform:uppercase;color:#8888a0;text-align:left;
             padding:10px 16px;border-bottom:1px solid rgba(255,255,255,.14);white-space:nowrap;}
          td{padding:15px 16px;border-bottom:1px solid rgba(255,255,255,.06);vertical-align:top;}
          td.outcome{font-weight:600;min-width:200px;}
          td.outcome .why{display:block;font-weight:400;color:#8888a0;font-size:15px;margin-top:3px;}
          td.macro{color:#c084fc;white-space:nowrap;}
          td.uuid{font-family:ui-monospace,Menlo,monospace;font-size:14px;color:#8888a0;
                  max-width:200px;word-break:break-all;}
          td.card{font-family:ui-monospace,Menlo,monospace;font-size:15px;color:#00f0ff;}
          td.card.none{color:#8888a0;font-style:italic;}
          .dash{color:#555570;}
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

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About New Music Research"
        win.titlebarAppearsTransparent = true
        win.backgroundColor = abyss
        win.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 168).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 168).isActive = true

        let name = label("New Music Research", size: 30, weight: .bold, color: NSColor(srgbRed: 0, green: 240.0/255, blue: 1, alpha: 1))
        let version = label("Version \(semver)", size: 15, weight: .semibold, color: .white)
        let build = buildLine(display, commitURL: info["NewMusicResearchVersionCommitURL"] as? String)
        let tag = label("Tidal → Spotify pipeline", size: 12.5, weight: .regular,
                        color: NSColor(srgbRed: 192.0/255, green: 132.0/255, blue: 252.0/255, alpha: 1))

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

    /// The monospaced build line (`MM-DD-YY h:MM AM/PM · <sha>`). When a commit URL was
    /// stamped at build time, the trailing SHA is a clickable link to the GitHub commit.
    private func buildLine(_ display: String, commitURL: String?) -> NSTextField {
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let attr = NSMutableAttributedString(
            string: display,
            attributes: [.font: mono, .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        if let s = commitURL, let url = URL(string: s),
           let sep = display.range(of: " · ", options: .backwards) {
            let shaRange = NSRange(sep.upperBound..<display.endIndex, in: display)
            attr.addAttributes([
                .link: url,
                .foregroundColor: NSColor(srgbRed: 0, green: 240.0 / 255, blue: 1, alpha: 1),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: shaRange)
        }
        let f = NSTextField(labelWithAttributedString: attr)
        f.alignment = .center
        f.isSelectable = true               // selectable + editable-attributes =
        f.allowsEditingTextAttributes = true // clickable link + pointing-hand cursor
        return f
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        return f
    }

    // MARK: - Menu

    private func buildMenu() {
        let menubar = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        addItem(appMenu, "About New Music Research", #selector(showAbout))
        appMenu.addItem(.separator())
        addItem(appMenu, "Run Again", #selector(runAgain), key: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide New Music Research", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit New Music Research", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu (so copy / select-all work on the results page)
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
        addItem(viewMenu, "Zoom In", #selector(zoomIn), key: "+")
        addItem(viewMenu, "Zoom Out", #selector(zoomOut), key: "-")
        addItem(viewMenu, "Actual Size", #selector(zoomActual), key: "0")
        viewMenu.addItem(.separator())
        let inspect = addItem(viewMenu, "Inspect Element", #selector(toggleInspector), key: "i")
        inspect.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        // Window menu
        let windowItem = NSMenuItem()
        menubar.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Scrape menu — pick which date-added window the run captures
        let scrapeItem = NSMenuItem()
        menubar.addItem(scrapeItem)
        let scrapeMenu = NSMenu(title: "Scrape")
        addItem(scrapeMenu, "This Week", #selector(scrapeThisWeek), key: "1")
        addItem(scrapeMenu, "Last Week", #selector(scrapeLastWeek), key: "2")
        scrapeItem.submenu = scrapeMenu

        // Help menu — documents which KM macros fire for each outcome.
        let helpItem = NSMenuItem()
        menubar.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        addItem(helpMenu, "Keyboard Maestro Firing Rules", #selector(showFiringRules))
        helpItem.submenu = helpMenu
        // AppKit auto-detects any menubar menu titled "Help" and injects its
        // Spotlight search field into it. Pointing NSApp.helpMenu at a detached
        // dummy menu makes the injection land there — i.e., nowhere visible.
        NSApp.helpMenu = NSMenu(title: "Help")

        NSApp.mainMenu = menubar
    }

    /// Build a menu item whose action is handled by this AppDelegate — with an
    /// explicit target so the first click never drops through the responder chain.
    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
}
