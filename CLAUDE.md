# New Music Research — notes for Claude

## The app bundles the Python pipeline (self-contained builds)

- `app/build.sh` copies the pipeline (`*.py`, `keyboard-maestro/km_progress.py`,
  `Playlist-Artwork.jpg`) into `Contents/Resources/pipeline/`. The installed app
  always runs its **bundled** copy — Python edits only take effect after a rebuild.
- **After merging any change to `app/` or the pipeline `.py` files into main,
  rebuild + reinstall: `cd app && ./build.sh`.** Do this automatically as part of
  any commit-and-merge flow in this repo.
- Building from a branch or worktree is always safe: the app is self-consistent
  wherever it's built from. Never set `NMRProjectDir` to a worktree to test code —
  just rebuild.
- `NMRProjectDir` (defaults domain `com.adrian.new-music-research`) points at the
  pipeline's *data* dir — `playlists.json`, `.env`, Spotify token caches,
  `scraped-files/`, `missed-tracks/`, `generated-artwork/`. Normally unset
  (defaults to `~/Development/New Music Research`). `NMRPipelineDir` overrides
  where the *code* is loaded from (stub testing only).

## Gotchas

- Launching the app runs `launch_check.py check` first: if a This-Week playlist
  for today already exists in Spotify it prompts (Y/N) to delete + re-scrape,
  then to run Last Week instead; otherwise it immediately starts a real
  This-Week scrape→export (creates a real Spotify playlist). Don't launch it
  just to "check" something.
- Changing `SCOPE` in `export_to_spotify.py` invalidates the cached token — the
  next run opens the browser once for re-consent. That's expected, not a bug.
- OAuth consent uses `http://127.0.0.1:8899/callback` — **8899, not 8888**,
  because Adrian's Spotify-Playlists-Dashboard app permanently occupies 8888
  (discovered 2026-07-10 when consent died with `[Errno 48]`). The URI must be
  registered in the Spotify Developer Dashboard. `launch_check.py` never starts
  the consent flow (cached token only) — only the exporter may, where failure
  is visible in the HUD.
- The pipeline's data/config/state is cwd-relative on purpose; scripts resolve
  their own imports/assets `__file__`-relative. Keep that split when editing.
  In particular `.env` must be loaded as `load_dotenv(os.path.join(os.getcwd(),
  ".env"))` — a bare `load_dotenv()` walks up from the *script's* dir, which is
  the app bundle for bundled runs (this broke the app on 2026-07-10).
- Spotify's public Web API has **no playlist-pin endpoint** (checked July 2026 —
  Feb 2026 changelog/migration guide). An auto-pin feature was built and then
  removed at Adrian's request (2026-07-10) because it could only ever report
  failure. Don't re-add pinning code or "couldn't pin" UI unless Spotify ships
  an official endpoint.
