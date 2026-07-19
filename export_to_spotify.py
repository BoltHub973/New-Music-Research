import bootstrap
import argparse
import base64
import csv
import glob
import os
import sys
import datetime
import time
import subprocess
import requests
import spotipy
import ui
from spotipy.oauth2 import SpotifyOAuth, SpotifyOauthError
from dotenv import load_dotenv

# Keyboard Maestro progress bridge lives in keyboard-maestro/ (a hyphenated,
# non-importable folder). When this exporter runs as a child of the pipeline it
# drives the same live HUD; standalone (no KM Engine) every call is a no-op.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "keyboard-maestro"))
import km_progress as km

# Load .env explicitly from the working directory (the project/data dir).
# A bare load_dotenv() searches upward from this *script's* directory — which is
# the app bundle when running the bundled copy, where no .env exists.
load_dotenv(os.path.join(os.getcwd(), ".env"))

# Configuration
CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID")
CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET")
# Port 8899 on purpose: Adrian's Spotify-Playlists-Dashboard app owns 8888, and
# the consent flow's temporary local server must be able to bind this port.
# The same URI must be registered in the Spotify Developer Dashboard.
REDIRECT_URI = "http://127.0.0.1:8899/callback"
# NOTE: adding a scope invalidates the cached token — the next run opens the
# browser once for re-consent. playlist-read-private lets the launch check see
# our private playlists; user-library-modify covers DELETE /me/library.
SCOPE = ("playlist-read-private playlist-modify-public playlist-modify-private "
         "ugc-image-upload user-library-modify")
ARTWORK_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Playlist-Artwork.jpg")

# Token cache lives in the working directory — the project/data dir, where it has
# always been. Explicitly NOT script-relative: the running copy of this script may
# be the one bundled inside the app, and the bundle is wiped on every rebuild.
CACHE_PATH = os.path.join(os.getcwd(), ".cache")

# Spotipy's default read timeout is 5s — the ugc-image-upload endpoint routinely
# blows past that, which is how a playlist once ended up created-but-empty.
REQUEST_TIMEOUT = 30
MAX_NETWORK_RETRIES = 4

# How each scrape mode brands its playlist: title prefix + artwork theme.
MODES = {
    "this-week": {"title": "🪁 DX {date}", "theme": "violet"},
    "last-week": {"title": "🟠 DX LAST WEEK {date}", "theme": "orange"},
}

def get_latest_csv():
    """Finds the most recently created SCRAPED csv file."""
    files = glob.glob("scraped-files/SCRAPED *.csv")
    if not files:
        return None
    # Sort by modification time (or name since it has timestamp)
    # Using os.path.getmtime just to be safe about "latest" creation
    latest_file = max(files, key=os.path.getmtime)
    return latest_file

def get_credentials():
    """Prompts user for credentials if not found in env."""
    global CLIENT_ID, CLIENT_SECRET

    if (not CLIENT_ID or not CLIENT_SECRET) and not sys.stdin.isatty():
        # Headless (spawned by the app) — there's nobody to type at a prompt.
        ui.err("SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET not set — "
               f"expected in {os.path.join(os.getcwd(), '.env')}")
        return False

    if not CLIENT_ID:
        ui.warn("Spotify credentials required — find these in your Developer Dashboard.")
        CLIENT_ID = input("Enter your Spotify Client ID: ").strip()

    if not CLIENT_SECRET:
        if not CLIENT_ID: # If user just hit enter above, maybe they set them now?
             CLIENT_ID = input("Enter your Spotify Client ID: ").strip()
        CLIENT_SECRET = input("Enter your Spotify Client Secret: ").strip()

    if not CLIENT_ID or not CLIENT_SECRET:
        ui.err("Client ID and Client Secret are required so we can talk to Spotify.")
        return False
    return True

def mac_notify(title, message):
    """Send a macOS notification via osascript."""
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script])

def spotify_call(fn, *args, **kwargs):
    """
    Calls a Spotify API function, automatically retrying:
      · 429 rate limits — waits out the Retry-After window (with a Mac notification)
      · transient failures (read timeouts, dropped connections, 5xx) — bounded
        retries with backoff. A retried write can in theory double-apply if the
        first request actually landed, but for this pipeline a rare duplicate
        beats an aborted export (see the created-but-empty playlist of 07-10-26).
    """
    attempts = 0
    while True:
        try:
            return fn(*args, **kwargs)
        except spotipy.exceptions.SpotifyException as e:
            if e.http_status == 429:
                retry_after = int(e.headers.get("Retry-After", 30)) + 1
                msg = f"Waiting {retry_after}s for rate limit to reset…"
                ui.warn(f"Rate limited — {msg}")
                mac_notify("🪁 DX — Spotify Rate Limit", msg)
                time.sleep(retry_after)
                ui.info("Retrying…")
            elif e.http_status is not None and e.http_status >= 500 and attempts < MAX_NETWORK_RETRIES:
                attempts += 1
                wait = 2 * attempts
                ui.warn(f"Spotify server error {e.http_status} — retrying in {wait}s "
                        f"({attempts}/{MAX_NETWORK_RETRIES})…")
                time.sleep(wait)
            else:
                raise
        except requests.exceptions.RequestException as e:
            if attempts >= MAX_NETWORK_RETRIES:
                raise
            attempts += 1
            wait = 2 * attempts
            ui.warn(f"Network hiccup ({type(e).__name__}) — retrying in {wait}s "
                    f"({attempts}/{MAX_NETWORK_RETRIES})…")
            time.sleep(wait)

def build_spotify_client():
    return spotipy.Spotify(
        auth_manager=SpotifyOAuth(
            client_id=CLIENT_ID,
            client_secret=CLIENT_SECRET,
            redirect_uri=REDIRECT_URI,
            scope=SCOPE,
            open_browser=True,
            cache_path=CACHE_PATH,
        ),
        requests_timeout=REQUEST_TIMEOUT,
    )


def authenticate():
    """Return (sp, user_id), transparently recovering from an expired refresh token.

    Spotify refresh tokens expire 6 months after the original authorization
    (developer.spotify.com blog, 2026-06-18; enforced for existing apps from
    2026-07-20). The refresh endpoint then returns 400 invalid_grant — per the
    blog the correct handling is: don't retry, discard the stored token, and
    send the user back through the sign-in flow (the browser opens once).
    """
    try:
        sp = build_spotify_client()
        return sp, spotify_call(sp.me)['id']
    except SpotifyOauthError as e:
        error_code = getattr(e, "error", "") or ""
        if "invalid_grant" not in error_code and "invalid_grant" not in str(e).lower():
            raise
        ui.warn("Spotify refresh token expired (6-month limit) — re-authorize in the browser…")
        km.log("Spotify session expired — re-authorizing in browser")
        try:
            os.remove(CACHE_PATH)
        except OSError:
            pass
        sp = build_spotify_client()
        return sp, spotify_call(sp.me)['id']


def main():
    # Inherit the live HUD state the pipeline built up (log, stats, phase) so we
    # can keep it animating with real export progress instead of a frozen spinner.
    km.hydrate()

    # 1. basic setup
    parser = argparse.ArgumentParser(description="Export a scraped Tidal CSV to a Spotify playlist.")
    parser.add_argument("csv_file", nargs="?", default=None, help="Scraped CSV (default: latest in scraped-files/)")
    parser.add_argument("--mode", choices=sorted(MODES), default="this-week",
                        help="Scrape window the CSV represents — controls playlist title & artwork theme")
    args = parser.parse_args()

    mode = MODES[args.mode]
    csv_file = args.csv_file
    if not csv_file:
        ui.info("Looking for latest scraped CSV…")
        csv_file = get_latest_csv()

    if not csv_file:
        ui.err("No CSV file provided or found.")
        sys.exit(1)

    # 2. Authenticate
    ui.section("AUTHENTICATE SPOTIFY")
    ui.step(f"Source snapshot: [{ui.PRIMARY}]{csv_file}[/]")
    if not get_credentials():
        sys.exit(1)

    try:
        sp, user_id = authenticate()
        ui.ok(f"Authenticated as [{ui.PRIMARY}]{user_id}[/]")
    except Exception as e:
        ui.err(f"Authentication failed: {e}")
        if "address already in use" in str(e).lower():
            ui.info(f"Another app is holding the consent port — quit whatever is using "
                    f"{REDIRECT_URI.split('/callback')[0]} and re-run. (The port is only "
                    f"needed during the one-time browser consent.)")
        else:
            ui.info(f"Check your Client ID/Secret and that {REDIRECT_URI} is a "
                    f"Redirect URI in your Spotify app settings.")
        sys.exit(1)

    # 3. Read Tracks
    tracks_to_search = []
    try:
        with open(csv_file, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                tracks_to_search.append(row)
    except Exception as e:
        ui.err(f"Error reading CSV {csv_file}: {e}")
        sys.exit(1)

    if not tracks_to_search:
        ui.warn("No tracks found in CSV.")
        return

    ui.ok(f"Loaded [bold {ui.PRIMARY}]{len(tracks_to_search)}[/] tracks from snapshot")

    # 4. Search and Collect URIs
    track_uris = []
    omitted = []  # Tracks that couldn't be confidently matched — saved to missed-tracks/

    def clean_query(t):
        return t.replace("ft.", "").replace("feat.", "").split("(")[0].strip()

    def pick_best_track(items):
        """Prefer the explicit version of a track. Falls back to the first result."""
        for item in items:
            if item.get('explicit', False):
                return item
        return items[0]

    def artist_matches(track_item, expected_artist):
        """
        Strict word-boundary artist check. Requires the expected artist name to match
        a whole word in the Spotify artist name (or vice versa), not just a substring.
        This prevents 'DRAM' matching 'DJ Drama' while still matching 'DRAM' exactly.
        Handles comma-separated artist strings (e.g. 'Artist A, Artist B').
        """
        import re
        # Split comma-separated artists from the scraped data
        expected_artists = [a.strip() for a in expected_artist.split(',')]
        for expected in expected_artists:
            expected_lower = expected.lower()
            for a in track_item['artists']:
                spotify_lower = a['name'].lower()
                # Exact match
                if expected_lower == spotify_lower:
                    return True
                # Word-boundary match: expected must appear as a whole word in spotify name,
                # or spotify name must appear as a whole word in expected
                pattern = r'\b' + re.escape(expected_lower) + r'\b'
                if re.search(pattern, spotify_lower):
                    return True
                pattern2 = r'\b' + re.escape(spotify_lower) + r'\b'
                if re.search(pattern2, expected_lower):
                    return True
        return False

    def filter_by_artist(items, expected_artist):
        return [t for t in items if artist_matches(t, expected_artist)]

    ui.section("MATCH TRACKS ON SPOTIFY")
    # Switch the HUD off the blocking "working" spinner and onto a real,
    # data-driven progress bar that advances as each track is matched. The bar
    # represents the *whole* export: matching fills it to MATCH_WEIGHT%, and the
    # publishing steps tick it the rest of the way to 100%.
    n_tracks = len(tracks_to_search)
    MATCH_WEIGHT = 90  # % of the bar allotted to the (long) match phase
    km.clear_busy()
    km.overall(0, n_tracks, "MATCHING ON SPOTIFY", pct=0)
    with ui.progress() as progress:
        match_task = progress.add_task(
            f"[bold {ui.PRIMARY}]Searching Spotify",
            total=len(tracks_to_search),
            detail="",
        )
        for idx, track in enumerate(tracks_to_search, 1):
            title = track.get('Title', '').strip()
            artist = track.get('Artist', '').strip()
            album = track.get('Album', '').strip()
            # Tidal album art captured at scrape time (empty on pre-artwork CSVs) —
            # shown in the HUD's hero panel while the track is being matched.
            art = (track.get('Art') or '').strip()
            video = (track.get('Video Art') or '').strip()

            if not title or not artist:
                progress.advance(match_task)
                km.overall(idx, n_tracks, "MATCHING ON SPOTIFY", pct=idx / n_tracks * MATCH_WEIGHT)
                continue

            km.current(f"{title} — {artist}",
                       f"{len(track_uris)} matched · {len(omitted)} missed", "exporting",
                       art=art, video=video)

            # Strategy 1: Title + Artist + Album
            res = spotify_call(sp.search, q=f"track:{clean_query(title)} artist:{clean_query(artist)} album:{clean_query(album)}", limit=5, type='track')
            items = filter_by_artist(res['tracks']['items'], artist)

            # Strategy 2: Title + Artist only
            if not items:
                res = spotify_call(sp.search, q=f"track:{clean_query(title)} artist:{clean_query(artist)}", limit=5, type='track')
                items = filter_by_artist(res['tracks']['items'], artist)

            # Strategy 3: Title only (broadest — catches cases where Tidal/Spotify artist names differ)
            if not items:
                res = spotify_call(sp.search, q=f"track:{clean_query(title)}", limit=10, type='track')
                items = filter_by_artist(res['tracks']['items'], artist)

            # No confident match — omit rather than risk a false track
            if items:
                best = pick_best_track(items)
                track_uris.append(best['uri'])
                spotify_artists = ', '.join(a['name'] for a in best['artists'])
                ui.found(f"{title} - {artist}",
                         f"{best['name']} - {spotify_artists}",
                         best.get('explicit', False))
            else:
                omitted.append({"Title": title, "Artist": artist, "Album": album,
                                "Source Playlist": track.get('Source Playlist', ''),
                                "Date Added": track.get('Date Added', ''),
                                "Art": art, "Video Art": video})
                ui.omitted(f"{title} - {artist}")

            progress.update(
                match_task,
                advance=1,
                detail=f"[{ui.OK}]{len(track_uris)} matched[/] · [{ui.ERR}]{len(omitted)} missed[/]",
            )
            km.overall(idx, n_tracks, "MATCHING ON SPOTIFY", pct=idx / n_tracks * MATCH_WEIGHT)

    # 5. Create Playlist & add tracks — the critical payload, done FIRST.
    # (Cover artwork used to come between playlist creation and track adding; a
    # single timed-out upload aborted the block and published an empty playlist.)
    ui.section("PUBLISH PLAYLIST")
    now = datetime.datetime.now()
    current_date = now.strftime("%m-%d-%y")
    current_timestamp = now.strftime("%m-%d-%y__%I.%M.%S %p")
    playlist_name = mode["title"].format(date=current_date)
    playlist_id = None
    missed_file = None
    tracks_added = 0
    publish_error = None

    try:
        ui.step(f"Creating playlist [{ui.VIOLET}]{playlist_name}[/]")
        km.overall(n_tracks, n_tracks, "PUBLISHING PLAYLIST", pct=92)
        km.current("Creating playlist", playlist_name, "exporting")
        playlist = spotify_call(sp.user_playlist_create, user_id, playlist_name, public=False)
        playlist_id = playlist['id']

        # 6. Add Tracks
        if track_uris:
            km.overall(n_tracks, n_tracks, "PUBLISHING PLAYLIST", pct=95)
            km.current("Adding tracks to playlist",
                       f"{len(track_uris)} tracks", "exporting")
            # Add in chunks of 100 as per API limits
            with ui.progress() as progress:
                add_task = progress.add_task(
                    f"[bold {ui.PRIMARY}]Adding tracks to playlist",
                    total=len(track_uris), detail="",
                )
                for i in range(0, len(track_uris), 100):
                    chunk = track_uris[i:i+100]
                    spotify_call(sp.playlist_add_items, playlist_id, chunk)
                    tracks_added += len(chunk)
                    progress.update(add_task, advance=len(chunk))
            ui.ok(f"Added [bold {ui.PRIMARY}]{tracks_added}[/] tracks to "
                  f"[{ui.VIOLET}]{playlist_name}[/]")
        else:
            ui.warn("No tracks were found on Spotify to add.")

        # Machine-readable handle for the AppleScript launcher — stdout ONLY.
        print(f"SPOTIFY_URI:spotify:playlist:{playlist_id}")

    except Exception as e:
        publish_error = e
        ui.err(f"Error creating/filling playlist: {e}")

    # 6b. Cover artwork — cosmetic, so every step is guarded: no artwork problem
    # may ever fail the export or stop tracks from reaching the playlist.
    if playlist_id and publish_error is None:
        artwork_to_upload = None
        try:
            from generate_artwork import generate_artwork
            os.makedirs("generated-artwork", exist_ok=True)
            dynamic_path = os.path.join(
                "generated-artwork",
                f"ARTWORK {current_timestamp}.jpg",
            )
            km.overall(n_tracks, n_tracks, "PUBLISHING PLAYLIST", pct=97)
            km.current("Rendering cover artwork", "HTML/CSS → Playwright → JPEG", "exporting")
            with ui.progress() as progress:
                art_task = progress.add_task(
                    f"[bold {ui.PRIMARY}]Rendering cover artwork",
                    total=None, detail="HTML/CSS → Playwright → JPEG",
                )
                generate_artwork(now, dynamic_path, theme=mode["theme"])
                progress.update(art_task, total=1, completed=1, detail="done")
            artwork_to_upload = dynamic_path
            ui.ok(f"Generated artwork → [{ui.PRIMARY}]{dynamic_path}[/]")
        except Exception as e:
            ui.warn(f"Dynamic artwork generation failed: {e}")
            if os.path.exists(ARTWORK_PATH):
                artwork_to_upload = ARTWORK_PATH
                ui.info(f"Falling back to static artwork: {ARTWORK_PATH}")

        try:
            if artwork_to_upload and os.path.exists(artwork_to_upload):
                km.overall(n_tracks, n_tracks, "PUBLISHING PLAYLIST", pct=99)
                km.current("Uploading cover art", "Sending artwork to Spotify", "exporting")
                with open(artwork_to_upload, 'rb') as img_file:
                    image_b64 = base64.b64encode(img_file.read()).decode('utf-8')
                spotify_call(sp.playlist_upload_cover_image, playlist_id, image_b64)
                ui.ok("Cover art uploaded to Spotify")
            else:
                ui.warn("No artwork available — skipping cover upload.")
        except Exception as e:
            ui.warn(f"Cover upload failed (playlist keeps its tracks): {e}")

    # 7. Save omitted tracks to missed-tracks/
    if omitted:
        os.makedirs("missed-tracks", exist_ok=True)
        missed_file = os.path.join("missed-tracks", f"MISSED {current_timestamp}.csv")
        keys = ["Title", "Artist", "Album", "Source Playlist", "Date Added", "Art", "Video Art"]
        with open(missed_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=keys)
            writer.writeheader()
            writer.writerows(omitted)
        ui.warn(f"{len(omitted)} track(s) omitted (no confident Spotify match) → {missed_file}")
        for t in omitted:
            ui.info(f"{t['Title']} - {t['Artist']}")
        # Machine-readable handle for the orchestrator's results page — stdout ONLY.
        print(f"MISSED_FILE:{missed_file}")
    else:
        ui.ok("All tracks matched successfully — nothing omitted.")

    # 8. Closing summary card — reports what actually happened, and a publish
    # failure exits non-zero so the pipeline (and its HUD) reports the failure
    # instead of celebrating an empty playlist.
    if publish_error is not None:
        ui.summary("BROADCAST FAILED", {
            "Playlist": playlist_name if playlist_id else "— not created —",
            "Tracks added": f"{tracks_added} of {len(track_uris)}",
            "Error": str(publish_error),
            "Snapshot": csv_file,
        })
        sys.exit(1)

    ui.summary("BROADCAST COMPLETE", {
        "Playlist": playlist_name,
        "Tracks added": tracks_added,
        "Omitted": len(omitted),
        "Snapshot": csv_file,
        "Missed log": missed_file or "—",
    })

if __name__ == "__main__":
    main()
