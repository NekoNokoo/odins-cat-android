#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"

PREFLIGHT_SCRIPT="${SCRIPT_DIR}/android-cdn-lab-preflight.sh"
APPLY_PRESET_SCRIPT="${SCRIPT_DIR}/android-reality-apply-preset.sh"
SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
CAPTURE_SCRIPT="${SCRIPT_DIR}/android-reality-capture-run.sh"
COMPARE_SCRIPT="${SCRIPT_DIR}/android-runtime-compare-captures.sh"
REPORT_SCRIPT="${SCRIPT_DIR}/android-runtime-report-draft.sh"
CHECKLIST_SCRIPT="${SCRIPT_DIR}/android-blocked-direct-checklist.sh"

PRESET="cdn-httpupgrade-lab"
CONTROL_CAPTURE=""
SETTLE_SECONDS="8"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-25}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"
RUN_PREFLIGHT="true"
RESTORE_STABLE="true"
OUTPUT_DIR=""
PLAN_FILE=""
PLAN_TAG=""
PLAN_INDEX=""

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
SESSION_LABEL=""
CAPTURE_DIR=""
PREFLIGHT_OUTPUT=""
COMPARE_OUTPUT=""
REPORT_OUTPUT=""
CHECKLIST_OUTPUT=""
SESSION_SUMMARY=""
CONTROL_CAPTURE_RESULT=""
CANDIDATE_CAPTURE_RESULT=""
RESTORE_CAPTURE_RESULT=""
CANDIDATE_APPLIED="false"
RESTORE_DONE="false"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-lab-session.sh [options]

Options:
  --preset <preset>            Hidden preset to run. Default: cdn-httpupgrade-lab
  --plan-file <file>           Reusable CDN plan JSON passed through the preset helper.
  --plan-tag <tag>             Select one front by tag from the plan file.
  --plan-index <n>             Select one front by 1-based index from the plan file.
  --control-capture <file>     Reuse an existing stable control capture instead of collecting a fresh one.
  --output-dir <dir>           Session directory. Default: /tmp/odin-one-android-cdn-lab-runs/<stamp>-<preset>
  --settle-seconds <seconds>   Seconds to wait after each start-from-prefs. Default: 8
  --wait-timeout-seconds <n>   Snapshot wait timeout. Default: 25
  --wait-poll-seconds <n>      Snapshot wait poll interval. Default: 1
  --skip-preflight             Skip host-side front/origin preflight.
  --skip-restore               Leave the handset on the candidate lane at the end.
  -h, --help                   Show this help.

Environment:
  The same ODIN_ONE_CDN_* overrides used by android-reality-profile-preset.sh and
  android-cdn-lab-preflight.sh are honored automatically.
  ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS / ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS
                    Optional defaults for snapshot waits during control/candidate/restore.

This helper is additive and owner-only:
  1. Runs host-side preflight for the hidden CDN lane.
  2. Captures a stable control lane (unless reused).
  3. Applies the hidden preset and captures the candidate lane.
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

normalize_label() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | "$SED_BIN" 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

log_section() {
  echo
  echo "=== $1 ==="
}

write_session_summary() {
  cat >"$SESSION_SUMMARY" <<EOF
# Android CDN Owner-Lab Session

- Session preset: \`$PRESET\`
- Session directory: \`$OUTPUT_DIR\`
- CDN plan file: \`${ODIN_ONE_CDN_PLAN_FILE:-n/a}\`
- CDN plan select tag: \`${ODIN_ONE_CDN_PLAN_SELECT_TAG:-n/a}\`
- CDN plan select index: \`${ODIN_ONE_CDN_PLAN_SELECT_INDEX:-n/a}\`
- Preflight: \`$PREFLIGHT_OUTPUT\`
- Control capture: \`${CONTROL_CAPTURE_RESULT:-$CONTROL_CAPTURE}\`
- Candidate capture: \`${CANDIDATE_CAPTURE_RESULT:-n/a}\`
- Compare output: \`$COMPARE_OUTPUT\`
- Report draft: \`$REPORT_OUTPUT\`
- Blocked-direct checklist: \`$CHECKLIST_OUTPUT\`
- Stable restore enabled: \`$RESTORE_STABLE\`
- Stable restore capture: \`${RESTORE_CAPTURE_RESULT:-n/a}\`
EOF
}

start_from_prefs_wake() {
  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-prefs >/dev/null
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

snapshot_matches() {
  "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --timeout-seconds 1 \
    --poll-seconds 1 \
    "$@" >/dev/null 2>&1
}

stop_runtime_for_transition() {
  local label="$1"
  if ! ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1; then
    echo "Warning: debug stop command returned a non-zero exit code during ${label}; continuing." >&2
    return 0
  fi
  if ! "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --status stopped \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" >/dev/null 2>&1
  then
    echo "Warning: runtime did not report status=stopped during ${label}; continuing." >&2
  fi
}

restore_stable_lane() {
  log_section "Restoring Stable Lane"
  stop_runtime_for_transition "stable restore"
  "$APPLY_PRESET_SCRIPT" baseline
  start_from_prefs_wake
  wait_for_snapshot "stable restore" --family direct-reality --status running
  sleep "$SETTLE_SECONDS"
  if [[ -n "${CAPTURE_DIR:-}" ]]; then
    collect_capture "stable-restored"
    RESTORE_CAPTURE_RESULT="$CAPTURE_RESULT"
    if ! "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
      --family direct-reality \
      --status running \
      --timeout-seconds 1 \
      --poll-seconds 1 >/dev/null 2>&1
    then
      echo "Warning: restore capture did not land on direct-reality/running; retrying with an explicit wake/start pass." >&2
      "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
      sleep 1
      start_from_prefs_wake
      wait_for_snapshot "stable restore fallback" --family direct-reality --status running
      sleep "$SETTLE_SECONDS"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --skip-preflight)
      RUN_PREFLIGHT="false"
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

require_script "$PREFLIGHT_SCRIPT"
require_script "$APPLY_PRESET_SCRIPT"
require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$CAPTURE_SCRIPT"
require_script "$COMPARE_SCRIPT"
require_script "$REPORT_SCRIPT"
require_script "$CHECKLIST_SCRIPT"

if [[ -n "$CONTROL_CAPTURE" && ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Control capture not found: $CONTROL_CAPTURE" >&2
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

SESSION_LABEL="$(normalize_label "$PRESET")"
if [[ -z "$SESSION_LABEL" ]]; then
  SESSION_LABEL="cdn-httpupgrade-lab"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-cdn-lab-runs/${SESSION_STAMP}-${SESSION_LABEL}"
fi

CAPTURE_DIR="${OUTPUT_DIR%/}/captures"
PREFLIGHT_OUTPUT="${OUTPUT_DIR%/}/preflight.md"
COMPARE_OUTPUT="${OUTPUT_DIR%/}/compare.md"
REPORT_OUTPUT="${OUTPUT_DIR%/}/report.md"
CHECKLIST_OUTPUT="${OUTPUT_DIR%/}/blocked-direct-checklist.md"
SESSION_SUMMARY="${OUTPUT_DIR%/}/session-summary.md"

mkdir -p "$OUTPUT_DIR" "$CAPTURE_DIR"

log_section "Owner-Lab Session"
echo "Preset: $PRESET"
echo "Output dir: $OUTPUT_DIR"
echo "Settle seconds: $SETTLE_SECONDS"
echo "Restore stable: $RESTORE_STABLE"

if [[ "$RUN_PREFLIGHT" == "true" ]]; then
  log_section "Host Preflight"
  "$PREFLIGHT_SCRIPT" --preset "$PRESET" --strict | tee "$PREFLIGHT_OUTPUT"
else
  log_section "Host Preflight"
  echo "Skipped by request."
  : >"$PREFLIGHT_OUTPUT"
fi

if [[ -z "$CONTROL_CAPTURE" ]]; then
  log_section "Stable Control Capture"
  "$APPLY_PRESET_SCRIPT" baseline
  start_from_prefs_wake
  wait_for_snapshot "stable control" --family direct-reality --status running
  sleep "$SETTLE_SECONDS"
  collect_capture "stable-control"
  CONTROL_CAPTURE_RESULT="$CAPTURE_RESULT"
else
  CONTROL_CAPTURE_RESULT="$CONTROL_CAPTURE"
  log_section "Stable Control Capture"
  echo "Reusing existing capture: $CONTROL_CAPTURE_RESULT"
fi

log_section "Candidate Capture"
stop_runtime_for_transition "candidate transition"
"$APPLY_PRESET_SCRIPT" "$PRESET"
CANDIDATE_APPLIED="true"
start_from_prefs_wake
wait_for_snapshot "candidate" --family cdn-anti-whitelist --status running
if ! snapshot_matches --family cdn-anti-whitelist --status running; then
  echo "Warning: candidate lane did not surface as cdn-anti-whitelist/running; retrying with an explicit wake/start pass." >&2
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 1
  start_from_prefs_wake
  wait_for_snapshot "candidate fallback" --family cdn-anti-whitelist --status running
fi
sleep "$SETTLE_SECONDS"
if snapshot_matches --family cdn-anti-whitelist --status running; then
  collect_capture "$PRESET"
else
  collect_capture "${PRESET}-fallback"
fi
CANDIDATE_CAPTURE_RESULT="$CAPTURE_RESULT"

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

log_section "Completed"
echo "Session summary: $SESSION_SUMMARY"
echo "Control capture: $CONTROL_CAPTURE_RESULT"
echo "Candidate capture: $CANDIDATE_CAPTURE_RESULT"
if [[ -n "$RESTORE_CAPTURE_RESULT" ]]; then
  echo "Restore capture: $RESTORE_CAPTURE_RESULT"
fi
echo "Compare: $COMPARE_OUTPUT"
echo "Report: $REPORT_OUTPUT"
echo "Checklist: $CHECKLIST_OUTPUT"
