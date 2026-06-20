import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webVC: WebViewController!
    private let pipeline = Pipeline()
    private var aboutWindow: NSWindow?
    private var zoomEqMonitor: Any?

    // Near-black abyss from the HUD palette — matches the page so there's no flash.
    private let abyss = NSColor(srgbRed: 5.0/255, green: 5.0/255, blue: 8.0/255, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        webVC.onClose = { [weak self] in self?.window.performClose(nil) }
        pipeline.onUpdate = { [weak self] json in self?.webVC.setPayload(json) }

        webVC.loadProgressUI()
        pipeline.start()

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
        window.title = "New Music Research"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

    @objc private func runAgain() {
        webVC.loadProgressUI()
        pipeline.start()
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
