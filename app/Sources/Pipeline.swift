import Foundation

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

    /// Where the Python project lives. Overridable via the `NMRProjectDir` user
    /// default (handy for pointing at a stub during testing) — defaults to the
    /// canonical checkout in ~/Development.
    var projectDir: String {
        if let override = UserDefaults.standard.string(forKey: "NMRProjectDir"),
           !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/New Music Research").path
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

    /// The Keyboard Maestro macro the pipeline fires when it finishes (via the
    /// `KM_MACRO_UUID` env var it reads) — the "▶ New Music Research (2) — Open Results"
    /// macro. Overridable via `NMRResultMacroUUID`; set it empty to fire nothing.
    var resultMacroUUID: String {
        UserDefaults.standard.string(forKey: "NMRResultMacroUUID")
            ?? "3A811FCB-BF75-4507-A09F-083C73B4B382"
    }

    /// Called on the main queue with the raw JSON text each time the file changes.
    var onUpdate: ((String) -> Void)?
    /// Called on the main queue when the pipeline process exits.
    var onFinished: ((Int32) -> Void)?

    private var process: Process?
    private var timer: Timer?
    private var lastPayload = ""

    var isRunning: Bool { process?.isRunning ?? false }

    /// Clear any stale progress, then spawn the pipeline and begin tailing.
    func start() {
        stop()
        try? FileManager.default.removeItem(at: Self.progressURL)
        lastPayload = ""
        startPolling()
        spawn()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
    }

    // MARK: - Subprocess

    private func spawn() {
        let p = Process()
        // Run the pipeline exactly as nmr_run.sh does: the system Python, from the
        // project dir. Absolute interpreter path = no PATH/interpreter-mismatch risk.
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = ["track_playlists.py"]
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)

        // GUI apps inherit a minimal PATH; augment it so any PATH-resolved helpers the
        // pipeline shells out to (open, osascript, …) resolve. Python itself is absolute.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        // Fire the "Open Results" KM macro at the end of the run, like nmr_run.sh did.
        let macro = resultMacroUUID
        if !macro.isEmpty { env["KM_MACRO_UUID"] = macro }
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
