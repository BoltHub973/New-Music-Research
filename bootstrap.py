import sys
import subprocess

def bootstrap():
    packages = {
        "python-dotenv": "dotenv",
        "spotipy": "spotipy",
        "playwright": "playwright"
    }

    in_venv = sys.prefix != sys.base_prefix

    for pkg_name, imp_name in packages.items():
        try:
            __import__(imp_name)
        except ImportError:
            print(f"[{pkg_name}] is missing. Installing...")
            cmd = [sys.executable, "-m", "pip", "install"]
            if not in_venv:
                cmd.append("--user")
            cmd.append(pkg_name)
            try:
                subprocess.run(cmd, check=True)
                print(f"Successfully installed [{pkg_name}].")
            except Exception as e:
                print(f"Error: Failed to install [{pkg_name}]: {e}", file=sys.stderr)
                sys.exit(1)

bootstrap()
