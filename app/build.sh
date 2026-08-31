#!/usr/bin/env bash
set -euo pipefail

# Pure-Swift build → /Applications. No Xcode project.
PRODUCT="NewMusicResearch"            # SPM product + CFBundleExecutable
APP_DISPLAY="New Music Research"      # .app bundle display name
BUNDLE_ID="com.adrian.new-music-research"

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SOURCE_DIR}/.." && pwd)"

# Build into /Applications so Gatekeeper doesn't refuse to launch (it quarantines
# executables in cloud-synced folders).
APP_PATH="/Applications/${APP_DISPLAY}.app"

echo "Building ${APP_DISPLAY}…"

# 1. Clean prior bundle.
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# 2. Compile.
cd "${SOURCE_DIR}"
swift build -c release --product "${PRODUCT}"
cp ".build/release/${PRODUCT}" "${APP_PATH}/Contents/MacOS/${PRODUCT}"

# 3. Info.plist + build stamp.
PLIST_DST="${APP_PATH}/Contents/Info.plist"
cp "Resources/Info.plist" "${PLIST_DST}"

COMMIT_URL=""
if git -C "${REPO_ROOT}" rev-parse --git-dir > /dev/null 2>&1; then
    COMMIT_TS=$(git -C "${REPO_ROOT}" log -1 --format=%cI origin/main 2>/dev/null \
        || git -C "${REPO_ROOT}" log -1 --format=%cI HEAD)
    BUILD_NUMBER=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${COMMIT_TS}" "+%Y%m%d.%H%M" 2>/dev/null || date "+%Y%m%d.%H%M")
    SHORT_SHA=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)
    PRETTY_DATE=$(date "+%m-%d-%y %-I:%M %p")
    DISPLAY="${PRETTY_DATE} · ${SHORT_SHA}"

    # Hyperlink target for the About panel: the GitHub commit page for HEAD. Derive the
    # repo's https URL from the origin remote (handles git@ / ssh:// / https forms).
    FULL_SHA=$(git -C "${REPO_ROOT}" rev-parse HEAD)
    REMOTE_URL=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "")
    if [ -n "${REMOTE_URL}" ]; then
        WEB_URL=$(printf '%s' "${REMOTE_URL}" \
            | sed -E 's#^git@([^:]+):#https://\1/#; s#^ssh://git@#https://#; s#\.git$##')
        COMMIT_URL="${WEB_URL}/commit/${FULL_SHA}"
    fi
else
    BUILD_NUMBER=$(date "+%Y%m%d.%H%M")
    DISPLAY=$(date "+%m-%d-%y %-I:%M %p")
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST_DST}"
/usr/libexec/PlistBuddy -c "Add :NewMusicResearchVersionDisplay string ${DISPLAY}" "${PLIST_DST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :NewMusicResearchVersionDisplay ${DISPLAY}" "${PLIST_DST}"

/usr/libexec/PlistBuddy -c "Delete :NewMusicResearchVersionCommitURL" "${PLIST_DST}" 2>/dev/null || true
if [ -n "${COMMIT_URL}" ]; then
    /usr/libexec/PlistBuddy -c "Add :NewMusicResearchVersionCommitURL string ${COMMIT_URL}" "${PLIST_DST}"
fi

# 4. Bundle the HUD (single source of truth lives in keyboard-maestro/).
cp "${REPO_ROOT}/keyboard-maestro/progress_window.html" "${APP_PATH}/Contents/Resources/progress_window.html"

# 4b. Bundle the Python pipeline — the app runs this copy, so the installed app is
# always self-consistent no matter what any checkout currently contains. Only code
# and static assets ship in the bundle; mutable state (.env, token caches, scraped
# CSVs, playlists.json) stays in the project/data dir the pipeline runs *in*.
PIPELINE_DST="${APP_PATH}/Contents/Resources/pipeline"
mkdir -p "${PIPELINE_DST}/keyboard-maestro"
for f in bootstrap.py ui.py track_playlists.py export_to_spotify.py \
         generate_artwork.py tidal_login.py launch_check.py Playlist-Artwork.jpg; do
    cp "${REPO_ROOT}/${f}" "${PIPELINE_DST}/"
done
cp "${REPO_ROOT}/keyboard-maestro/km_progress.py" "${PIPELINE_DST}/keyboard-maestro/"

# 5. Icon, if present.
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"

# Native macOS 26 icon (no Tahoe white rim) — see ~/.claude/skills/mac-app-icons
_icon_ensure="$HOME/.claude/skills/mac-app-icons/scripts/ensure-native-icon.sh"
[ -x "$_icon_ensure" ] && "$_icon_ensure" "Resources" "${APP_PATH}" || true

# 6. Strip quarantine + ad-hoc sign with entitlements.
xattr -cr "${APP_PATH}"
ENTITLEMENTS="Resources/${PRODUCT}.entitlements"
if [ -f "${ENTITLEMENTS}" ]; then
    codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${APP_PATH}"
else
    codesign --force --deep --sign - "${APP_PATH}"
fi

# Finder icon: stamp the repo's chosen style (Resources/.icon-style = dering) AFTER
# signing — macOS's own icon slab always paints a light edge ring, and custom icons
# render literally. The rm -rf above wipes the stamp each build; car stays fallback.
[ -x "$_icon_ensure" ] && "$_icon_ensure" --stamp "Resources" "${APP_PATH}" || true

echo "✓ Built ${APP_PATH}"
echo "  Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_DST}") (${DISPLAY})"

# Debug worktree menu item — standard on every Mac app.
# Prints nothing once the menu is installed. See ~/.claude/skills/mac-worktree-menu.
_wtm_check="$HOME/.claude/skills/mac-worktree-menu/check.sh"
[ -x "$_wtm_check" ] && "$_wtm_check" "$(dirname "$0")" || true
