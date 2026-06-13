import bootstrap
import csv
import json
import os
import sys
import datetime
import subprocess
import ui
from pathlib import Path

# Keyboard Maestro integration lives in keyboard-maestro/ (a hyphenated, non-importable
# folder name), so make it importable before pulling in the progress bridge.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "keyboard-maestro"))
import km_progress as km
from dotenv import load_dotenv
import tidalapi

load_dotenv()

# A track counts as "recent" if it was added to the playlist within this many days.
# (The old web scraper matched the UI's "today / yesterday / this week" buckets;
# the API gives real timestamps, so this is now an exact rolling window.)
RECENT_DAYS = 7

# OAuth session token for the Tidal API, created once by `python3 tidal_login.py`
# and refreshed automatically on every run. Lives outside the repo on purpose.
TIDAL_SESSION_FILE = Path.home() / ".config" / "new-music-research" / "tidal-session.json"


# Generate output filename with timestamp
# Format: scraped-files/SCRAPED MM-dd-yy__h.mm.ss a.csv
os.makedirs("scraped-files", exist_ok=True)
current_time = datetime.datetime.now().strftime("%m-%d-%y__%I.%M.%S %p")
output_file = os.path.join("scraped-files", f"SCRAPED {current_time}.csv")

def trigger_km_macro(uuid):
    """Triggers a Keyboard Maestro macro by its UUID using osascript."""
    script = f'tell application "Keyboard Maestro Engine" to do script "{uuid}"'
    try:
        # Silence osascript's stdout — `do script` echoes "missing value", which
        # would otherwise leak into our redirected stdout (the SPOTIFY_URI file).
        subprocess.run(["osascript", "-e", script], check=True, stdout=subprocess.DEVNULL)
        ui.ok(f"Triggered Keyboard Maestro macro {uuid}")
    except subprocess.CalledProcessError as e:
        ui.err(f"Failed to trigger KM macro: {e}")

def open_spotify_playlist(uri):
    """Open a spotify: URI in the Spotify desktop app. Best-effort, never fatal.

    This is the reliable way the playlist opens: when the pipeline is launched in
    its own iTerm window (e.g. by the Keyboard Maestro macro) nothing is capturing
    stdout, so the SPOTIFY_URI line alone would never cause the playlist to open.
    """
    try:
        # `-a Spotify` forces the desktop app to handle the spotify: URI. Plain
        # `open <uri>` lets LaunchServices pick a handler and can silently route
        # to the web player (or nowhere) — that's why the playlist wasn't opening.
        subprocess.run(["open", "-a", "Spotify", uri], check=False)
        ui.ok(f"Opening playlist in Spotify → [{ui.PRIMARY}]{uri}[/]")
    except Exception as e:
        ui.warn(f"Could not open Spotify automatically: {e}")


def read_tracks_csv(path):
    """Read a scraped/missed CSV into a list of row dicts (empty list on any error)."""
    rows = []
    try:
        with open(path, 'r', encoding='utf-8') as f:
            rows = list(csv.DictReader(f))
    except Exception:
        pass
    return rows


def load_playlists(filename="playlists.json"):
    if not os.path.exists(filename):
        ui.err(f"{filename} not found.")
        return []
    with open(filename, 'r') as f:
        try:
            return json.load(f)
        except json.JSONDecodeError as e:
            ui.err(f"Error decoding JSON: {e}")
            return []

def _login_print(msg):
    """Surface Tidal login-flow messages (the approval link) in both UIs."""
    ui.warn(msg)
    km.log(msg)

def tidal_session():
    """Restore the saved Tidal API session (refreshing tokens as needed).

    If no valid session exists, tidalapi starts a device-login flow: it prints a
    link.tidal.com URL (surfaced via ui/km) and waits up to 5 minutes for the
    user to approve it. Returns None if login ultimately fails.
    """
    session = tidalapi.Session()
    try:
        TIDAL_SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
        if session.login_session_file(TIDAL_SESSION_FILE, fn_print=_login_print):
            return session
    except TimeoutError:
        ui.err("Tidal login link expired — run `python3 tidal_login.py`, approve on your phone, then re-run.")
    except Exception as e:
        ui.err(f"Tidal login failed: {e}")
    return None

def fetch_playlist(session, playlist, progress, overall):
    """Fetch one playlist via the Tidal API, narrating live progress under `progress`.

    A transient sub-task shows the running scanned/recent counts; on completion
    it's removed and replaced by a persistent summary line, then the `overall`
    task is advanced.
    """
    sub = progress.add_task(
        f"[{ui.VIOLET}]  └─ {playlist['name']}", total=None, detail="fetching…"
    )
    km.current(playlist['name'], "fetching…", "opening")
    try:
        playlist_uuid = playlist['url'].rstrip('/').split('/')[-1]
        pl = session.playlist(playlist_uuid)
        progress.update(sub, total=pl.num_tracks or None)

        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=RECENT_DAYS)
        tracks_data = []
        scanned = 0
        offset = 0
        while True:
            batch = pl.tracks(limit=100, offset=offset)
            if not batch:
                break
            for t in batch:
                scanned += 1
                if t.date_added and t.date_added >= cutoff:
                    artists = ", ".join(a.name for a in (t.artists or []) if a.name)
                    tracks_data.append({
                        "Title": t.name or "Unknown Title",
                        "Artist": artists or "Unknown Artist",
                        "Album": (t.album.name if t.album else None) or "Unknown Album",
                        "Date Added": t.date_added.astimezone().strftime("%Y-%m-%d"),
                        "Source Playlist": playlist['name'],
                    })
            progress.update(
                sub, completed=scanned,
                detail=f"scanned {scanned} · {len(tracks_data)} recent",
            )
            km.current(
                playlist['name'],
                f"scanned {scanned} · {len(tracks_data)} recent",
                "scanning",
            )
            offset += len(batch)

        progress.remove_task(sub)
        if tracks_data:
            ui.ok(
                f"[{ui.VIOLET}]{playlist['name']}[/] — "
                f"[bold {ui.PRIMARY}]{len(tracks_data)}[/] matches "
                f"[{ui.MUTED}]out of {scanned} scanned[/]"
            )
            km.log(f"{playlist['name']} — {len(tracks_data)} matches out of {scanned} scanned")
        else:
            ui.info(f"{playlist['name']} — 0 matches out of {scanned} scanned")
            km.log(f"{playlist['name']} — 0 matches out of {scanned} scanned")
        progress.advance(overall)
        return tracks_data

    except Exception as e:
        progress.remove_task(sub)
        ui.err(f"Error fetching {playlist['name']}: {e}")
        km.log(f"Error fetching {playlist['name']}: {e}")
        progress.advance(overall)
        return []

def main():
    ui.banner()
    km.reset()

    playlists = load_playlists()
    if not playlists:
        km.finish(ok=False, message="playlists.json not found or empty")
        return

    all_tracks = []

    # ── PHASE 1 — Scrape Tidal (via the official API, not the website) ──────
    ui.phase(1, 3, "SCRAPE TIDAL")
    km.phase(1, 3, "SCRAPE TIDAL")
    km.overall(0, len(playlists), "Scanning playlists")
    ui.step(f"Connecting to the Tidal API for {len(playlists)} playlists")

    session = tidal_session()
    if not session:
        km.finish(ok=False, message="Tidal login required — run `python3 tidal_login.py`")
        return

    with ui.progress() as progress:
        overall = progress.add_task(
            f"[bold {ui.PRIMARY}]Scanning playlists",
            total=len(playlists),
            detail="",
        )
        for idx, playlist in enumerate(playlists):
            tracks = fetch_playlist(session, playlist, progress, overall)
            all_tracks.extend(tracks)
            km.overall(idx + 1, len(playlists))

    # ── PHASE 2 — Dedupe & snapshot ──────────────────────────────────────────
    ui.phase(2, 3, "DEDUPE & SNAPSHOT")
    km.phase(2, 3, "DEDUPE & SNAPSHOT")
    keys = ["Title", "Artist", "Album", "Source Playlist", "Date Added"]

    if all_tracks:
        ui.step(f"{len(all_tracks)} recent matches found across all playlists")
        km.current("Dedupe", f"{len(all_tracks)} recent matches found", "working")

        # Remove duplicates based on Artist, Album, Title
        unique_tracks = []
        seen_tracks = set()
        for track in all_tracks:
            track_key = (track['Artist'], track['Album'], track['Title'])
            if track_key not in seen_tracks:
                seen_tracks.add(track_key)
                unique_tracks.append(track)

        dupes = len(all_tracks) - len(unique_tracks)
        ui.ok(f"{len(unique_tracks)} unique tracks "
              f"[{ui.MUTED}]({dupes} duplicate{'s' if dupes != 1 else ''} removed)[/]")
        km.stats(recent=len(all_tracks), unique=len(unique_tracks), duplicates=dupes)
        km.log(f"{len(unique_tracks)} unique tracks ({dupes} duplicate{'s' if dupes != 1 else ''} removed)")

        # Write to CSV
        with open(output_file, 'w', newline='', encoding='utf-8') as f:
            dict_writer = csv.DictWriter(f, fieldnames=keys)
            dict_writer.writeheader()
            dict_writer.writerows(unique_tracks)
        ui.ok(f"Snapshot saved → [{ui.PRIMARY}]{output_file}[/]")

        # ── PHASE 3 — Hand off to the Spotify exporter ───────────────────────
        ui.phase(3, 3, "EXPORT TO SPOTIFY")
        km.phase(3, 3, "EXPORT TO SPOTIFY")
        km.current("Spotify", "matching & adding tracks…", "exporting")
        ui.info("Handing off to export_to_spotify.py")
        # The exporter is a blocking subprocess that doesn't stream progress back
        # to KM, so the HUD would otherwise sit frozen for ~10-15s. Switch the
        # window to a clean "working" message for the duration of the export.
        km.busy("EXPORTING TO SPOTIFY",
                "Matching tracks on Spotify and building your playlist — this can take a moment…")
        try:
            # The exporter renders its progress to stderr (streamed live); its
            # stdout carries only machine-readable data lines — SPOTIFY_URI: and
            # MISSED_FILE: — which we capture so we can open the playlist and
            # build the results page.
            result = subprocess.run(
                [sys.executable, "export_to_spotify.py", output_file],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )

            spotify_uri = ""
            missed_file = ""
            for line in result.stdout.splitlines():
                if line.startswith("SPOTIFY_URI:"):
                    spotify_uri = line[len("SPOTIFY_URI:"):].strip()
                elif line.startswith("MISSED_FILE:"):
                    missed_file = line[len("MISSED_FILE:"):].strip()

            # Preserve the data contract for any AppleScript launcher watching
            # *our* stdout (e.g. the `do shell script` recipe in the README).
            if spotify_uri:
                print(f"SPOTIFY_URI:{spotify_uri}")
                sys.stdout.flush()  # keep the stdout data contract intact for any launcher watching it

            # The child exporter already left busy-mode to drive a real progress
            # bar; clear our own stale busy flag so resuming here doesn't flash
            # the working spinner before the results page appears.
            km.clear_busy()

            # Hand the scraped + missed track lists to the progress window so it
            # can render a results page once the run completes.
            missed = read_tracks_csv(missed_file) if missed_file else []
            km.results(scraped=unique_tracks, missed=missed)

            # Actually open the freshly created playlist (see open_spotify_playlist).
            if spotify_uri:
                open_spotify_playlist(spotify_uri)

            km.finish(ok=True, message="Playlist created — opening in Spotify",
                      spotify_uri=spotify_uri)
        except subprocess.CalledProcessError as e:
            ui.err(f"Spotify export failed: {e}")
            km.finish(ok=False, message="Spotify export failed")
        except Exception as e:
            ui.err(f"An error occurred during export: {e}")
            km.finish(ok=False, message="An error occurred during export")

    else:
        ui.warn(f"No matching tracks found (added in the last {RECENT_DAYS} days).")
        km.finish(ok=True, message=f"No new tracks found (added in the last {RECENT_DAYS} days)")
        # Create empty CSV with headers just in case
        with open(output_file, 'w', newline='', encoding='utf-8') as f:
            dict_writer = csv.DictWriter(f, fieldnames=keys)
            dict_writer.writeheader()
        ui.info(f"Created empty snapshot → {output_file}")

    # Trigger Keyboard Maestro macro (optional — only runs if KM_MACRO_UUID is set in .env)
    km_uuid = os.getenv("KM_MACRO_UUID")
    if km_uuid:
        trigger_km_macro(km_uuid)
    else:
        ui.info("KM_MACRO_UUID not set — skipping Keyboard Maestro trigger.")

if __name__ == "__main__":
    main()
