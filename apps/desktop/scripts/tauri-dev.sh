#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
FRONTEND_PORT="${ODIN_ONE_DESKTOP_PORT:-3000}"
CORE_PORT="${ODIN_ONE_CORE_PORT:-8088}"

core_started=0
frontend_started=0

is_listening() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

if ! is_listening "$CORE_PORT"; then
  (
    cd "$ROOT_DIR/core/go"
    go run ./cmd/mvpd
  ) &
  CORE_PID=$!
  core_started=1
else
  CORE_PID=""
fi

if ! is_listening "$FRONTEND_PORT"; then
  (
    cd "$ROOT_DIR/apps/desktop"
    npm run dev -- --port "$FRONTEND_PORT"
  ) &
  FRONTEND_PID=$!
  frontend_started=1
else
  FRONTEND_PID=""
fi

cleanup() {
  if [[ "$core_started" -eq 1 && -n "${CORE_PID:-}" ]]; then
    kill "$CORE_PID" 2>/dev/null || true
  fi
  if [[ "$frontend_started" -eq 1 && -n "${FRONTEND_PID:-}" ]]; then
    kill "$FRONTEND_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

if [[ "$frontend_started" -eq 1 ]]; then
  wait "$FRONTEND_PID"
else
  while true; do
    sleep 3600
  done
fi
