#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"
TEE_BIN="/usr/bin/tee"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

SESSION_SCRIPT="${SCRIPT_DIR}/android-reality-whitelist-session.sh"
SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
PRESET="reality-whitelist-scaffold"
HINTS_FILE="${ODIN_ONE_REALITY_HINTS_FILE:-}"
OUTPUT_DIR=""
CONTROL_CAPTURE=""
LIMIT=""
SKIP_PLACEHOLDERS="false"
STOP_ON_ERROR="false"
RETRY_MISMATCH_COUNT="1"
SETTLE_SECONDS=""
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-25}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"

typeset -a HINT_TAGS=()
typeset -a HINT_INDICES=()

SELECTED_HINTS_FILE=""
SELECTED_HINTS_TSV=""
RUN_RESULTS_FILE=""
RESULTS_JSON=""
SUMMARY_MD=""
FINAL_SNAPSHOT_FILE=""
RUNS_DIR=""
CURRENT_CONTROL_CAPTURE=""
BATCH_FAILURE="false"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-batch-session.sh [options]

Options:
  --hints-file <file>          Curated whitelist hint dataset JSON.
  --preset <preset>            Hidden preset to run. Default: reality-whitelist-scaffold
  --control-capture <file>     Reuse an existing stable control capture for all runs.
  --output-dir <dir>           Batch directory. Default: /tmp/odin-one-android-reality-whitelist-batch/<stamp>-<preset>
  --limit <count>              Limit selected hints after filtering.
  --hint-tag <tag>             Select one hint by tag. May be repeated.
  --hint-index <n>             Select one hint by 1-based index. May be repeated.
  --skip-placeholders          Skip hints that still point at .example.com placeholders.
  --stop-on-error              Stop after the first failing session.
  --retry-mismatch-count <n>   Retry a hint when the candidate comes back on the stable family.
                               Default: 1
  --settle-seconds <seconds>   Forwarded to single-hint sessions.
  --wait-timeout-seconds <n>   Snapshot wait timeout. Default: 25
  --wait-poll-seconds <n>      Snapshot wait poll interval. Default: 1
  -h, --help                   Show this help.

Environment:
  ODIN_ONE_REALITY_HINTS_FILE  Optional default for --hints-file.
  ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS
                               Optional default for --wait-timeout-seconds.
  ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS
                               Optional default for --wait-poll-seconds.

This helper is additive and owner-only:
  - selects one or more curated whitelist hints
  - runs the existing single-hint owner-lab session once per hint
  - reuses the first successful stable control capture when available
  - produces a batch summary and results JSON for fast operator review
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

parse_control_capture_from_summary() {
  local summary_path="$1"
  if [[ ! -f "$summary_path" ]]; then
    return 1
  fi
  "$SED_BIN" -n 's/^- Control capture: `\(.*\)`/\1/p' "$summary_path" | tail -n 1
}

parse_candidate_capture_from_summary() {
  local summary_path="$1"
  if [[ ! -f "$summary_path" ]]; then
    return 1
  fi
  "$SED_BIN" -n 's/^- Candidate capture: `\(.*\)`/\1/p' "$summary_path" | tail -n 1
}

refresh_batch_outputs() {
  "$SERVICE_CONTROL_SCRIPT" print-snapshot > "$FINAL_SNAPSHOT_FILE" 2>/dev/null || rm -f "$FINAL_SNAPSHOT_FILE"

  "$PYTHON_BIN" - "$SELECTED_HINTS_FILE" "$RUN_RESULTS_FILE" "$RESULTS_JSON" "$SUMMARY_MD" "$FINAL_SNAPSHOT_FILE" "$CURRENT_CONTROL_CAPTURE" "$OUTPUT_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

selected_path = Path(sys.argv[1])
run_results_path = Path(sys.argv[2])
results_json_path = Path(sys.argv[3])
summary_md_path = Path(sys.argv[4])
final_snapshot_path = Path(sys.argv[5])
shared_control_capture = sys.argv[6].strip() or None
output_dir = sys.argv[7]

selected_payload = json.loads(selected_path.read_text(encoding="utf-8"))
selected_hints = selected_payload.get("selectedHints") or []

def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None

MULTI_LABEL_PUBLIC_SUFFIXES = {
    "ac.ru",
    "com.ru",
    "edu.ru",
    "gov.ru",
    "mil.ru",
    "net.ru",
    "org.ru",
    "ac.uk",
    "co.uk",
    "gov.uk",
    "org.uk",
}

def normalize_hostname(value: str):
    return str(value or "").strip().lower().rstrip(".")

def registrable_domain(hostname: str):
    normalized = normalize_hostname(hostname)
    labels = [label for label in normalized.split(".") if label]
    if len(labels) < 2:
        return normalized
    suffix = ".".join(labels[-2:])
    if suffix in MULTI_LABEL_PUBLIC_SUFFIXES and len(labels) >= 3:
        return ".".join(labels[-3:])
    return suffix

def parse_session_summary(path: Path):
    result = {}
    if not path.is_file():
        return result
    pattern = re.compile(r"^- ([^:]+): `(.*)`$")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.match(line.strip())
        if not match:
            continue
        key = match.group(1).strip().lower().replace(" ", "_")
        result[key] = match.group(2)
    return result

def extract_snapshot(path: Path):
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    marker = "Snapshot JSON:\n"
    index = text.find(marker)
    if index == -1:
        return {}
    payload = text[index + len(marker):].lstrip()
    decoder = json.JSONDecoder()
    try:
        snapshot, _ = decoder.raw_decode(payload)
    except json.JSONDecodeError:
        return {}
    return snapshot if isinstance(snapshot, dict) else {}

def artifact_dir_for_capture(capture_path: str):
    if not capture_path or capture_path == "n/a":
        return None
    capture = Path(capture_path)
    return capture.with_name(capture.stem + ".artifacts")

def load_scaffold(candidate_capture: str):
    artifact_dir = artifact_dir_for_capture(candidate_capture)
    if artifact_dir is None:
        return None
    scaffold_path = artifact_dir / "reality-whitelist-assisted-scaffold.json"
    if not scaffold_path.is_file():
        return None
    return load_json(scaffold_path)

def load_probe_matrix(candidate_capture: str):
    artifact_dir = artifact_dir_for_capture(candidate_capture)
    if artifact_dir is None:
        return []
    matrix_path = artifact_dir / "reality-whitelist-probe-matrix.json"
    payload = load_json(matrix_path)
    if isinstance(payload, list):
        return payload
    return []

def summarize_probe_matrix(entries):
    parts = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        label = str(entry.get("label") or "probe")
        status = str(entry.get("status") or "unknown")
        detail = str(entry.get("error") or entry.get("output") or "").strip()
        if detail:
          parts.append(f"{label}={status} ({detail})")
        else:
          parts.append(f"{label}={status}")
    return "; ".join(parts) if parts else "n/a"

selected_by_tag = {}
for hint in selected_hints:
    tag = str(hint.get("tag") or "").strip()
    if tag:
        selected_by_tag[tag] = hint

runs = []
if run_results_path.is_file():
    for raw_line in run_results_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line.strip():
            continue
        index, tag, server_name, cidr_bucket, exit_code, run_dir, attempt = raw_line.split("\t")
        run_path = Path(run_dir)
        session_summary = parse_session_summary(run_path / "session-summary.md")
        control_capture = session_summary.get("control_capture")
        candidate_capture = session_summary.get("candidate_capture")
        restore_capture = session_summary.get("stable_restore_capture")
        candidate_snapshot = extract_snapshot(Path(candidate_capture)) if candidate_capture and candidate_capture != "n/a" else {}
        restore_snapshot = extract_snapshot(Path(restore_capture)) if restore_capture and restore_capture != "n/a" else {}
        scaffold = load_scaffold(candidate_capture) if candidate_capture else None
        probe_matrix = load_probe_matrix(candidate_capture) if candidate_capture else []
        selected_hint = selected_by_tag.get(tag, {})
        scaffold_selected = (scaffold or {}).get("selectedHint") or {}
        observed_runtime_family = (
            (scaffold or {}).get("runtimeFamily")
            or candidate_snapshot.get("runtimeFamily")
        )
        observed_activation = (
            (scaffold or {}).get("activationState")
            or candidate_snapshot.get("activationState")
        )
        observed_sni = (
            scaffold_selected.get("serverName")
            or candidate_snapshot.get("selectedSniHint")
        )
        observed_cidr = (
            scaffold_selected.get("cidrBucket")
            or candidate_snapshot.get("selectedCidrHint")
        )
        observed_source = (
            scaffold_selected.get("source")
            or candidate_snapshot.get("whitelistHintSource")
        )
        observed_tag = (
            scaffold_selected.get("tag")
            or candidate_snapshot.get("whitelistHintTag")
        )
        observed_family = registrable_domain(observed_sni or selected_hint.get("serverName") or server_name)
        restore_ready = (
            restore_snapshot.get("runtimeFamily") == "direct-reality"
            and restore_snapshot.get("status") == "running"
        )
        generic_probe_passed = session_summary.get("candidate_test_status") == "passed"
        hint_probe_passed = session_summary.get("candidate_hint_test_status") == "passed"
        any_probe_passed = generic_probe_passed or hint_probe_passed or any(
            isinstance(entry, dict) and entry.get("status") == "passed"
            for entry in probe_matrix
        )
        runs.append(
            {
                "index": int(index),
                "tag": tag,
                "serverName": selected_hint.get("serverName") or server_name,
                "cidrBucket": selected_hint.get("cidrBucket") or cidr_bucket or None,
                "source": selected_hint.get("source"),
                "exitCode": int(exit_code),
                "runDir": str(run_path),
                "attempt": int(attempt),
                "sessionSummary": session_summary,
                "controlCapture": control_capture,
                "candidateCapture": candidate_capture,
                "restoreCapture": restore_capture,
                "compareOutput": session_summary.get("compare_output"),
                "reportOutput": session_summary.get("report_draft"),
                "checklistOutput": session_summary.get("blocked-direct_checklist"),
                "candidateDispatchClass": session_summary.get("candidate_dispatch_class"),
                "candidateRequestHiddenEnabled": session_summary.get("candidate_request_hidden_enabled"),
                "candidateRequestHintTag": session_summary.get("candidate_request_hint_tag"),
                "candidateRequestHintServer": session_summary.get("candidate_request_hint_server"),
                "observedRuntimeFamily": observed_runtime_family,
                "observedActivationState": observed_activation,
                "observedSniHint": observed_sni,
                "observedDomainFamily": observed_family,
                "observedCidrHint": observed_cidr,
                "observedHintSource": observed_source,
                "observedHintTag": observed_tag,
                "lastFailureCode": candidate_snapshot.get("lastFailureCode"),
                "candidateStatus": candidate_snapshot.get("status"),
                "restoreStatus": restore_snapshot.get("status"),
                "restoreRuntimeFamily": restore_snapshot.get("runtimeFamily"),
                "restoreActivationState": restore_snapshot.get("activationState"),
                "restoreReady": restore_ready,
                "candidateTestStatus": session_summary.get("candidate_test_status"),
                "candidateTestUrl": session_summary.get("candidate_test_url"),
                "candidateTestError": session_summary.get("candidate_test_error"),
                "candidateHintTestStatus": session_summary.get("candidate_hint_test_status"),
                "candidateHintTestUrl": session_summary.get("candidate_hint_test_url"),
                "candidateHintTestError": session_summary.get("candidate_hint_test_error"),
                "candidateProbeMode": session_summary.get("candidate_probe_mode"),
                "candidateProbeCount": int(session_summary.get("candidate_probe_count") or 0),
                "candidateProbePassCount": int(session_summary.get("candidate_probe_pass_count") or 0),
                "candidateProbeMatrix": probe_matrix,
                "candidateProbeMatrixSummary": summarize_probe_matrix(probe_matrix),
                "candidateHealthClass": session_summary.get("candidate_health_class"),
                "candidateHealthNotes": session_summary.get("candidate_health_notes"),
                "genericProbePassed": generic_probe_passed,
                "hintProbePassed": hint_probe_passed,
                "anyProbePassed": any_probe_passed,
            }
        )

completed_runs = sum(1 for run in runs if run["exitCode"] == 0)
candidate_family_matches = sum(1 for run in runs if run["observedRuntimeFamily"] == "reality-whitelist-assisted")
restore_ready_count = sum(1 for run in runs if run["restoreReady"])
dispatch_noop_runs = sum(1 for run in runs if run.get("candidateDispatchClass") == "dispatch_noop")
any_probe_pass_runs = sum(1 for run in runs if run.get("anyProbePassed"))
generic_probe_pass_runs = sum(1 for run in runs if run.get("genericProbePassed"))
hint_probe_pass_runs = sum(1 for run in runs if run.get("hintProbePassed"))
observed_families = sorted({run.get("observedDomainFamily") for run in runs if run.get("observedDomainFamily")})
probe_family_stats = {}
for run in runs:
    family = run.get("observedDomainFamily")
    if not family:
        continue
    stats = probe_family_stats.setdefault(family, {"runs": 0, "probePassed": False, "probeEvaluated": False})
    stats["runs"] += 1
    if run.get("anyProbePassed"):
        stats["probePassed"] = True
    if (
        run.get("candidateProbeMode")
        or run.get("candidateProbeCount")
        or run.get("candidateTestStatus")
        or run.get("candidateHintTestStatus")
        or run.get("candidateHealthClass")
    ):
        stats["probeEvaluated"] = True
passing_family_count = sum(1 for stats in probe_family_stats.values() if stats["probePassed"])
failed_probe_family_count = sum(
    1 for stats in probe_family_stats.values()
    if stats["probeEvaluated"] and not stats["probePassed"]
)

final_snapshot = load_json(final_snapshot_path) if final_snapshot_path.is_file() else None

results_payload = {
    "kind": "odin-one-reality-whitelist-batch-results-v1",
    "outputDir": output_dir,
    "sourceFile": selected_payload.get("sourceFile"),
    "sharedControlCapture": shared_control_capture,
    "filters": selected_payload.get("filters"),
    "runs": runs,
    "counts": {
        "selectedHints": len(selected_hints),
        "completedRuns": completed_runs,
        "candidateFamilyMatches": candidate_family_matches,
        "restoreReadyRuns": restore_ready_count,
        "dispatchNoopRuns": dispatch_noop_runs,
        "anyProbePassRuns": any_probe_pass_runs,
        "genericProbePassRuns": generic_probe_pass_runs,
        "hintProbePassRuns": hint_probe_pass_runs,
        "distinctObservedFamilies": len(observed_families),
        "passingObservedFamilies": passing_family_count,
        "failedProbeObservedFamilies": failed_probe_family_count,
    },
    "finalStableSnapshot": final_snapshot,
}
results_json_path.write_text(json.dumps(results_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Android REALITY Whitelist Batch Session",
    "",
    f"- Output directory: `{output_dir}`",
    f"- Curated hints file: `{selected_payload.get('sourceFile')}`",
    f"- Selected hint count: `{len(selected_hints)}`",
    f"- Completed runs: `{completed_runs}/{len(selected_hints)}`",
    f"- Candidate family matches: `{candidate_family_matches}/{len(selected_hints)}`",
    f"- Restore-ready runs: `{restore_ready_count}/{len(selected_hints)}`",
    f"- Dispatch no-op runs: `{dispatch_noop_runs}/{len(selected_hints)}`",
    f"- Any probe pass runs: `{any_probe_pass_runs}/{len(selected_hints)}`",
    f"- Generic probe pass runs: `{generic_probe_pass_runs}/{len(selected_hints)}`",
    f"- Hint probe pass runs: `{hint_probe_pass_runs}/{len(selected_hints)}`",
    f"- Distinct observed domain families: `{len(observed_families)}`",
    f"- Passing observed domain families: `{passing_family_count}`",
    f"- Failed observed domain families: `{failed_probe_family_count}`",
    f"- Shared control capture: `{shared_control_capture or 'n/a'}`",
    f"- Results JSON: `{results_json_path}`",
]

if final_snapshot:
    summary_lines.append(
        f"- Final stable snapshot: `{final_snapshot.get('runtimeFamily') or 'n/a'} / {final_snapshot.get('activationState') or 'n/a'} / {final_snapshot.get('status') or 'n/a'}`"
    )

summary_lines.extend(["", "## Runs"])

for run in runs:
    summary_lines.append(
        "- "
        f"`{run['tag']}` | server=`{run['serverName']}` | cidr=`{run['cidrBucket'] or 'n/a'}` | "
        f"family=`{run.get('observedDomainFamily') or 'n/a'}` | "
        f"attempt=`{run['attempt']}` | exit=`{run['exitCode']}` | "
        f"candidate=`{run['observedRuntimeFamily'] or 'n/a'}/{run['observedActivationState'] or 'n/a'}` | "
        f"dispatch=`{run.get('candidateDispatchClass') or 'n/a'}` | "
        f"health=`{run.get('candidateHealthClass') or 'n/a'}` | "
        f"probe=`{run.get('candidateProbeMatrixSummary') or 'n/a'}` | "
        f"restore=`{run['restoreRuntimeFamily'] or 'n/a'}/{run['restoreStatus'] or 'n/a'}` | "
        f"dir=`{run['runDir']}`"
    )
    if run.get("compareOutput"):
        summary_lines.append(f"  compare: `{run['compareOutput']}`")
    if run.get("reportOutput"):
        summary_lines.append(f"  report: `{run['reportOutput']}`")
    if run.get("checklistOutput"):
        summary_lines.append(f"  checklist: `{run['checklistOutput']}`")

warnings = []
if completed_runs != len(selected_hints):
    warnings.append("At least one single-hint session exited non-zero. Inspect session logs before field testing.")
if candidate_family_matches != len(selected_hints):
    warnings.append("One or more runs did not surface the expected `reality-whitelist-assisted` family.")
if dispatch_noop_runs:
    warnings.append("One or more runs preserved a hidden request but kept the old stable snapshot (`dispatch_noop`).")
if restore_ready_count != len(selected_hints):
    warnings.append("One or more runs did not finish with a clean `direct-reality / running` restore snapshot.")
if any_probe_pass_runs == 0 and runs:
    warnings.append("No active-lab run produced a passing quick probe yet; current hints look transport-valid but reachability-negative.")
if failed_probe_family_count and not passing_family_count:
    warnings.append("All probe-evaluated domain families in this batch were reachability-negative; generate the next queue with --exclude-failed-families and a per-family cap.")
if warnings:
    summary_lines.extend(["", "## Warnings"])
    summary_lines.extend([f"- {warning}" for warning in warnings])

summary_md_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
print(f"Wrote results JSON to {results_json_path}")
print(f"Wrote batch summary to {summary_md_path}")
PY
}

candidate_runtime_family_from_summary() {
  local summary_path="$1"
  local candidate_capture
  candidate_capture="$(parse_candidate_capture_from_summary "$summary_path" || true)"
  if [[ -z "$candidate_capture" || ! -f "$candidate_capture" ]]; then
    return 1
  fi
  "$PYTHON_BIN" - "$candidate_capture" <<'PY'
import json
import sys
from pathlib import Path

capture_path = Path(sys.argv[1])
text = capture_path.read_text(encoding="utf-8", errors="replace")
marker = "Snapshot JSON:\n"
index = text.find(marker)
if index == -1:
    raise SystemExit(1)
payload = text[index + len(marker):].lstrip()
snapshot, _ = json.JSONDecoder().raw_decode(payload)
runtime_family = snapshot.get("runtimeFamily") if isinstance(snapshot, dict) else None
if not runtime_family:
    raise SystemExit(1)
print(runtime_family)
PY
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
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --hint-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINT_TAGS+=("$2")
      shift 2
      ;;
    --hint-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINT_INDICES+=("$2")
      shift 2
      ;;
    --skip-placeholders)
      SKIP_PLACEHOLDERS="true"
      shift
      ;;
    --stop-on-error)
      STOP_ON_ERROR="true"
      shift
      ;;
    --retry-mismatch-count)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RETRY_MISMATCH_COUNT="$2"
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

require_script "$SESSION_SCRIPT"
require_script "$SERVICE_CONTROL_SCRIPT"
require_python

if [[ -z "$HINTS_FILE" ]]; then
  echo "Provide --hints-file or set ODIN_ONE_REALITY_HINTS_FILE." >&2
  exit 1
fi
if [[ ! -f "$HINTS_FILE" ]]; then
  echo "Hints file not found: $HINTS_FILE" >&2
  exit 1
fi
if [[ -n "$CONTROL_CAPTURE" && ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Control capture not found: $CONTROL_CAPTURE" >&2
  exit 1
fi
if [[ -n "$LIMIT" ]]; then
  if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
    echo "--limit must be a positive integer" >&2
    exit 1
  fi
fi
if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "--wait-poll-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$RETRY_MISMATCH_COUNT" =~ ^[0-9]+$ ]]; then
  echo "--retry-mismatch-count must be a non-negative integer" >&2
  exit 1
fi
if [[ -n "$SETTLE_SECONDS" ]]; then
  if ! [[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$SETTLE_SECONDS" -le 0 ]]; then
    echo "--settle-seconds must be a positive integer" >&2
    exit 1
  fi
fi
for hint_index in "${HINT_INDICES[@]}"; do
  if ! [[ "$hint_index" =~ ^[0-9]+$ ]] || [[ "$hint_index" -le 0 ]]; then
    echo "--hint-index values must be positive integers" >&2
    exit 1
  fi
done

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-reality-whitelist-batch/${SESSION_STAMP}-$(normalize_label "$PRESET")"
fi

RUNS_DIR="${OUTPUT_DIR%/}/runs"
SELECTED_HINTS_FILE="${OUTPUT_DIR%/}/selected-hints.json"
SELECTED_HINTS_TSV="${OUTPUT_DIR%/}/selected-hints.tsv"
RUN_RESULTS_FILE="${OUTPUT_DIR%/}/run-results.tsv"
RESULTS_JSON="${OUTPUT_DIR%/}/results.json"
SUMMARY_MD="${OUTPUT_DIR%/}/summary.md"
FINAL_SNAPSHOT_FILE="${OUTPUT_DIR%/}/final-stable-snapshot.json"

mkdir -p "$OUTPUT_DIR" "$RUNS_DIR"
cp "$HINTS_FILE" "${OUTPUT_DIR%/}/curated-hints.json"

"$PYTHON_BIN" - "$HINTS_FILE" "$SELECTED_HINTS_FILE" "$LIMIT" "$SKIP_PLACEHOLDERS" "${HINT_TAGS[@]}" --indices "${HINT_INDICES[@]}" <<'PY'
import json
import sys
from pathlib import Path

dataset_path = Path(sys.argv[1])
selected_path = Path(sys.argv[2])
limit_raw = sys.argv[3].strip()
skip_placeholders = sys.argv[4].strip().lower() == "true"
remaining = sys.argv[5:]

if "--indices" in remaining:
    split_index = remaining.index("--indices")
    tags = remaining[:split_index]
    indices = remaining[split_index + 1 :]
else:
    tags = remaining
    indices = []

payload = json.loads(dataset_path.read_text(encoding="utf-8"))
hints = payload.get("hints") or []
if not isinstance(hints, list):
    raise SystemExit("Curated dataset does not contain a valid `hints` array.")

indexed_hints = []
for index, hint in enumerate(hints, start=1):
    if not isinstance(hint, dict):
        continue
    item = dict(hint)
    item["_index"] = index
    indexed_hints.append(item)

tag_lookup = {}
for hint in indexed_hints:
    tag = str(hint.get("tag") or "").strip()
    if tag:
        tag_lookup[tag] = hint

selected = []
if tags:
    missing = [tag for tag in tags if tag not in tag_lookup]
    if missing:
        raise SystemExit(f"Unknown hint tag(s): {', '.join(missing)}")
    selected = [dict(tag_lookup[tag]) for tag in tags]
elif indices:
    hint_by_index = {hint["_index"]: hint for hint in indexed_hints}
    missing = [idx for idx in indices if int(idx) not in hint_by_index]
    if missing:
        raise SystemExit(f"Unknown hint index(es): {', '.join(missing)}")
    selected = [dict(hint_by_index[int(idx)]) for idx in indices]
else:
    selected = [dict(hint) for hint in indexed_hints]

if skip_placeholders:
    selected = [
        hint for hint in selected
        if not str(hint.get("serverName") or "").lower().endswith(".example.com")
    ]

limit = int(limit_raw) if limit_raw else None
if limit is not None:
    selected = selected[:limit]

if not selected:
    raise SystemExit("No hints matched the requested batch selection.")

selected_payload = {
    "kind": "odin-one-reality-whitelist-batch-selection-v1",
    "sourceFile": str(dataset_path),
    "baseMode": payload.get("baseMode"),
    "selection": payload.get("selection"),
    "bootstrap": payload.get("bootstrap"),
    "filters": {
        "tags": tags,
        "indices": [int(idx) for idx in indices],
        "skipPlaceholders": skip_placeholders,
        "limit": limit,
    },
    "selectedHints": selected,
}

selected_path.write_text(json.dumps(selected_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Selected {len(selected)} hint(s) into {selected_path}")
PY

CURRENT_CONTROL_CAPTURE="$CONTROL_CAPTURE"
: > "$RUN_RESULTS_FILE"

"$PYTHON_BIN" - "$SELECTED_HINTS_FILE" "$SELECTED_HINTS_TSV" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tsv_path = Path(sys.argv[2])
selected = payload.get("selectedHints") or []
lines = []
for index, hint in enumerate(selected, start=1):
    tag = str(hint.get("tag") or f"hint-{index}").strip()
    server_name = str(hint.get("serverName") or "").strip()
    cidr_bucket = str(hint.get("cidrBucket") or "").strip()
    lines.append(f"{index}\t{tag}\t{server_name}\t{cidr_bucket}")
tsv_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY

selected_count="$(wc -l < "$SELECTED_HINTS_TSV" | tr -d '[:space:]')"

refresh_batch_outputs >/dev/null

log_section "Whitelist Batch Session"
echo "Preset: $PRESET"
echo "Output dir: $OUTPUT_DIR"
echo "Hints file: $HINTS_FILE"
echo "Selected hints: $selected_count"
echo "Skip placeholders: $SKIP_PLACEHOLDERS"
echo "Stop on error: $STOP_ON_ERROR"
echo "Retry mismatch count: $RETRY_MISMATCH_COUNT"
echo "Control capture override: ${CONTROL_CAPTURE:-n/a}"

while IFS=$'\t' read -r run_index hint_tag server_name cidr_bucket; do
  run_label="$(normalize_label "$hint_tag")"
  if [[ -z "$run_label" ]]; then
    run_label="hint-${run_index}"
  fi
  run_dir_base="${RUNS_DIR%/}/$(printf '%02d-%s' "$run_index" "$run_label")"
  max_attempts=$(( RETRY_MISMATCH_COUNT + 1 ))
  attempt=1
  final_run_dir=""
  final_run_exit_code=0
  final_candidate_family=""

  while [[ "$attempt" -le "$max_attempts" ]]; do
    if [[ "$attempt" -eq 1 ]]; then
      run_dir="$run_dir_base"
    else
      run_dir="${run_dir_base}-retry-$((attempt - 1))"
    fi
    run_log="${run_dir%/}/session.log"
    run_summary="${run_dir%/}/session-summary.md"
    mkdir -p "$run_dir"

    cmd=("$SESSION_SCRIPT" --hints-file "$HINTS_FILE" --preset "$PRESET" --output-dir "$run_dir" --hint-tag "$hint_tag")
    if [[ -n "$CURRENT_CONTROL_CAPTURE" ]]; then
      cmd+=(--control-capture "$CURRENT_CONTROL_CAPTURE")
    fi
    if [[ -n "$SETTLE_SECONDS" ]]; then
      cmd+=(--settle-seconds "$SETTLE_SECONDS")
    fi
    if [[ -n "$WAIT_TIMEOUT_SECONDS" ]]; then
      cmd+=(--wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS")
    fi
    if [[ -n "$WAIT_POLL_SECONDS" ]]; then
      cmd+=(--wait-poll-seconds "$WAIT_POLL_SECONDS")
    fi

    log_section "Hint ${run_index}/${selected_count}: ${hint_tag} (attempt ${attempt}/${max_attempts})"
    echo "serverName: $server_name"
    echo "cidrBucket: ${cidr_bucket:-n/a}"
    echo "Run dir: $run_dir"

    {
      echo "# Command"
      echo
      echo '```bash'
      printf '%q ' "${cmd[@]}"
      echo
      echo '```'
      echo
    } > "$run_log"

    if "${cmd[@]}" </dev/null > >("$TEE_BIN" -a "$run_log") 2>&1; then
      run_exit_code=0
    else
      run_exit_code=$?
      BATCH_FAILURE="true"
    fi

    if [[ -z "$CURRENT_CONTROL_CAPTURE" && -f "$run_summary" ]]; then
      discovered_control="$(parse_control_capture_from_summary "$run_summary" || true)"
      if [[ -n "$discovered_control" && -f "$discovered_control" ]]; then
        CURRENT_CONTROL_CAPTURE="$discovered_control"
      fi
    fi

    candidate_family="$(candidate_runtime_family_from_summary "$run_summary" || true)"
    final_run_dir="$run_dir"
    final_run_exit_code="$run_exit_code"
    final_candidate_family="$candidate_family"

    if [[ "$run_exit_code" -eq 0 && "$candidate_family" == "reality-whitelist-assisted" ]]; then
      break
    fi

    if [[ "$run_exit_code" -eq 0 && "$candidate_family" != "reality-whitelist-assisted" && "$attempt" -lt "$max_attempts" ]]; then
      echo "Warning: candidate family for ${hint_tag} came back as ${candidate_family:-unknown}; retrying." >&2
      attempt=$(( attempt + 1 ))
      continue
    fi

    break
  done

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_index" \
    "$hint_tag" \
    "$server_name" \
    "${cidr_bucket:-}" \
    "$final_run_exit_code" \
    "$final_run_dir" \
    "$attempt" >> "$RUN_RESULTS_FILE"

  refresh_batch_outputs >/dev/null

  if [[ "$final_run_exit_code" -ne 0 && "$STOP_ON_ERROR" == "true" ]]; then
    echo "Stopping batch after failure for hint tag: $hint_tag" >&2
    break
  fi
done < "$SELECTED_HINTS_TSV"

"$SERVICE_CONTROL_SCRIPT" wait-snapshot \
  --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
  --poll-seconds "$WAIT_POLL_SECONDS" \
  --family direct-reality \
  --status running >/dev/null 2>&1 || true

refresh_batch_outputs

echo
echo "Results JSON: $RESULTS_JSON"
echo "Batch summary: $SUMMARY_MD"

if [[ "$BATCH_FAILURE" == "true" ]]; then
  exit 1
fi
