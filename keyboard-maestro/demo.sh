#!/usr/bin/env bash
# Preview the progress HUD in its own 1920×1250 window — no app launch, no real
# scrape, no Spotify. Replays the scripted demo run (demo_run.js) against real
# Tidal cover URLs.
#
#   ./demo.sh          happy path — scrape → match → results mosaic
#   ./demo.sh fail     export fails after matching
#   ./demo.sh empty    scrape finds zero new tracks
#
# Opens a chromeless Chrome "app mode" window (Beta preferred — it's the one
# Adrian's macros use) with a throwaway profile so --window-size is honored
# even while a normal Chrome session is running. The tiny static server keeps
# running afterward so the window can be reloaded; it's idempotent across runs.
set -euo pipefail
cd "$(dirname "$0")"

PORT=8741
VARIANT="${1:-}"
URL="http://localhost:${PORT}/progress_window.html?demo${VARIANT:+=$VARIANT}"

if ! nc -z localhost "$PORT" 2>/dev/null; then
    nohup python3 -m http.server "$PORT" --directory . >/dev/null 2>&1 &
    # give the server a beat to bind before Chrome asks for the page
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        nc -z localhost "$PORT" 2>/dev/null && break
        sleep 0.2
    done
fi

CHROME=""
for app in "Google Chrome Beta" "Google Chrome"; do
    if [ -d "/Applications/${app}.app" ]; then CHROME="$app"; break; fi
done

if [ -n "$CHROME" ]; then
    open -na "$CHROME" --args \
        --app="$URL" \
        --window-size=1920,1250 \
        --window-position=0,0 \
        --user-data-dir="${TMPDIR:-/tmp}/nmr-hud-demo-profile" \
        --no-first-run --no-default-browser-check
else
    open "$URL"   # default browser, unsized — better than nothing
fi
