#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

(
  cd "$(dirname "$0")/../core/go"
  go run ./cmd/mvpd
) &

CORE_PID=$!

cleanup() {
  kill "$CORE_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

cd "$(dirname "$0")/.."
npm run dev

