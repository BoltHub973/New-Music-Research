"""One-time (re-)authentication for the Tidal API.

Prints a link.tidal.com URL — open it on any device (your phone on cellular
data works even if this network is blocked by Tidal's website) and approve.
The session token is saved outside the repo and refreshed automatically by
every pipeline run, so this normally only needs to happen once.
"""
import sys
from pathlib import Path

import tidalapi

SESSION_FILE = Path.home() / ".config" / "new-music-research" / "tidal-session.json"


def main():
    SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    session = tidalapi.Session()
    try:
        ok = session.login_session_file(SESSION_FILE)
    except TimeoutError:
        print("Login link expired — run this again and approve within 5 minutes.", file=sys.stderr)
        sys.exit(1)
    if not ok:
        print("Tidal login failed.", file=sys.stderr)
        sys.exit(1)
    print(f"Logged in. Session saved to {SESSION_FILE}")


if __name__ == "__main__":
    main()
