#!/bin/zsh
set -euo pipefail

ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
PACKAGE_NAME="${ODIN_ONE_ANDROID_PACKAGE:-com.odinone.desktop.vk}"
ANDROID_SERIAL="${ODIN_ONE_ANDROID_SERIAL:-}"
WAKE_MAIN_ACTIVITY="${ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY:-false}"

SERVICE_COMPONENT="${PACKAGE_NAME}/.VpnRuntimeService"
DEBUG_RECEIVER_COMPONENT="${PACKAGE_NAME}/.VpnRuntimeDebugReceiver"
MAIN_ACTIVITY_COMPONENT="${PACKAGE_NAME}/.MainActivity"
ACTION_START="com.odinone.desktop.vk.action.START_VPN_RUNTIME"
ACTION_STOP="com.odinone.desktop.vk.action.STOP_VPN_RUNTIME"
ACTION_DEBUG_START="com.odinone.desktop.vk.action.DEBUG_START_VPN_RUNTIME"
ACTION_DEBUG_STOP="com.odinone.desktop.vk.action.DEBUG_STOP_VPN_RUNTIME"
ACTION_DEBUG_RUN_TEST="com.odinone.desktop.vk.action.DEBUG_RUN_VPN_CONNECTIVITY_TEST"
ACTION_DEBUG_REFRESH_RELAY_AUTOSELECT="com.odinone.desktop.vk.action.DEBUG_REFRESH_REALITY_RELAY_AUTOSELECT"
EXTRA_START_ARGS="start_args"
EXTRA_START_ARGS_BASE64="start_args_base64"
EXTRA_TEST_URL="test_url"

TMP_DIR="${TMPDIR:-/tmp}"
MKTEMP_BIN="/usr/bin/mktemp"
PREFS_FILE=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-runtime-service-control.sh print-request
  apps/desktop/scripts/android-runtime-service-control.sh print-attempted-request
  apps/desktop/scripts/android-runtime-service-control.sh print-snapshot
  apps/desktop/scripts/android-runtime-service-control.sh print-relay-autoselect-state
  apps/desktop/scripts/android-runtime-service-control.sh wait-snapshot [filters]
  apps/desktop/scripts/android-runtime-service-control.sh wait-test-result [filters]
  apps/desktop/scripts/android-runtime-service-control.sh start-from-prefs
  apps/desktop/scripts/android-runtime-service-control.sh start-from-attempted-request
  apps/desktop/scripts/android-runtime-service-control.sh start-from-json-file <path>
  apps/desktop/scripts/android-runtime-service-control.sh refresh-relay-autoselect-from-json-file <path>
  apps/desktop/scripts/android-runtime-service-control.sh stop
  apps/desktop/scripts/android-runtime-service-control.sh run-test [--url <https-url>]
  apps/desktop/scripts/android-runtime-service-control.sh start-direct-from-prefs
  apps/desktop/scripts/android-runtime-service-control.sh stop-direct

Commands:
  print-request     Print the persisted last_request JSON from shared prefs.
  print-attempted-request
                    Print the persisted last_attempted_request JSON from shared prefs.
  print-snapshot    Print the persisted snapshot JSON from shared prefs.
  print-relay-autoselect-state
                    Print the persisted hidden relay autoselect state JSON from shared prefs.
  wait-snapshot     Poll the persisted snapshot until it matches the requested filters.
  wait-test-result  Poll the persisted snapshot until lastTest reaches a terminal state.
  start-from-prefs  Send a debug-only broadcast that starts VpnRuntimeService with the persisted last_request JSON.
  start-from-attempted-request
                    Send a debug-only broadcast that starts VpnRuntimeService with the persisted last_attempted_request JSON.
  start-from-json-file
                    Send a debug-only broadcast that starts VpnRuntimeService with the JSON payload stored in <path>.
  refresh-relay-autoselect-from-json-file
                    Send a debug-only broadcast that refreshes relay autoselect using the JSON payload stored in <path>.
  stop              Send a debug-only broadcast that stops VpnRuntimeService.
  run-test          Send a debug-only broadcast that runs the Android VPN connectivity test.
  start-direct-from-prefs
                    Start VpnRuntimeService directly with the persisted last_request JSON.
  stop-direct       Send ACTION_STOP directly to VpnRuntimeService.

Environment:
  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY
                    Optional boolean. When true, front the app's MainActivity
                    before debug start. Default: false.

wait-snapshot filters:
  --family <value>          Match snapshot.runtimeFamily
  --status <value>          Match snapshot.status
  --activation <value>      Match snapshot.activationState
  --failure-code <value>    Match snapshot.lastFailureCode
  --timeout-seconds <int>   Default: 25
  --poll-seconds <int>      Default: 1

wait-test-result filters:
  --since <checked-at>      Wait for snapshot.lastTest.checkedAt to change from this value.
  --timeout-seconds <int>   Default: 45
  --poll-seconds <int>      Default: 1
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

adb_cmd() {
  if [[ -n "$ANDROID_SERIAL" ]]; then
    "$ADB_BIN" -s "$ANDROID_SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

cleanup() {
  rm -f "$PREFS_FILE"
}
trap cleanup EXIT INT TERM

capture_run_as_file() {
  local remote_path="$1"
  local target_file="$2"
  adb_cmd exec-out run-as "$PACKAGE_NAME" cat "$remote_path" >"$target_file" 2>/dev/null || return 1
  [[ -s "$target_file" ]] || return 1
  if /usr/bin/grep -qiE '^(cat:|run-as:|error:)' "$target_file"; then
    return 1
  fi
  return 0
}

load_runtime_payload() {
  if ! capture_run_as_file "shared_prefs/odin_one_vpn_runtime.xml" "$PREFS_FILE"; then
    echo "Unable to read shared_prefs/odin_one_vpn_runtime.xml via run-as." >&2
    exit 1
  fi

  "$PYTHON_BIN" - "$PREFS_FILE" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
raw = path.read_text(encoding="utf-8", errors="replace").strip()
if not raw:
    raise SystemExit("Shared prefs XML is empty.")

root = ET.fromstring(raw)
snapshot = None
last_request = None
last_attempted_request = None
for child in root:
    if child.tag != "string":
        continue
    name = child.attrib.get("name")
    value = child.text or ""
    if name == "snapshot":
        snapshot = value
    elif name == "last_request":
        last_request = value
    elif name == "last_attempted_request":
        last_attempted_request = value

payload = {}
if snapshot and snapshot.strip():
    payload["snapshot"] = json.loads(snapshot)
if last_request and last_request.strip():
    payload["last_request"] = json.loads(last_request)
if last_attempted_request and last_attempted_request.strip():
    payload["last_attempted_request"] = json.loads(last_attempted_request)

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

load_last_request() {
  local payload
  payload="$(load_runtime_payload)"
  "$PYTHON_BIN" - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
last_request = payload.get("last_request")
if not isinstance(last_request, dict):
    raise SystemExit("No persisted last_request found.")
print(json.dumps(last_request, ensure_ascii=False, separators=(",", ":")))
PY
}

load_last_attempted_request() {
  local payload
  payload="$(load_runtime_payload)"
  "$PYTHON_BIN" - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
last_attempted_request = payload.get("last_attempted_request")
if not isinstance(last_attempted_request, dict):
    raise SystemExit("No persisted last_attempted_request found.")
print(json.dumps(last_attempted_request, ensure_ascii=False, separators=(",", ":")))
PY
}

load_last_request_base64() {
  local start_args
  start_args="$(load_last_request)"
  encode_json_base64 "$start_args"
}

encode_json_base64() {
  local start_args="$1"
  "$PYTHON_BIN" - "$start_args" <<'PY'
import base64
import sys

raw = sys.argv[1]
print(base64.b64encode(raw.encode("utf-8")).decode("ascii"))
PY
}

load_last_attempted_request_base64() {
  local start_args
  start_args="$(load_last_attempted_request)"
  encode_json_base64 "$start_args"
}

wake_main_activity() {
  adb_cmd shell am start \
    -W \
    -n "$MAIN_ACTIVITY_COMPONENT" \
    -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER >/dev/null
}

should_wake_main_activity() {
  case "${WAKE_MAIN_ACTIVITY:l}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_snapshot() {
  local payload
  payload="$(load_runtime_payload)"
  "$PYTHON_BIN" - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
snapshot = payload.get("snapshot")
if not isinstance(snapshot, dict):
    raise SystemExit("No persisted snapshot found.")
print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
}

load_relay_autoselect_state() {
  if ! capture_run_as_file "shared_prefs/odin_one_vpn_runtime.xml" "$PREFS_FILE"; then
    echo "Unable to read shared_prefs/odin_one_vpn_runtime.xml via run-as." >&2
    exit 1
  fi
  "$PYTHON_BIN" - "$PREFS_FILE" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
raw = path.read_text(encoding="utf-8", errors="replace").strip()
if not raw:
    raise SystemExit("Shared prefs XML is empty.")

root = ET.fromstring(raw)
for child in root:
    if child.tag != "string":
        continue
    if child.attrib.get("name") != "reality_relay_autoselect_state":
        continue
    value = (child.text or "").strip()
    if not value:
        raise SystemExit("No persisted reality_relay_autoselect_state found.")
    print(json.dumps(json.loads(value), ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(0)

raise SystemExit("No persisted reality_relay_autoselect_state found.")
PY
}

start_from_prefs() {
  local start_args_b64
  start_args_b64="$(load_last_request_base64)"
  start_from_base64 "$start_args_b64"
}

start_from_attempted_request() {
  local start_args_b64
  start_args_b64="$(load_last_attempted_request_base64)"
  start_from_base64 "$start_args_b64"
}

start_from_json_file() {
  local json_path="${1:-}"
  if [[ -z "$json_path" || ! -f "$json_path" ]]; then
    echo "JSON file not found: $json_path" >&2
    exit 1
  fi
  local start_args_b64
  start_args_b64="$("$PYTHON_BIN" - "$json_path" <<'PY'
import json
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
payload = json.loads(path.read_text(encoding="utf-8"))
raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
print(base64.b64encode(raw.encode("utf-8")).decode("ascii"))
PY
)"
  start_from_base64 "$start_args_b64"
}

refresh_relay_autoselect_from_json_file() {
  local json_path="${1:-}"
  if [[ -z "$json_path" || ! -f "$json_path" ]]; then
    echo "JSON file not found: $json_path" >&2
    exit 1
  fi
  local start_args_b64
  start_args_b64="$("$PYTHON_BIN" - "$json_path" <<'PY'
import json
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
payload = json.loads(path.read_text(encoding="utf-8"))
raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
print(base64.b64encode(raw.encode("utf-8")).decode("ascii"))
PY
)"
  refresh_relay_autoselect_from_base64 "$start_args_b64"
}

start_from_base64() {
  local start_args_b64="$1"
  if should_wake_main_activity; then
    wake_main_activity
  fi
  adb_cmd shell am broadcast \
    --include-stopped-packages \
    -n "$DEBUG_RECEIVER_COMPONENT" \
    -a "$ACTION_DEBUG_START" \
    --es "$EXTRA_START_ARGS_BASE64" "$start_args_b64"
}

refresh_relay_autoselect_from_base64() {
  local start_args_b64="$1"
  if should_wake_main_activity; then
    wake_main_activity
  fi
  adb_cmd shell am broadcast \
    --include-stopped-packages \
    -n "$DEBUG_RECEIVER_COMPONENT" \
    -a "$ACTION_DEBUG_REFRESH_RELAY_AUTOSELECT" \
    --es "$EXTRA_START_ARGS_BASE64" "$start_args_b64"
}

stop_service() {
  if should_wake_main_activity; then
    wake_main_activity
  fi
  adb_cmd shell am broadcast \
    --include-stopped-packages \
    -n "$DEBUG_RECEIVER_COMPONENT" \
    -a "$ACTION_DEBUG_STOP"
}

start_direct_from_prefs() {
  local start_args_b64
  start_args_b64="$(load_last_request_base64)"
  adb_cmd shell am start-foreground-service \
    -n "$SERVICE_COMPONENT" \
    -a "$ACTION_START" \
    --es "$EXTRA_START_ARGS_BASE64" "$start_args_b64"
}

stop_direct_service() {
  adb_cmd shell am start-service \
    -n "$SERVICE_COMPONENT" \
    -a "$ACTION_STOP"
}

run_test() {
  local target_url="https://example.com"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        [[ $# -ge 2 ]] || { echo "--url requires a value" >&2; exit 1; }
        target_url="$2"
        shift 2
        ;;
      *)
        echo "Unknown run-test argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if should_wake_main_activity; then
    wake_main_activity
  fi

  adb_cmd shell am broadcast \
    --include-stopped-packages \
    -n "$DEBUG_RECEIVER_COMPONENT" \
    -a "$ACTION_DEBUG_RUN_TEST" \
    --es "$EXTRA_TEST_URL" "$target_url"
}

wait_snapshot() {
  local expected_family=""
  local expected_status=""
  local expected_activation=""
  local expected_failure_code=""
  local timeout_seconds="25"
  local poll_seconds="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --family)
        [[ $# -ge 2 ]] || { echo "--family requires a value" >&2; exit 1; }
        expected_family="$2"
        shift 2
        ;;
      --status)
        [[ $# -ge 2 ]] || { echo "--status requires a value" >&2; exit 1; }
        expected_status="$2"
        shift 2
        ;;
      --activation)
        [[ $# -ge 2 ]] || { echo "--activation requires a value" >&2; exit 1; }
        expected_activation="$2"
        shift 2
        ;;
      --failure-code)
        [[ $# -ge 2 ]] || { echo "--failure-code requires a value" >&2; exit 1; }
        expected_failure_code="$2"
        shift 2
        ;;
      --timeout-seconds)
        [[ $# -ge 2 ]] || { echo "--timeout-seconds requires a value" >&2; exit 1; }
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-seconds)
        [[ $# -ge 2 ]] || { echo "--poll-seconds requires a value" >&2; exit 1; }
        poll_seconds="$2"
        shift 2
        ;;
      *)
        echo "Unknown wait-snapshot argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -le 0 ]]; then
    echo "--timeout-seconds must be a positive integer" >&2
    exit 1
  fi
  if ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] || [[ "$poll_seconds" -le 0 ]]; then
    echo "--poll-seconds must be a positive integer" >&2
    exit 1
  fi

  local elapsed=0
  local payload=""
  local snapshot_json=""
  while (( elapsed <= timeout_seconds )); do
    payload="$(load_runtime_payload 2>/dev/null || true)"
    if [[ -n "$payload" ]]; then
      snapshot_json="$("$PYTHON_BIN" - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
snapshot = payload.get("snapshot")
if isinstance(snapshot, dict):
    print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
)"
      if [[ -n "$snapshot_json" ]]; then
        if SNAPSHOT_JSON="$snapshot_json" \
          EXPECTED_FAMILY="$expected_family" \
          EXPECTED_STATUS="$expected_status" \
          EXPECTED_ACTIVATION="$expected_activation" \
          EXPECTED_FAILURE_CODE="$expected_failure_code" \
          "$PYTHON_BIN" - <<'PY'
import json
import os

snapshot = json.loads(os.environ["SNAPSHOT_JSON"])

checks = {
    "runtimeFamily": os.environ.get("EXPECTED_FAMILY", "").strip(),
    "status": os.environ.get("EXPECTED_STATUS", "").strip(),
    "activationState": os.environ.get("EXPECTED_ACTIVATION", "").strip(),
    "lastFailureCode": os.environ.get("EXPECTED_FAILURE_CODE", "").strip(),
}

for key, expected in checks.items():
    if expected and str(snapshot.get(key, "")).strip() != expected:
        raise SystemExit(1)
print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
        then
          return 0
        fi
      fi
    fi
    sleep "$poll_seconds"
    (( elapsed += poll_seconds ))
  done

  echo "Timed out waiting for snapshot filters." >&2
  if [[ -n "$snapshot_json" ]]; then
    echo "Last observed snapshot: $snapshot_json" >&2
  fi
  return 1
}

wait_test_result() {
  local expected_since=""
  local timeout_seconds="45"
  local poll_seconds="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        [[ $# -ge 2 ]] || { echo "--since requires a value" >&2; exit 1; }
        expected_since="$2"
        shift 2
        ;;
      --timeout-seconds)
        [[ $# -ge 2 ]] || { echo "--timeout-seconds requires a value" >&2; exit 1; }
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-seconds)
        [[ $# -ge 2 ]] || { echo "--poll-seconds requires a value" >&2; exit 1; }
        poll_seconds="$2"
        shift 2
        ;;
      *)
        echo "Unknown wait-test-result argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -le 0 ]]; then
    echo "--timeout-seconds must be a positive integer" >&2
    exit 1
  fi
  if ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] || [[ "$poll_seconds" -le 0 ]]; then
    echo "--poll-seconds must be a positive integer" >&2
    exit 1
  fi

  local elapsed=0
  local snapshot_json=""
  while (( elapsed <= timeout_seconds )); do
    snapshot_json="$(load_snapshot 2>/dev/null || true)"
    if [[ -n "$snapshot_json" ]]; then
      if SNAPSHOT_JSON="$snapshot_json" EXPECTED_SINCE="$expected_since" "$PYTHON_BIN" - <<'PY'
import json
import os

snapshot = json.loads(os.environ["SNAPSHOT_JSON"])
expected_since = os.environ.get("EXPECTED_SINCE", "").strip()
last_test = snapshot.get("lastTest")
if not isinstance(last_test, dict):
    raise SystemExit(1)
status = str(last_test.get("status") or "").strip().lower()
checked_at = str(last_test.get("checkedAt") or "").strip()
if status not in {"passed", "failed"}:
    raise SystemExit(1)
if expected_since and checked_at == expected_since:
    raise SystemExit(1)
print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
      then
        return 0
      fi
    fi
    sleep "$poll_seconds"
    (( elapsed += poll_seconds ))
  done

  echo "Timed out waiting for a terminal lastTest result." >&2
  if [[ -n "$snapshot_json" ]]; then
    echo "Last observed snapshot: $snapshot_json" >&2
  fi
  return 1
}

command="${1:-}"

if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
  usage
  exit 0
fi

require_bin "$ADB_BIN" "adb"
require_bin "$PYTHON_BIN" "python3"
require_bin "$MKTEMP_BIN" "mktemp"

PREFS_FILE="$("$MKTEMP_BIN" "${TMP_DIR%/}/odin-one-android-runtime-service-control.XXXXXX")"

case "$command" in
  print-request)
    load_last_request
    ;;
  print-attempted-request)
    load_last_attempted_request
    ;;
  print-snapshot)
    load_snapshot
    ;;
  print-relay-autoselect-state)
    load_relay_autoselect_state
    ;;
  wait-snapshot)
    shift
    wait_snapshot "$@"
    ;;
  wait-test-result)
    shift
    wait_test_result "$@"
    ;;
  start-from-prefs)
    start_from_prefs
    ;;
  start-from-attempted-request)
    start_from_attempted_request
    ;;
  start-from-json-file)
    shift
    start_from_json_file "${1:-}"
    ;;
  refresh-relay-autoselect-from-json-file)
    shift
    refresh_relay_autoselect_from_json_file "${1:-}"
    ;;
  stop)
    stop_service
    ;;
  run-test)
    shift
    run_test "$@"
    ;;
  start-direct-from-prefs)
    start_direct_from_prefs
    ;;
  stop-direct)
    stop_direct_service
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
