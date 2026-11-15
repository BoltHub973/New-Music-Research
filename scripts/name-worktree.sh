#!/bin/zsh
#
# name-worktree.sh — give a checkout a human-readable name.
#
# Worktrees are created with machine names ("playlist-emoji-display-name-977537").
# The app's worktree menu shows a readable one instead: a name set here if there
# is one, otherwise the Claude Code chat's own title, otherwise the branch cleaned
# up ("claude/playlist-emoji-display-name-977537" → "Playlist Emoji Display Name").
#
# Names live in ~/.claude/worktree-labels.json, keyed by checkout path — outside
# the repo, so naming a worktree never shows up in git status or a diff.
#
# The labels file is global, so this script is project-independent: drop it in each
# project's scripts/ (so the project's CLAUDE.md can point at it), or keep one copy
# at ~/.claude/scripts/name-worktree.sh. Either way it needs no per-project edits.
#
# Usage:
#   name-worktree.sh "Emoji + cancel button"     # names the current checkout
#   name-worktree.sh /path/to/checkout "Name"    # names a specific checkout
#   name-worktree.sh --list                      # show every stored name
#   name-worktree.sh --clear [path]              # drop back to the derived name

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LABELS="$HOME/.claude/worktree-labels.json"

usage() { print -r -- "usage: name-worktree.sh \"Human Name\" | <path> \"Human Name\" | --list | --clear [path]"; exit 1 }

case "${1:-}" in
    ""|-h|--help) usage ;;
    --list)
        python3 - "$LABELS" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path)) if os.path.exists(path) else {}
if not data:
    print("No worktree names set.")
for k, v in sorted(data.items(), key=lambda kv: kv[1].lower()):
    print(f"{v}\n    {k}")
PY
        exit 0 ;;
    --clear) target="$(cd "${2:-$PWD}" 2>/dev/null && pwd)" || exit 1; label="" ;;
    /*) target="$(cd "$1" 2>/dev/null && pwd)" || { print -r -- "No such checkout: $1"; exit 1 }
        label="${2:-}"; [[ -n "$label" ]] || usage ;;
    *)  target="$PWD"; label="$1" ;;
esac

# Only a linked git worktree (.git is a file) may take a worktree label; naming
# the main checkout (.git is a directory) makes the menu bar show a branch
# nickname beside the ● main dot instead of "Main".
if [[ -n "$label" ]]; then
    if [[ -d "$target/.git" ]]; then
        print -r -- "error: $target is the main checkout — only linked worktrees take a label" >&2
        exit 1
    elif [[ ! -f "$target/.git" ]]; then
        print -r -- "error: $target is not a linked git worktree (.git file not found)" >&2
        exit 1
    fi
fi

python3 - "$LABELS" "$target" "$label" <<'PY'
import json, os, sys
path, target, label = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except ValueError:
        data = {}
# Purge any accidental main-checkout entries (.git is a directory)
for k in list(data.keys()):
    if os.path.isdir(os.path.join(k, ".git")):
        data.pop(k, None)
if label:
    data[target] = label
    print(f'"{label}"  →  {target}')
else:
    data.pop(target, None)
    print(f"cleared  →  {target}  (falls back to the derived name)")
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
