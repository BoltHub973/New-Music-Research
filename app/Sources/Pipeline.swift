import Foundation

/// Which date-added window the pipeline scrapes. Raw values match the
/// `--mode` argument `track_playlists.py` accepts.
enum ScrapeMode: String {
    case thisWeek = "this-week"   // rolling 7 days — today + this week
    case lastWeek = "last-week"   // previous calendar week (Mon → Mon)
}

/// Drives one run of the Tidal → Spotify pipeline and streams its progress.
///
/// Responsibilities:
///   1. Spawn `python3 track_playlists.py` (in a login shell so it inherits the
///      user's real PATH / Python, exactly as a Terminal run would).
///   2. Tail `~/.config/new-music-research/progress.json` — the file the pipeline's
///      `km_progress` module writes — and hand each fresh frame to `onUpdate`.
///
/// The pipeline opens the resulting playlist in Spotify itself, so this class never
/// needs to touch stdout; it only mirrors stdout+stderr into a log file for
/// troubleshooting.
final class Pipeline {
    /// The progress file the Python `km_progress` channel writes. Kept in sync with
    /// `PROGRESS_FILE` in `keyboard-maestro/km_progress.py`.
    static let progressURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/new-music-research/progress.json")

    static let logURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/New Music Research.log")

    /// The pipeline's *data* directory — the working directory the scripts run in.
    /// This is where mutable state lives: `playlists.json`, `.env`, token caches,
    /// `scraped-files/`, `missed-tracks/`, `generated-artwork/`. Overridable via the
    /// `NMRProjectDir` user default — defaults to the canonical checkout in
    /// ~/Development. (The *code* comes from `scriptsDir`, not from here.)
    var projectDir: String {
        if let override = UserDefaults.standard.string(forKey: "NMRProjectDir"),
           !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/New Music Research").path
    }

    /// Where the pipeline *code* runs from. `build.sh` bundles the Python pipeline
    /// into Resources/pipeline, so the installed app always executes exactly the
    /// code it was built with — no more app-half/pipeline-half version mismatch
    /// when building from a branch or worktree. Overridable via `NMRPipelineDir`
    /// (handy for pointing at a stub during testing); falls back to `projectDir`
    /// for unbundled dev runs of the raw binary.
    var scriptsDir: String {
        if let override = UserDefaults.standard.string(forKey: "NMRPipelineDir"),
           !override.isEmpty {
            return override
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("pipeline"),
           FileManager.default.fileExists(
               atPath: bundled.appendingPathComponent("track_playlists.py").path) {
            return bundled.path
        }
        return projectDir
    }

    /// The Python interpreter to run the pipeline with. Defaults to the system Python
    /// that `nmr_run.sh` uses (and where the project's deps are installed). Overridable
    /// via the `NMRPython` user default.
    var pythonPath: String {
        if let override = UserDefaults.standard.string(forKey: "NMRPython"), !override.isEmpty {
            return override
        }
        return "/usr/bin/python3"
    }

    /// The Keyboard Maestro macro the pipeline fires when a scrape run finishes
    /// (via the `KM_MACRO_UUID` env var it reads) — fired ONLY when scraping
    /// actually occurred. Overridable via `NMRResultMacroUUID`; empty = fire nothing.
    var resultMacroUUID: String {
        UserDefaults.standard.string(forKey: "NMRResultMacroUUID")
            ?? "3A811FCB-BF75-4507-A09F-083C73B4B382"
    }

    /// Display name for `resultMacroUUID`, shown in the HUD when it fires.
    var resultMacroName: String {
        UserDefaults.standard.string(forKey: "NMRResultMacroName")
            ?? "▶ New Music Research (2) — Open Results"
    }

    /// The macro fired instead when NO scrape happens — the user declined both
    /// launch prompts and landed on the previous run's results screen.
    /// Overridable via `NMRPreviousResultsMacroUUID`; empty = fire nothing.
    var previousResultsMacroUUID: String {
        UserDefaults.standard.string(forKey: "NMRPreviousResultsMacroUUID")
            ?? "2F8301F2-67D8-4976-8A97-6A6124C4AE8E"
    }

    /// Display name for `previousResultsMacroUUID`, shown in the HUD when it fires.
    var previousResultsMacroName: String {
        UserDefaults.standard.string(forKey: "NMRPreviousResultsMacroName")
            ?? "Open URLs in Google Chrome Beta?"
    }

    /// Fire a Keyboard Maestro macro by UUID (best-effort, non-blocking).
    func fireMacro(uuid: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Keyboard Maestro Engine\" to do script \"\(uuid)\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Called on the main queue with the raw JSON text each time the file changes.
    var onUpdate: ((String) -> Void)?
    /// Called on the main queue when the pipeline process exits.
    var onFinished: ((Int32) -> Void)?

    private var process: Process?
    private var timer: Timer?
    private var lastPayload = ""

    var isRunning: Bool { process?.isRunning ?? false }

    /// The window the current/most recent run scraped — what "Run Again" repeats.
    private(set) var lastMode: ScrapeMode = .thisWeek

    /// Clear any stale progress, then spawn the pipeline and begin tailing.
    func start(mode: ScrapeMode = .thisWeek) {
        stop()
        lastMode = mode
        try? FileManager.default.removeItem(at: Self.progressURL)
        lastPayload = ""
        startPolling()
        spawn(mode: mode)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    // MARK: - Launch-check helper

    /// Run the bundled `launch_check.py` with the given arguments and hand its
    /// stdout to `completion` on the main queue (empty string if it failed to run).
    /// Used by the launch flow: `["check"]` / `["delete", id, …]`.
    func runHelper(_ args: [String], completion: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [(scriptsDir as NSString).appendingPathComponent("launch_check.py")] + args
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        // The helper is designed to never block (cached-token auth only), but a
        // hung helper would freeze the launch flow invisibly — kill it after 30s
        // and let the caller fall back to the normal run.
        let timeout = DispatchWorkItem {
            if p.isRunning {
                NSLog("New Music Research: launch_check timed out — terminating")
                p.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

        p.terminationHandler = { _ in
            timeout.cancel()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion(text) }
        }
        do {
            try p.run()
        } catch {
            timeout.cancel()
            NSLog("New Music Research: failed to run launch_check — \(error)")
            DispatchQueue.main.async { completion("") }
        }
    }

    // MARK: - Subprocess

    private func spawn(mode: ScrapeMode) {
        let p = Process()
        // Code from the bundle (scriptsDir), data in the project dir (cwd): the
        // scripts resolve their imports/assets next to themselves, and read/write
        // playlists.json, .env, token caches and output folders relative to cwd.
        p.executableURL = URL(fileURLWithPath: pythonPath)
        let script = (scriptsDir as NSString).appendingPathComponent("track_playlists.py")
        p.arguments = [script, "--mode", mode.rawValue]
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)

        // GUI apps inherit a minimal PATH; augment it so any PATH-resolved helpers the
        // pipeline shells out to (open, osascript, …) resolve. Python itself is absolute.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        // Fire the "Open Results" KM macro at the end of the run, like nmr_run.sh did.
        // KM_MACRO_NAME rides along so the pipeline can name the macro in the HUD.
        let macro = resultMacroUUID
        if !macro.isEmpty {
            env["KM_MACRO_UUID"] = macro
            env["KM_MACRO_NAME"] = resultMacroName
        }
        p.environment = env

        // Mirror stdout+stderr into a fresh log for this run.
        if let logHandle = Self.freshLogHandle() {
            p.standardOutput = logHandle
            p.standardError = logHandle
        }

        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.onFinished?(status) }
        }

        do {
            try p.run()
            process = p
        } catch {
            NSLog("New Music Research: failed to launch pipeline — \(error)")
        }
    }

    // MARK: - File tailing

    private func startPolling() {
        // Match the HTML's own 300 ms cadence closely.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard
            let data = try? Data(contentsOf: Self.progressURL),
            let text = String(data: data, encoding: .utf8),
            !text.isEmpty,
            text != lastPayload
        else { return }
        lastPayload = text
        onUpdate?(text)
    }

    // MARK: - Helpers

    private static func freshLogHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        return try? FileHandle(forWritingTo: logURL)
    }
}
