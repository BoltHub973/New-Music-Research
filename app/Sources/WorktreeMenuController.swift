import Cocoa

/// The "which checkout am I looking at" menu — the last item in the menu bar.
///
/// The app can be pointed at any checkout (a launcher script sets the project-root
/// env var), so a running window no longer implies main. This names the checkout,
/// says whether it's main or a worktree, how long ago that code last changed, and
/// warns when the branch's native sources are newer than the running binary —
/// since native changes only land through a build.
///
/// Drop-in: fill in `Config` at the call site, hold the controller in a property
/// (it owns a timer), and add `menuItem` last in the main menu.
///
///     worktreeMenu = WorktreeMenuController(
///         projectRoot: backendManager.projectRoot,
///         config: .init(watchedPaths: ["app.py", "static", "scripts",
///                                      "desktop/MyApp/Sources", "CLAUDE.md"],
///                       nativeSourceDir: "desktop/MyApp"))
///     mainMenu.addItem(worktreeMenu!.menuItem)
///     viewMenu.addItem(worktreeMenu!.toggleMenuItem)   // View ▸ Show Git Info in Menu Bar
///
/// Show/hide (Adrian, 09-25-26): the user can hide the whole item. The setting
/// is ON by default and lives in the app's shared store —
/// `~/Library/Application Support/<storeFolder>/worktree-menu.json`, key
/// `showWorktreeMenu` — so every checkout of the app agrees, and a folder
/// watcher applies a change made by any of them at once. The app's Settings
/// row reads `isShown`, writes `setShown(_:)`, and listens on
/// `onVisibilityChange`; the View-menu item above is the quick path.
///
/// Switch To (Adrian, 10-29-26): a submenu listing every checkout of this repo
/// (main + each worktree folder; branches with no folder are left out, his pick).
/// Picking one hands the app over to that checkout:
///   1. its copy is already running → it comes forward, this one quits;
///   2. its copy is built and newer than its code → it opens, this one quits;
///   3. otherwise `config.switchCommand` (`build.sh --relaunch`) runs in that
///      checkout while this app stays usable, the bar shows a live clock, and on
///      success the new copy comes forward and this one quits. A failure stays
///      in the bar with the build log until dismissed.
/// Two files make it work across copies, in their own folder inside the shared
/// store (`<store>/Worktree Switch/`): `apps.json` (each checkout's installed app,
/// its build time and pid, written at launch) and `handoff.json` (which checkout
/// should come forward). A subfolder on purpose: apps that reload on ANY change to
/// their store folder (Open Source Maker, 10-29-26) never see these writes.
///
final class WorktreeMenuController: NSObject, NSMenuDelegate {

    struct Config {
        /// Files and folders whose mtime counts as "this version changed".
        ///
        /// SOURCE ONLY. Anything the app rewrites while it runs (token caches,
        /// live-edited config, logs, build output) pins the age to "just now"
        /// forever and quietly turns the whole row into noise.
        var watchedPaths: [String]

        /// Directory holding code that only reaches the app through a build,
        /// relative to the project root (e.g. "desktop/MyApp", "src-tauri").
        /// `nil` disables the stale-binary warning.
        var nativeSourceDir: String?

        /// Extensions inside `nativeSourceDir` that require a rebuild.
        var nativeExtensions: Set<String> = ["swift", "m", "mm", "h"]

        /// Branch prefixes stripped when deriving a name from the branch.
        var branchPrefixes: [String] = ["claude/", "feature/", "fix/", "wip/"]

        /// What to call the non-worktree checkout.
        var mainLabel: String = "Main"

        /// Rebuild command named in the stale-binary warning.
        var buildCommand: String = "build.sh"

        /// Folder under ~/Library/Application Support holding the app's shared
        /// user-owned state. `nil` → the bundle's CFBundleName. Set it when a
        /// per-worktree build changes that name, or every checkout would keep
        /// its own copy of the show/hide setting.
        var storeFolder: String?

        /// Switch To: the command that builds, installs and relaunches a checkout,
        /// run from that checkout's root (first word relative to it). `nil` hides
        /// the Switch To submenu.
        var switchCommand: [String]? = ["build.sh", "--relaunch"]

        /// Brings this app forward when another checkout hands over to it.
        /// `nil` → activate the app and front its main window.
        var bringForward: (() -> Void)?

        init(watchedPaths: [String], nativeSourceDir: String? = nil, storeFolder: String? = nil) {
            self.watchedPaths = watchedPaths
            self.nativeSourceDir = nativeSourceDir
            self.storeFolder = storeFolder
        }
    }

    struct CheckoutInfo {
        var branch: String
        var isWorktree: Bool
        var worktreeName: String?
        var lastChange: Date?
        /// Human label for the menu — a hand-written one from
        /// ~/.claude/worktree-labels.json, else the Claude Code chat title,
        /// else prettified from the branch.
        var label: String = "—"
        /// Title of the Claude Code chat working in this checkout, when there is one.
        var chatTitle: String?
        /// Desktop-app session id (`local_…`) — what the deep link navigates to.
        var desktopSessionID: String?
        /// CLI session id, for claude://resume when there is no desktop chat.
        var cliSessionID: String?
    }

    /// One row of Switch To.
    struct Checkout {
        var root: String
        var info: CheckoutInfo
        var isCurrent: Bool
        /// Installed copy that is already newer than this checkout's code.
        var readyApp: String?
    }

    private enum SwitchState {
        case idle
        case building(target: Checkout, pid: pid_t, started: Date, log: URL)
        case failed(target: Checkout, detail: String, log: URL)
    }

    let menuItem = NSMenuItem()

    /// "Show Git Info in Menu Bar" with a check mark — add it to the View menu.
    /// It stays reachable while the status item is hidden, which is the point.
    let toggleMenuItem = NSMenuItem(title: WorktreeMenuController.toggleTitle,
                                    action: nil, keyEquivalent: "")

    /// Same words for the View-menu item and the Settings row.
    static let toggleTitle = "Show Git Info in Menu Bar"

    /// Key in the shared store — detect.sh looks for it OUTSIDE this file to
    /// confirm a Settings row was wired, so reference it by name there.
    static let settingKey = "showWorktreeMenu"

    /// Called on the main thread whenever visibility changes, from any source
    /// (the View menu, the Settings row, another checkout of the app).
    var onVisibilityChange: ((Bool) -> Void)?

    /// Whether the item is in the menu bar. ON unless the user turned it off.
    private(set) var isShown = true

    private let projectRoot: String
    private let config: Config
    private let menu = NSMenu(title: "Checkout")
    private var info: CheckoutInfo
    private var refreshTimer: Timer?
    private var storeWatcher: DispatchSourceFileSystemObject?
    private var switchWatcher: DispatchSourceFileSystemObject?
    private var checkouts: [Checkout] = []
    private var switchState: SwitchState = .idle
    private var switchClock: Timer?
    private var buildExit: DispatchSourceProcess?
    private var handoffWait: DispatchSourceProcess?
    private var handoffCheckPending = false

    init(projectRoot: String, config: Config) {
        self.projectRoot = projectRoot
        self.config = config
        self.info = CheckoutInfo(branch: "—", isWorktree: false, worktreeName: nil, lastChange: nil)
        super.init()

        menu.delegate = self
        // Keep the rows we mark disabled disabled (AppKit would re-enable
        // anything with a target/action otherwise).
        menu.autoenablesItems = false
        menuItem.submenu = menu
        applyTitle("⎇ …")

        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleShown)
        isShown = Self.readShown(at: storeURL)
        applyVisibility()
        watchStore()
        registerSelf()
        watchSwitchFolder()
        checkHandoff()

        refresh()
        // The title carries a relative time, so it goes stale on its own.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        switchClock?.invalidate()
        storeWatcher?.cancel()
        switchWatcher?.cancel()
        buildExit?.cancel()
        handoffWait?.cancel()
    }

    // MARK: - Show / hide

    /// Turn the item on or off, persist it, and tell every listener.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        Self.writeShown(shown, at: storeURL)
        applyVisibility()
        if shown { refresh() }
        onVisibilityChange?(shown)
    }

    @objc private func toggleShown() { setShown(!isShown) }

    /// `isHidden` rather than removing the item: an app that rebuilds its menu
    /// bar re-adds `menuItem` and the choice still holds.
    private func applyVisibility() {
        menuItem.isHidden = !isShown
        toggleMenuItem.state = isShown ? .on : .off
    }

    private var storeFolderName: String {
        config.storeFolder
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    private var storeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storeFolderName, isDirectory: true)
    }

    private var storeURL: URL { storeDir.appendingPathComponent("worktree-menu.json") }

    /// Missing file, unreadable file, or missing key → shown (the default).
    private static func readShown(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shown = obj[settingKey] as? Bool
        else { return true }
        return shown
    }

    private static func writeShown(_ shown: Bool, at url: URL) {
        var obj = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        obj[settingKey] = shown
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Watch the store FOLDER, not the file: an atomic write replaces the file,
    /// which would silently orphan a watcher on the old one.
    private func watchStore() {
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let fd = open(storeDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let shown = Self.readShown(at: self.storeURL)
            guard shown != self.isShown else { return }
            self.isShown = shown
            self.applyVisibility()
            if shown { self.refresh() }
            self.onVisibilityChange?(shown)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        storeWatcher = source
    }

    // MARK: - Data

    private func refresh() {
        // Hidden → nothing to show; skip the source walk until it comes back.
        guard isShown else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let sessions = Self.claudeSessions()
            let fresh = Self.readCheckout(at: self.projectRoot, config: self.config, sessions: sessions)
            let list = self.config.switchCommand == nil ? []
                : Self.readCheckouts(current: self.projectRoot, currentInfo: fresh,
                                     config: self.config, sessions: sessions,
                                     registry: Self.readJSON(self.appsURL))
            DispatchQueue.main.async {
                self.info = fresh
                self.checkouts = list
                self.applyTitle(self.titleText())
                self.rebuildItems()
            }
        }
    }

    private static func readCheckout(at root: String, config: Config) -> CheckoutInfo {
        readCheckout(at: root, config: config, sessions: claudeSessions())
    }

    /// Branch + worktree state straight from the git metadata — no subprocess.
    /// A linked worktree marks itself by making `.git` a FILE holding
    /// "gitdir: <common>/.git/worktrees/<name>".
    private static func readCheckout(at root: String, config: Config,
                                     sessions: [ClaudeSession]) -> CheckoutInfo {
        let fm = FileManager.default
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: dotGit.path, isDirectory: &isDir)

        var gitDir = dotGit
        var isWorktree = false
        var worktreeName: String?

        if exists && !isDir.boolValue,
           let contents = try? String(contentsOf: dotGit, encoding: .utf8) {
            let pointer = contents
                .replacingOccurrences(of: "gitdir:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pointer.isEmpty {
                gitDir = URL(fileURLWithPath: pointer)
                isWorktree = true
                worktreeName = gitDir.lastPathComponent
            }
        }

        var branch = "—"
        if let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
            let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ref:") {
                branch = line
                    .replacingOccurrences(of: "ref: refs/heads/", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                branch = String(line.prefix(7)) // detached HEAD
            }
        }

        let chat = claudeChat(forCheckout: root, sessions: sessions)
        return CheckoutInfo(branch: branch,
                            isWorktree: isWorktree,
                            worktreeName: worktreeName,
                            lastChange: newestChange(under: root, config: config),
                            label: humanLabel(root: root,
                                              branch: branch,
                                              isWorktree: isWorktree,
                                              chatTitle: chat.title,
                                              config: config),
                            chatTitle: chat.title,
                            desktopSessionID: chat.desktopSessionID,
                            cliSessionID: chat.cliSessionID)
    }

    // MARK: - Human name

    /// Worktree folders are machine-named (`playlist-emoji-display-name-977537`).
    /// A hand-written label wins; otherwise the branch is cleaned up into
    /// something readable — "claude/playlist-emoji-display-name-977537"
    /// becomes "Playlist Emoji Display Name".
    private static func humanLabel(root: String,
                                   branch: String,
                                   isWorktree: Bool,
                                   chatTitle: String?,
                                   config: Config) -> String {
        if !isWorktree { return config.mainLabel }
        if let label = storedLabel(for: root), !label.isEmpty { return label }
        // Claude Code already names each chat in plain English — reuse that
        // before falling back to cleaning up the branch.
        if let title = chatTitle, !title.isEmpty { return title }

        var name = branch
        for prefix in config.branchPrefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }

        var words = name
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)

        // Drop the random disambiguating suffix the worktree tooling appends.
        if let last = words.last, last.count >= 4,
           last.allSatisfy({ $0.isHexDigit || $0.isNumber }) {
            words.removeLast()
        }
        guard !words.isEmpty else { return branch }

        return words
            .map { $0.count <= 2 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// ~/.claude/worktree-labels.json — { "<checkout path>": "Human Name" }.
    /// Lives outside the repo so naming a worktree never shows up in git status.
    private static func storedLabel(for root: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/worktree-labels.json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return map[root] ?? map[(root as NSString).resolvingSymlinksInPath]
    }

    // MARK: - Claude Code session

    /// The Claude Code chat working in this checkout.
    ///
    /// Claude Code's desktop app keeps one JSON per chat under
    /// ~/Library/Application Support/Claude/claude-code-sessions/<org>/<user>/,
    /// carrying its cwd, title, sessionId, cliSessionId and archived flag. The
    /// newest unarchived chat for this checkout wins; an archived one is still
    /// worth reporting, but only a live one is worth focusing.
    struct ClaudeSession {
        var cwd: String
        var title: String?
        var desktopID: String?
        var cliID: String?
        /// Live chats outrank archived ones; newest activity breaks ties.
        var rank: Double
    }

    /// Every desktop chat on record, read once per refresh (Switch To names
    /// several checkouts from the same walk).
    private static func claudeSessions() -> [ClaudeSession] {
        let store = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: store,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var out: [ClaudeSession] = []
        for case let url as URL in walker where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String
            else { continue }
            let archived = (obj["isArchived"] as? Bool) ?? false
            let activity = (obj["lastActivityAt"] as? Double) ?? 0
            out.append(ClaudeSession(cwd: cwd,
                                     title: obj["title"] as? String,
                                     desktopID: obj["sessionId"] as? String, // already "local_…"
                                     cliID: obj["cliSessionId"] as? String,
                                     rank: archived ? activity : activity + 1e15))
        }
        return out
    }

    private static func claudeChat(forCheckout root: String, sessions: [ClaudeSession])
        -> (title: String?, desktopSessionID: String?, cliSessionID: String?) {

        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())

        if let best = sessions.filter({ $0.cwd == root }).max(by: { $0.rank < $1.rank }) {
            return (best.title, best.desktopID, best.cliID)
        }

        // No desktop chat on record — fall back to the newest CLI transcript for
        // this directory, which claude://resume can still open. The store path is
        // the checkout path with every non-alphanumeric character replaced by a dash.
        let encoded = String(root.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = home.appendingPathComponent(".claude/projects/\(encoded)")
        let newest = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.pathExtension == "jsonl" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da < db
            }
        return (nil, nil, newest?.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Ages

    private static func newestChange(under root: String, config: Config) -> Date? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var newest: Date?

        func consider(_ url: URL) {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return }
            if newest == nil || date > newest! { newest = date }
        }

        for relative in config.watchedPaths {
            let url = rootURL.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let child as URL in walker {
                    if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        consider(child)
                    }
                }
            } else {
                consider(url)
            }
        }
        return newest
    }

    /// Compact relative age: "just now", "6m ago", "3h ago", "2d ago".
    private static func relative(_ date: Date?) -> String {
        guard let date = date else { return "unknown" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<0:      return "just now"   // clock skew / file from the future
        case ..<60:     return "just now"
        case ..<3600:   return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default:        return "\(seconds / 86_400)d ago"
        }
    }


    /// Long relative age for the detail row: "11 minutes ago", "2 hours ago".
    private static func relativeLong(_ date: Date?) -> String {
        guard let date = date else { return "unknown" }
        let seconds = Int(Date().timeIntervalSince(date))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60:     return "just now"
        case ..<3600:   return unit(seconds / 60, "minute")
        case ..<86_400: return unit(seconds / 3600, "hour")
        default:        return unit(seconds / 86_400, "day")
        }
    }

    /// "6m ago (3:04:58 PM)" — the absolute local wall time rides along
    /// (Adrian's standard across every worktree menu, 09-01-26).
    private static func withClock(_ base: String, _ date: Date?) -> String {
        guard let date = date else { return base }
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return "\(base) (\(f.string(from: date)))"
    }

    // MARK: - Title

    /// A menu-bar item renders its SUBMENU's title, not its own — set both or
    /// the bar just says "Checkout".
    private func applyTitle(_ title: String) {
        menuItem.title = title
        menu.title = title
    }

    /// Shown in full — the whole point is knowing which version this is at a
    /// glance, so the name is never truncated.
    private func titleText() -> String {
        let marker = info.isWorktree ? "⎇" : "●"
        let normal = "\(marker) \(info.label) · \(Self.withClock(Self.relative(info.lastChange), info.lastChange))"
        switch switchState {
        case .idle:
            return normal
        case .building(let target, _, let started, _):
            return "⏳ Switching to \(target.info.label) · \(Self.clock(since: started))"
        case .failed:
            return "⚠︎ Couldn't switch · \(normal)"
        }
    }

    /// Running m:ss clock for a switch in progress.
    private static func clock(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        applyTitle(titleText())
        rebuildItems()
    }

    /// Built eagerly on every refresh, not only when the menu opens — a menu
    /// that is empty until clicked reads as broken and hides its contents from
    /// anything inspecting the app's state.
    private func rebuildItems() {
        let menu = self.menu
        menu.removeAllItems()

        switch switchState {
        case .idle:
            break
        case .building(let target, _, let started, _):
            addRow("Building \(target.info.label)…  \(Self.clock(since: started))", to: menu)
            addAction("Show Build Log", #selector(showBuildLog), to: menu)
            addAction("Cancel Switch", #selector(cancelSwitch), to: menu)
            menu.addItem(.separator())
        case .failed(let target, let detail, _):
            addRow("⚠︎  Couldn't switch to \(target.info.label)", to: menu)
            if !detail.isEmpty { addRow(detail, to: menu) }
            addAction("Show Build Log", #selector(showBuildLog), to: menu)
            addAction("Try Again", #selector(retrySwitch), to: menu)
            addAction("Dismiss", #selector(dismissFailure), to: menu)
            menu.addItem(.separator())
        }

        addRow("\(info.label)  —  \(info.isWorktree ? "worktree" : "main checkout")", to: menu)
        addRow("Branch:  \(info.branch)", to: menu)
        addRow("Path:  \(abbreviatedRoot())", to: menu)

        menu.addItem(.separator())

        addRow("Code changed:  \(Self.withClock(Self.relativeLong(info.lastChange), info.lastChange))", to: menu)

        // Native code only reaches the app through a build — flag a binary that
        // predates the branch's sources rather than let it read as current.
        // Compare against the EXECUTABLE's mtime; Info.plist is rewritten by the
        // build script and by nothing else, so it is not a build timestamp.
        let built = try? Bundle.main.executableURL?
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let change = info.lastChange, let builtDate = built ?? nil,
           nativeChangedAfter(builtDate), change > builtDate {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "⚠︎  Native code is newer than this build — run \(config.buildCommand)",
                action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        // Hidden when there is nowhere to switch to (one checkout) and while a
        // switch is already under way.
        if checkouts.count > 1, case .idle = switchState {
            let item = NSMenuItem(title: "Switch To", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Switch To")
            sub.autoenablesItems = false
            for c in checkouts {
                let marker = c.info.isWorktree ? "⎇" : "●"
                let age = Self.withClock(Self.relative(c.info.lastChange), c.info.lastChange)
                let row = NSMenuItem(title: "\(marker) \(c.info.label) · \(age)",
                                     action: #selector(switchTo(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = c.root
                if c.isCurrent {
                    row.state = .on
                    row.isEnabled = false
                }
                let hint = c.isCurrent ? "Running now"
                    : c.readyApp != nil ? "Opens at once (already built)"
                    : "Builds first (\(config.switchCommand?.joined(separator: " ") ?? ""))"
                if #available(macOS 14.4, *) { row.subtitle = hint } else { row.toolTip = hint }
                sub.addItem(row)
            }
            item.submenu = sub
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let chat = NSMenuItem(title: "Open in Claude Code",
                              action: #selector(openClaudeChat), keyEquivalent: "")
        chat.target = self
        chat.isEnabled = info.desktopSessionID != nil || info.cliSessionID != nil
        menu.addItem(chat)

        let reveal = NSMenuItem(title: "Reveal Checkout in Finder",
                                action: #selector(revealCheckout), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let copyItem = NSMenuItem(title: "Copy Checkout Path",
                                  action: #selector(copyPath), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
    }

    private func nativeChangedAfter(_ date: Date) -> Bool {
        guard let relative = config.nativeSourceDir else { return false }
        let sources = URL(fileURLWithPath: projectRoot).appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        for case let url as URL in walker
        where config.nativeExtensions.contains(url.pathExtension) {
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, m > date {
                return true
            }
        }
        return false
    }

    private func abbreviatedRoot() -> String {
        let home = NSHomeDirectory()
        return projectRoot.hasPrefix(home)
            ? "~" + projectRoot.dropFirst(home.count)
            : projectRoot
    }

    /// Informational rows: visible, never clickable.
    private func addRow(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    /// Open this checkout's chat in Claude Code.
    ///
    /// `claude://claude.ai/epitaxy/local_<id>` navigates the desktop app to that
    /// exact chat (verified 08-15-26 — the host must be `claude.ai`; `epitaxy` is
    /// the Code surface's internal route, and hosts like `claude://epitaxy/…` or
    /// `claude://local_sessions/…` are never dispatched).
    ///
    /// `claude://resume?session=<cli id>` is the fallback and only that: it
    /// IMPORTS a transcript, so on a chat the app already holds it spawns a
    /// second untitled copy ("General coding session").
    @objc private func openClaudeChat() {
        if let id = info.desktopSessionID,
           let url = URL(string: "claude://claude.ai/epitaxy/\(id)") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let id = info.cliSessionID,
              let url = URL(string: "claude://resume?session=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealCheckout() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectRoot)
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(projectRoot, forType: .string)
    }

    // MARK: - Switch To

    private var switchDir: URL { storeDir.appendingPathComponent("Worktree Switch", isDirectory: true) }
    private var appsURL: URL { switchDir.appendingPathComponent("apps.json") }
    private var handoffURL: URL { switchDir.appendingPathComponent("handoff.json") }
    private var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(storeFolderName)/worktree-switch.log")
    }
    private var cancelling = false
    private var handoffPoll: Timer?

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
    }

    private static func modified(_ path: String) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970
    }

    /// Record where this checkout's app lives, when it was built and its pid, so
    /// another copy can bring it forward or open it instead of rebuilding.
    private func registerSelf() {
        guard config.switchCommand != nil,
              let exe = Bundle.main.executablePath, let built = Self.modified(exe) else { return }
        var apps = Self.readJSON(appsURL)
        apps[projectRoot] = ["app": Bundle.main.bundlePath, "exeModified": built, "pid": Int(getpid())]
        Self.writeJSON(apps, to: appsURL)
    }

    /// A hand-over written by another copy lands here; react at once.
    private func watchSwitchFolder() {
        guard config.switchCommand != nil else { return }
        try? FileManager.default.createDirectory(at: switchDir, withIntermediateDirectories: true)
        let fd = open(switchDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.checkHandoff() }
        source.setCancelHandler { close(fd) }
        source.resume()
        switchWatcher = source
    }

    /// Main + every linked worktree, straight from the git metadata: the common
    /// dir's parent is the main checkout, and `<common>/worktrees/<name>/gitdir`
    /// points at each worktree's `.git` file. A folder deleted before git pruned
    /// it is skipped.
    private static func checkoutRoots(from root: String) -> [String] {
        let fm = FileManager.default
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return [root] }
        var common = dotGit
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return [root] }
            var gitDir = pointer.replacingOccurrences(of: "gitdir:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !gitDir.hasPrefix("/") { gitDir = (root as NSString).appendingPathComponent(gitDir) }
            guard let rel = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"),
                                        encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            else { return [root] }
            common = rel.hasPrefix("/") ? rel : (gitDir as NSString).appendingPathComponent(rel)
            common = (common as NSString).standardizingPath
        }
        var roots: [String] = []
        if (common as NSString).lastPathComponent == ".git" {
            roots.append((common as NSString).deletingLastPathComponent)
        }
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        for name in (try? fm.contentsOfDirectory(atPath: worktrees)) ?? [] {
            guard let pointer = try? String(contentsOfFile: "\(worktrees)/\(name)/gitdir", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  fm.fileExists(atPath: pointer)
            else { continue }
            roots.append((pointer as NSString).deletingLastPathComponent)
        }
        if !roots.contains(where: { samePath($0, root) }) { roots.insert(root, at: 0) }
        return roots
    }

    private static func readCheckouts(current: String, currentInfo: CheckoutInfo, config: Config,
                                      sessions: [ClaudeSession], registry: [String: Any]) -> [Checkout] {
        let list = checkoutRoots(from: current).map { root -> Checkout in
            let isCurrent = samePath(root, current)
            let info = isCurrent ? currentInfo : readCheckout(at: root, config: config, sessions: sessions)
            return Checkout(root: root, info: info, isCurrent: isCurrent,
                            readyApp: isCurrent ? nil
                                : readyApp(for: root, lastChange: info.lastChange, registry: registry))
        }
        // Main first, then the most recently changed worktree.
        return list.sorted { a, b in
            if a.info.isWorktree != b.info.isWorktree { return !a.info.isWorktree }
            return (a.info.lastChange ?? .distantPast) > (b.info.lastChange ?? .distantPast)
        }
    }

    /// The checkout's installed copy, when it still holds that checkout's build
    /// (no other checkout rebuilt over it) and is newer than its code.
    private static func readyApp(for root: String, lastChange: Date?, registry: [String: Any]) -> String? {
        guard let entry = registry[root] as? [String: Any],
              let app = entry["app"] as? String,
              let built = entry["exeModified"] as? Double,
              let exe = Bundle(path: app)?.executablePath,
              let now = modified(exe), abs(now - built) < 1
        else { return nil }
        if let change = lastChange, change.timeIntervalSince1970 > built + 1 { return nil }
        return app
    }

    private static func runningApp(for root: String, registry: [String: Any]) -> NSRunningApplication? {
        guard let entry = registry[root] as? [String: Any],
              let app = entry["app"] as? String,
              let pid = (entry["pid"] as? NSNumber)?.int32Value, pid != getpid(),
              let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated,
              let url = running.bundleURL, samePath(url.path, app)
        else { return nil }
        return running
    }

    @objc private func switchTo(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? String else { return }
        _ = switchTo(checkoutAt: root)
    }

    /// The same switch from outside the menu (a URL route such as
    /// `<scheme>://switch?to=<checkout path>`, for Raycast, Keyboard Maestro and tests).
    /// False when the path is not another checkout of this repo.
    @discardableResult
    func switchTo(checkoutAt root: String) -> Bool {
        // The cached list is up to a minute old: a worktree made since then is
        // read fresh rather than refused.
        var list = checkouts
        if !list.contains(where: { Self.samePath($0.root, root) }) {
            list = Self.readCheckouts(current: projectRoot, currentInfo: info, config: config,
                                      sessions: Self.claudeSessions(), registry: Self.readJSON(appsURL))
        }
        guard config.switchCommand != nil,
              let target = list.first(where: { Self.samePath($0.root, root) }), !target.isCurrent
        else { return false }
        startSwitch(to: target)
        return true
    }

    private func startSwitch(to target: Checkout) {
        if case .building = switchState { return }
        let registry = Self.readJSON(appsURL)

        // 1. That checkout's copy is already open: bring it forward, step aside.
        if let running = Self.runningApp(for: target.root, registry: registry) {
            writeHandoff(to: target.root, buildPid: nil)
            running.activate(options: [.activateAllWindows])
            stepAside()
            return
        }

        // 2. Its copy is built and newer than its code: open it. The code age is read
        //    NOW, not from the menu's last refresh (up to a minute old).
        let changed = Self.newestChange(under: target.root, config: config)
        if let app = Self.readyApp(for: target.root, lastChange: changed, registry: registry) {
            writeHandoff(to: target.root, buildPid: nil)
            let open = NSWorkspace.OpenConfiguration()
            open.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: open) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let error = error {
                        self.removeHandoff()
                        self.fail(target, detail: error.localizedDescription, log: self.logURL)
                    } else {
                        self.stepAside()
                    }
                }
            }
            return
        }

        // 3. Build it, while this copy stays usable.
        startBuild(target)
    }

    private func startBuild(_ target: Checkout) {
        guard let command = config.switchCommand, let first = command.first else { return }
        let log = logURL
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let script = first.hasPrefix("/") ? first : (target.root as NSString).appendingPathComponent(first)
        let argv = (FileManager.default.isExecutableFile(atPath: script) ? [script] : ["/bin/zsh", script])
            + command.dropFirst()
        guard let pid = Self.spawn(argv, in: target.root, log: log.path) else {
            fail(target, detail: "Couldn't start \(command.joined(separator: " "))", log: log)
            return
        }
        cancelling = false
        writeHandoff(to: target.root, buildPid: pid)
        switchState = .building(target: target, pid: pid, started: Date(), log: log)
        applyTitle(titleText())
        rebuildItems()
        switchClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
            self?.buildEnded(pid: pid)   // backstop in case the exit event was missed
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.buildEnded(pid: pid) }
        buildExit = source
        source.resume()
    }

    /// Only the clock moves each second: the title and the first row.
    private func tick() {
        guard case .building(let target, _, let started, _) = switchState else { return }
        applyTitle(titleText())
        menu.items.first?.title = "Building \(target.info.label)…  \(Self.clock(since: started))"
    }

    private func buildEnded(pid: pid_t) {
        guard case .building(let target, let current, _, let log) = switchState, current == pid else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }   // still running
        buildExit?.cancel(); buildExit = nil
        switchClock?.invalidate(); switchClock = nil

        let exited = (status & 0x7f) == 0
        let code = (status >> 8) & 0xff
        if exited && code == 0 {
            // The new copy is up. This app is still the active one, so macOS lets
            // it hand the front over; then it steps aside.
            if let running = Self.runningApp(for: target.root, registry: Self.readJSON(appsURL)) {
                running.activate(options: [.activateAllWindows])
            }
            stepAside()
            return
        }

        // Calls the hand-over off: the new copy only comes forward if this file survives.
        removeHandoff()
        if cancelling {
            cancelling = false
            switchState = .idle
            refresh()
            return
        }
        let reason = exited ? "The build stopped (exit \(code))" : "The build was stopped"
        let last = Self.lastLine(of: log)
        fail(target, detail: last.isEmpty ? reason : "\(reason). Last step: \(last)", log: log)
    }

    private func fail(_ target: Checkout, detail: String, log: URL) {
        switchState = .failed(target: target, detail: detail, log: log)
        applyTitle(titleText())
        rebuildItems()
    }

    private static func lastLine(of log: URL) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    @objc private func showBuildLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func cancelSwitch() {
        guard case .building(_, let pid, _, _) = switchState else { return }
        cancelling = true
        kill(-pid, SIGTERM)   // the build's own process group: the script and its compilers
    }

    @objc private func retrySwitch() {
        guard case .failed(let target, _, _) = switchState else { return }
        switchState = .idle
        startSwitch(to: checkouts.first { $0.root == target.root } ?? target)
    }

    @objc private func dismissFailure() {
        switchState = .idle
        applyTitle(titleText())
        rebuildItems()
    }

    /// Quit through a run-loop timer, never from a GCD main-queue block: an app whose
    /// quit answers `.terminateLater` and finishes on the main queue (Open Source Maker
    /// flushes its pages first) would deadlock inside that block, half-quit forever (10-29-26).
    private func stepAside() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.4)
    }

    private func writeHandoff(to root: String, buildPid: pid_t?) {
        var obj: [String: Any] = ["activate": root, "from": projectRoot,
                                  "requestedAt": Date().timeIntervalSince1970]
        if let pid = buildPid { obj["buildPid"] = Int(pid) }
        Self.writeJSON(obj, to: handoffURL)
    }

    private func removeHandoff() {
        try? FileManager.default.removeItem(at: handoffURL)
    }

    /// Another checkout asked THIS one to come forward (read at launch and on
    /// every change to the store folder).
    private func checkHandoff() {
        let handoff = Self.readJSON(handoffURL)
        guard let target = handoff["activate"] as? String, Self.samePath(target, projectRoot) else { return }
        if Date().timeIntervalSince1970 - ((handoff["requestedAt"] as? Double) ?? 0) > 15 * 60 {
            removeHandoff()   // left over from an abandoned switch
            return
        }
        guard let pid = (handoff["buildPid"] as? NSNumber)?.int32Value, pid > 0 else {
            removeHandoff()
            DispatchQueue.main.async { [weak self] in self?.comeForward() }
            return
        }
        // The build that launched this copy is still finishing (its guards and
        // checks). Come forward once it ends, unless the old copy calls it off.
        guard handoffPoll == nil else { return }
        handoffPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard kill(pid, 0) != 0 else { return }
            timer.invalidate()
            self.handoffPoll = nil
            // A second later: a failed build has had time to delete the file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let now = Self.readJSON(self.handoffURL)
                guard let t = now["activate"] as? String, Self.samePath(t, self.projectRoot) else { return }
                self.removeHandoff()
                self.comeForward()
            }
        }
    }

    private func comeForward() {
        if let custom = config.bringForward { custom(); return }
        NSApp.unhide(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }

    /// The build runs in its own process group (so Cancel stops the compilers
    /// too) with its output in the log, and outlives this app: a worktree build
    /// that closes the main app keeps going.
    private static func spawn(_ argv: [String], in dir: String, log: String) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, dir)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, dir)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT: the build gets stdin/out/err and nothing else. An inherited
        // pipe end would keep this app's own readers waiting until the build ended.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        // An app opened from Finder gets a bare PATH; builds need Homebrew, cargo and ~/.local/bin.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { (envp + args).forEach { free($0) } }

        var pid: pid_t = 0
        return posix_spawn(&pid, argv[0], &actions, &attr, args, envp) == 0 ? pid : nil
    }
}
