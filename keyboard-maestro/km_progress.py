"""
Push live pipeline progress to a JSON file that the standalone **New Music
Research** macOS app reads and renders.

The app polls ``~/.config/new-music-research/progress.json`` a few times a second
and feeds whatever it finds into the progress HUD (the same ``progress_window.html``
that the old Keyboard Maestro Custom HTML Prompt used). Driving the window through a
file — instead of the old ``osascript`` → KM-variable bridge — means the pipeline no
longer depends on Keyboard Maestro at all: the app spawns the pipeline directly and
owns the window, so it can be resized and moved between monitors like any native app.

(The module keeps its historical ``km_progress`` name so the two importers —
``track_playlists.py`` and ``export_to_spotify.py`` — need no changes.)

Design notes
------------
* All failures are swallowed. If the progress directory can't be written (e.g. the
  pipeline is run by hand in a plain terminal with no app listening), every call is a
  cheap best-effort no-op and the pipeline behaves exactly as before.
* Writes are **atomic** — the JSON is written to a sibling ``.tmp`` file and then
  ``os.replace``-d into place — so the polling app never observes a half-written file.
* High-frequency updates (the per-scroll scan counter) are throttled; structural
  updates (phase / overall / log / done) are pushed immediately.
"""

import json
import os
import time
from pathlib import Path

# The single source of truth the standalone app polls. Sits alongside the Tidal
# session token in the project's existing ~/.config/new-music-research/ dir.
PROGRESS_FILE = Path.home() / ".config" / "new-music-research" / "progress.json"

_MIN_INTERVAL = 0.35  # seconds between throttled pushes

_state = {
    "phase": 0,
    "phaseTotal": 3,
    "phaseLabel": "INITIALIZING",
    "overall": {"current": 0, "total": 0, "label": "", "pct": None},
    "current": {"name": "", "detail": "", "status": "idle"},
    "log": [],
    "stats": {},
    "tracks": {"scraped": [], "missed": []},
    "done": False,
    "ok": True,
    "message": "",
    "spotifyUri": "",
    "busy": False,
    "busyLabel": "",
    "busyDetail": "",
    "ts": 0.0,
}
_last_push = 0.0


def _push(force: bool = False) -> None:
    global _last_push
    now = time.monotonic()
    if not force and (now - _last_push) < _MIN_INTERVAL:
        return
    _last_push = now
    _state["ts"] = time.time()
    try:
        PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = PROGRESS_FILE.with_name(PROGRESS_FILE.name + ".tmp")
        # ensure_ascii=False keeps real glyphs (em dashes, middle dots, accented
        # playlist names) in the UTF-8 file; the app reads it as UTF-8 and JSON.parse
        # restores them exactly. (The old ASCII-escaping dance was only needed for the
        # osascript / Mac-Roman bridge, which is gone.)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_state, f, ensure_ascii=False)
        os.replace(tmp, PROGRESS_FILE)
    except Exception:
        pass


# ── Public API ───────────────────────────────────────────────────────────────
def reset() -> None:
    """Push the current (initial) state so the window has something at once."""
    _push(force=True)


def hydrate() -> None:
    """Pull the live progress file into this process's state so a *child* process
    (the Spotify exporter) can keep driving the same HUD — preserving the log,
    stats and phase accumulated by the parent instead of resetting them. A no-op
    when there's nothing to read (e.g. the exporter is run by hand)."""
    try:
        raw = PROGRESS_FILE.read_text(encoding="utf-8").strip()
        if raw:
            data = json.loads(raw)
            if isinstance(data, dict):
                _state.update(data)
    except Exception:
        pass


def clear_busy() -> None:
    """Leave the full-panel 'working' message and return to the live progress
    widgets (used when a previously-blocking step starts reporting real
    incremental progress, e.g. the Spotify match loop)."""
    _state["busy"] = False
    _state["busyLabel"] = ""
    _state["busyDetail"] = ""
    _push(force=True)


def phase(index: int, total: int, label: str) -> None:
    _state["phase"] = index
    _state["phaseTotal"] = total
    _state["phaseLabel"] = label
    _push(force=True)


def overall(current, total, label=None, pct=None) -> None:
    _state["overall"]["current"] = current
    _state["overall"]["total"] = total
    if label is not None:
        _state["overall"]["label"] = label
    # Optional explicit bar percentage. When set it drives the fill independently
    # of current/total, so the count can keep showing "tracks" while the bar
    # reflects the whole export (matching + publishing). None → fall back to
    # current/total in the window.
    _state["overall"]["pct"] = pct
    _push(force=True)


def current(name: str, detail: str = "", status: str = "working") -> None:
    _state["current"] = {"name": name, "detail": detail, "status": status}
    _push()  # throttled — this is the high-frequency scan counter


def log(line: str) -> None:
    _state["log"].append(line)
    _state["log"] = _state["log"][-12:]
    _push(force=True)


def stats(**kw) -> None:
    _state["stats"].update(kw)
    _push(force=True)


def _slim(tracks) -> list:
    """Reduce a track list to the small shape the results page renders."""
    out = []
    for t in tracks or []:
        out.append({
            "title": (t.get("Title") or "").strip(),
            "artist": (t.get("Artist") or "").strip(),
            "source": (t.get("Source Playlist") or "").strip(),
        })
    return out


def busy(label: str, detail: str = "") -> None:
    """Switch the window to a full-panel 'working' message (no progress bar) for a
    long blocking step that can't report incremental progress (e.g. the Spotify
    export). Cleared automatically by ``finish``."""
    _state["busy"] = True
    _state["busyLabel"] = label
    _state["busyDetail"] = detail
    _push(force=True)


def results(scraped=None, missed=None) -> None:
    """Stash the scraped + missed track lists for the completion results page."""
    _state["tracks"] = {"scraped": _slim(scraped), "missed": _slim(missed)}
    _push(force=True)


def finish(ok: bool = True, message: str = "", spotify_uri: str = "") -> None:
    _state["done"] = True
    _state["ok"] = ok
    _state["message"] = message
    _state["spotifyUri"] = spotify_uri
    _state["busy"] = False  # the results page replaces the working message
    _state["current"] = {"name": "", "detail": "", "status": "done"}
    _push(force=True)
