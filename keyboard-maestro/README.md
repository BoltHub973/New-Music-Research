# Keyboard Maestro

Everything in this folder powers the live **Keyboard Maestro** progress window for
the DX broadcast pipeline. It is optional — if Keyboard Maestro isn't running, the
pipeline ignores it and behaves exactly the same.

| File | Role |
| :--- | :--- |
| `km_progress.py` | Pushes live pipeline state (phase, counts, log, scraped/missed tracks, done) into the KM global variable `NMRProgress` via `osascript`. Imported by `track_playlists.py`. |
| `progress_window.html` | The KM **Custom HTML Prompt** UI. Polls `NMRProgress` every 300 ms and renders the futuristic progress HUD, then a scraped-vs-missed results page when the run completes. |

## ⚠️ After moving this folder

`progress_window.html` is loaded **by your Keyboard Maestro macro**, not by the
Python code, so its path is *not* tracked in this repo. If you moved this folder
(or renamed the project), update the macro's "Custom HTML Prompt" / "Read file"
action to point at the new location:

```
.../New Music Research/keyboard-maestro/progress_window.html
```

`km_progress.py` is found automatically — `track_playlists.py` adds this folder to
`sys.path` at startup, so no macro change is needed for it.
