#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

CAPTURE_SCRIPT="${SCRIPT_DIR}/android-reality-capture-run.sh"
COMPARE_SCRIPT="${SCRIPT_DIR}/android-runtime-compare-captures.sh"
REPORT_SCRIPT="${SCRIPT_DIR}/android-runtime-report-draft.sh"
CHECKLIST_SCRIPT="${SCRIPT_DIR}/android-blocked-direct-checklist.sh"
SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
APPLY_PRESET_SCRIPT="${SCRIPT_DIR}/android-reality-apply-preset.sh"

OUTPUT_ROOT="${TMPDIR:-/tmp}"
SESSION_ROOT="${OUTPUT_ROOT%/}/odin-one-android-reality-whitelist-manual"
SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"

SUBCOMMAND=""
OUTPUT_DIR=""
SESSION_LABEL=""
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-25}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh begin [options]
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh candidate [options]
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh restore [options]
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh finalize [options]
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh status [options]

Subcommands:
  begin       Capture the current stable control lane from the handset.
  candidate   Capture the current in-app hidden whitelist scaffold lane.
  restore     Apply baseline prefs, restart the stable lane, and capture restore.
  finalize    Build compare/report/checklist artifacts from the saved captures.
  status      Print the current session state JSON.

Options:
  --output-dir <dir>           Session directory. Default:
                               /tmp/odin-one-android-reality-whitelist-manual/<stamp>
  --label <label>              Optional session label suffix.
  --wait-timeout-seconds <n>   Snapshot wait timeout. Default: 25
  --wait-poll-seconds <n>      Snapshot wait poll interval. Default: 1
  -h, --help                   Show this help.

Examples:
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh begin
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh candidate --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh restore --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
  apps/desktop/scripts/android-reality-whitelist-manual-session.sh finalize --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
EOF
}

require_script() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required script is missing or not executable: $path" >&2
    exit 1
  fi
}

require_python() {
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    echo "python3 not found" >&2
    exit 1
  fi
}

normalize_label() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | "$SED_BIN" 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

log_section() {
  echo
  echo "=== $1 ==="
}

resolve_latest_session_dir() {
  if [[ ! -d "$SESSION_ROOT" ]]; then
    return 1
  fi
  local latest
  latest="$(/bin/ls -dt "$SESSION_ROOT"/* 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" && -d "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    begin|candidate|restore|finalize|status)
      if [[ -n "$SUBCOMMAND" ]]; then
        echo "Only one subcommand may be used." >&2
        exit 1
      fi
      SUBCOMMAND="$1"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --label)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SESSION_LABEL="$2"
      shift 2
      ;;
    --wait-timeout-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --wait-poll-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      WAIT_POLL_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SUBCOMMAND" ]]; then
  usage >&2
  exit 1
fi

require_python
require_script "$CAPTURE_SCRIPT"
require_script "$COMPARE_SCRIPT"
require_script "$REPORT_SCRIPT"
require_script "$CHECKLIST_SCRIPT"
require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$APPLY_PRESET_SCRIPT"

if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "--wait-poll-seconds must be a positive integer" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  if [[ "$SUBCOMMAND" == "begin" ]]; then
    OUTPUT_DIR="${SESSION_ROOT}/${SESSION_STAMP}"
    if [[ -n "$SESSION_LABEL" ]]; then
      OUTPUT_DIR="${OUTPUT_DIR}-$(normalize_label "$SESSION_LABEL")"
    fi
  else
    OUTPUT_DIR="$(resolve_latest_session_dir || true)"
    if [[ -z "$OUTPUT_DIR" ]]; then
      echo "No existing manual session directory was found. Run 'begin' first or pass --output-dir." >&2
      exit 1
    fi
  fi
fi

CAPTURE_DIR="${OUTPUT_DIR}/captures"
STATE_FILE="${OUTPUT_DIR}/session.json"
COMPARE_OUTPUT="${OUTPUT_DIR}/compare.md"
REPORT_OUTPUT="${OUTPUT_DIR}/report.md"
CHECKLIST_OUTPUT="${OUTPUT_DIR}/blocked-direct-checklist.md"
SUMMARY_OUTPUT="${OUTPUT_DIR}/summary.md"

mkdir -p "$CAPTURE_DIR"

state_set() {
  local key="$1"
  local value="$2"
  local value_type="${3:-string}"
  STATE_FILE="$STATE_FILE" STATE_KEY="$key" STATE_VALUE="$value" STATE_VALUE_TYPE="$value_type" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

state_path = Path(os.environ["STATE_FILE"])
key = os.environ["STATE_KEY"]
raw_value = os.environ["STATE_VALUE"]
value_type = os.environ["STATE_VALUE_TYPE"]

if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8", errors="replace"))
else:
    state = {}

if value_type == "json":
    value = json.loads(raw_value)
elif value_type == "int":
    value = int(raw_value)
elif value_type == "bool":
    value = raw_value.lower() in {"1", "true", "yes", "on"}
else:
    value = raw_value

state[key] = value
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

state_get() {
  local key="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    return 1
  fi
  STATE_FILE="$STATE_FILE" STATE_KEY="$key" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

state = json.loads(Path(os.environ["STATE_FILE"]).read_text(encoding="utf-8", errors="replace"))
value = state.get(os.environ["STATE_KEY"])
if value is None:
    raise SystemExit(1)
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(str(value))
PY
}

capture_run() {
  local label="$1"
  local capture_output
  capture_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "$label")"
  printf '%s\n' "$capture_output" >&2
  local capture_path
  capture_path="$(printf '%s\n' "$capture_output" | "$SED_BIN" -n 's/^Wrote handset dump to //p' | tail -n 1)"
  if [[ -z "$capture_path" || ! -f "$capture_path" ]]; then
    echo "Unable to resolve capture path for label '$label'." >&2
    exit 1
  fi
  printf '%s\n' "$capture_path"
}

wait_for_snapshot() {
  "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" \
    "$@"
}

write_summary() {
  local control_capture
  local candidate_capture
  local restore_capture
  local request_source
  local control_source
  control_capture="$(state_get control_capture 2>/dev/null || true)"
  candidate_capture="$(state_get candidate_capture 2>/dev/null || true)"
  restore_capture="$(state_get restore_capture 2>/dev/null || true)"
  request_source="$(state_get candidate_request_source 2>/dev/null || true)"
  control_source="$(state_get control_capture_source 2>/dev/null || true)"
  cat >"$SUMMARY_OUTPUT" <<EOF
# Android REALITY Whitelist Manual Session

- Session directory: \`$OUTPUT_DIR\`
- Control capture: \`${control_capture:-n/a}\`
- Control capture source: \`${control_source:-direct-control}\`
- Candidate capture: \`${candidate_capture:-n/a}\`
- Restore capture: \`${restore_capture:-n/a}\`
- Candidate request source: \`${request_source:-n/a}\`
- Compare output: \`$COMPARE_OUTPUT\`
- Report output: \`$REPORT_OUTPUT\`
- Checklist output: \`$CHECKLIST_OUTPUT\`
EOF
}

parse_candidate_request_source() {
  local capture_path="$1"
  local artifact_dir="${capture_path%.txt}.artifacts"
  local runtime_xml="${artifact_dir}/odin-one-vpn-runtime.xml"
  [[ -f "$runtime_xml" ]] || return 1
  "$PYTHON_BIN" - "$runtime_xml" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = ET.fromstring(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
last_request = {}
last_attempted_request = {}
for child in root:
    if child.tag != "string":
        continue
    name = child.attrib.get("name")
    value = (child.text or "").strip()
    if not value:
        continue
    if name == "last_request":
        try:
            last_request = json.loads(value)
        except Exception:
            last_request = {}
    elif name == "last_attempted_request":
        try:
            last_attempted_request = json.loads(value)
        except Exception:
            last_attempted_request = {}

if last_attempted_request:
    print("last_attempted_request")
elif last_request:
    print("last_request")
PY
}

latest_capture_matching() {
  local pattern="$1"
  local latest
  latest="$(/bin/ls -t "$CAPTURE_DIR"/*.txt 2>/dev/null | /usr/bin/grep -E "$pattern" | head -n 1 || true)"
  [[ -n "$latest" && -f "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

case "$SUBCOMMAND" in
  begin)
    log_section "Stable Control Capture"
    wait_for_snapshot --family direct-reality --status running --activation active >/dev/null
    control_capture="$(capture_run stable-control)"
    state_set session_dir "$OUTPUT_DIR"
    state_set control_capture "$control_capture"
    state_set control_capture_source "direct-control"
    state_set created_at "$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ')"
    write_summary
    printf 'Manual whitelist session initialized at %s\n' "$OUTPUT_DIR"
    ;;
  candidate)
    log_section "Candidate Capture"
    wait_for_snapshot --family reality-whitelist-assisted --activation scaffold_only >/dev/null
    candidate_capture="$(capture_run reality-whitelist-scaffold)"
    state_set candidate_capture "$candidate_capture"
    request_source="$(parse_candidate_request_source "$candidate_capture" || true)"
    if [[ -n "$request_source" ]]; then
      state_set candidate_request_source "$request_source"
    fi
    write_summary
    printf 'Captured candidate lane into %s\n' "$candidate_capture"
    ;;
  restore)
    log_section "Restore Stable Lane"
    "$APPLY_PRESET_SCRIPT" baseline >/dev/null
    ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null
    wait_for_snapshot --family direct-reality --status running --activation active >/dev/null
    restore_capture="$(capture_run stable-restored)"
    state_set restore_capture "$restore_capture"
    write_summary
    printf 'Restored stable lane into %s\n' "$restore_capture"
    ;;
  finalize)
    control_capture="$(state_get control_capture 2>/dev/null || true)"
    candidate_capture="$(state_get candidate_capture 2>/dev/null || true)"
    restore_capture="$(state_get restore_capture 2>/dev/null || true)"
    if [[ -z "$control_capture" || ! -f "$control_capture" ]]; then
      control_capture="$(latest_capture_matching 'stable-control\.txt$' || true)"
      if [[ -n "$control_capture" ]]; then
        state_set control_capture "$control_capture"
        state_set control_capture_source "recovered-stable-control"
      fi
    fi
    if [[ -z "$candidate_capture" || ! -f "$candidate_capture" ]]; then
      candidate_capture="$(latest_capture_matching 'reality-whitelist-scaffold\.txt$' || true)"
      if [[ -n "$candidate_capture" ]]; then
        state_set candidate_capture "$candidate_capture"
      fi
    fi
    if [[ -z "$restore_capture" || ! -f "$restore_capture" ]]; then
      restore_capture="$(latest_capture_matching 'stable-restored\.txt$' || true)"
      if [[ -n "$restore_capture" ]]; then
        state_set restore_capture "$restore_capture"
      fi
    fi
    if [[ ( -z "$control_capture" || ! -f "$control_capture" ) && -n "$restore_capture" && -f "$restore_capture" ]]; then
      control_capture="$restore_capture"
      state_set control_capture "$control_capture"
      state_set control_capture_source "stable-restored-fallback"
    fi
    if [[ -z "$control_capture" || ! -f "$control_capture" ]]; then
      echo "Missing control capture in $STATE_FILE" >&2
      exit 1
    fi
    if [[ -z "$candidate_capture" || ! -f "$candidate_capture" ]]; then
      echo "Missing candidate capture in $STATE_FILE" >&2
      exit 1
    fi
    log_section "Finalize Artifacts"
    "$COMPARE_SCRIPT" "$control_capture" "$candidate_capture" >"$COMPARE_OUTPUT"
    "$REPORT_SCRIPT" "$control_capture" "$candidate_capture" >"$REPORT_OUTPUT"
    "$CHECKLIST_SCRIPT" "$control_capture" "$candidate_capture" >"$CHECKLIST_OUTPUT"
    state_set compare_output "$COMPARE_OUTPUT"
    state_set report_output "$REPORT_OUTPUT"
    state_set checklist_output "$CHECKLIST_OUTPUT"
    write_summary
    printf 'Wrote compare/report/checklist into %s\n' "$OUTPUT_DIR"
    ;;
  status)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No session state file found at $STATE_FILE" >&2
      exit 1
    fi
    cat "$STATE_FILE"
    ;;
esac
