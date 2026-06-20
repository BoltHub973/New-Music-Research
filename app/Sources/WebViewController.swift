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

    /// The most recent progress frame, re-applied once the page finishes loading so a
    /// frame that arrives before the document is ready (or across a reload) isn't lost.
    private var lastPayload = ""

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Web Inspector (1/3): enable before constructing the web view.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let ucc = config.userContentController
        ucc.add(self, name: "nmr")
        ucc.addUserScript(WKUserScript(
            source: Self.kmShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true  // Web Inspector (2/3)
        }
        // Let the dark window show through until the page paints — no white flash.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.view = webView
    }

    /// Load the bundled HUD.
    func loadProgressUI() {
        guard let html = Bundle.main.url(forResource: "progress_window", withExtension: "html") else {
            webView.loadHTMLString(
                "<body style='background:#050508;color:#e8e8f0;font-family:sans-serif;padding:40px'>"
                + "<h2>progress_window.html is missing from the app bundle.</h2></body>",
                baseURL: nil)
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    /// Hand a fresh progress frame (raw JSON text) to the HUD's poll loop.
    func setPayload(_ json: String) {
        // Encode the JSON text as a JS string literal so it injects safely regardless
        // of quotes / unicode in playlist names. The HUD does JSON.parse on it.
        lastPayload = json
        guard let data = try? JSONEncoder().encode(json),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__nmrPayload = \(literal);", completionHandler: nil)
    }

    func focusWebView() {
        view.window?.makeFirstResponder(webView)
    }

    // MARK: - Zoom (⌘+ / ⌘- / ⌘0), persisted across launches

    private let zoomKey = "pageZoom"
    private let zoomStep: CGFloat = 0.1
    private let zoomRange: ClosedRange<CGFloat> = 0.5...3.0

    private var storedZoom: CGFloat {
        let v = UserDefaults.standard.double(forKey: zoomKey)
        return v == 0 ? 1.0 : CGFloat(v)
    }

    func zoomIn()    { applyZoom(storedZoom + zoomStep) }
    func zoomOut()   { applyZoom(storedZoom - zoomStep) }
    func zoomReset() { applyZoom(1.0) }

    private func applyZoom(_ value: CGFloat) {
        let z = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        UserDefaults.standard.set(Double(z), forKey: zoomKey)
        webView.pageZoom = z
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
        if message.name == "nmr", (message.body as? String) == "close" {
            onClose?()
        }
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.pageZoom = storedZoom  // survive reloads / re-runs
        // Re-apply the latest frame: an update may have arrived before the document
        // was ready, or the page may have just been reloaded for a re-run.
        if !lastPayload.isEmpty { setPayload(lastPayload) }
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
