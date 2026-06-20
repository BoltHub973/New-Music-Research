# 🪁 Generate Spotify Playlist featuring the latest Hip-Hop & R&B tracks

Collects new tracks from curated Tidal playlists (via the Tidal API) and exports them directly into a new Spotify playlist.

---

## ▶️ How to Run

```bash
python3 track_playlists.py
```

That's it. The script handles everything automatically from start to finish.

Prefer a window over a terminal? Build the standalone **[New Music Research](app/)**
macOS app (`cd app && ./build.sh`). Launching it runs the whole pipeline and shows the
live progress HUD in a real, resizable window — no Keyboard Maestro required.

---

## ✅ What to Expect

1. **Tidal is fetched via its API** — every playlist in `playlists.json` is checked for tracks added **within the last 7 days**. No browser, no scraping — the run takes seconds and can't trip Tidal's bot detection (which once blocked this machine's IP when this step was a headless-browser scraper)
   - All artists on a track are captured (not just the first), so featuring/co-artist info is preserved
2. **A CSV is saved** — a timestamped file is created in the `scraped-files` folder, e.g.:
   ```
   scraped-files/SCRAPED 02-20-26__10.15.00 PM.csv
   ```
3. **A Spotify playlist is created** — a new private playlist is added to your Spotify account named:
   ```
   🪁 DX 02-20-26
   ```
   A **custom 500×500 cover** is generated on the fly and uploaded — a dark, purple, futuristic "pirate radio broadcast" slate with the playlist's creation date stamped vertically (`MAY` / `22` / `26`). The generated JPEG is also saved to `generated-artwork/` as a historical record.
4. **All found tracks are added** to that playlist automatically using a 3-step search strategy:
   - **Strategy 1**: Title + Artist + Album (most precise)
   - **Strategy 2**: Title + Artist only
   - **Strategy 3**: Title only (broadest fallback — catches cases where Tidal/Spotify artist names differ)
5. **Live progress screen** — the whole run renders a futuristic dark HUD with phase rules and live progress bars (powered by [`rich`](https://github.com/Textualize/rich)), narrating every key activity: which playlist is being scanned, how many tracks were scanned vs. recent, search matches/misses in real time, artwork rendering, cover upload, and track adds. Each matched track shows what Spotify actually returned, e.g.:
   ```
   ✓ EXPLICIT  Expectations - Adamn Killa  →  Expectations - Adamn Killa
   ✕ OMITTED   Obscure Track - Unknown
   ```
   This makes it easy to spot cases where the Spotify match is a different version of the song.

   > All of this UI is written to **stderr**; **stdout** carries only the single machine-readable `SPOTIFY_URI:` line, so the AppleScript launcher below keeps working and its captured output stays clean.
6. **The playlist opens in the Spotify desktop app** automatically once it's been created
7. **A Keyboard Maestro macro is triggered** _(optional)_ — if `KM_MACRO_UUID` is set in `.env`, the macro is fired via `osascript` at the very end

> If a track exists on multiple Tidal playlists, duplicates are removed before export.

---

## 📂 Data Persistence

The project organizes its output into two main directories:

- **`scraped-files/`** — Stores timestamped CSVs of every matching track found on Tidal (added in the last 7 days). These serve as a historical record of what was collected before the Spotify matching process begins.
- **`missed-tracks/`** — If a track found on Tidal cannot be confidently matched on Spotify (e.g., due to different artist formatting or if the track is not yet on Spotify), it is saved here in a `MISSED` CSV. This makes it easy to manually find and add any tracks the script couldn't automate.
- **`generated-artwork/`** — Stores the timestamped JPEG cover art generated for each playlist run (e.g. `ARTWORK 02-20-26__10.15.00 PM.jpg`). Each cover is rendered fresh via `generate_artwork.py` (HTML/CSS → Playwright → JPEG) and stamped with that day's date. To preview a cover without creating a playlist, run `python3 generate_artwork.py 2026-05-22`.

---

## 📋 Playlists Tracked

| Playlist                 | URL                                                                     |
| :----------------------- | :---------------------------------------------------------------------- |
| Rap Bars & Melodies      | [Open](https://tidal.com/playlist/90bb6aed-d267-4766-952e-1360c1e5c6ed) |
| Thoro Hip-Hop            | [Open](https://tidal.com/playlist/34c543c9-bb74-4b79-91a8-feb6d815f43c) |
| Women of Hip-Hop         | [Open](https://tidal.com/playlist/6be1934e-3c52-4401-9001-676d05409083) |
| Hip-Hop & R&B Club Music | [Open](https://tidal.com/playlist/640fb9c7-14c3-4e99-b1c4-c74114fd776e) |
| New Midwest              | [Open](https://tidal.com/playlist/1b9478ed-c2ed-43db-8391-71fac43238fb) |
| Hip-Hop: RISING          | [Open](https://tidal.com/playlist/5eec3912-d862-4159-9a4c-a393b826a011) |
| Viral Hype               | [Open](https://tidal.com/playlist/ed9f3bf6-2149-4f18-b664-a56ff27ea130) |
| New West Coast           | [Open](https://tidal.com/playlist/496b977b-dd14-4ce7-9cb3-bfbd3e950229) |
| New South                | [Open](https://tidal.com/playlist/117dd55c-2c0b-453f-87c7-8b453286e92d) |
| Drill Hype               | [Open](https://tidal.com/playlist/6896171c-2b4a-47bf-b044-ae3886a521d7) |
| New East Coast           | [Open](https://tidal.com/playlist/7da79d8b-32d5-4d0e-be93-5021761805c4) |

To add or remove playlists, edit `playlists.json`.

---

## ⚙️ Setup

### Requirements

```bash
pip install tidalapi playwright spotipy python-dotenv rich
playwright install chromium
```

> You don't actually need to run this — `bootstrap.py` auto-installs any missing packages on first run. (Playwright/Chromium is only used by `generate_artwork.py` to render the playlist cover — Tidal itself is reached through its API, not a browser.)

### Tidal login (one-time)

```bash
python3 tidal_login.py
```

Prints a `link.tidal.com` URL — open it on any device (your phone on cellular data works even if this network is blocked by Tidal's website) and approve. The session token is saved to `~/.config/new-music-research/tidal-session.json` and refreshes itself on every run.

### Environment Variables

Create a `.env` file in the project root:

```
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
KM_MACRO_UUID=your_macro_uuid   # optional — omit to skip the KM trigger
```

Get these from the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
Make sure `http://127.0.0.1:8888/callback` is added as a Redirect URI in your app settings.

---

## 🍎 Run from Anywhere (AppleScript)

You can trigger the full pipeline from anywhere on your Mac — via **Script Editor**, **Raycast**, **Alfred**, **Keyboard Maestro**,or any AppleScript-compatible launcher.

Save the following as a `.scpt` file in Script Editor:

```applescript
set projectPath to "your path here"

-- Run the Python script and capture output
set scriptOutput to do shell script "cd " & quoted form of projectPath & " && python3 track_playlists.py"

-- Find the Spotify URI from the output
set spotifyURI to ""
repeat with outputLine in paragraphs of scriptOutput
    if outputLine starts with "SPOTIFY_URI:" then
        set spotifyURI to text 13 thru -1 of outputLine
        exit repeat
    end if
end repeat

-- Open the playlist in the Spotify desktop app
if spotifyURI is not "" then
    tell application "Spotify"
        activate
        open location spotifyURI
    end tell
else
    display dialog "Playlist was created but could not find the Spotify URI in the script output." buttons {"OK"} default button "OK"
end if
```

**How it works:**

1. Runs `track_playlists.py`, which fetches the Tidal playlists via the API and calls `export_to_spotify.py`
2. `export_to_spotify.py` prints a `SPOTIFY_URI:` tag after the playlist is created
3. AppleScript captures that URI and opens the playlist directly in the **Spotify desktop app**

> **Note:** `track_playlists.py` now opens the playlist itself (via `open spotify:playlist:…`) as soon as the run completes, so the playlist opens even from a fire-and-forget launcher that doesn't capture stdout (e.g. a Keyboard Maestro macro that runs the pipeline in its own iTerm window). The `SPOTIFY_URI:` line is still printed for the AppleScript recipe above, so both paths keep working.
