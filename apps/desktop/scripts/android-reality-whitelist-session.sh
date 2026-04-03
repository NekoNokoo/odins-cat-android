#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

APPLY_PRESET_SCRIPT="${SCRIPT_DIR}/android-reality-apply-preset.sh"
SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
CAPTURE_SCRIPT="${SCRIPT_DIR}/android-reality-capture-run.sh"
COMPARE_SCRIPT="${SCRIPT_DIR}/android-runtime-compare-captures.sh"
REPORT_SCRIPT="${SCRIPT_DIR}/android-runtime-report-draft.sh"
CHECKLIST_SCRIPT="${SCRIPT_DIR}/android-blocked-direct-checklist.sh"

PRESET="reality-whitelist-scaffold"
CONTROL_CAPTURE=""
SETTLE_SECONDS="8"
RESTORE_STABLE="true"
OUTPUT_DIR=""
HINTS_FILE="${ODIN_ONE_REALITY_HINTS_FILE:-}"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-25}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"
STABLE_BASELINE_RETRY_COUNT="${ODIN_ONE_REALITY_STABLE_BASELINE_RETRY_COUNT:-3}"
RUN_CONNECTIVITY_TEST="${ODIN_ONE_REALITY_RUN_CONNECTIVITY_TEST:-auto}"
TEST_URL="${ODIN_ONE_REALITY_TEST_URL:-https://example.com}"
TEST_MODE="${ODIN_ONE_REALITY_TEST_MODE:-auto}"
TEST_WAIT_TIMEOUT_SECONDS="${ODIN_ONE_REALITY_TEST_WAIT_TIMEOUT_SECONDS:-20}"
HINT_SELECT_TAG="${ODIN_ONE_REALITY_HINT_SELECT_TAG:-}"
HINT_SELECT_INDEX="${ODIN_ONE_REALITY_HINT_SELECT_INDEX:-}"
CANDIDATE_MISMATCH_RETRY_COUNT="${ODIN_ONE_REALITY_CANDIDATE_MISMATCH_RETRY_COUNT:-1}"

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
SESSION_LABEL=""
CAPTURE_DIR=""
COMPARE_OUTPUT=""
REPORT_OUTPUT=""
CHECKLIST_OUTPUT=""
SESSION_SUMMARY=""
CONTROL_CAPTURE_RESULT=""
CANDIDATE_CAPTURE_RESULT=""
RESTORE_CAPTURE_RESULT=""
CANDIDATE_APPLIED="false"
RESTORE_DONE="false"
OBSERVED_CANDIDATE_FAMILY=""
OBSERVED_CANDIDATE_ACTIVATION=""
OBSERVED_CANDIDATE_STATUS=""
CANDIDATE_ATTEMPTS_USED="0"
CANDIDATE_DISPATCH_CLASS=""
CANDIDATE_REQUEST_SOURCE=""
CANDIDATE_REQUEST_HIDDEN_ENABLED=""
CANDIDATE_REQUEST_HINT_TAG=""
CANDIDATE_REQUEST_HINT_SERVER=""
CANDIDATE_TEST_STATUS=""
CANDIDATE_TEST_OUTPUT=""
CANDIDATE_TEST_ERROR=""
CANDIDATE_TEST_URL=""
CANDIDATE_HINT_TEST_STATUS=""
CANDIDATE_HINT_TEST_OUTPUT=""
CANDIDATE_HINT_TEST_ERROR=""
CANDIDATE_HINT_TEST_URL=""
CANDIDATE_PROBE_MODE=""
CANDIDATE_PROBE_COUNT="0"
CANDIDATE_PROBE_PASS_COUNT="0"
CANDIDATE_PROBE_MATRIX_JSON=""
CANDIDATE_OUTBOUND_EOF_COUNT="0"
CANDIDATE_HEALTH_CLASS=""
CANDIDATE_HEALTH_NOTES=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-session.sh [options]

Options:
  --hints-file <file>          Curated whitelist hint dataset JSON.
  --preset <preset>            Hidden preset to run. Default: reality-whitelist-scaffold
  --control-capture <file>     Reuse an existing stable control capture.
  --output-dir <dir>           Session directory. Default: /tmp/odin-one-android-reality-whitelist-runs/<stamp>-<preset>
  --settle-seconds <seconds>   Seconds to wait after each start-from-prefs. Default: 8
  --wait-timeout-seconds <n>   Snapshot wait timeout. Default: 25
  --wait-poll-seconds <n>      Snapshot wait poll interval. Default: 1
  --candidate-mismatch-retry-count <n>
                               Retry candidate start when the handset unexpectedly
                               stays on the stable family. Default: 1
  --run-connectivity-test <auto|true|false>
                               Run a debug-only quick probe after candidate start.
                               Default: auto (`true` for reality-whitelist-lab).
  --test-url <url>             URL for the quick probe. Default: https://example.com
  --test-mode <auto|single|matrix>
                               Probe strategy after candidate start. `matrix` runs the
                               generic test URL plus `https://<selectedSniHint>/`.
                               Default: auto (`matrix` for reality-whitelist-lab).
  --test-wait-timeout-seconds <n>
                               Connectivity test wait timeout. Default: 20
  --hint-tag <tag>             Select one hint by tag from the curated dataset.
  --hint-index <n>             Select one hint by 1-based index from the curated dataset.
  --skip-restore               Leave the handset on the candidate lane at the end.
  -h, --help                   Show this help.

Environment:
  ODIN_ONE_REALITY_HINTS_FILE  Optional curated dataset JSON. When set, the hidden
                               preset will use its `hints` array instead of placeholder values.
  ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS
                               Optional default for --wait-timeout-seconds.
  ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS
                               Optional default for --wait-poll-seconds.
  ODIN_ONE_REALITY_STABLE_BASELINE_RETRY_COUNT
                               Optional default for stable baseline retries.
  ODIN_ONE_REALITY_RUN_CONNECTIVITY_TEST
                               Optional default for --run-connectivity-test.
  ODIN_ONE_REALITY_TEST_URL    Optional default for --test-url.
  ODIN_ONE_REALITY_TEST_MODE   Optional default for --test-mode.
  ODIN_ONE_REALITY_TEST_WAIT_TIMEOUT_SECONDS
                               Optional default for --test-wait-timeout-seconds.
  ODIN_ONE_REALITY_HINT_SELECT_TAG
                               Optional default for --hint-tag.
  ODIN_ONE_REALITY_HINT_SELECT_INDEX
                               Optional default for --hint-index.
  ODIN_ONE_REALITY_CANDIDATE_MISMATCH_RETRY_COUNT
                               Optional default for --candidate-mismatch-retry-count.

This helper is additive and owner-only:
  1. Captures a stable control lane.
  2. Applies the hidden whitelist-assisted preset.
  3. Captures the candidate lane.
  4. Builds compare/report/checklist artifacts.
  5. Restores the handset to stable baseline unless --skip-restore is used.
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

current_epoch_seconds() {
  "$DATE_BIN" '+%s'
}

expected_candidate_activation() {
  if [[ "$PRESET" == "reality-whitelist-lab" ]]; then
    printf 'active'
  else
    printf 'scaffold_only'
  fi
}

expected_candidate_status() {
  if [[ "$PRESET" == "reality-whitelist-lab" ]]; then
    printf 'running'
  else
    printf ''
  fi
}

log_section() {
  echo
  echo "=== $1 ==="
}

write_session_summary() {
  cat >"$SESSION_SUMMARY" <<EOF
# Android REALITY Whitelist-Assisted Session

- Session preset: \`$PRESET\`
- Session directory: \`$OUTPUT_DIR\`
- Curated hints file: \`${HINTS_FILE:-n/a}\`
- Hint select tag: \`${HINT_SELECT_TAG:-n/a}\`
- Hint select index: \`${HINT_SELECT_INDEX:-n/a}\`
- Control capture: \`${CONTROL_CAPTURE_RESULT:-$CONTROL_CAPTURE}\`
- Candidate capture: \`${CANDIDATE_CAPTURE_RESULT:-n/a}\`
- Compare output: \`$COMPARE_OUTPUT\`
- Report draft: \`$REPORT_OUTPUT\`
- Blocked-direct checklist: \`$CHECKLIST_OUTPUT\`
- Stable restore enabled: \`$RESTORE_STABLE\`
- Stable restore capture: \`${RESTORE_CAPTURE_RESULT:-n/a}\`
- Candidate attempts used: \`${CANDIDATE_ATTEMPTS_USED:-0}\`
- Observed candidate family: \`${OBSERVED_CANDIDATE_FAMILY:-n/a}\`
- Observed candidate activation: \`${OBSERVED_CANDIDATE_ACTIVATION:-n/a}\`
- Observed candidate status: \`${OBSERVED_CANDIDATE_STATUS:-n/a}\`
- Candidate dispatch class: \`${CANDIDATE_DISPATCH_CLASS:-n/a}\`
- Candidate request source: \`${CANDIDATE_REQUEST_SOURCE:-n/a}\`
- Candidate request hidden enabled: \`${CANDIDATE_REQUEST_HIDDEN_ENABLED:-n/a}\`
- Candidate request hint tag: \`${CANDIDATE_REQUEST_HINT_TAG:-n/a}\`
- Candidate request hint server: \`${CANDIDATE_REQUEST_HINT_SERVER:-n/a}\`
- Candidate test status: \`${CANDIDATE_TEST_STATUS:-n/a}\`
- Candidate test url: \`${CANDIDATE_TEST_URL:-n/a}\`
- Candidate test output: \`${CANDIDATE_TEST_OUTPUT:-n/a}\`
- Candidate test error: \`${CANDIDATE_TEST_ERROR:-n/a}\`
- Candidate hint test status: \`${CANDIDATE_HINT_TEST_STATUS:-n/a}\`
- Candidate hint test url: \`${CANDIDATE_HINT_TEST_URL:-n/a}\`
- Candidate hint test output: \`${CANDIDATE_HINT_TEST_OUTPUT:-n/a}\`
- Candidate hint test error: \`${CANDIDATE_HINT_TEST_ERROR:-n/a}\`
- Candidate probe mode: \`${CANDIDATE_PROBE_MODE:-n/a}\`
- Candidate probe count: \`${CANDIDATE_PROBE_COUNT:-0}\`
- Candidate probe pass count: \`${CANDIDATE_PROBE_PASS_COUNT:-0}\`
- Candidate probe matrix: \`${CANDIDATE_PROBE_MATRIX_JSON:-n/a}\`
- Candidate outbound EOF count: \`${CANDIDATE_OUTBOUND_EOF_COUNT:-0}\`
- Candidate health class: \`${CANDIDATE_HEALTH_CLASS:-n/a}\`
- Candidate health notes: \`${CANDIDATE_HEALTH_NOTES:-n/a}\`
EOF
}

restore_stable_lane() {
  log_section "Restoring Stable Lane"
  if ! start_stable_baseline "stable restore"; then
    echo "Warning: continuing with restore capture after baseline retries were exhausted." >&2
  fi
  if [[ -n "${CAPTURE_DIR:-}" ]]; then
    collect_capture "stable-restored"
    RESTORE_CAPTURE_RESULT="$CAPTURE_RESULT"
    if ! stable_snapshot_matches; then
      echo "Warning: restore capture did not reach direct-reality/active/running; retrying with an explicit stop/start recovery pass." >&2
      "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
      sleep 1
      if ! start_stable_baseline "stable restore fallback"; then
        echo "Warning: fallback stable restore still did not reach direct-reality/running." >&2
      fi
      collect_capture "stable-restored-final"
      RESTORE_CAPTURE_RESULT="$CAPTURE_RESULT"
    fi
  fi
  RESTORE_DONE="true"
}

cleanup() {
  if [[ "$RESTORE_STABLE" == "true" && "$CANDIDATE_APPLIED" == "true" && "$RESTORE_DONE" != "true" ]]; then
    echo >&2
    echo "Best-effort restore: returning handset to stable baseline..." >&2
    if "$APPLY_PRESET_SCRIPT" baseline >/dev/null 2>&1; then
      ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true \
        "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM

collect_capture() {
  local label="$1"
  local capture_output
  capture_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "$label")"
  printf '%s\n' "$capture_output"
  CAPTURE_RESULT="$(printf '%s\n' "$capture_output" | "$SED_BIN" -n 's/^Wrote handset dump to //p' | tail -n 1)"
  if [[ -z "$CAPTURE_RESULT" || ! -f "$CAPTURE_RESULT" ]]; then
    echo "Unable to determine capture path for label: $label" >&2
    exit 1
  fi
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
  echo "Warning: timed out waiting for snapshot state during ${label}; continuing with capture." >&2
  return 0
}

snapshot_field() {
  local field_name="$1"
  local snapshot_json
  snapshot_json="$("$SERVICE_CONTROL_SCRIPT" print-snapshot 2>/dev/null || true)"
  [[ -n "$snapshot_json" ]] || return 1

  SNAPSHOT_JSON="$snapshot_json" SNAPSHOT_FIELD="$field_name" "$PYTHON_BIN" - <<'PY'
import json
import os

snapshot = json.loads(os.environ["SNAPSHOT_JSON"])
field_name = os.environ["SNAPSHOT_FIELD"]
value = snapshot
for part in field_name.split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value.get(part)
if value is None:
    raise SystemExit(1)
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
else:
    print(str(value))
PY
}

should_run_connectivity_test() {
  case "${RUN_CONNECTIVITY_TEST:l}" in
    auto)
      [[ "$PRESET" == "reality-whitelist-lab" ]]
      ;;
    1|true|yes|on)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    *)
      echo "Unsupported --run-connectivity-test value: $RUN_CONNECTIVITY_TEST" >&2
      exit 1
      ;;
  esac
}

resolved_test_mode() {
  case "${TEST_MODE:l}" in
    auto)
      if [[ "$PRESET" == "reality-whitelist-lab" ]]; then
        printf 'matrix'
      else
        printf 'single'
      fi
      ;;
    single|matrix)
      printf '%s' "${TEST_MODE:l}"
      ;;
    *)
      echo "Unsupported --test-mode value: $TEST_MODE" >&2
      exit 1
      ;;
  esac
}

append_probe_result_json() {
  local label="$1"
  local url="$2"
  local probe_status_value="$3"
  local output="$4"
  local error="$5"
  local result_path="$6"
  PROBE_LABEL="$label" \
  PROBE_URL="$url" \
  PROBE_STATUS="$probe_status_value" \
    PROBE_OUTPUT="$output" \
    PROBE_ERROR="$error" \
    PROBE_RESULT_PATH="$result_path" \
    "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["PROBE_RESULT_PATH"])
payload = []
if path.is_file():
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        payload = []
if not isinstance(payload, list):
    payload = []
payload.append(
    {
        "label": os.environ["PROBE_LABEL"],
        "url": os.environ["PROBE_URL"],
        "status": os.environ["PROBE_STATUS"] or None,
        "output": os.environ["PROBE_OUTPUT"] or None,
        "error": os.environ["PROBE_ERROR"] or None,
    }
)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

run_single_connectivity_test() {
  local label="$1"
  local target_url="$2"
  local deadline=$(( $(current_epoch_seconds) + TEST_WAIT_TIMEOUT_SECONDS ))
  local current_status=""

  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true \
    "$SERVICE_CONTROL_SCRIPT" run-test --url "$target_url" >/dev/null

  while (( $(current_epoch_seconds) <= deadline )); do
    current_status="$(snapshot_field "lastTest.status" || true)"
    if [[ "$current_status" == "passed" || "$current_status" == "failed" ]]; then
      break
    fi
    sleep "$WAIT_POLL_SECONDS"
  done

  local probe_status probe_output probe_error probe_url
  probe_status="$(snapshot_field "lastTest.status" || true)"
  probe_output="$(snapshot_field "lastTest.output" || true)"
  probe_error="$(snapshot_field "lastTest.error" || true)"
  probe_url="$(snapshot_field "lastTest.url" || printf '%s' "$target_url")"

  case "$label" in
    generic_primary)
      CANDIDATE_TEST_STATUS="$probe_status"
      CANDIDATE_TEST_OUTPUT="$probe_output"
      CANDIDATE_TEST_ERROR="$probe_error"
      CANDIDATE_TEST_URL="$probe_url"
      ;;
    hint_https)
      CANDIDATE_HINT_TEST_STATUS="$probe_status"
      CANDIDATE_HINT_TEST_OUTPUT="$probe_output"
      CANDIDATE_HINT_TEST_ERROR="$probe_error"
      CANDIDATE_HINT_TEST_URL="$probe_url"
      ;;
  esac

  if [[ -n "$CANDIDATE_PROBE_MATRIX_JSON" ]]; then
    append_probe_result_json "$label" "$probe_url" "$probe_status" "$probe_output" "$probe_error" "$CANDIDATE_PROBE_MATRIX_JSON"
  fi
}

run_candidate_connectivity_test() {
  local mode hint_server hint_url
  mode="$(resolved_test_mode)"
  CANDIDATE_PROBE_MODE="$mode"
  CANDIDATE_TEST_STATUS=""
  CANDIDATE_TEST_OUTPUT=""
  CANDIDATE_TEST_ERROR=""
  CANDIDATE_TEST_URL="$TEST_URL"
  CANDIDATE_HINT_TEST_STATUS=""
  CANDIDATE_HINT_TEST_OUTPUT=""
  CANDIDATE_HINT_TEST_ERROR=""
  CANDIDATE_HINT_TEST_URL=""
  CANDIDATE_PROBE_COUNT="0"
  CANDIDATE_PROBE_PASS_COUNT="0"
  CANDIDATE_PROBE_MATRIX_JSON="${OUTPUT_DIR%/}/candidate-probe-matrix.json"
  : > "$CANDIDATE_PROBE_MATRIX_JSON"

  hint_server="$(snapshot_field "selectedSniHint" || true)"
  hint_url=""
  if [[ -n "$hint_server" ]]; then
    hint_url="https://${hint_server}/"
  fi

  if [[ "$mode" == "matrix" && -n "$hint_url" && "$hint_url" != "$TEST_URL" ]]; then
    run_single_connectivity_test "hint_https" "$hint_url"
  fi
  run_single_connectivity_test "generic_primary" "$TEST_URL"

  if [[ -f "$CANDIDATE_PROBE_MATRIX_JSON" ]]; then
    local counts
    counts="$("$PYTHON_BIN" - "$CANDIDATE_PROBE_MATRIX_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, list):
    payload = []
count = len(payload)
passed = sum(1 for item in payload if isinstance(item, dict) and item.get("status") == "passed")
print(f"{count}\t{passed}")
PY
)"
    CANDIDATE_PROBE_COUNT="${counts%%$'\t'*}"
    CANDIDATE_PROBE_PASS_COUNT="${counts#*$'\t'}"
  fi
}

stable_snapshot_matches() {
  local family activation snapshot_status
  family="$(snapshot_field runtimeFamily || true)"
  activation="$(snapshot_field activationState || true)"
  snapshot_status="$(snapshot_field status || true)"
  [[ "$family" == "direct-reality" && "$activation" == "active" && "$snapshot_status" == "running" ]]
}

refresh_candidate_snapshot_observation() {
  OBSERVED_CANDIDATE_FAMILY="$(snapshot_field runtimeFamily || true)"
  OBSERVED_CANDIDATE_ACTIVATION="$(snapshot_field activationState || true)"
  OBSERVED_CANDIDATE_STATUS="$(snapshot_field status || true)"
}

refresh_candidate_capture_observation() {
  local capture_path="$1"
  if [[ -z "$capture_path" || ! -f "$capture_path" ]]; then
    return 1
  fi

  local artifact_dir="${capture_path%.txt}.artifacts"
  local runtime_xml="${artifact_dir}/odin-one-vpn-runtime.xml"
  local parsed_output=""

  parsed_output="$("$PYTHON_BIN" - "$capture_path" "$runtime_xml" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

capture_path = Path(sys.argv[1])
runtime_xml_path = Path(sys.argv[2])

snapshot = {}
text = capture_path.read_text(encoding="utf-8", errors="replace")
marker = "Snapshot JSON:\n"
index = text.find(marker)
if index != -1:
    payload = text[index + len(marker):].lstrip()
    try:
        snapshot, _ = json.JSONDecoder().raw_decode(payload)
    except json.JSONDecodeError:
        snapshot = {}
if not isinstance(snapshot, dict):
    snapshot = {}

request = {}
last_request = {}
last_attempted_request = {}
if runtime_xml_path.is_file():
    root = ET.fromstring(runtime_xml_path.read_text(encoding="utf-8", errors="replace"))
    for child in root:
        if child.tag != "string":
            continue
        name = child.attrib.get("name")
        value = child.text or ""
        if name == "last_request" and value.strip():
            try:
                last_request = json.loads(value)
            except json.JSONDecodeError:
                last_request = {}
        elif name == "last_attempted_request" and value.strip():
            try:
                last_attempted_request = json.loads(value)
            except json.JSONDecodeError:
                last_attempted_request = {}
    request = last_attempted_request or last_request
if not isinstance(request, dict):
    request = {}

profile = {}
profile_raw = request.get("profileJson")
if isinstance(profile_raw, str) and profile_raw.strip():
    try:
        profile = json.loads(profile_raw)
    except json.JSONDecodeError:
        profile = {}
if not isinstance(profile, dict):
    profile = {}

runtime = ((profile.get("androidRuntime") or {}).get("realityWhitelistHints") or {})
if not isinstance(runtime, dict):
    runtime = {}
hints = runtime.get("hints") or []
first_hint = hints[0] if isinstance(hints, list) and hints and isinstance(hints[0], dict) else {}

print(json.dumps({
    "runtimeFamily": snapshot.get("runtimeFamily"),
    "activationState": snapshot.get("activationState"),
    "status": snapshot.get("status"),
    "lastTestStatus": ((snapshot.get("lastTest") or {}).get("status")),
    "lastTestOutput": ((snapshot.get("lastTest") or {}).get("output")),
    "lastTestError": ((snapshot.get("lastTest") or {}).get("error")),
    "lastTestUrl": ((snapshot.get("lastTest") or {}).get("url")),
    "outboundEofCount": sum(1 for line in (snapshot.get("logTail") or []) if isinstance(line, str) and "EOF" in line),
    "requestSource": "last_attempted_request" if last_attempted_request else ("last_request" if last_request else "missing"),
    "hiddenEnabled": bool(runtime.get("enabled", False)),
    "hintTag": first_hint.get("tag"),
    "hintServer": first_hint.get("serverName"),
}, ensure_ascii=False))
PY
)"

  [[ -n "$parsed_output" ]] || return 1

  OBSERVED_CANDIDATE_FAMILY="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("runtimeFamily")
if value is not None:
    print(str(value))
PY
)"
  OBSERVED_CANDIDATE_ACTIVATION="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("activationState")
if value is not None:
    print(str(value))
PY
)"
  OBSERVED_CANDIDATE_STATUS="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("status")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_REQUEST_SOURCE="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("requestSource")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_REQUEST_HIDDEN_ENABLED="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print("true" if payload.get("hiddenEnabled") else "false")
PY
)"
  CANDIDATE_REQUEST_HINT_TAG="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("hintTag")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_REQUEST_HINT_SERVER="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("hintServer")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_TEST_STATUS="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("lastTestStatus")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_TEST_OUTPUT="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("lastTestOutput")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_TEST_ERROR="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("lastTestError")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_TEST_URL="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("lastTestUrl")
if value is not None:
    print(str(value))
PY
)"
  CANDIDATE_OUTBOUND_EOF_COUNT="$("$PYTHON_BIN" - "$parsed_output" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get("outboundEofCount")
print(str(value if value is not None else 0))
PY
)"

  if [[ "$OBSERVED_CANDIDATE_FAMILY" == "reality-whitelist-assisted" && "$OBSERVED_CANDIDATE_ACTIVATION" == "$(expected_candidate_activation)" ]]; then
    if [[ "$(expected_candidate_status)" == "" || "$OBSERVED_CANDIDATE_STATUS" == "$(expected_candidate_status)" ]]; then
      CANDIDATE_DISPATCH_CLASS="expected_hidden"
    else
      CANDIDATE_DISPATCH_CLASS="hidden_request_unexpected_surface"
    fi
  elif [[ "$CANDIDATE_REQUEST_HIDDEN_ENABLED" == "true" && "$OBSERVED_CANDIDATE_FAMILY" == "direct-reality" && "$OBSERVED_CANDIDATE_STATUS" == "running" ]]; then
    CANDIDATE_DISPATCH_CLASS="dispatch_noop"
  elif [[ "$CANDIDATE_REQUEST_HIDDEN_ENABLED" == "true" ]]; then
    CANDIDATE_DISPATCH_CLASS="hidden_request_unexpected_surface"
  else
    CANDIDATE_DISPATCH_CLASS="request_not_hidden"
  fi

  if [[ "$CANDIDATE_TEST_STATUS" == "passed" ]]; then
    CANDIDATE_HEALTH_CLASS="connectivity_passed"
    CANDIDATE_HEALTH_NOTES="${CANDIDATE_TEST_OUTPUT:-HTTP probe passed}"
  elif [[ "$CANDIDATE_HINT_TEST_STATUS" == "passed" ]]; then
    CANDIDATE_HEALTH_CLASS="hint_probe_passed_generic_failed"
    CANDIDATE_HEALTH_NOTES="Hint-host probe passed via ${CANDIDATE_HINT_TEST_URL:-n/a}, but the generic probe failed: ${CANDIDATE_TEST_ERROR:-${CANDIDATE_TEST_OUTPUT:-unknown error}}"
  elif [[ "$CANDIDATE_TEST_STATUS" == "failed" ]]; then
    if [[ "${CANDIDATE_OUTBOUND_EOF_COUNT:-0}" -gt 0 ]]; then
      CANDIDATE_HEALTH_CLASS="probe_failed_with_outbound_eof"
      CANDIDATE_HEALTH_NOTES="Probe failed and logTail recorded ${CANDIDATE_OUTBOUND_EOF_COUNT} outbound EOF event(s): ${CANDIDATE_TEST_ERROR:-${CANDIDATE_TEST_OUTPUT:-unknown error}}"
    else
      CANDIDATE_HEALTH_CLASS="probe_failed"
      CANDIDATE_HEALTH_NOTES="${CANDIDATE_TEST_ERROR:-${CANDIDATE_TEST_OUTPUT:-unknown error}}"
    fi
  elif [[ "$OBSERVED_CANDIDATE_STATUS" == "running" && "${CANDIDATE_OUTBOUND_EOF_COUNT:-0}" -gt 0 ]]; then
    CANDIDATE_HEALTH_CLASS="runtime_running_with_outbound_eof"
    CANDIDATE_HEALTH_NOTES="Runtime stayed running but logTail recorded ${CANDIDATE_OUTBOUND_EOF_COUNT} outbound EOF event(s)."
  elif [[ "$OBSERVED_CANDIDATE_STATUS" == "running" ]]; then
    CANDIDATE_HEALTH_CLASS="runtime_running_unprobed"
    CANDIDATE_HEALTH_NOTES="Runtime surfaced as running without a completed quick probe result."
  else
    CANDIDATE_HEALTH_CLASS="candidate_not_running"
    CANDIDATE_HEALTH_NOTES="Candidate did not finish in a running state."
  fi
}

candidate_snapshot_matches() {
  refresh_candidate_snapshot_observation
  if [[ "$OBSERVED_CANDIDATE_FAMILY" != "reality-whitelist-assisted" ]]; then
    return 1
  fi
  if [[ "$OBSERVED_CANDIDATE_ACTIVATION" != "$(expected_candidate_activation)" ]]; then
    return 1
  fi
  local expected_status
  expected_status="$(expected_candidate_status)"
  [[ -z "$expected_status" || "$OBSERVED_CANDIDATE_STATUS" == "$expected_status" ]]
}

apply_candidate_preset() {
  if [[ -n "$HINTS_FILE" ]]; then
    env_args=("ODIN_ONE_REALITY_HINTS_FILE=$HINTS_FILE")
    if [[ -n "$HINT_SELECT_TAG" ]]; then
      env_args+=("ODIN_ONE_REALITY_HINT_SELECT_TAG=$HINT_SELECT_TAG")
    fi
    if [[ -n "$HINT_SELECT_INDEX" ]]; then
      env_args+=("ODIN_ONE_REALITY_HINT_SELECT_INDEX=$HINT_SELECT_INDEX")
    fi
    env "${env_args[@]}" "$APPLY_PRESET_SCRIPT" "$PRESET"
  else
    "$APPLY_PRESET_SCRIPT" "$PRESET"
  fi
}

start_candidate_lane() {
  local max_attempts=$(( CANDIDATE_MISMATCH_RETRY_COUNT + 1 ))
  local attempt
  local -a wait_args

  for attempt in $(seq 1 "$max_attempts"); do
    apply_candidate_preset
    CANDIDATE_APPLIED="true"
    ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true \
      "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null
    sleep "$SETTLE_SECONDS"

    wait_args=(
      --timeout-seconds "$WAIT_TIMEOUT_SECONDS"
      --poll-seconds "$WAIT_POLL_SECONDS"
      --family reality-whitelist-assisted
      --activation "$(expected_candidate_activation)"
    )
    if [[ -n "$(expected_candidate_status)" ]]; then
      wait_args+=(--status "$(expected_candidate_status)")
    fi

    if "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
      "${wait_args[@]}" >/dev/null 2>&1
    then
      refresh_candidate_snapshot_observation
      CANDIDATE_ATTEMPTS_USED="$attempt"
      return 0
    fi

    if candidate_snapshot_matches; then
      CANDIDATE_ATTEMPTS_USED="$attempt"
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      echo "Warning: candidate lane surfaced ${OBSERVED_CANDIDATE_FAMILY:-unknown}/${OBSERVED_CANDIDATE_ACTIVATION:-unknown}/${OBSERVED_CANDIDATE_STATUS:-unknown}; retrying (attempt ${attempt}/${max_attempts})." >&2
    fi
  done

  CANDIDATE_ATTEMPTS_USED="$max_attempts"
  echo "Warning: candidate lane did not surface reality-whitelist-assisted/$(expected_candidate_activation) after ${max_attempts} attempt(s); continuing with capture." >&2
  return 1
}

start_stable_baseline() {
  local label="$1"
  local attempt

  for attempt in $(seq 1 "$STABLE_BASELINE_RETRY_COUNT"); do
    "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 1
    "$APPLY_PRESET_SCRIPT" baseline
    ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true \
      "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null
    sleep "$SETTLE_SECONDS"
    if stable_snapshot_matches; then
      return 0
    fi
    if "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
      --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
      --poll-seconds "$WAIT_POLL_SECONDS" \
      --family direct-reality \
      --activation active \
      --status running >/dev/null
    then
      return 0
    fi
    echo "Warning: stable baseline did not reach direct-reality/active/running during ${label} (attempt ${attempt}/${STABLE_BASELINE_RETRY_COUNT})." >&2
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hints-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINTS_FILE="$2"
      shift 2
      ;;
    --preset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PRESET="$2"
      shift 2
      ;;
    --control-capture)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONTROL_CAPTURE="$2"
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
    --candidate-mismatch-retry-count)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CANDIDATE_MISMATCH_RETRY_COUNT="$2"
      shift 2
      ;;
    --run-connectivity-test)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RUN_CONNECTIVITY_TEST="$2"
      shift 2
      ;;
    --test-mode)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_MODE="$2"
      shift 2
      ;;
    --test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_URL="$2"
      shift 2
      ;;
    --test-wait-timeout-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --hint-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINT_SELECT_TAG="$2"
      shift 2
      ;;
    --hint-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINT_SELECT_INDEX="$2"
      shift 2
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

require_script "$APPLY_PRESET_SCRIPT"
require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$CAPTURE_SCRIPT"
require_script "$COMPARE_SCRIPT"
require_script "$REPORT_SCRIPT"
require_script "$CHECKLIST_SCRIPT"
require_python

if [[ -n "$CONTROL_CAPTURE" && ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Control capture not found: $CONTROL_CAPTURE" >&2
  exit 1
fi
if [[ -n "$HINTS_FILE" && ! -f "$HINTS_FILE" ]]; then
  echo "Hints file not found: $HINTS_FILE" >&2
  exit 1
fi
if [[ (-n "$HINT_SELECT_TAG" || -n "$HINT_SELECT_INDEX") && -z "$HINTS_FILE" ]]; then
  echo "--hint-tag/--hint-index require --hints-file or ODIN_ONE_REALITY_HINTS_FILE." >&2
  exit 1
fi
if [[ -n "$HINT_SELECT_TAG" && -n "$HINT_SELECT_INDEX" ]]; then
  echo "Use either --hint-tag or --hint-index, not both." >&2
  exit 1
fi
if ! [[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$SETTLE_SECONDS" -le 0 ]]; then
  echo "--settle-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "--wait-poll-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$STABLE_BASELINE_RETRY_COUNT" =~ ^[0-9]+$ ]] || [[ "$STABLE_BASELINE_RETRY_COUNT" -le 0 ]]; then
  echo "ODIN_ONE_REALITY_STABLE_BASELINE_RETRY_COUNT must be a positive integer" >&2
  exit 1
fi
if ! [[ "$TEST_WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TEST_WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--test-wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$CANDIDATE_MISMATCH_RETRY_COUNT" =~ ^[0-9]+$ ]]; then
  echo "--candidate-mismatch-retry-count must be a non-negative integer" >&2
  exit 1
fi
if [[ -n "$HINT_SELECT_INDEX" ]] && { ! [[ "$HINT_SELECT_INDEX" =~ ^[0-9]+$ ]] || [[ "$HINT_SELECT_INDEX" -le 0 ]]; }; then
  echo "--hint-index must be a positive integer" >&2
  exit 1
fi

SESSION_LABEL="$(normalize_label "$PRESET")"
if [[ -z "$SESSION_LABEL" ]]; then
  SESSION_LABEL="reality-whitelist-scaffold"
fi
if [[ -n "$HINT_SELECT_TAG" ]]; then
  SESSION_LABEL="${SESSION_LABEL}-$(normalize_label "$HINT_SELECT_TAG")"
elif [[ -n "$HINT_SELECT_INDEX" ]]; then
  SESSION_LABEL="${SESSION_LABEL}-hint-${HINT_SELECT_INDEX}"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-reality-whitelist-runs/${SESSION_STAMP}-${SESSION_LABEL}"
fi

CAPTURE_DIR="${OUTPUT_DIR%/}/captures"
COMPARE_OUTPUT="${OUTPUT_DIR%/}/compare.md"
REPORT_OUTPUT="${OUTPUT_DIR%/}/report.md"
CHECKLIST_OUTPUT="${OUTPUT_DIR%/}/blocked-direct-checklist.md"
SESSION_SUMMARY="${OUTPUT_DIR%/}/session-summary.md"

mkdir -p "$OUTPUT_DIR" "$CAPTURE_DIR"

if [[ -n "$HINTS_FILE" ]]; then
  cp "$HINTS_FILE" "${OUTPUT_DIR%/}/curated-hints.json"
fi

log_section "Owner-Lab Session"
echo "Preset: $PRESET"
echo "Output dir: $OUTPUT_DIR"
echo "Settle seconds: $SETTLE_SECONDS"
echo "Wait timeout seconds: $WAIT_TIMEOUT_SECONDS"
echo "Wait poll seconds: $WAIT_POLL_SECONDS"
echo "Run connectivity test: $RUN_CONNECTIVITY_TEST"
echo "Test mode: $TEST_MODE"
echo "Test url: $TEST_URL"
echo "Test wait timeout seconds: $TEST_WAIT_TIMEOUT_SECONDS"
echo "Candidate mismatch retry count: $CANDIDATE_MISMATCH_RETRY_COUNT"
echo "Restore stable: $RESTORE_STABLE"
echo "Hints file: ${HINTS_FILE:-n/a}"
echo "Hint select tag: ${HINT_SELECT_TAG:-n/a}"
echo "Hint select index: ${HINT_SELECT_INDEX:-n/a}"

if [[ -z "$CONTROL_CAPTURE" ]]; then
  log_section "Stable Control Capture"
  if ! start_stable_baseline "stable control"; then
    echo "Warning: continuing with control capture after baseline retries were exhausted." >&2
  fi
  collect_capture "stable-control"
  CONTROL_CAPTURE_RESULT="$CAPTURE_RESULT"
else
  CONTROL_CAPTURE_RESULT="$CONTROL_CAPTURE"
  log_section "Stable Control Capture"
  echo "Reusing existing capture: $CONTROL_CAPTURE_RESULT"
fi

log_section "Candidate Capture"
if ! start_candidate_lane; then
  refresh_candidate_snapshot_observation
fi
if should_run_connectivity_test; then
  log_section "Candidate Quick Test"
  run_candidate_connectivity_test
fi
collect_capture "$PRESET"
CANDIDATE_CAPTURE_RESULT="$CAPTURE_RESULT"
if [[ -n "$CANDIDATE_PROBE_MATRIX_JSON" ]]; then
  candidate_artifact_dir="${CANDIDATE_CAPTURE_RESULT%.txt}.artifacts"
  if [[ -d "$candidate_artifact_dir" ]]; then
    cp "$CANDIDATE_PROBE_MATRIX_JSON" "${candidate_artifact_dir}/reality-whitelist-probe-matrix.json"
  fi
fi
refresh_candidate_capture_observation "$CANDIDATE_CAPTURE_RESULT" || true

log_section "Compare"
"$COMPARE_SCRIPT" "$CONTROL_CAPTURE_RESULT" "$CANDIDATE_CAPTURE_RESULT" | tee "$COMPARE_OUTPUT"

log_section "Report Draft"
"$REPORT_SCRIPT" "$CONTROL_CAPTURE_RESULT" "$CANDIDATE_CAPTURE_RESULT" "$REPORT_OUTPUT"
echo "Wrote report draft to $REPORT_OUTPUT"

log_section "Blocked-Direct Checklist"
"$CHECKLIST_SCRIPT" "$CONTROL_CAPTURE_RESULT" "$CANDIDATE_CAPTURE_RESULT" "$CHECKLIST_OUTPUT"
echo "Wrote blocked-direct checklist to $CHECKLIST_OUTPUT"

if [[ "$RESTORE_STABLE" == "true" ]]; then
  restore_stable_lane
fi

write_session_summary
echo
echo "Session summary: $SESSION_SUMMARY"
