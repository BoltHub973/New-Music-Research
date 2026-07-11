# New Music Research — standalone macOS app

A tiny native app that **is** the run button. Launching it:

1. Opens a real, resizable, movable window (native `NSWindow` — remembers its size
   and position per display, unlike the old Keyboard Maestro HTML prompt).
2. Checks Spotify (via the bundled `launch_check.py`) for a This-Week playlist
   already created today, showing a "Checking Spotify" spinner meanwhile. If one
   exists it asks — answer with the **Y**/**N** keys — whether to delete it and
   re-scrape; declining offers a Last Week run; declining again brings back the
   previous run's results. The window title always names the run's scrape
   window ("This Week" / "Last Week").
3. Spawns the pipeline (`python3 track_playlists.py --mode …`) and renders the
   live futuristic HUD by tailing the pipeline's progress file into
   `progress_window.html`.

The pipeline opens the finished playlist in Spotify itself, so the app stays a pure
driver + viewer. Keyboard Maestro is no longer in the loop — a hotkey, Spotlight, or
the Dock can launch the app.

## Architecture

```
launch app
   │
   ├─ spawn:  python3 <app bundle>/Resources/pipeline/track_playlists.py   (cwd = <project>)
   │             │        code: bundled at build time → always matches the app
   │             │        data: playlists.json, .env, .cache, scraped-files/ … from cwd
   │             └─ km_progress.py writes ~/.config/new-music-research/progress.json (atomic)
   │
   └─ WKWebView loads bundled progress_window.html
          └─ a `window.KeyboardMaestro` shim feeds it the polled progress file
             (so the HUD HTML is byte-for-byte the same file KM used)
```

The **code/data split** is the point: `build.sh` copies the Python pipeline into
`Contents/Resources/pipeline/`, so the installed app always runs exactly the code it
was built with — building from any branch or worktree yields a self-consistent app
you can test straight from /Applications. Mutable state stays in the project dir.

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

Pure Swift, no Xcode project. `build.sh` bundles `../keyboard-maestro/progress_window.html`
**and the Python pipeline** (`*.py`, `km_progress.py`, `Playlist-Artwork.jpg` →
`Resources/pipeline/`), stamps a date+commit build number, strips quarantine, and
ad-hoc signs. Python changes require a rebuild to reach the installed app.

## Configuration

| User default (`com.adrian.new-music-research`) | Default | Purpose |
| :--- | :--- | :--- |
| `NMRProjectDir` | `~/Development/New Music Research` | The pipeline's **data** dir (cwd): `playlists.json`, `.env`, token caches, `scraped-files/`, `missed-tracks/`, `generated-artwork/` |
| `NMRPipelineDir` | bundled `Resources/pipeline` | Where the pipeline **code** is loaded from — override only to point at a stub during testing |
| `NMRResultMacroUUID` | `3A811FCB…B382` ("▶ New Music Research (2) — Open Results") | KM macro fired when a run **created a playlist**. Failed / empty / aborted runs fire nothing (the completion card says so). Empty = fire nothing |
| `NMRPreviousResultsMacroUUID` | `2F8301F2…AE8E` ("Open URLs in Google Chrome Beta?") | KM macro fired instead when no scrape happens (both launch prompts declined → previous results shown). Empty = fire nothing |

Every macro firing is reported in the HUD — as an activity-log line during the run
and a `⌨ Keyboard Maestro ▸ <macro name>` line on the completion card.

## Menu shortcuts

- **⌘1** — Scrape ▸ This Week (today + this week — the rolling 7-day window; also what launching the app runs)
- **⌘2** — Scrape ▸ Last Week (previous calendar week, Mon → Sun; orange `🟠 DX LAST WEEK` playlist)
- **⌘+ / ⌘- / ⌘0** — Zoom In / Out / Actual Size (persisted across launches)
- **⌘R** — Run again (re-runs the pipeline in place, repeating the last-used scrape mode)
- **⌥⌘I** — Inspect Element (Web Inspector)
- **⌘W / ⌘Q** — Close / Quit
- **Help ▸ Keyboard Maestro Firing Rules** — table of which KM macro fires for
  each outcome (playlist created / failed / empty / aborted / no-scrape) with UUIDs

## App icon

`Resources/AppIcon.icns` is a Tahoe-safe icon (full-bleed, opaque — no Liquid Glass
platter) generated from a transparent source PNG via the `mac-app-icons` pipeline.
To replace it, drop a new ≥1024² PNG and re-run that pipeline, then rebuild.
