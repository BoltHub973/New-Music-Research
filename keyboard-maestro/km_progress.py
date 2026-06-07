"""
Push live pipeline progress to a Keyboard Maestro variable so the standalone
HTML progress window (a KM Custom HTML Prompt) can render it.

The window polls the global KM variable ``NMRProgress`` via the KM JavaScript
bridge (``window.KeyboardMaestro.GetVariable``); here we just keep that variable
up to date with a small JSON blob.

Design notes
------------
* All failures are swallowed. If the Keyboard Maestro Engine isn't running (e.g.
  the pipeline is run by hand in a plain terminal), every call is a cheap no-op
  and the pipeline behaves exactly as before.
* The JSON is handed to ``osascript`` through an environment variable that
  AppleScript reads with ``system attribute`` — this sidesteps all shell/AS
  quoting issues no matter what ends up in playlist names or log lines.
* High-frequency updates (the per-scroll scan counter) are throttled; structural
  updates (phase / overall / log / done) are pushed immediately.
"""

import json
import os
import subprocess
import time

VAR = "NMRProgress"
_MIN_INTERVAL = 0.35  # seconds between throttled pushes

_state = {
    "phase": 0,
    "phaseTotal": 3,
    "phaseLabel": "INITIALIZING",
    "overall": {"current": 0, "total": 0, "label": ""},
    "current": {"name": "", "detail": "", "status": "idle"},
    "log": [],
    "stats": {},
    "tracks": {"scraped": [], "missed": []},
    "done": False,
    "ok": True,
    "message": "",
    "spotifyUri": "",
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
    env = dict(os.environ)
    # ensure_ascii=True escapes every non-ASCII char as \uXXXX. The payload then
    # travels through the NMR_PAYLOAD env var as pure ASCII, so AppleScript's
    # `system attribute` (which decodes the bytes as Mac Roman) can't mangle it.
    # The browser's JSON.parse restores the real glyphs — em dashes, middle dots,
    # accented playlist names — exactly.
    env["NMR_PAYLOAD"] = json.dumps(_state)
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                'tell application "Keyboard Maestro Engine" to setvariable '
                '"' + VAR + '" to (system attribute "NMR_PAYLOAD")',
            ],
            env=env,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception:
        pass


# ── Public API ───────────────────────────────────────────────────────────────
def reset() -> None:
    """Push the current (initial) state so the window has something at once."""
    _push(force=True)


def phase(index: int, total: int, label: str) -> None:
    _state["phase"] = index
    _state["phaseTotal"] = total
    _state["phaseLabel"] = label
    _push(force=True)


def overall(current, total, label=None) -> None:
    _state["overall"]["current"] = current
    _state["overall"]["total"] = total
    if label is not None:
        _state["overall"]["label"] = label
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


def results(scraped=None, missed=None) -> None:
    """Stash the scraped + missed track lists for the completion results page."""
    _state["tracks"] = {"scraped": _slim(scraped), "missed": _slim(missed)}
    _push(force=True)


def finish(ok: bool = True, message: str = "", spotify_uri: str = "") -> None:
    _state["done"] = True
    _state["ok"] = ok
    _state["message"] = message
    _state["spotifyUri"] = spotify_uri
    _state["current"] = {"name": "", "detail": "", "status": "done"}
    _push(force=True)
