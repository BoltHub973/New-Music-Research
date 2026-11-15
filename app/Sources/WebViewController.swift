import AppKit
import WebKit

/// Hosts the progress HUD (`progress_window.html`) and bridges it to the native app.
///
/// The HTML was written for a Keyboard Maestro Custom HTML Prompt, so it talks to a
/// `window.KeyboardMaestro` object: `GetVariable('NMRProgress')` for data,
/// `ResizeWindow(...)` to fit the screen, and `Cancel()` to close. We inject a small
/// shim that implements exactly those three calls natively — so the HTML runs
/// unchanged in both the KM window and this app.
final class WebViewController: NSViewController {
    private(set) var webView: WKWebView!

    /// Invoked when the HUD asks to close (its Close button → `KeyboardMaestro.Cancel`).
    var onClose: (() -> Void)?
    var onReady: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleAppearance: (() -> Void)?
    var projectDirProvider: (() -> String)?

    private(set) var isReady = false
    private var confirmCompletion: ((Bool) -> Void)?
    private var choiceCompletion: ((String) -> Void)?

    /// The most recent progress frame, re-applied once the page finishes loading so a
    /// frame that arrives before the document is ready (or across a reload) isn't lost.
    private var lastPayload = ""

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nmr")
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Web Inspector + Clipboard permissions
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        config.preferences.setValue(true, forKey: "DOMPasteAllowed")

        let ucc = config.userContentController
        ucc.add(self, name: "nmr")
        ucc.addUserScript(WKUserScript(
            source: Self.kmShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc.addUserScript(WKUserScript(
            source: ThemeManager.shared.activeInjectionScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true  // Web Inspector (2/3)
        }
        // Let the window background show through cleanly until the page paints.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.view = webView

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHistoryChanged),
            name: HistoryStore.changedNotification,
            object: nil
        )
    }

    /// Load the bundled HUD.
    func loadProgressUI() {
        isReady = false
        guard let html = Bundle.main.url(forResource: "progress_window", withExtension: "html") else {
            webView.loadHTMLString(
                "<body style='background:#050508;color:#e8e8f0;font-family:sans-serif;padding:40px'>"
                + "<h2>progress_window.html is missing from the app bundle.</h2></body>",
                baseURL: nil)
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    /// Hand a fresh progress frame (raw JSON text) to the HUD.
    func setPayload(_ json: String) {
        lastPayload = json
        guard let data = try? JSONEncoder().encode(json),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.__nmrPayload = \(literal); if (window.__nmrOnPayload) window.__nmrOnPayload();",
            completionHandler: nil
        )
    }

    func focusWebView() {
        view.window?.makeFirstResponder(webView)
    }

    func applyAppearance() {
        let mode = ThemeManager.shared.currentSide
        view.window?.appearance = NSAppearance(named: mode == .light ? .aqua : .darkAqua)
        view.window?.backgroundColor = ThemeManager.shared.activePalette().bgColor
        guard isReady else { return }
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.setTheme('\(mode.rawValue)');", completionHandler: nil)
        ThemeManager.shared.applyLiveTheme(to: webView)
    }

    func applyStoredZoom() {
        webView.pageZoom = CGFloat(SharedStore.shared.pageZoom)
    }

    func pushHistory() {
        guard isReady else { return }
        let dir = projectDirProvider?() ?? (NSHomeDirectory() + "/Development/New Music Research")
        let json = HistoryStore.shared.loadJSONString(projectDir: dir)
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.setHistory(\(json));", completionHandler: nil)
    }

    func pushShortcuts() {
        guard isReady else { return }
        let payload: [String: String] = [
            "openLog": ShortcutRegistry.shared.primaryDisplay(for: "openLog") ?? "⌘L",
            "openSettings": ShortcutRegistry.shared.primaryDisplay(for: "openSettings") ?? "⌘,",
            "toggleAppearance": ShortcutRegistry.shared.primaryDisplay(for: "toggleAppearance") ?? "⌘⇧L",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.setShortcuts(\(json));", completionHandler: nil)
    }

    func openLog(tab: String? = nil) {
        let arg = tab.flatMap { jsonString($0) } ?? "null"
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.openLog(\(arg));", completionHandler: nil)
    }

    func toggleLog(tab: String? = nil) {
        let arg = tab.flatMap { jsonString($0) } ?? "null"
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.toggleLog(\(arg));", completionHandler: nil)
    }

    func openHUD() {
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.openHUD();", completionHandler: nil)
    }

    func setOccluded(_ occluded: Bool) {
        guard isReady else { return }
        webView.evaluateJavaScript("window.NMRApp && window.NMRApp.setOccluded(\(occluded ? "true" : "false"));", completionHandler: nil)
    }

    func askConfirm(
        title: String,
        subtitle: String,
        tile: String = "warn",
        kind: String = "warn",
        facts: [[String]],
        yesLabel: String = "Yes",
        noLabel: String = "No",
        completion: @escaping (Bool) -> Void
    ) {
        if let prev = confirmCompletion {
            confirmCompletion = nil
            prev(false)
        }
        confirmCompletion = completion
        dispatchModalPayload([
            "title": title,
            "subtitle": subtitle,
            "tile": tile,
            "kind": kind,
            "facts": facts,
            "yesLabel": yesLabel,
            "noLabel": noLabel,
        ]) { [weak self] in
            if let fn = self?.confirmCompletion {
                self?.confirmCompletion = nil
                fn(false)
            }
        }
    }

    func askChoice(
        title: String,
        subtitle: String,
        tile: String = "music",
        kind: String = "warn",
        facts: [[String]],
        buttons: [[String: Any]],
        completion: @escaping (String) -> Void
    ) {
        if let prev = choiceCompletion {
            choiceCompletion = nil
            prev("cancel")
        }
        choiceCompletion = completion
        dispatchModalPayload([
            "title": title,
            "subtitle": subtitle,
            "tile": tile,
            "kind": kind,
            "facts": facts,
            "buttons": buttons,
        ]) { [weak self] in
            if let fn = self?.choiceCompletion {
                self?.choiceCompletion = nil
                fn("cancel")
            }
        }
    }

    private func dispatchModalPayload(_ payload: [String: Any], onEncodeFailure: () -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            onEncodeFailure()
            return
        }
        let invoke = { [weak self] in
            self?.webView.evaluateJavaScript("window.NMRApp && window.NMRApp.askConfirm(\(json));", completionHandler: nil)
        }
        if isReady {
            invoke()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { invoke() }
        }
    }

    func evalJS(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { result, _ in
            completion?(result)
        }
    }

    func takeSnapshot(to path: String, completion: @escaping (Bool) -> Void) {
        let capture = { [weak self] in
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
        if isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { capture() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { capture() }
        }
    }

    @objc private func handleSharedStoreChanged() {
        applyAppearance()
        applyStoredZoom()
        pushShortcuts()
    }

    @objc private func handleThemesChanged() {
        applyAppearance()
    }

    @objc private func handleHistoryChanged() {
        pushHistory()
    }

    private func jsonString(_ str: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [str]),
              let arr = String(data: data, encoding: .utf8),
              arr.count >= 2 else { return nil }
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - Zoom (⌘= / ⌘- / ⌘0), synced cleanly across windows via SharedStore

    private let zoomStep: Double = 0.1
    private let zoomRange: ClosedRange<Double> = 0.5...3.0

    func zoomIn()    { applyZoom(SharedStore.shared.pageZoom + zoomStep) }
    func zoomOut()   { applyZoom(SharedStore.shared.pageZoom - zoomStep) }
    func zoomReset() { applyZoom(1.0) }

    private func applyZoom(_ value: Double) {
        let z = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        SharedStore.shared.setPageZoom(z)
        webView.pageZoom = CGFloat(SharedStore.shared.pageZoom)
    }

    // The shim that stands in for Keyboard Maestro's injected bridge.
    private static let kmShim = """
    (function(){
      if (window.__nmrShimInstalled) return;
      window.__nmrShimInstalled = true;
      window.__nmrPayload = '';
      window.KeyboardMaestro = {
        GetVariable: function(name){
          return (name === 'NMRProgress') ? (window.__nmrPayload || '') : '';
        },
        SetVariable: function(){},
        ResizeWindow: function(){},          /* native window owns its own size */
        Cancel: function(){ try { window.webkit.messageHandlers.nmr.postMessage('close'); } catch(e){} },
        Submit: function(){ try { window.webkit.messageHandlers.nmr.postMessage('close'); } catch(e){} }
      };
    })();
    """
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "nmr", let body = message.body as? String else { return }
        if body == "ready" {
            isReady = true
            applyAppearance()
            applyStoredZoom()
            pushShortcuts()
            pushHistory()
            onReady?()
        } else if body == "close" {
            onClose?()
        } else if body == "openSettings" {
            onOpenSettings?()
        } else if body == "toggleAppearance" {
            onToggleAppearance?()
        } else if body == "clearHistory" {
            HistoryStore.shared.clearAll()
        } else if body.hasPrefix("deleteRun:") {
            let runId = String(body.dropFirst("deleteRun:".count))
            HistoryStore.shared.deleteRun(id: runId)
        } else if body.hasPrefix("confirmResponse:") {
            let ans = body.dropFirst("confirmResponse:".count) == "true"
            if let fn = confirmCompletion {
                confirmCompletion = nil
                fn(ans)
            }
        } else if body.hasPrefix("choiceResponse:") {
            let choice = String(body.dropFirst("choiceResponse:".count))
            if let fn = choiceCompletion {
                choiceCompletion = nil
                fn(choice)
            }
        } else if body.hasPrefix("copyText:") {
            let text = String(body.dropFirst("copyText:".count))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if body.hasPrefix("editMacro:") {
            openMacroInEditor(String(body.dropFirst("editMacro:".count)))
        }
    }

    /// The HUD's fired-macro entries are clickable: open that macro in the
    /// Keyboard Maestro editor. The UUID comes from the progress file, so
    /// validate its shape before splicing it into AppleScript.
    private func openMacroInEditor(_ uuid: String) {
        guard !uuid.isEmpty, uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return }
        let script = "tell application \"Keyboard Maestro\"\neditMacro \"\(uuid)\"\nactivate\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        applyStoredZoom()
        applyAppearance()
        pushShortcuts()
        pushHistory()
        // Re-apply the latest frame: an update may have arrived before the document
        // was ready, or the page may have just been reloaded for a re-run.
        if !lastPayload.isEmpty { setPayload(lastPayload) }
        onReady?()
    }

    func webView(_ webView: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           (url.scheme ?? "").lowercased() == "spotify" {
            // The HUD's "Open in Spotify" button navigates to a spotify: URI.
            // Force the desktop app rather than letting WebKit route to the web player.
            openInSpotify(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func openInSpotify(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Spotify", url.absoluteString]
        try? p.run()
    }
}

extension WebViewController: WKUIDelegate {}
