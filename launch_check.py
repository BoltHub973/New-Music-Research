"""
Launch-time helper for the New Music Research app.

    python3 launch_check.py check           → EXISTS:<id>[,<id>…] | NONE | CHECK_ERROR:<why>
    python3 launch_check.py delete <id>…    → DELETED:<id> / DELETE_ERROR:<id>:<why> per id

`check` looks through the user's own playlists for any whose name is exactly
today's This-Week playlist title (🪁 DX MM-DD-YY). The app uses the result to
offer a re-scrape before kicking off the launch run.

`delete` removes the given playlists from the library — Spotify's notion of
deleting a playlist you own.

STRICTLY NON-INTERACTIVE: auth uses the cached token only (refreshing it is
fine — that's a plain HTTPS call). If consent is needed (first run, scope
change, 6-month refresh-token expiry) this prints CHECK_ERROR and exits so the
app falls back to a normal run — the exporter then drives the browser consent
where failure is visible in the HUD, instead of hanging the launch invisibly.

Machine-readable output goes to stdout only; run it from the project/data dir
(cwd), exactly like the pipeline itself.
"""

import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_to_spotify as ex  # reuses .env loading, auth + retries, MODES


def today_this_week_name():
    return ex.MODES["this-week"]["title"].format(
        date=datetime.datetime.now().strftime("%m-%d-%y"))


def find_todays_playlists(sp, user_id):
    """Return ids of the user's own playlists named exactly like today's run."""
    name = today_this_week_name()
    ids = []
    offset = 0
    while True:
        page = ex.spotify_call(sp.current_user_playlists, limit=50, offset=offset)
        items = (page or {}).get("items") or []
        for pl in items:
            if (pl and pl.get("name") == name
                    and (pl.get("owner") or {}).get("id") == user_id):
                ids.append(pl["id"])
        if len(items) < 50 or offset >= 950:
            return ids
        offset += 50


def delete_playlist(sp, playlist_id):
    """Remove a playlist from the library ( = delete, for playlists you own).

    The modern endpoint is DELETE /me/library?uris=… (Feb 2026 library
    consolidation; spotipy 2.26 has no wrapper yet, hence the private _delete).
    The deprecated unfollow endpoint is the fallback while it still answers.
    """
    try:
        ex.spotify_call(sp._delete, "me/library",
                        uris=f"spotify:playlist:{playlist_id}")
    except Exception:
        ex.spotify_call(sp.current_user_unfollow_playlist, playlist_id)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "check"

    if not ex.CLIENT_ID or not ex.CLIENT_SECRET:
        print("CHECK_ERROR:missing Spotify credentials in "
              + os.path.join(os.getcwd(), ".env"))
        return

    try:
        sp = ex.build_spotify_client()
        auth = sp.auth_manager
        # validate_token() returns a usable token or None; it refreshes an
        # expired one non-interactively but never opens the consent flow.
        if not auth.validate_token(auth.cache_handler.get_cached_token()):
            print("CHECK_ERROR:re-authorization needed — the run will open the consent page")
            return
        user_id = ex.spotify_call(sp.me)["id"]
    except Exception as e:
        print(f"CHECK_ERROR:auth failed: {e}")
        return

    if action == "check":
        ids = find_todays_playlists(sp, user_id)
        print(("EXISTS:" + ",".join(ids)) if ids else "NONE")
    elif action == "delete":
        for pid in sys.argv[2:]:
            try:
                delete_playlist(sp, pid)
                print(f"DELETED:{pid}")
            except Exception as e:
                print(f"DELETE_ERROR:{pid}:{e}")
    else:
        print(f"CHECK_ERROR:unknown action {action!r}")


if __name__ == "__main__":
    main()
