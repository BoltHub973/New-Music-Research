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

from concurrent.futures import ThreadPoolExecutor
import datetime
import os
import sys

import spotipy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_to_spotify as ex  # reuses .env loading, auth + retries, MODES


def today_playlist_name(mode="this-week"):
    return ex.format_playlist_name(mode, timestamped=False)


def _fetch_playlists_page(access_token, offset):
    client = spotipy.Spotify(auth=access_token, requests_timeout=ex.REQUEST_TIMEOUT)
    return ex.spotify_call(client.current_user_playlists, limit=50, offset=offset) or {}


def find_todays_playlists(sp, user_id, mode="this-week", access_token=None, first_page=None):
    """Return ids of the user's own playlists named exactly like today's run for mode."""
    name = today_playlist_name(mode)
    page0 = first_page if first_page is not None else ex.spotify_call(
        sp.current_user_playlists, limit=50, offset=0
    ) or {}
    pages = [page0]
    total = min(int(page0.get("total") or 0), 1000)
    remaining_offsets = list(range(50, total, 50))
    if remaining_offsets:
        token = access_token
        if not token and getattr(sp, "auth_manager", None):
            tok_info = sp.auth_manager.get_cached_token()
            token = tok_info.get("access_token") if tok_info else None
        if token:
            with ThreadPoolExecutor(max_workers=min(8, len(remaining_offsets))) as pool:
                pages.extend(pool.map(lambda off: _fetch_playlists_page(token, off), remaining_offsets))
        else:
            for off in remaining_offsets:
                pages.append(ex.spotify_call(sp.current_user_playlists, limit=50, offset=off) or {})

    ids = []
    seen = set()
    for page in pages:
        for pl in (page or {}).get("items") or []:
            if (pl and pl.get("name") == name
                    and (pl.get("owner") or {}).get("id") == user_id):
                pid = pl.get("id")
                if pid and pid not in seen:
                    seen.add(pid)
                    ids.append(pid)
    return ids


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
    mode = "this-week"
    if action == "check" and "--mode" in sys.argv[2:]:
        idx = sys.argv.index("--mode")
        if idx + 1 < len(sys.argv) and sys.argv[idx + 1] in ex.MODES:
            mode = sys.argv[idx + 1]

    if not ex.CLIENT_ID or not ex.CLIENT_SECRET:
        print("CHECK_ERROR:missing Spotify credentials in "
              + os.path.join(os.getcwd(), ".env"))
        return

    try:
        sp = ex.build_spotify_client()
        auth = sp.auth_manager
        # validate_token() returns a usable token or None; it refreshes an
        # expired one non-interactively but never opens the consent flow.
        tok_info = auth.validate_token(auth.cache_handler.get_cached_token())
        if not tok_info:
            print("CHECK_ERROR:re-authorization needed — the run will open the consent page")
            return
        access_token = tok_info.get("access_token") if isinstance(tok_info, dict) else None
    except Exception as e:
        print(f"CHECK_ERROR:auth failed: {e}")
        return

    if action == "check":
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                me_fut = pool.submit(
                    lambda: ex.spotify_call(
                        spotipy.Spotify(auth=access_token, requests_timeout=ex.REQUEST_TIMEOUT).me
                    )
                ) if access_token else pool.submit(lambda: ex.spotify_call(sp.me))
                p0_fut = pool.submit(_fetch_playlists_page, access_token, 0) if access_token else pool.submit(
                    lambda: ex.spotify_call(sp.current_user_playlists, limit=50, offset=0) or {}
                )
                user_id = me_fut.result()["id"]
                page0 = p0_fut.result()
            ids = find_todays_playlists(sp, user_id, mode=mode, access_token=access_token, first_page=page0)
            print(("EXISTS:" + ",".join(ids)) if ids else "NONE")
        except Exception as e:
            print(f"CHECK_ERROR:auth failed: {e}")
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
