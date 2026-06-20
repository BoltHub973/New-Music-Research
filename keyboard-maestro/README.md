# Progress HUD (formerly Keyboard Maestro)

This folder holds the live progress **HUD** and the channel that feeds it. It used to
drive a Keyboard Maestro **Custom HTML Prompt**; it now feeds the standalone
**[New Music Research](../app)** macOS app, which owns a real, resizable window instead
of KM's non-resizable HTML prompt. The pieces are unchanged enough that the same HTML
runs in both.

| File | Role |
| :--- | :--- |
| `km_progress.py` | Writes live pipeline state (phase, counts, log, scraped/missed tracks, done) **atomically to `~/.config/new-music-research/progress.json`**. Imported by `track_playlists.py` and `export_to_spotify.py`. (Keeps its historical name so those imports don't change.) |
| `progress_window.html` | The HUD UI. Polls the progress every 300 ms and renders the futuristic HUD, then a scraped-vs-missed results page when the run completes. The app bundles a copy of this file at build time. |

## How the HUD gets its data

The HTML was written for a KM prompt, so it talks to a `window.KeyboardMaestro` object
(`GetVariable('NMRProgress')`, `ResizeWindow`, `Cancel`). The app injects a tiny native
shim implementing exactly those calls and feeds it the polled `progress.json` — so the
HTML needs **no** changes to run in the app. See [`app/`](../app).

## If you still use the old Keyboard Maestro macro

`km_progress.py` no longer writes the KM `NMRProgress` variable, so the old Custom HTML
Prompt window won't update anymore. Point your launcher at the app instead:

```
open -a "New Music Research"
```

(Build the app first: `cd app && ./build.sh`.)
