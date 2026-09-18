#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG_FILE="$ROOT_DIR/.codex-watch/local.env"
if [[ -f "$LOCAL_CONFIG_FILE" ]]; then
  set -a
  # This file is intentionally ignored by Git and is owned by the local user.
  # shellcheck disable=SC1090
  source "$LOCAL_CONFIG_FILE"
  set +a
fi

PROJECT="$ROOT_DIR/CodexWatchCompanion.xcodeproj"
SCHEME="CodexWatchCompanion"
PHONE_SCHEME="CodexWatchPhone"
BUNDLE_ID="${CODEX_WATCH_BUNDLE_ID:-dev.codexwatchcompanion.phone.watchkitapp}"
PHONE_BUNDLE_ID="${CODEX_WATCH_PHONE_BUNDLE_ID:-dev.codexwatchcompanion.phone}"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
WATCH_APP="$DERIVED_DATA/Build/Products/Debug-watchos/CodexWatchCompanion.app"
SIM_APP="$DERIVED_DATA/Build/Products/Debug-watchsimulator/CodexWatchCompanion.app"
PHONE_APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/CodexWatchPhone.app"
BRIDGE_SESSION="codex-watch-bridge"
BRIDGE_LOG="$ROOT_DIR/build/codex-watch-bridge.log"
LAUNCHD_BRIDGE_LOG="/tmp/codex-watch-bridge.log"
LAUNCHD_BRIDGE_ERROR_LOG="/tmp/codex-watch-bridge.error.log"
ACTIVE_BRIDGE_LOG="$BRIDGE_LOG"
SIMULATOR_NAME="${CODEX_WATCH_SIMULATOR_NAME:-Apple Watch Series 11 (46mm)}"
DEVICE_ID="${CODEX_WATCH_DEVICE_ID:-}"
PHONE_DEVICE_ID="${CODEX_WATCH_PHONE_DEVICE_ID:-}"
XCODE_LOCAL_SETTINGS=()
if [[ -n "${CODEX_WATCH_DEVELOPMENT_TEAM:-}" ]]; then
  XCODE_LOCAL_SETTINGS+=("DEVELOPMENT_TEAM=$CODEX_WATCH_DEVELOPMENT_TEAM")
fi
if [[ -n "${CODEX_WATCH_DEFAULT_BRIDGE_URL:-}" ]]; then
  XCODE_LOCAL_SETTINGS+=("CODEX_WATCH_DEFAULT_BRIDGE_URL=$CODEX_WATCH_DEFAULT_BRIDGE_URL")
fi
if [[ -n "${CODEX_WATCH_DEFAULT_MAC_HOST:-}" ]]; then
  XCODE_LOCAL_SETTINGS+=("CODEX_WATCH_DEFAULT_MAC_HOST=$CODEX_WATCH_DEFAULT_MAC_HOST")
fi
MODE="device"
START_BRIDGE=1
RUN_TESTS=0
BRIDGE_ENV_NAMES=(
  CODEX_SESSIONS_DIR
  CODEX_WATCH_CODEX_API_BASE_URL
  CODEX_WATCH_HOST
  CODEX_WATCH_LOCAL_HOSTNAME
  CODEX_WATCH_OPEN_CODEX
  CODEX_WATCH_PORT
  CODEX_WATCH_RESTART_DELAY
  CODEX_WATCH_SHOW_NETWORK_HINTS
  CODEX_WATCH_TRANSCRIBE_PROVIDER
  CODEX_WATCH_VERBOSE
)

NODE_BIN="${CODEX_WATCH_NODE_PATH:-}"
if [[ -z "$NODE_BIN" ]] && command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
fi
if [[ -z "$NODE_BIN" && -x "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" ]]; then
  NODE_BIN="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
fi
if [[ -n "$NODE_BIN" ]]; then
  export PATH="$(dirname "$NODE_BIN"):$PATH"
fi

usage() {
  cat <<USAGE
Usage:
  scripts/install.sh --phone-device <iphone-devicectl-id> [--watch-device <watch-devicectl-id>]
  scripts/install.sh --device <watch-devicectl-id> --phone-device <iphone-devicectl-id>
  scripts/install.sh --simulator
  scripts/install.sh --bridge-only

Options:
  --phone-device <id>
                    Build, install, and launch the iPhone gateway.
  --watch-device <id>
                    Also install and launch the Watch App on a physical watch.
  --device <id>     Backwards-compatible alias for --watch-device.
  --simulator       Build, install, and launch on the configured watch simulator.
  --bridge-only     Start/restart the Mac bridge only.
  --skip-bridge     Do not start/restart the Mac bridge.
  --test            Run bridge and watch simulator tests before installing.
  --help            Show this help.

Environment:
  CODEX_WATCH_DEVICE_ID         Physical watch CoreDevice identifier.
  CODEX_WATCH_SIMULATOR_NAME    watchOS simulator name. Default: Apple Watch Series 11 (46mm).
  CODEX_WATCH_PHONE_DEVICE_ID   Physical iPhone CoreDevice identifier.
  CODEX_WATCH_DEVICE_ID          Physical Apple Watch CoreDevice identifier.
  CODEX_WATCH_BUNDLE_ID          Watch bundle identifier. Default: dev.codexwatchcompanion.phone.watchkitapp.
  CODEX_WATCH_PHONE_BUNDLE_ID    iPhone bundle identifier. Default: dev.codexwatchcompanion.phone.
  CODEX_WATCH_DEVELOPMENT_TEAM   Optional Apple Development Team ID for local device signing.
  CODEX_WATCH_DEFAULT_BRIDGE_URL Optional private iPhone-to-Mac bridge URL injected at build time.
  CODEX_WATCH_DEFAULT_MAC_HOST   Optional private Mac host injected into the Watch migration fallback.
  CODEX_WATCH_NODE_PATH          Optional Node executable. The Codex-bundled Node is detected automatically.
  CODEX_WATCH_SHOW_NETWORK_HINTS=1
                                Print LAN/hostname bridge URLs in the bridge log.
  CODEX_WATCH_OPEN_CODEX=1      Open /Applications/Codex.app when the watch connects.
  CODEX_WATCH_RESTART_DELAY     Seconds before restarting a crashed bridge. Default: 2.

Find a physical device id:
  xcrun devicectl list devices
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      MODE="device"
      DEVICE_ID="${2:-}"
      shift 2
      ;;
    --watch-device)
      MODE="device"
      DEVICE_ID="${2:-}"
      shift 2
      ;;
    --phone-device)
      MODE="device"
      PHONE_DEVICE_ID="${2:-}"
      shift 2
      ;;
    --simulator)
      MODE="simulator"
      shift
      ;;
    --bridge-only)
      MODE="bridge"
      shift
      ;;
    --skip-bridge)
      START_BRIDGE=0
      shift
      ;;
    --test)
      RUN_TESTS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

bridge_command() {
  local command
  local name
  printf -v command 'cd %q && exec env CODEX_WATCH_BRIDGE_SUPERVISOR=1' "$ROOT_DIR"
  for name in "${BRIDGE_ENV_NAMES[@]}"; do
    if [[ -n "${!name+x}" ]]; then
      printf -v command '%s %q' "$command" "$name=${!name}"
    fi
  done
  printf -v command '%s bash scripts/run-bridge-supervisor.sh' "$command"
  printf '%s' "$command"
}

launchctl_bridge_command() {
  local command
  local name
  printf -v command 'cd %q && exec env' "$ROOT_DIR"
  for name in "${BRIDGE_ENV_NAMES[@]}"; do
    if [[ -n "${!name+x}" ]]; then
      printf -v command '%s %q' "$command" "$name=${!name}"
    fi
  done
  printf -v command '%s %q' "$command" "CODEX_WATCH_RUNTIME_DIR=/tmp/codex-watch"
  printf -v command '%s %q %q' \
    "$command" \
    "$NODE_BIN" \
    "$ROOT_DIR/bridge/codex-watch-bridge.mjs"
  printf '%s' "$command"
}

start_bridge() {
  mkdir -p "$ROOT_DIR/build"
  : > "$BRIDGE_LOG"
  local command
  local active_log="$BRIDGE_LOG"
  command="$(bridge_command)"
  pkill -f "CODEX_WATCH_BRIDGE_SUPERVISOR=1" >/dev/null 2>&1 || true
  pkill -f "node .*bridge/codex-watch-bridge.mjs" >/dev/null 2>&1 || true
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$BRIDGE_SESSION" >/dev/null 2>&1 || true
    tmux new-session -d -s "$BRIDGE_SESSION" "$command"
  else
    pkill -f "node .*codex-watch-bridge.mjs" >/dev/null 2>&1 || true
    launchctl remove "$BRIDGE_SESSION" >/dev/null 2>&1 || true
    wait_for_previous_launchd_job
    local launchctl_command
    launchctl_command="$(launchctl_bridge_command)"
    active_log="$LAUNCHD_BRIDGE_LOG"
    : > "$LAUNCHD_BRIDGE_LOG"
    : > "$LAUNCHD_BRIDGE_ERROR_LOG"
    if ! launchctl submit -l "$BRIDGE_SESSION" -o "$LAUNCHD_BRIDGE_LOG" -e "$LAUNCHD_BRIDGE_ERROR_LOG" -- /bin/bash -lc "$launchctl_command" >/dev/null 2>&1; then
      nohup bash -lc "$command" </dev/null >/dev/null 2>&1 &
      disown "$!" 2>/dev/null || true
      active_log="$BRIDGE_LOG"
    fi
  fi
  ACTIVE_BRIDGE_LOG="$active_log"
  wait_for_bridge
  tail -n 3 "$active_log" || true
}

wait_for_bridge() {
  local health_url="http://127.0.0.1:${CODEX_WATCH_PORT:-17842}/"
  local attempts=40
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if "$NODE_BIN" -e 'fetch(process.argv[1]).then(response => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))' "$health_url" >/dev/null 2>&1; then
      echo "Bridge health check passed: $health_url"
      return 0
    fi
    sleep 0.25
  done
  echo "Bridge did not pass health check: $health_url" >&2
  tail -n 40 "$BRIDGE_LOG" >&2 || true
  exit 1
}

wait_for_previous_launchd_job() {
  local service="gui/$(id -u)/$BRIDGE_SESSION"
  local attempts=40
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if ! launchctl print "$service" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
}

run_tests() {
  (cd "$ROOT_DIR" && "$NODE_BIN" --check bridge/codex-watch-bridge.mjs && "$NODE_BIN" --test tests/server/*.test.mjs)
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=watchOS Simulator,name=$SIMULATOR_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:CodexWatchCompanionTests \
    "${XCODE_LOCAL_SETTINGS[@]}" \
    test
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$PHONE_SCHEME" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA" \
    "${XCODE_LOCAL_SETTINGS[@]}" \
    build
}

install_device() {
  if [[ -z "$PHONE_DEVICE_ID" ]]; then
    echo "No physical iPhone device id provided." >&2
    echo "Run: xcrun devicectl list devices" >&2
    echo "Then: scripts/install.sh --phone-device <iphone-id> --watch-device <watch-id>" >&2
    exit 2
  fi

  # Register the actual watch before building the iPhone container. A profile
  # created for the phone alone may not authorize installation on the watch.
  if [[ -n "$DEVICE_ID" ]]; then
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "platform=watchOS,id=$DEVICE_ID" \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      "${XCODE_LOCAL_SETTINGS[@]}" \
      build
  fi

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$PHONE_SCHEME" \
    -destination "id=$PHONE_DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "${XCODE_LOCAL_SETTINGS[@]}" \
    build

  xcrun devicectl device install app \
    --device "$PHONE_DEVICE_ID" \
    --timeout 180 \
    "$PHONE_APP"

  xcrun devicectl device process launch \
    --device "$PHONE_DEVICE_ID" \
    --timeout 60 \
    "$PHONE_BUNDLE_ID"

  if [[ -n "$DEVICE_ID" ]]; then
    xcrun devicectl device install app \
      --device "$DEVICE_ID" \
      --timeout 180 \
      "$WATCH_APP"

    xcrun devicectl device process launch \
      --device "$DEVICE_ID" \
      --timeout 60 \
      "$BUNDLE_ID"
  fi
}

install_simulator() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=watchOS Simulator,name=$SIMULATOR_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    "${XCODE_LOCAL_SETTINGS[@]}" \
    build

  xcrun simctl boot "$SIMULATOR_NAME" >/dev/null 2>&1 || true
  open -a Simulator
  xcrun simctl install "$SIMULATOR_NAME" "$SIM_APP"
  SIMCTL_CHILD_CODEX_WATCH_DIRECT_BRIDGE=1 \
  SIMCTL_CHILD_CODEX_WATCH_SERVER_URL="ws://127.0.0.1:${CODEX_WATCH_PORT:-17842}/codex-watch" \
    xcrun simctl launch "$SIMULATOR_NAME" "$BUNDLE_ID"
}

if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  echo "Missing Node.js. Install Node 20+ or set CODEX_WATCH_NODE_PATH." >&2
  exit 1
fi
if [[ "$MODE" != "bridge" || "$RUN_TESTS" -eq 1 ]]; then
  require xcodebuild
  require xcrun
fi

if [[ "$START_BRIDGE" -eq 1 ]]; then
  start_bridge
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
  run_tests
fi

case "$MODE" in
  bridge)
    echo "Bridge is running. Log: $ACTIVE_BRIDGE_LOG"
    ;;
  simulator)
    install_simulator
    ;;
  device)
    install_device
    ;;
esac
