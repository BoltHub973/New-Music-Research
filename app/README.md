# New Music Research — standalone macOS app

A tiny native app that **is** the run button. Launching it:

1. Opens a real, resizable, movable window (native `NSWindow` — remembers its size
   and position per display, unlike the old Keyboard Maestro HTML prompt).
2. Spawns the pipeline (`python3 track_playlists.py`) in a login shell, so it
   inherits your normal `PATH` / Python exactly as a Terminal run would.
3. Renders the live futuristic HUD by tailing the pipeline's progress file and
   feeding it into `progress_window.html`.

The pipeline opens the finished playlist in Spotify itself, so the app stays a pure
driver + viewer. Keyboard Maestro is no longer in the loop — a hotkey, Spotlight, or
the Dock can launch the app.

## Architecture

```
launch app
   │
   ├─ spawn:  /bin/zsh -lc 'cd <project> && python3 track_playlists.py'
   │             └─ km_progress.py writes ~/.config/new-music-research/progress.json (atomic)
   │
   └─ WKWebView loads bundled progress_window.html
          └─ a `window.KeyboardMaestro` shim feeds it the polled progress file
             (so the HUD HTML is byte-for-byte the same file KM used)
```

The HTML talks to three KM calls — `GetVariable`, `ResizeWindow`, `Cancel` — which the
app shims natively ([WebViewController.swift](Sources/WebViewController.swift)). That's
why `keyboard-maestro/progress_window.html` needs **no** changes to run here.

| Path | Role |
| :--- | :--- |
| `~/.config/new-music-research/progress.json` | Live progress, written by the pipeline, polled by the app |
| `~/Library/Logs/New Music Research.log` | The pipeline's stdout+stderr for the latest run (troubleshooting) |

## Build

```sh
cd app
./build.sh          # compiles + installs /Applications/New Music Research.app
```

Pure Swift, no Xcode project. `build.sh` bundles `../keyboard-maestro/progress_window.html`,
stamps a date+commit build number, strips quarantine, and ad-hoc signs.

## Configuration

| User default (`com.adrian.new-music-research`) | Default | Purpose |
| :--- | :--- | :--- |
| `NMRProjectDir` | `~/Development/New Music Research` | Where to run the pipeline from. Override e.g. `defaults write com.adrian.new-music-research NMRProjectDir -string /path/to/checkout` |

## Menu shortcuts

- **⌘+ / ⌘- / ⌘0** — Zoom In / Out / Actual Size (persisted across launches)
- **⌘R** — Run again (re-runs the pipeline in place)
- **⌥⌘I** — Inspect Element (Web Inspector)
- **⌘W / ⌘Q** — Close / Quit

## App icon

`Resources/AppIcon.icns` is a Tahoe-safe icon (full-bleed, opaque — no Liquid Glass
platter) generated from a transparent source PNG via the `mac-app-icons` pipeline.
To replace it, drop a new ≥1024² PNG and re-run that pipeline, then rebuild.
