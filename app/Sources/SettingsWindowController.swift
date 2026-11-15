import AppKit
import WebKit

private final class SettingsDragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var isPageReady = false
    private var pendingSection: String?
    private var shouldFocusSearchOnReady = true
    private var isBackgroundShow = false
    private let projectDirProvider: () -> String
    private let worktreeShownProvider: () -> Bool

    var onSetWorktreeMenu: ((Bool) -> Void)?
    var onZoomAction: ((String) -> Void)?
    var onRunURL: ((String) -> Void)?

    init(projectDirProvider: @escaping () -> String, worktreeShownProvider: @escaping () -> Bool) {
        self.projectDirProvider = projectDirProvider
        self.worktreeShownProvider = worktreeShownProvider

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        config.preferences.setValue(true, forKey: "DOMPasteAllowed")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 740), configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        self.webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings — New Music Research"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 1100, height: 720)
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.managed]

        super.init(window: win)
        win.delegate = self

        let content = NSView(frame: win.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1120, height: 740))
        content.autoresizingMask = [.width, .height]
        win.contentView = content

        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.configuration.userContentController.add(self, name: "nmrSettings")
        content.addSubview(wv)

        let dragBar = SettingsDragHandleView()
        dragBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dragBar)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: content.topAnchor),
            wv.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            dragBar.topAnchor.constraint(equalTo: content.topAnchor),
            dragBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 72),
            dragBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -54),
            dragBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        applyAppearance()
        applyZoom()
        loadHTML()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChanged),
            name: SharedStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChanged),
            name: HistoryStore.changedNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nmrSettings")
    }

    private func loadHTML() {
        if let url = Bundle.main.url(forResource: "settings", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func show(anchor: NSWindow?, section: String? = nil, background: Bool = false) {
        guard let win = window else { return }
        isBackgroundShow = background
        let wasVisible = win.isVisible

        if !wasVisible {
            win.placeOver(anchor, defaultRatio: 0.75, minSize: NSSize(width: 1100, height: 720))
        }
        applyAppearance()
        applyZoom()

        if let sec = section {
            pendingSection = sec
        }

        if background {
            win.orderBack(nil)
        } else {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if isPageReady {
            hydrate(section: section)
            if !background {
                win.makeFirstResponder(webView)
                focusSearch()
            }
        } else {
            shouldFocusSearchOnReady = !background
        }
    }

    func toggle(anchor: NSWindow?) {
        guard let win = window else { return }
        if win.isVisible && win.isKeyWindow {
            win.close()
        } else {
            show(anchor: anchor, section: nil, background: false)
        }
    }

    func closeWindow() {
        ShortcutRegistry.shared.isRecording = false
        window?.close()
    }

    func selectSection(_ section: String) {
        pendingSection = section
        guard isPageReady else { return }
        let safe = jsonString(section) ?? "\"general\""
        webView.evaluateJavaScript("window.NMRSettings && window.NMRSettings.selectSection(\(safe));", completionHandler: nil)
    }

    func focusSearch() {
        guard isPageReady else { return }
        webView.evaluateJavaScript("window.NMRSettings && window.NMRSettings.focusSearch();", completionHandler: nil)
    }

    func applyAppearance() {
        let app = SharedStore.shared.appearance
        window?.appearance = NSAppearance(named: app == .light ? .aqua : .darkAqua)
        if isPageReady {
            webView.evaluateJavaScript("window.NMRSettings && window.NMRSettings.setTheme('\(app.rawValue)');", completionHandler: nil)
        }
    }

    func applyZoom() {
        webView.pageZoom = CGFloat(SharedStore.shared.pageZoom)
    }

    func hydrate(section: String? = nil) {
        guard isPageReady else { return }
        let runs = HistoryStore.shared.loadRuns(projectDir: projectDirProvider())
        var payload: [String: Any] = [
            "appearance": SharedStore.shared.appearance.rawValue,
            "pageZoom": SharedStore.shared.pageZoom,
            "showWorktreeMenu": worktreeShownProvider(),
            "sectionOrder": SharedStore.shared.settingsSectionOrder,
            "storePath": HistoryStore.shared.historyURL.path,
            "runCount": runs.count,
            "shortcuts": ShortcutRegistry.shared.exportPayload(),
            "urlRoutes": URLRoutes.exportPayload(),
        ]
        if let sec = section ?? pendingSection {
            payload["section"] = sec
            pendingSection = nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.NMRSettings && window.NMRSettings.hydrate(\(json));", completionHandler: nil)
    }

    func evalJS(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { result, _ in
            completion?(result)
        }
    }

    func takeSnapshot(to path: String, completion: @escaping (Bool) -> Void) {
        let doSnap = { [weak self] in
            guard let self = self else { completion(false); return }
            let cfg = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: cfg) { image, _ in
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    completion(false)
                    return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        }
        if !isPageReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doSnap() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { doSnap() }
        }
    }

    @objc private func handleStoreChanged() {
        applyAppearance()
        applyZoom()
        hydrate()
    }

    // MARK: - NSWindowDelegate
    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        ShortcutRegistry.shared.isRecording = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !isBackgroundShow {
            focusSearch()
        }
    }

    private func saveFrame() {
        guard let win = window, win.isVisible else { return }
        SharedStore.shared.setSecondaryWindowFrame(NSStringFromRect(win.frame))
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageReady = true
        applyAppearance()
        applyZoom()
        hydrate()
        if shouldFocusSearchOnReady && !isBackgroundShow {
            window?.makeFirstResponder(webView)
            focusSearch()
        }
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nmrSettings", let body = message.body as? [String: Any] else { return }
        guard let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isPageReady = true
            hydrate()
            if !isBackgroundShow {
                window?.makeFirstResponder(webView)
                focusSearch()
            }
        case "close":
            closeWindow()
        case "sectionOrder":
            if let order = body["order"] as? [String] {
                SharedStore.shared.setSettingsSectionOrder(order)
            }
        case "setAppearance":
            if let mode = body["mode"] as? String, let app = AppAppearance(rawValue: mode) {
                SharedStore.shared.setAppearance(app)
            }
        case "setWorktreeMenu":
            if let show = body["show"] as? Bool {
                onSetWorktreeMenu?(show)
            }
        case "zoom":
            if let action = body["action"] as? String {
                onZoomAction?(action)
            }
        case "setCombos":
            if let actionId = body["actionId"] as? String, let combos = body["combos"] as? [String] {
                ShortcutRegistry.shared.setCombos(combos, for: actionId)
                hydrate()
            }
        case "resetShortcut":
            if let actionId = body["actionId"] as? String {
                ShortcutRegistry.shared.resetCombos(for: actionId)
                hydrate()
            }
        case "resetAllShortcuts":
            SharedStore.shared.setShortcuts([:])
            hydrate()
        case "recording":
            ShortcutRegistry.shared.isRecording = (body["active"] as? Bool) ?? false
        case "revealDataDir":
            let url = HistoryStore.shared.historyURL
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(SharedStore.shared.storeDir)
            }
        case "clearHistory":
            HistoryStore.shared.clearAll()
            hydrate()
        case "copyText":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "runURL":
            if let urlStr = body["url"] as? String {
                onRunURL?(urlStr)
            }
        default:
            break
        }
    }

    private func jsonString(_ str: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [str]),
              let arr = String(data: data, encoding: .utf8),
              arr.count >= 2 else { return nil }
        return String(arr.dropFirst().dropLast())
    }
}
