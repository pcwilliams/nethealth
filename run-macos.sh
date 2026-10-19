#!/bin/zsh
# run-macos.sh — Build NetHealth and either launch the window or run a CLI mode.
#
# Usage:
#   ./run-macos.sh                      # build Debug + launch the window
#   ./run-macos.sh Release              # build Release + launch the window
#   ./run-macos.sh Debug --selftest     # headless networking self-test, then exit
#   ./run-macos.sh Debug --netdiag      # raw-socket diagnostics (errno per step)
#   ./run-macos.sh Debug --speedtest    # per-connection download + upload test
#
# The first argument, if it's a configuration name (Debug/Release), selects the
# build config; anything else is treated as an app argument. Remaining arguments
# are passed straight through to the app. When a CLI flag (--selftest/--netdiag)
# is present the signed binary is run in the foreground and its exit code is
# propagated (so it composes in scripts); otherwise the .app is launched detached.
#
# Builds into the project-local ./build DerivedData dir, so the product lives at
#   build/Build/Products/<Config>/NetHealth.app  — matching the paths in CLAUDE.md.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NetHealth"
SCHEME="NetHealth"

# First arg is the configuration only if it names one; otherwise default Debug
# and treat every argument as an app argument.
CONFIG="Debug"
if [[ "${1:-}" == "Debug" || "${1:-}" == "Release" ]]; then
    CONFIG="$1"
    shift
fi
APP_ARGS=("$@")

# Pick up APPLE_TEAM_ID from the shared env if present; otherwise rely on the
# DEVELOPMENT_TEAM already baked into the project. Never inline the team ID here.
[[ -f "${HOME}/appledev/setupenv.sh" ]] && source "${HOME}/appledev/setupenv.sh"
TEAM_ARGS=()
[[ -n "${APPLE_TEAM_ID:-}" ]] && TEAM_ARGS=(DEVELOPMENT_TEAM="${APPLE_TEAM_ID}")

DERIVED="build"

echo "🛠  Building ${APP_NAME} (${CONFIG})…" >&2
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${DERIVED}" \
    -destination 'platform=macOS' \
    "${TEAM_ARGS[@]}" \
    build | tail -5 >&2

APP_PATH="${DERIVED}/Build/Products/${CONFIG}/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "❌ Build succeeded but ${APP_NAME}.app not found at ${APP_PATH}" >&2
    exit 1
fi

# Is a headless CLI mode requested? If so, run the binary in the foreground so
# its stdout and exit code reach the caller; otherwise launch the GUI detached.
HEADLESS=0
for a in "${APP_ARGS[@]:-}"; do
    case "$a" in
        --selftest|--netdiag|--speedtest|--watch) HEADLESS=1 ;;
    esac
done

if [[ "${HEADLESS}" == "1" ]]; then
    exec "${APP_PATH}/Contents/MacOS/${APP_NAME}" "${APP_ARGS[@]}"
else
    echo "🚀 Launching ${APP_NAME}…" >&2
    open -n "${APP_PATH}" ${APP_ARGS:+--args "${APP_ARGS[@]}"}
fi
