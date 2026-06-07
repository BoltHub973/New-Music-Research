import bootstrap
import asyncio
import csv
import json
import os
import sys
import datetime
import subprocess
import ui
import km_progress as km
from dotenv import load_dotenv
from playwright.async_api import async_playwright

load_dotenv()

# Date buckets that count as "recent" — shared by the scraper and the live counters.
RECENT_KEYWORDS = {"today", "yesterday", "this week"}


# Generate output filename with timestamp
# Format: scraped-files/SCRAPED MM-dd-yy__h.mm.ss a.csv
os.makedirs("scraped-files", exist_ok=True)
current_time = datetime.datetime.now().strftime("%m-%d-%y__%I.%M.%S %p")
output_file = os.path.join("scraped-files", f"SCRAPED {current_time}.csv")

def trigger_km_macro(uuid):
    """Triggers a Keyboard Maestro macro by its UUID using osascript."""
    script = f'tell application "Keyboard Maestro Engine" to do script "{uuid}"'
    try:
        subprocess.run(["osascript", "-e", script], check=True)
        ui.ok(f"Triggered Keyboard Maestro macro {uuid}")
    except subprocess.CalledProcessError as e:
        ui.err(f"Failed to trigger KM macro: {e}")

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

async def extract_visible_tracks(page):
    """Extract tracks currently visible in the virtualized DOM."""
    return await page.evaluate('''() => {
        const tracks = [];
        const rows = document.querySelectorAll('[data-test="tracklist-row"]');
        
        rows.forEach(row => {
            const dateAddedCell = row.querySelector('[data-test="track-row-date-added"]');
            if (!dateAddedCell) return;
            
            const dateText = dateAddedCell.innerText.trim();
            const lowerDateText = dateText.toLowerCase();
            
            // Collect ALL tracks — we filter by date below but also need
            // to know when we've scrolled past the recent section.
            const titleElement = row.querySelector('[data-test="table-row-title"] [data-test="table-cell-title"]');
            const artistElements = row.querySelectorAll('[data-test="track-row-artist"] a'); 
            const albumElement = row.querySelector('[data-test="track-row-album"] a');
            const artistNames = Array.from(artistElements).map(a => a.innerText.trim());
            
            tracks.push({
                "Title": titleElement ? titleElement.innerText.trim() : "Unknown Title",
                "Artist": artistNames.length > 0 ? artistNames.join(', ') : "Unknown Artist",
                "Album": albumElement ? albumElement.innerText.trim() : "Unknown Album",
                "Date Added": dateText
            });
        });
        return tracks;
    }''')

def _count_recent(tracks):
    """How many of the scanned tracks fall in the recent date buckets."""
    return sum(
        1 for t in tracks if t["Date Added"].strip().lower() in RECENT_KEYWORDS
    )

async def scrape_playlist(page, playlist, progress, overall):
    """Scrape one playlist, narrating live scroll/scan progress under `progress`.

    A transient sub-task shows the indeterminate scroll with running
    scanned/recent counts; on completion it's removed and replaced by a
    persistent summary line, then the `overall` task is advanced.
    """
    # total=None → an indeterminate, pulsing bar (we don't know the track count yet)
    sub = progress.add_task(
        f"[{ui.VIOLET}]  └─ {playlist['name']}", total=None, detail="opening…"
    )
    km.current(playlist['name'], "opening…", "opening")
    try:
        await page.goto(playlist['url'])
        progress.update(sub, detail="waiting for tracklist…")
        km.current(playlist['name'], "waiting for tracklist…", "opening")
        # Wait for the tracklist to load
        try:
            await page.wait_for_selector('[data-test="tracklist-row"]', timeout=10000)
        except:
            progress.remove_task(sub)
            ui.warn(f"{playlist['name']} — timed out waiting for tracklist")
            km.log(f"{playlist['name']} — timed out waiting for tracklist")
            progress.advance(overall)
            return []

        # Give the DOM a moment to fully render after initial load
        await asyncio.sleep(1)

        # Tidal uses a virtualized list: only ~16-18 rows exist in the DOM
        # at any given time. We must scroll the #main container (not window)
        # and collect tracks at each scroll position, deduplicating by key.
        seen_keys = set()
        all_tracks = []
        no_new_tracks_count = 0

        for scroll_attempt in range(50):  # Max 50 scroll attempts (handles 60+ track playlists)
            # Extract whatever tracks are currently in the DOM
            visible = await extract_visible_tracks(page)

            new_this_round = 0
            for t in visible:
                key = (t["Title"], t["Artist"])
                if key not in seen_keys:
                    seen_keys.add(key)
                    all_tracks.append(t)
                    new_this_round += 1

            progress.update(
                sub,
                detail=f"scanned {len(all_tracks)} · {_count_recent(all_tracks)} recent",
            )
            km.current(
                playlist['name'],
                f"scanned {len(all_tracks)} · {_count_recent(all_tracks)} recent",
                "scanning",
            )

            if new_this_round == 0:
                no_new_tracks_count += 1
                if no_new_tracks_count >= 3:
                    break  # Three consecutive scrolls with no new tracks — we're at the end
            else:
                no_new_tracks_count = 0

            # Scroll the #main container (Tidal's actual scrollable element)
            await page.evaluate('document.getElementById("main").scrollBy(0, 600)')
            await asyncio.sleep(0.8)

        # Filter to only recent tracks (today / yesterday / this week)
        tracks_data = [
            t for t in all_tracks
            if t["Date Added"].strip().lower() in RECENT_KEYWORDS
        ]

        # Add source playlist to each track
        for track in tracks_data:
            track["Source Playlist"] = playlist['name']

        progress.remove_task(sub)
        if tracks_data:
            ui.ok(
                f"[{ui.VIOLET}]{playlist['name']}[/] — "
                f"[bold {ui.PRIMARY}]{len(tracks_data)}[/] recent "
                f"[{ui.MUTED}]of {len(all_tracks)} scanned[/]"
            )
            km.log(f"{playlist['name']} — {len(tracks_data)} recent of {len(all_tracks)} scanned")
        else:
            ui.info(f"{playlist['name']} — 0 recent of {len(all_tracks)} scanned")
            km.log(f"{playlist['name']} — 0 recent of {len(all_tracks)} scanned")
        progress.advance(overall)
        return tracks_data

    except Exception as e:
        progress.remove_task(sub)
        ui.err(f"Error scraping {playlist['name']}: {e}")
        km.log(f"Error scraping {playlist['name']}: {e}")
        progress.advance(overall)
        return []

async def main():
    ui.banner()
    km.reset()

    playlists = load_playlists()
    if not playlists:
        km.finish(ok=False, message="playlists.json not found or empty")
        return

    all_tracks = []

    # ── PHASE 1 — Scrape Tidal ───────────────────────────────────────────────
    ui.phase(1, 3, "SCRAPE TIDAL")
    km.phase(1, 3, "SCRAPE TIDAL")
    km.overall(0, len(playlists), "Scanning playlists")
    ui.step(f"Launching headless browser for {len(playlists)} playlists")

    async with async_playwright() as p:
        try:
            browser = await p.chromium.launch(headless=True)
        except Exception as e:
            err_str = str(e)
            if "Executable doesn't exist" in err_str or "playwright install" in err_str:
                ui.warn("Playwright browser not found — installing Chromium…")
                subprocess.run([sys.executable, "-m", "playwright", "install"], check=True)
                browser = await p.chromium.launch(headless=True)
            else:
                raise
        context = await browser.new_context(viewport={'width': 1920, 'height': 1080})
        page = await context.new_page()

        with ui.progress() as progress:
            overall = progress.add_task(
                f"[bold {ui.PRIMARY}]Scanning playlists",
                total=len(playlists),
                detail="",
            )
            for idx, playlist in enumerate(playlists):
                tracks = await scrape_playlist(page, playlist, progress, overall)
                all_tracks.extend(tracks)
                km.overall(idx + 1, len(playlists))

        await browser.close()

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
        try:
            # Stream live (no capture): the exporter renders its own progress to
            # stderr while its single SPOTIFY_URI line flows through stdout to
            # any AppleScript launcher watching this process.
            subprocess.run([sys.executable, "export_to_spotify.py", output_file], check=True)
            km.finish(ok=True, message="Playlist created — opening in Spotify")
        except subprocess.CalledProcessError as e:
            ui.err(f"Spotify export failed: {e}")
            km.finish(ok=False, message="Spotify export failed")
        except Exception as e:
            ui.err(f"An error occurred during export: {e}")
            km.finish(ok=False, message="An error occurred during export")

    else:
        ui.warn("No matching tracks found (Today / Yesterday / This Week).")
        km.finish(ok=True, message="No new tracks found (Today / Yesterday / This Week)")
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
    asyncio.run(main())
