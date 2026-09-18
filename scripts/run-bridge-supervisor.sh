#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_LOG="$ROOT_DIR/build/codex-watch-bridge.log"
RESTART_DELAY="${CODEX_WATCH_RESTART_DELAY:-2}"
NODE_BIN="${CODEX_WATCH_NODE_PATH:-}"
if [[ -z "$NODE_BIN" ]] && command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
fi
if [[ -z "$NODE_BIN" && -x "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" ]]; then
  NODE_BIN="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
fi

if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  echo "Node.js was not found. Set CODEX_WATCH_NODE_PATH or install Node 20+." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/build"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

{
  echo "[$(timestamp)] bridge supervisor started"
  while true; do
    echo "[$(timestamp)] starting Codex Watch bridge"
    set +e
    (cd "$ROOT_DIR" && "$NODE_BIN" bridge/codex-watch-bridge.mjs)
    status=$?
    set -e
    echo "[$(timestamp)] bridge exited with status $status; restarting in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
} >> "$BRIDGE_LOG" 2>&1
