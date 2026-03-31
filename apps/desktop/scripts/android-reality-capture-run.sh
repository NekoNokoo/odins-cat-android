#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DUMP_SCRIPT="$ROOT_DIR/apps/desktop/scripts/android-reality-device-dump.sh"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"

SCENARIO_LABEL="${1:-baseline}"
NORMALIZED_LABEL="$(printf '%s' "$SCENARIO_LABEL" | tr '[:upper:]' '[:lower:]' | "$SED_BIN" 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
if [[ -z "$NORMALIZED_LABEL" ]]; then
  NORMALIZED_LABEL="baseline"
fi

STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
OUTPUT_DIR="${ODIN_ONE_ANDROID_DUMP_DIR:-$ROOT_DIR/tmp/android-reality-device-dumps}"
OUTPUT_FILE="${OUTPUT_DIR%/}/${STAMP}-${NORMALIZED_LABEL}.txt"

section() {
  echo
  echo "=== $1 ==="
}

require_script() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required script is missing or not executable: $path" >&2
    exit 1
  fi
}

require_script "$DUMP_SCRIPT"
mkdir -p "$OUTPUT_DIR"

section "Android REALITY Capture"
echo "Scenario: $SCENARIO_LABEL"
echo "Output: $OUTPUT_FILE"

"$DUMP_SCRIPT" | tee "$OUTPUT_FILE"

section "Saved"
echo "Wrote handset dump to $OUTPUT_FILE"
