#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart"
BOTTLE_NAME="${CROSSOVER_BOTTLE:-OdinOne}"
RUNNER_CMD="$ROOT_DIR/tools/crossover/odin-one-crossover.cmd"

if [[ ! -x "$CROSSOVER_BIN" ]]; then
  echo "CrossOver CLI was not found at:"
  echo "$CROSSOVER_BIN"
  echo
  echo "Install CrossOver or update CROSSOVER_BIN inside this file."
  read -r "?Press Enter to close..."
  exit 1
fi

if [[ ! -f "$RUNNER_CMD" ]]; then
  echo "Missing runner:"
  echo "$RUNNER_CMD"
  read -r "?Press Enter to close..."
  exit 1
fi

echo "Starting Odin's Cat in CrossOver bottle: $BOTTLE_NAME"
echo
echo "Tip: install Node.js LTS, Rust, and WebView2 Runtime inside this bottle first."
echo

"$CROSSOVER_BIN" --bottle "$BOTTLE_NAME" --new-console cmd /k "Z:${RUNNER_CMD//\//\\}"

