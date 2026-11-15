import CoreServices
import Foundation

/// Event-driven FSEvents watcher for the app's own themes folder and `theme-names.json`.
/// Runs only while the app is open, costs zero CPU between saves, and filters events
/// so edits to other apps' folders under ~/Development/Themes do not reload this app.
final class ThemesFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nmr.themes-watcher")
    private var stream: FSEventStreamRef?
    private var pending = false

    private let paths: [String]
    private let relevant: (String) -> Bool
    private let onChange: () -> Void

    init(appFolder: URL, nameTable: URL, onChange: @escaping () -> Void) {
        let folder = appFolder.standardizedFileURL.path
        let table = nameTable.standardizedFileURL.path
        paths = [folder, nameTable.deletingLastPathComponent().standardizedFileURL.path]
        relevant = { raw in
            let p = (raw as NSString).standardizingPath
            return p == table || p == folder || p.hasPrefix(folder + "/")
        }
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        let retainedSelf = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedSelf.toOpaque(),
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ThemesFolderWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            retainedSelf.release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            self.stream = nil
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info, count > 0 else { return }
        let watcher = Unmanaged<ThemesFolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
        if changed.contains(where: watcher.relevant) {
            watcher.coalesce()
        }
    }

    private func coalesce() {
        if pending { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.pending = false
            DispatchQueue.main.async { self.onChange() }
        }
    }
}
