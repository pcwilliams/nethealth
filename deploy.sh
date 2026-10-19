#!/bin/zsh
# deploy.sh — Build NetHealth in Release and install it into /Applications.
#
# Usage: ./deploy.sh
#
# Makes a clean Release build in a throwaway DerivedData dir, then copies the
# .app into /Applications (falling back to ~/Applications if that isn't
# writable). Does not launch it — open it from Spotlight/Launchpad afterwards.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NetHealth"
SCHEME="NetHealth"
CONFIG="Release"

# Pick up APPLE_TEAM_ID from the shared env if present; otherwise rely on the
# DEVELOPMENT_TEAM already baked into the project. Never inline the team ID here.
[[ -f "${HOME}/appledev/setupenv.sh" ]] && source "${HOME}/appledev/setupenv.sh"
TEAM_ARGS=()
[[ -n "${APPLE_TEAM_ID:-}" ]] && TEAM_ARGS=(DEVELOPMENT_TEAM="${APPLE_TEAM_ID}")

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "🛠  Building ${APP_NAME} (${CONFIG})…"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${BUILD_DIR}" \
    -destination 'generic/platform=macOS' \
    "${TEAM_ARGS[@]}" \
    build | tail -20

APP_PATH=$(find "${BUILD_DIR}" -name "${APP_NAME}.app" -maxdepth 6 -type d | head -1)
if [[ -z "${APP_PATH}" ]]; then
    echo "❌ Build succeeded but ${APP_NAME}.app not found"
    exit 1
fi

DEST="/Applications/${APP_NAME}.app"
if [[ ! -w /Applications ]]; then
    DEST="${HOME}/Applications/${APP_NAME}.app"
    mkdir -p "${HOME}/Applications"
    echo "ℹ️  /Applications not writable — installing to ${DEST}"
fi

echo "📦 Installing to ${DEST}…"
pkill -f "${DEST}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${APP_PATH}" "${DEST}"

echo "✅ Installed ${APP_NAME} → ${DEST}"
echo "   Launch it from Spotlight / Launchpad, or:  open \"${DEST}\""
