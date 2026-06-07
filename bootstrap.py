import sys
import subprocess

def bootstrap():
    packages = {
        "python-dotenv": "dotenv",
        "spotipy": "spotipy",
        "playwright": "playwright",
        "rich": "rich"
    }

    in_venv = sys.prefix != sys.base_prefix

    # All bootstrap chatter goes to stderr so stdout stays reserved for the
    # pipeline's machine-readable output (e.g. the SPOTIFY_URI: line the
    # AppleScript launcher parses), even on a first-ever install run.
    for pkg_name, imp_name in packages.items():
        try:
            __import__(imp_name)
        except ImportError:
            print(f"[{pkg_name}] is missing. Installing...", file=sys.stderr)
            cmd = [sys.executable, "-m", "pip", "install"]
            if not in_venv:
                cmd.append("--user")
            cmd.append(pkg_name)
            try:
                subprocess.run(cmd, check=True, stdout=sys.stderr)
                print(f"Successfully installed [{pkg_name}].", file=sys.stderr)
            except Exception as e:
                print(f"Error: Failed to install [{pkg_name}]: {e}", file=sys.stderr)
                sys.exit(1)

bootstrap()
