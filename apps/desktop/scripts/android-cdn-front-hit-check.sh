#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"

SESSION_SCRIPT="${SCRIPT_DIR}/android-cdn-lab-session.sh"
APPLY_PRESET_SCRIPT="${SCRIPT_DIR}/android-reality-apply-preset.sh"
SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
CAPTURE_SCRIPT="${SCRIPT_DIR}/android-reality-capture-run.sh"
COMPARE_SCRIPT="${SCRIPT_DIR}/android-runtime-compare-captures.sh"
REPORT_SCRIPT="${SCRIPT_DIR}/android-runtime-report-draft.sh"
CHECKLIST_SCRIPT="${SCRIPT_DIR}/android-blocked-direct-checklist.sh"

PRESET="cdn-httpupgrade-lab"
PLAN_FILE=""
PLAN_TAG=""
PLAN_INDEX=""
TEST_URL="https://ya.ru"
OUTPUT_DIR=""
RUN_PREFLIGHT="false"
RESTORE_STABLE="true"
SETTLE_SECONDS="5"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-45}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"
SERVER_HOST="${ODIN_ONE_CDN_FRONT_LOG_SSH_HOST:-95.81.120.226}"
SERVER_USER="${ODIN_ONE_CDN_FRONT_LOG_SSH_USER:-root}"
SERVER_KEY="${ODIN_ONE_CDN_FRONT_LOG_SSH_KEY:-$HOME/.ssh/afina_bot}"
SERVER_KNOWN_HOSTS="${ODIN_ONE_CDN_FRONT_LOG_KNOWN_HOSTS:-/tmp/odin-one-known-hosts}"
SERVER_SERVICE="${ODIN_ONE_CDN_FRONT_LOG_SERVICE:-whitelist-cdn-front-lab.service}"
LOG_WINDOW_MARGIN_SECONDS="${ODIN_ONE_CDN_FRONT_LOG_WINDOW_MARGIN_SECONDS:-5}"
DEVICE_INTERFACE_OVERRIDE="${ODIN_ONE_CDN_DEVICE_UNDERLYING_INTERFACE:-}"

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
OUTPUT_LABEL=""
BASE_SESSION_DIR=""
CAPTURE_DIR=""
CAPTURE_RESULT=""
SUMMARY_PATH=""
SERVER_LOG_PATH=""
SERVER_LOG_FILTERED_PATH=""
SERVER_LOG_SUMMARY_PATH=""
SERVER_STATUS_PATH=""
DEVICE_PROBE_SUMMARY_PATH=""
DEVICE_FRONT_CURL_PATH=""
DEVICE_ORIGIN_CURL_PATH=""
COMPARE_OUTPUT=""
REPORT_OUTPUT=""
CHECKLIST_OUTPUT=""
CONTROL_CAPTURE=""
CANDIDATE_CAPTURE=""
POST_TEST_CAPTURE=""
RESTORE_CAPTURE=""
PRETEST_SNAPSHOT_PATH=""
POSTTEST_SNAPSHOT_PATH=""
RUN_TEST_STATUS="not-run"
RUN_TEST_CHECKED_AT="n/a"
RUN_TEST_OUTPUT="n/a"
RUN_TEST_ERROR="n/a"
EXPECTED_FRONT_HOST="n/a"
EXPECTED_FRONT_CONNECT_HOST="n/a"
EXPECTED_FRONT_CONNECT_PORT="n/a"
EXPECTED_FRONT_PATH="n/a"
EXPECTED_ORIGIN_PATH="n/a"
SERVER_CONFIRMATION="unknown"
SERVER_MATCH_COUNT="0"
DEVICE_INTERFACE_NAME="n/a"
DEVICE_FRONT_CURL_RESULT="n/a"
DEVICE_ORIGIN_CURL_RESULT="n/a"
RESTORE_DONE="false"
SESSION_CANDIDATE_ACTIVE="false"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-front-hit-check.sh [options]

Options:
  --preset <preset>            Hidden preset to run. Default: cdn-httpupgrade-lab
  --plan-file <file>           Reusable CDN plan JSON passed through the preset helper.
  --plan-tag <tag>             Select one front by tag from the plan file.
  --plan-index <n>             Select one front by 1-based index from the plan file.
  --test-url <url>             URL used by run-test. Default: https://ya.ru
  --output-dir <dir>           Output directory. Default: /tmp/odin-one-android-cdn-front-hit-check/<stamp>-<preset>
  --settle-seconds <seconds>   Seconds to wait after run-test before the post-test capture. Default: 5
  --run-preflight              Include the base session preflight. Default: off to keep access-log windows clean.
  --skip-restore               Leave the handset on the candidate lane at the end.
  -h, --help                   Show this help.

This helper is owner-only and additive:
  1. Runs android-cdn-lab-session.sh with --skip-restore to leave the candidate active.
  2. Records the candidate snapshot before run-test.
  3. Runs an explicit Android VPN connectivity test.
  4. Captures a remote journalctl window from whitelist-cdn-front-lab.service.
  5. Saves optional device-side curl probes bound to the detected cellular interface.
  6. Writes filtered server-hit evidence plus compare/report/checklist using the post-test capture.
  7. Restores stable baseline unless --skip-restore is used.

Optional env:
  ODIN_ONE_CDN_DEVICE_UNDERLYING_INTERFACE=rmnet_data2
    Override the detected cellular interface for device-side curl probes.
EOF
}

require_bin() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" || ! -x "$path" ]]; then
    echo "${label} not found" >&2
    exit 1
  fi
}

require_script() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required script is missing or not executable: $path" >&2
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

capture_output_path_from_run() {
  printf '%s\n' "$1" | "$SED_BIN" -n 's/^Wrote handset dump to //p' | tail -n 1
}

summary_value() {
  local key="$1"
  "$PYTHON_BIN" - "$SUMMARY_PATH" "$key" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
pattern = re.compile(rf"^- {re.escape(key)}: `(.*)`$")
for line in path.read_text(encoding="utf-8").splitlines():
    match = pattern.match(line.strip())
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

snapshot_checked_at() {
  local snapshot_path="$1"
  "$PYTHON_BIN" - "$snapshot_path" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
last_test = snapshot.get("lastTest")
if isinstance(last_test, dict):
    print((last_test.get("checkedAt") or "").strip())
PY
}

run_ssh() {
  "$SSH_BIN" \
    -i "$SERVER_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$SERVER_KNOWN_HOSTS" \
    "${SERVER_USER}@${SERVER_HOST}" \
    "$@"
}

resolve_device_interface() {
  local capture_path="$1"
  if [[ -n "$DEVICE_INTERFACE_OVERRIDE" ]]; then
    printf '%s\n' "$DEVICE_INTERFACE_OVERRIDE"
    return 0
  fi
  "$PYTHON_BIN" - "$capture_path" <<'PY'
import re
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
network_id = None
for line in lines:
    if "VPN CONNECTED extra: VPN:com.odinone.desktop.vk" not in line:
        continue
    match = re.search(r"UnderlyingNetworks: \[(\d+)\]", line)
    if match:
        network_id = match.group(1)
        break
if not network_id:
    raise SystemExit(1)
for line in lines:
    if f"NetworkAgentInfo{{network{{{network_id}}}" not in line:
        continue
    match = re.search(r"InterfaceName: ([^ ]+)", line)
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

curl_result_label() {
  local output_path="$1"
  local exit_code="$2"
  if [[ ! -f "$output_path" ]]; then
    printf 'exit:%s (missing output)' "$exit_code"
    return 0
  fi
  local tail_line
  tail_line="$("$PYTHON_BIN" - "$output_path" <<'PY'
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
print(lines[-1] if lines else "")
PY
)"
  if [[ -n "$tail_line" ]]; then
    printf 'exit:%s (%s)' "$exit_code" "$tail_line"
  else
    printf 'exit:%s' "$exit_code"
  fi
}

run_device_cellular_probe() {
  local label="$1"
  local output_path="$2"
  local host="$3"
  local port="$4"
  local connect_host="$5"
  local scheme="$6"
  local path="$7"
  if [[ "$host" == "n/a" || -z "$host" || "$port" == "n/a" || -z "$port" || "$connect_host" == "n/a" || -z "$connect_host" || "$scheme" == "n/a" || -z "$scheme" || "$path" == "n/a" || -z "$path" || "$DEVICE_INTERFACE_NAME" == "n/a" || -z "$DEVICE_INTERFACE_NAME" ]]; then
    printf 'skipped\n' >"$output_path"
    printf 'skipped'
    return 0
  fi
  local url="${scheme}://${host}${path}"
  local exit_code=0
  if "$ADB_BIN" shell curl \
    --interface "$DEVICE_INTERFACE_NAME" \
    --resolve "${host}:${port}:${connect_host}" \
    -k \
    -I \
    --max-time 10 \
    "$url" >"$output_path" 2>&1
  then
    exit_code=0
  else
    exit_code=$?
  fi
  curl_result_label "$output_path" "$exit_code"
}

run_device_cellular_probes() {
  DEVICE_INTERFACE_NAME="$(resolve_device_interface "$POST_TEST_CAPTURE" 2>/dev/null || true)"
  if [[ -z "$DEVICE_INTERFACE_NAME" ]]; then
    DEVICE_INTERFACE_NAME="n/a"
  fi
  if [[ "$DEVICE_INTERFACE_NAME" == "n/a" ]]; then
    printf 'skipped\n' >"$DEVICE_FRONT_CURL_PATH"
    printf 'skipped\n' >"$DEVICE_ORIGIN_CURL_PATH"
    DEVICE_FRONT_CURL_RESULT="skipped (no underlying cellular interface detected)"
    DEVICE_ORIGIN_CURL_RESULT="skipped (no underlying cellular interface detected)"
  else
    DEVICE_FRONT_CURL_RESULT="$(run_device_cellular_probe "front" "$DEVICE_FRONT_CURL_PATH" "$EXPECTED_FRONT_HOST" "$EXPECTED_FRONT_CONNECT_PORT" "$EXPECTED_FRONT_CONNECT_HOST" "https" "$EXPECTED_FRONT_PATH")"
    DEVICE_ORIGIN_CURL_RESULT="$(run_device_cellular_probe "origin" "$DEVICE_ORIGIN_CURL_PATH" "$EXPECTED_FRONT_HOST" "$EXPECTED_FRONT_CONNECT_PORT" "$EXPECTED_FRONT_CONNECT_HOST" "https" "$EXPECTED_ORIGIN_PATH")"
  fi
  cat >"$DEVICE_PROBE_SUMMARY_PATH" <<EOF
# Device Cellular Probe Summary

- detected interface: \`$DEVICE_INTERFACE_NAME\`
- front probe result: \`$DEVICE_FRONT_CURL_RESULT\`
- front probe output: \`$DEVICE_FRONT_CURL_PATH\`
- origin probe result: \`$DEVICE_ORIGIN_CURL_RESULT\`
- origin probe output: \`$DEVICE_ORIGIN_CURL_PATH\`
EOF
}

epoch_to_utc() {
  local epoch="$1"
  "$DATE_BIN" -u -r "$epoch" '+%Y-%m-%d %H:%M:%S'
}

collect_capture() {
  local label="$1"
  local output
  output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "$label")"
  printf '%s\n' "$output"
  local capture_path
  capture_path="$(capture_output_path_from_run "$output")"
  if [[ -z "$capture_path" || ! -f "$capture_path" ]]; then
    echo "Unable to determine capture path for label: $label" >&2
    exit 1
  fi
  CAPTURE_RESULT="$capture_path"
}

wait_for_snapshot() {
  local label="$1"
  shift
  if "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" \
    "$@" >/dev/null
  then
    return 0
  fi
  echo "Warning: timed out waiting for snapshot during ${label}; continuing." >&2
  return 1
}

restore_stable_lane() {
  log_section "Restoring Stable Lane"
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  "$APPLY_PRESET_SCRIPT" baseline
  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null
  wait_for_snapshot "stable restore" --family direct-reality --status running || true
  sleep "$SETTLE_SECONDS"
  collect_capture "stable-restored"
  RESTORE_CAPTURE="$CAPTURE_RESULT"
  RESTORE_DONE="true"
}

cleanup() {
  if [[ "$RESTORE_STABLE" == "true" && "$SESSION_CANDIDATE_ACTIVE" == "true" && "$RESTORE_DONE" != "true" ]]; then
    echo >&2
    echo "Best-effort restore: returning handset to stable baseline..." >&2
    "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
    if "$APPLY_PRESET_SCRIPT" baseline >/dev/null 2>&1; then
      ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM

write_summary() {
  cat >"$SUMMARY_PATH" <<EOF
# Android CDN Front Hit Check

- Session directory: \`$OUTPUT_DIR\`
- Base session directory: \`$BASE_SESSION_DIR\`
- Session preset: \`$PRESET\`
- CDN plan file: \`${ODIN_ONE_CDN_PLAN_FILE:-n/a}\`
- CDN plan select tag: \`${ODIN_ONE_CDN_PLAN_SELECT_TAG:-n/a}\`
- CDN plan select index: \`${ODIN_ONE_CDN_PLAN_SELECT_INDEX:-n/a}\`
- Test URL: \`$TEST_URL\`
- Expected front host: \`$EXPECTED_FRONT_HOST\`
- Expected front path: \`$EXPECTED_FRONT_PATH\`
- Expected origin path: \`$EXPECTED_ORIGIN_PATH\`
- Control capture: \`${CONTROL_CAPTURE:-n/a}\`
- Candidate capture before test: \`${CANDIDATE_CAPTURE:-n/a}\`
- Candidate snapshot before test: \`${PRETEST_SNAPSHOT_PATH:-n/a}\`
- Candidate snapshot after test: \`${POSTTEST_SNAPSHOT_PATH:-n/a}\`
- Candidate capture after test: \`${POST_TEST_CAPTURE:-n/a}\`
- Server status: \`${SERVER_STATUS_PATH:-n/a}\`
- Server front journal: \`${SERVER_LOG_PATH:-n/a}\`
- Server front filtered journal: \`${SERVER_LOG_FILTERED_PATH:-n/a}\`
- Server front summary: \`${SERVER_LOG_SUMMARY_PATH:-n/a}\`
- Server confirmation: \`$SERVER_CONFIRMATION\`
- Server match count: \`$SERVER_MATCH_COUNT\`
- Device cellular probe summary: \`${DEVICE_PROBE_SUMMARY_PATH:-n/a}\`
- Device cellular interface: \`$DEVICE_INTERFACE_NAME\`
- Device front probe result: \`$DEVICE_FRONT_CURL_RESULT\`
- Device front probe output: \`${DEVICE_FRONT_CURL_PATH:-n/a}\`
- Device origin probe result: \`$DEVICE_ORIGIN_CURL_RESULT\`
- Device origin probe output: \`${DEVICE_ORIGIN_CURL_PATH:-n/a}\`
- run-test status: \`$RUN_TEST_STATUS\`
- run-test checkedAt: \`$RUN_TEST_CHECKED_AT\`
- run-test output: \`$RUN_TEST_OUTPUT\`
- run-test error: \`$RUN_TEST_ERROR\`
- Compare output: \`$COMPARE_OUTPUT\`
- Report draft: \`$REPORT_OUTPUT\`
- Blocked-direct checklist: \`$CHECKLIST_OUTPUT\`
- Stable restore enabled: \`$RESTORE_STABLE\`
- Stable restore capture: \`${RESTORE_CAPTURE:-n/a}\`
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PRESET="$2"
      shift 2
      ;;
    --plan-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_FILE="$2"
      shift 2
      ;;
    --plan-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_TAG="$2"
      shift 2
      ;;
    --plan-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_INDEX="$2"
      shift 2
      ;;
    --test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_URL="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --settle-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SETTLE_SECONDS="$2"
      shift 2
      ;;
    --run-preflight)
      RUN_PREFLIGHT="true"
      shift
      ;;
    --skip-restore)
      RESTORE_STABLE="false"
      shift
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

require_bin "$PYTHON_BIN" "python3"
require_bin "$SSH_BIN" "ssh"
require_bin "$ADB_BIN" "adb"
require_script "$SESSION_SCRIPT"
require_script "$APPLY_PRESET_SCRIPT"
require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$CAPTURE_SCRIPT"
require_script "$COMPARE_SCRIPT"
require_script "$REPORT_SCRIPT"
require_script "$CHECKLIST_SCRIPT"

if [[ -n "$PLAN_FILE" ]]; then
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "Plan file not found: $PLAN_FILE" >&2
    exit 1
  fi
  export ODIN_ONE_CDN_PLAN_FILE="$PLAN_FILE"
fi
if [[ -n "$PLAN_TAG" ]]; then
  export ODIN_ONE_CDN_PLAN_SELECT_TAG="$PLAN_TAG"
fi
if [[ -n "$PLAN_INDEX" ]]; then
  export ODIN_ONE_CDN_PLAN_SELECT_INDEX="$PLAN_INDEX"
fi

if ! [[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$SETTLE_SECONDS" -le 0 ]]; then
  echo "--settle-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$LOG_WINDOW_MARGIN_SECONDS" =~ ^[0-9]+$ ]] || [[ "$LOG_WINDOW_MARGIN_SECONDS" -lt 0 ]]; then
  echo "ODIN_ONE_CDN_FRONT_LOG_WINDOW_MARGIN_SECONDS must be a non-negative integer" >&2
  exit 1
fi
if [[ ! -r "$SERVER_KEY" ]]; then
  echo "SSH key not readable: $SERVER_KEY" >&2
  exit 1
fi

OUTPUT_LABEL="$(normalize_label "$PRESET")"
if [[ -z "$OUTPUT_LABEL" ]]; then
  OUTPUT_LABEL="cdn-front-hit-check"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-cdn-front-hit-check/${SESSION_STAMP}-${OUTPUT_LABEL}"
fi

BASE_SESSION_DIR="${OUTPUT_DIR%/}/base-session"
CAPTURE_DIR="${OUTPUT_DIR%/}/captures"
SUMMARY_PATH="${OUTPUT_DIR%/}/session-summary.md"
SERVER_LOG_PATH="${OUTPUT_DIR%/}/server-front-journal.txt"
SERVER_LOG_FILTERED_PATH="${OUTPUT_DIR%/}/server-front-journal-filtered.txt"
SERVER_LOG_SUMMARY_PATH="${OUTPUT_DIR%/}/server-front-hit-summary.md"
SERVER_STATUS_PATH="${OUTPUT_DIR%/}/server-front-status.txt"
DEVICE_PROBE_SUMMARY_PATH="${OUTPUT_DIR%/}/device-cellular-probe-summary.md"
DEVICE_FRONT_CURL_PATH="${OUTPUT_DIR%/}/device-cellular-front-curl.txt"
DEVICE_ORIGIN_CURL_PATH="${OUTPUT_DIR%/}/device-cellular-origin-curl.txt"
COMPARE_OUTPUT="${OUTPUT_DIR%/}/compare.md"
REPORT_OUTPUT="${OUTPUT_DIR%/}/report.md"
CHECKLIST_OUTPUT="${OUTPUT_DIR%/}/blocked-direct-checklist.md"
PRETEST_SNAPSHOT_PATH="${OUTPUT_DIR%/}/candidate-snapshot-before-test.json"
POSTTEST_SNAPSHOT_PATH="${OUTPUT_DIR%/}/candidate-snapshot-after-test.json"

mkdir -p "$OUTPUT_DIR" "$CAPTURE_DIR"

log_section "Base Session"
echo "Preset: $PRESET"
echo "Output dir: $OUTPUT_DIR"
echo "Test URL: $TEST_URL"
echo "Remote log service: $SERVER_SERVICE"

session_args=(--preset "$PRESET" --skip-restore --output-dir "$BASE_SESSION_DIR")
if [[ "$RUN_PREFLIGHT" != "true" ]]; then
  session_args+=(--skip-preflight)
fi
if [[ -n "$PLAN_FILE" ]]; then
  session_args+=(--plan-file "$PLAN_FILE")
fi
if [[ -n "$PLAN_TAG" ]]; then
  session_args+=(--plan-tag "$PLAN_TAG")
fi
if [[ -n "$PLAN_INDEX" ]]; then
  session_args+=(--plan-index "$PLAN_INDEX")
fi

"$SESSION_SCRIPT" "${session_args[@]}"
SESSION_CANDIDATE_ACTIVE="true"

if [[ ! -f "${BASE_SESSION_DIR}/session-summary.md" ]]; then
  echo "Base session summary missing: ${BASE_SESSION_DIR}/session-summary.md" >&2
  exit 1
fi
SUMMARY_PATH_BASE="${BASE_SESSION_DIR}/session-summary.md"
SUMMARY_PATH="$SUMMARY_PATH_BASE"
CONTROL_CAPTURE="$(summary_value "Control capture")"
CANDIDATE_CAPTURE="$(summary_value "Candidate capture")"
SUMMARY_PATH="${OUTPUT_DIR%/}/session-summary.md"

if [[ -z "$CONTROL_CAPTURE" || ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Unable to resolve base control capture path." >&2
  exit 1
fi
if [[ -z "$CANDIDATE_CAPTURE" || ! -f "$CANDIDATE_CAPTURE" ]]; then
  echo "Unable to resolve base candidate capture path." >&2
  exit 1
fi

log_section "Pre-Test Snapshot"
"$SERVICE_CONTROL_SCRIPT" print-snapshot >"$PRETEST_SNAPSHOT_PATH"
PREVIOUS_CHECKED_AT="$(snapshot_checked_at "$PRETEST_SNAPSHOT_PATH")"

log_section "run-test"
WINDOW_START_EPOCH="$("$DATE_BIN" -u '+%s')"
ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" run-test --url "$TEST_URL" >/dev/null
if [[ -n "$PREVIOUS_CHECKED_AT" ]]; then
  if "$SERVICE_CONTROL_SCRIPT" wait-test-result \
    --since "$PREVIOUS_CHECKED_AT" \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" >"$POSTTEST_SNAPSHOT_PATH"
  then
    RUN_TEST_STATUS="completed"
  else
    echo "Warning: run-test did not reach a terminal state before timeout; saving the current snapshot." >&2
    "$SERVICE_CONTROL_SCRIPT" print-snapshot >"$POSTTEST_SNAPSHOT_PATH"
    RUN_TEST_STATUS="timeout"
  fi
else
  if "$SERVICE_CONTROL_SCRIPT" wait-test-result \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" >"$POSTTEST_SNAPSHOT_PATH"
  then
    RUN_TEST_STATUS="completed"
  else
    echo "Warning: run-test did not reach a terminal state before timeout; saving the current snapshot." >&2
    "$SERVICE_CONTROL_SCRIPT" print-snapshot >"$POSTTEST_SNAPSHOT_PATH"
    RUN_TEST_STATUS="timeout"
  fi
fi
WINDOW_END_EPOCH="$("$DATE_BIN" -u '+%s')"

"$PYTHON_BIN" - "$POSTTEST_SNAPSHOT_PATH" <<'PY' >"${OUTPUT_DIR%/}/run-test-fields.txt"
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
last_test = snapshot.get("lastTest") or {}
for key in ("status", "checkedAt", "output", "error"):
    value = last_test.get(key)
    if value is None or value == "":
        value = "n/a"
    print(f"{key}={value}")
PY
RUN_TEST_STATUS_FIELD="$(grep '^status=' "${OUTPUT_DIR%/}/run-test-fields.txt" | head -n 1 | cut -d= -f2-)"
RUN_TEST_CHECKED_AT="$(grep '^checkedAt=' "${OUTPUT_DIR%/}/run-test-fields.txt" | head -n 1 | cut -d= -f2-)"
RUN_TEST_OUTPUT="$(grep '^output=' "${OUTPUT_DIR%/}/run-test-fields.txt" | head -n 1 | cut -d= -f2-)"
RUN_TEST_ERROR="$(grep '^error=' "${OUTPUT_DIR%/}/run-test-fields.txt" | head -n 1 | cut -d= -f2-)"
rm -f "${OUTPUT_DIR%/}/run-test-fields.txt"
if [[ "$RUN_TEST_STATUS" == "completed" ]]; then
  RUN_TEST_STATUS="$RUN_TEST_STATUS_FIELD"
fi

sleep "$SETTLE_SECONDS"

log_section "Post-Test Capture"
collect_capture "candidate-after-test"
POST_TEST_CAPTURE="$CAPTURE_RESULT"

"$PYTHON_BIN" - "$POSTTEST_SNAPSHOT_PATH" "$POST_TEST_CAPTURE" <<'PY' >"${OUTPUT_DIR%/}/expected-front-fields.txt"
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
capture_path = Path(sys.argv[2])
front_host = (snapshot.get("frontHost") or "").strip()
front_path = (snapshot.get("frontPath") or "").strip()
front_connect_host = str(snapshot.get("frontConnectHost") or "").strip()
front_connect_port = str(snapshot.get("frontConnectPort") or "").strip()
origin_path = ""
artifacts_dir = capture_path.with_suffix(".artifacts")
scaffold_path = artifacts_dir / "cdn-anti-whitelist-scaffold.json"
scaffold = None
if scaffold_path.exists():
    scaffold = json.loads(scaffold_path.read_text(encoding="utf-8"))
    origin = scaffold.get("selectedOrigin") or {}
    origin_path = str(origin.get("path") or "").strip()
if not front_path and scaffold is not None:
    front = scaffold.get("selectedFront") or {}
    front_path = str(front.get("path") or "").strip()
for key, value in (
    ("frontHost", front_host or "n/a"),
    ("frontConnectHost", front_connect_host or "n/a"),
    ("frontConnectPort", front_connect_port or "n/a"),
    ("frontPath", front_path or "n/a"),
    ("originPath", origin_path or "n/a"),
):
    print(f"{key}={value}")
PY
EXPECTED_FRONT_HOST="$(grep '^frontHost=' "${OUTPUT_DIR%/}/expected-front-fields.txt" | head -n 1 | cut -d= -f2-)"
EXPECTED_FRONT_CONNECT_HOST="$(grep '^frontConnectHost=' "${OUTPUT_DIR%/}/expected-front-fields.txt" | head -n 1 | cut -d= -f2-)"
EXPECTED_FRONT_CONNECT_PORT="$(grep '^frontConnectPort=' "${OUTPUT_DIR%/}/expected-front-fields.txt" | head -n 1 | cut -d= -f2-)"
EXPECTED_FRONT_PATH="$(grep '^frontPath=' "${OUTPUT_DIR%/}/expected-front-fields.txt" | head -n 1 | cut -d= -f2-)"
EXPECTED_ORIGIN_PATH="$(grep '^originPath=' "${OUTPUT_DIR%/}/expected-front-fields.txt" | head -n 1 | cut -d= -f2-)"
rm -f "${OUTPUT_DIR%/}/expected-front-fields.txt"

log_section "Remote Front Logs"
WINDOW_START_FETCH_EPOCH=$(( WINDOW_START_EPOCH - LOG_WINDOW_MARGIN_SECONDS ))
WINDOW_END_FETCH_EPOCH=$(( WINDOW_END_EPOCH + LOG_WINDOW_MARGIN_SECONDS ))
WINDOW_START_UTC="$(epoch_to_utc "$WINDOW_START_FETCH_EPOCH")"
WINDOW_END_UTC="$(epoch_to_utc "$WINDOW_END_FETCH_EPOCH")"

if run_ssh "printf 'host=%s\nservice=%s\nutc_now=%s\n' \"\$(hostname)\" \"$SERVER_SERVICE\" \"\$(date -u '+%Y-%m-%d %H:%M:%S')\"; systemctl is-active \"$SERVER_SERVICE\"" >"$SERVER_STATUS_PATH" 2>&1; then
  :
else
  echo "Warning: unable to fetch remote service status." >&2
fi

if run_ssh "journalctl -u \"$SERVER_SERVICE\" --utc --since \"$WINDOW_START_UTC\" --until \"$WINDOW_END_UTC\" --no-pager -o cat" >"$SERVER_LOG_PATH" 2>&1; then
  :
else
  echo "Warning: unable to fetch remote front journal window." >&2
fi

"$PYTHON_BIN" - "$SERVER_LOG_PATH" "$SERVER_LOG_FILTERED_PATH" "$SERVER_LOG_SUMMARY_PATH" "$EXPECTED_FRONT_HOST" "$EXPECTED_FRONT_PATH" "$EXPECTED_ORIGIN_PATH" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
filtered_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
expected_host = (sys.argv[4] or "").strip()
expected_front_path = (sys.argv[5] or "").strip()
expected_origin_path = (sys.argv[6] or "").strip()

raw_lines = []
if log_path.exists():
    raw_lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()

matches = []
for line in raw_lines:
    payload = line.strip()
    if not payload.startswith("{"):
        continue
    try:
        event = json.loads(payload)
    except json.JSONDecodeError:
        continue
    request = event.get("request") or {}
    host = str(request.get("host") or "").strip()
    uri = str(request.get("uri") or "").strip()
    headers = request.get("headers") or {}
    user_agents = headers.get("User-Agent") or headers.get("User-agent") or []
    user_agent = user_agents[0] if user_agents else ""
    if expected_host and host != expected_host:
        continue
    if expected_front_path not in {"", "n/a"} and uri.startswith(expected_front_path):
        pass
    elif expected_origin_path not in {"", "n/a"} and uri.startswith(expected_origin_path):
        pass
    else:
        continue
    if user_agent == "odin-one-cdn-preflight/1":
        continue
    matches.append(event)

filtered_lines = [json.dumps(item, ensure_ascii=False, separators=(",", ":")) for item in matches]
filtered_path.write_text("\n".join(filtered_lines) + ("\n" if filtered_lines else ""), encoding="utf-8")

confirmed = "yes" if matches else "no"
summary_lines = [
    "# Server Front Hit Summary",
    "",
    f"- expected host: `{expected_host or 'n/a'}`",
    f"- expected front path: `{expected_front_path or 'n/a'}`",
    f"- expected origin path: `{expected_origin_path or 'n/a'}`",
    f"- confirmed handset-front hit: `{confirmed}`",
    f"- matching log entries: `{len(matches)}`",
]
if matches:
    first = matches[0]
    request = first.get("request") or {}
    headers = request.get("headers") or {}
    user_agents = headers.get("User-Agent") or headers.get("User-agent") or []
    summary_lines.extend(
        [
            f"- first match method: `{request.get('method') or 'n/a'}`",
            f"- first match uri: `{request.get('uri') or 'n/a'}`",
            f"- first match remote ip: `{request.get('remote_ip') or 'n/a'}`",
            f"- first match user-agent: `{(user_agents[0] if user_agents else 'n/a')}`",
        ]
    )
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
print(f"confirmed={confirmed}")
print(f"match_count={len(matches)}")
PY
"$PYTHON_BIN" - "$SERVER_LOG_SUMMARY_PATH" <<'PY' >"${OUTPUT_DIR%/}/server-front-fields.txt"
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for key in ("confirmed handset-front hit", "matching log entries"):
    pattern = re.compile(rf"- {re.escape(key)}: `(.*)`")
    match = pattern.search(text)
    if match:
        name = "confirmed" if "confirmed" in key else "match_count"
        print(f"{name}={match.group(1)}")
PY
SERVER_CONFIRMATION="$(grep '^confirmed=' "${OUTPUT_DIR%/}/server-front-fields.txt" | head -n 1 | cut -d= -f2-)"
SERVER_MATCH_COUNT="$(grep '^match_count=' "${OUTPUT_DIR%/}/server-front-fields.txt" | head -n 1 | cut -d= -f2-)"
rm -f "${OUTPUT_DIR%/}/server-front-fields.txt"

log_section "Device Cellular Probes"
run_device_cellular_probes
echo "Wrote device probe summary to $DEVICE_PROBE_SUMMARY_PATH"

log_section "Compare"
"$COMPARE_SCRIPT" "$CONTROL_CAPTURE" "$POST_TEST_CAPTURE" | tee "$COMPARE_OUTPUT"

log_section "Report Draft"
"$REPORT_SCRIPT" "$CONTROL_CAPTURE" "$POST_TEST_CAPTURE" "$REPORT_OUTPUT"
echo "Wrote report draft to $REPORT_OUTPUT"

log_section "Blocked-Direct Checklist"
"$CHECKLIST_SCRIPT" "$CONTROL_CAPTURE" "$POST_TEST_CAPTURE" "$CHECKLIST_OUTPUT"
echo "Wrote blocked-direct checklist to $CHECKLIST_OUTPUT"

if [[ "$RESTORE_STABLE" == "true" ]]; then
  restore_stable_lane
fi

write_summary

log_section "Completed"
echo "Session summary: $SUMMARY_PATH"
echo "Base session dir: $BASE_SESSION_DIR"
echo "Control capture: $CONTROL_CAPTURE"
echo "Candidate before test: $CANDIDATE_CAPTURE"
echo "Candidate after test: $POST_TEST_CAPTURE"
echo "Server front summary: $SERVER_LOG_SUMMARY_PATH"
if [[ -n "$RESTORE_CAPTURE" ]]; then
  echo "Restore capture: $RESTORE_CAPTURE"
fi
echo "Compare: $COMPARE_OUTPUT"
echo "Report: $REPORT_OUTPUT"
echo "Checklist: $CHECKLIST_OUTPUT"
