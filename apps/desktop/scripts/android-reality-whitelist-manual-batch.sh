#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
SED_BIN="/usr/bin/sed"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

MANUAL_SESSION_SCRIPT="${SCRIPT_DIR}/android-reality-whitelist-manual-session.sh"

OUTPUT_ROOT="${TMPDIR:-/tmp}"
BATCH_ROOT="${OUTPUT_ROOT%/}/odin-one-android-reality-whitelist-manual-batch"
BATCH_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"

SUBCOMMAND=""
OUTPUT_DIR=""
BATCH_LABEL=""
HINTS_FILE="${ODIN_ONE_REALITY_HINTS_FILE:-}"
LIMIT=""
SKIP_PLACEHOLDERS="false"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-25}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"

typeset -a HINT_TAGS=()
typeset -a HINT_INDICES=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin [options]
  apps/desktop/scripts/android-reality-whitelist-manual-batch.sh advance [options]
  apps/desktop/scripts/android-reality-whitelist-manual-batch.sh status [options]

Subcommands:
  begin       Select curated hints, capture the first stable control sample, and prepare the first in-app hint.
  advance     Capture the currently launched in-app hint, restore stable, finalize the run, and prepare the next hint.
  status      Print the current batch state JSON.

Options:
  --hints-file <file>          Curated whitelist hint dataset JSON. Required for begin.
  --output-dir <dir>           Batch directory. Default:
                               /tmp/odin-one-android-reality-whitelist-manual-batch/<stamp>
  --label <label>              Optional batch label suffix for begin.
  --limit <count>              Limit selected hints after filtering.
  --hint-tag <tag>             Select one hint by tag. May be repeated.
  --hint-index <n>             Select one hint by 1-based index. May be repeated.
  --skip-placeholders          Skip hints that still point at .example.com placeholders.
  --wait-timeout-seconds <n>   Snapshot wait timeout forwarded to manual sessions. Default: 25
  --wait-poll-seconds <n>      Snapshot wait poll interval forwarded to manual sessions. Default: 1
  -h, --help                   Show this help.

Environment:
  ODIN_ONE_REALITY_HINTS_FILE  Optional default for --hints-file.
  ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS
                               Optional default for --wait-timeout-seconds.
  ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS
                               Optional default for --wait-poll-seconds.

Workflow:
  1. begin    -> prepares the first current-hint markdown and captures stable control.
  2. launch   -> from the phone UI, run Owner lab -> Whitelist scaffold with the current hint values.
  3. advance  -> host captures candidate, restores stable, finalizes the run, and prepares the next hint.
  4. repeat   -> until summary.md shows the batch is completed.
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

resolve_latest_batch_dir() {
  if [[ ! -d "$BATCH_ROOT" ]]; then
    return 1
  fi
  local latest
  latest="$(/bin/ls -dt "$BATCH_ROOT"/* 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" && -d "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    begin|advance|status)
      if [[ -n "$SUBCOMMAND" ]]; then
        echo "Only one subcommand may be used." >&2
        exit 1
      fi
      SUBCOMMAND="$1"
      shift
      ;;
    --hints-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINTS_FILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --label)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      BATCH_LABEL="$2"
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
require_script "$MANUAL_SESSION_SCRIPT"

if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "--wait-poll-seconds must be a positive integer" >&2
  exit 1
fi
if [[ -n "$LIMIT" ]]; then
  if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
    echo "--limit must be a positive integer" >&2
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
  if [[ "$SUBCOMMAND" == "begin" ]]; then
    OUTPUT_DIR="${BATCH_ROOT}/${BATCH_STAMP}"
    if [[ -n "$BATCH_LABEL" ]]; then
      OUTPUT_DIR="${OUTPUT_DIR}-$(normalize_label "$BATCH_LABEL")"
    fi
  else
    OUTPUT_DIR="$(resolve_latest_batch_dir || true)"
    if [[ -z "$OUTPUT_DIR" ]]; then
      echo "No existing manual batch directory was found. Run 'begin' first or pass --output-dir." >&2
      exit 1
    fi
  fi
fi

RUNS_DIR="${OUTPUT_DIR%/}/runs"
STATE_FILE="${OUTPUT_DIR%/}/state.json"
SELECTED_HINTS_FILE="${OUTPUT_DIR%/}/selected-hints.json"
SELECTED_HINTS_TSV="${OUTPUT_DIR%/}/selected-hints.tsv"
RUN_RESULTS_FILE="${OUTPUT_DIR%/}/run-results.tsv"
RESULTS_JSON="${OUTPUT_DIR%/}/results.json"
SUMMARY_MD="${OUTPUT_DIR%/}/summary.md"
CURRENT_HINT_JSON="${OUTPUT_DIR%/}/current-hint.json"
CURRENT_HINT_MD="${OUTPUT_DIR%/}/current-hint.md"

mkdir -p "$OUTPUT_DIR" "$RUNS_DIR"

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

selected_hint_json() {
  local hint_index="$1"
  SELECTED_HINTS_FILE="$SELECTED_HINTS_FILE" HINT_INDEX="$hint_index" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["SELECTED_HINTS_FILE"]).read_text(encoding="utf-8"))
selected = payload.get("selectedHints") or []
index = int(os.environ["HINT_INDEX"])
if index <= 0 or index > len(selected):
    raise SystemExit(1)
print(json.dumps(selected[index - 1], ensure_ascii=False))
PY
}

write_current_hint_files() {
  local hint_json="$1"
  local current_index="$2"
  local selected_count="$3"
  local run_dir="$4"
  CURRENT_HINT_JSON="$CURRENT_HINT_JSON" \
  CURRENT_HINT_MD="$CURRENT_HINT_MD" \
  HINT_JSON="$hint_json" \
  CURRENT_INDEX="$current_index" \
  SELECTED_COUNT="$selected_count" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  RUN_DIR="$run_dir" \
  "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

hint = json.loads(os.environ["HINT_JSON"])
current_index = int(os.environ["CURRENT_INDEX"])
selected_count = int(os.environ["SELECTED_COUNT"])
output_dir = os.environ["OUTPUT_DIR"]
run_dir = os.environ["RUN_DIR"]

json_path = Path(os.environ["CURRENT_HINT_JSON"])
md_path = Path(os.environ["CURRENT_HINT_MD"])
json_path.write_text(json.dumps(hint, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

server_name = hint.get("serverName") or "n/a"
cidr_bucket = hint.get("cidrBucket") or "leave empty"
source = hint.get("source") or "n/a"
tag = hint.get("tag") or f"hint-{current_index}"

lines = [
    "# Current Manual Whitelist Hint",
    "",
    f"- Batch directory: `{output_dir}`",
    f"- Run directory: `{run_dir}`",
    f"- Hint index: `{current_index}/{selected_count}`",
    f"- Tag: `{tag}`",
    f"- `serverName`: `{server_name}`",
    f"- `cidrBucket`: `{cidr_bucket}`",
    f"- `source`: `{source}`",
    "",
    "## Phone Steps",
    "",
    "1. Open `Odin One` on the handset.",
    "2. Open `Logs & test`.",
    "3. Tap the sheet title five times if the owner lab panel is hidden.",
    "4. Choose `Whitelist scaffold`.",
    f"5. Enter `serverName = {server_name}`.",
    f"6. Enter `cidrBucket = {cidr_bucket}` or leave it empty if that is intentional.",
    f"7. Enter `source = {source}`.",
    f"8. Enter `tag = {tag}`.",
    "9. Launch the owner lab run.",
    "",
    "## Host Step",
    "",
    f"After the phone run starts, continue with:",
    "",
    "```bash",
    f"apps/desktop/scripts/android-reality-whitelist-manual-batch.sh advance --output-dir {output_dir}",
    "```",
]

md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

write_completed_hint_note() {
  cat >"$CURRENT_HINT_MD" <<EOF
# Current Manual Whitelist Hint

- Batch directory: \`$OUTPUT_DIR\`
- Status: \`completed\`

No further handset launch is pending for this batch.
EOF
  rm -f "$CURRENT_HINT_JSON"
}

record_completed_run() {
  local current_index="$1"
  local hint_json="$2"
  local run_dir="$3"
  RUN_RESULTS_FILE="$RUN_RESULTS_FILE" CURRENT_INDEX="$current_index" HINT_JSON="$hint_json" RUN_DIR="$run_dir" COMPLETED_AT="$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ')" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

results_path = Path(os.environ["RUN_RESULTS_FILE"])
index = int(os.environ["CURRENT_INDEX"])
hint = json.loads(os.environ["HINT_JSON"])
run_dir = os.environ["RUN_DIR"]
completed_at = os.environ["COMPLETED_AT"]

rows = []
if results_path.exists():
    for raw_line in results_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t")
        if len(parts) != 7:
            continue
        try:
            row_index = int(parts[0])
        except ValueError:
            continue
        if row_index == index:
            continue
        rows.append(parts)

rows.append(
    [
        str(index),
        str(hint.get("tag") or f"hint-{index}"),
        str(hint.get("serverName") or ""),
        str(hint.get("cidrBucket") or ""),
        str(hint.get("source") or ""),
        run_dir,
        completed_at,
    ]
)
rows.sort(key=lambda item: int(item[0]))
content = "\n".join("\t".join(row) for row in rows)
if content:
    content += "\n"
results_path.write_text(content, encoding="utf-8")
PY
}

select_hints() {
  : >"$RUN_RESULTS_FILE"
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
    raise SystemExit("No hints matched the requested manual batch selection.")

selected_payload = {
    "kind": "odin-one-reality-whitelist-manual-batch-selection-v1",
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
print(len(selected))
PY

  "$PYTHON_BIN" - "$SELECTED_HINTS_FILE" "$SELECTED_HINTS_TSV" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = payload.get("selectedHints") or []
lines = []
for index, hint in enumerate(selected, start=1):
    tag = str(hint.get("tag") or f"hint-{index}").strip()
    server_name = str(hint.get("serverName") or "").strip()
    cidr_bucket = str(hint.get("cidrBucket") or "").strip()
    source = str(hint.get("source") or "").strip()
    lines.append(f"{index}\t{tag}\t{server_name}\t{cidr_bucket}\t{source}")
Path(sys.argv[2]).write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY
}

rebuild_outputs() {
  SELECTED_HINTS_FILE="$SELECTED_HINTS_FILE" \
  STATE_FILE="$STATE_FILE" \
  RUN_RESULTS_FILE="$RUN_RESULTS_FILE" \
  RESULTS_JSON="$RESULTS_JSON" \
  SUMMARY_MD="$SUMMARY_MD" \
  CURRENT_HINT_MD="$CURRENT_HINT_MD" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  "$PYTHON_BIN" - <<'PY'
import json
import re
import os
from pathlib import Path

selected_path = Path(os.environ["SELECTED_HINTS_FILE"])
state_path = Path(os.environ["STATE_FILE"])
run_results_path = Path(os.environ["RUN_RESULTS_FILE"])
results_json_path = Path(os.environ["RESULTS_JSON"])
summary_md_path = Path(os.environ["SUMMARY_MD"])
current_hint_md_path = Path(os.environ["CURRENT_HINT_MD"])
output_dir = os.environ["OUTPUT_DIR"]

selected_payload = json.loads(selected_path.read_text(encoding="utf-8"))
state = {}
if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8", errors="replace"))
selected_hints = selected_payload.get("selectedHints") or []

def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None

def parse_summary(path: Path):
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

completed_rows = {}
if run_results_path.is_file():
    for raw_line in run_results_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t")
        if len(parts) != 7:
            continue
        index, tag, server_name, cidr_bucket, source, run_dir, completed_at = parts
        run_path = Path(run_dir)
        session_summary = parse_summary(run_path / "summary.md")
        control_capture = session_summary.get("control_capture")
        candidate_capture = session_summary.get("candidate_capture")
        restore_capture = session_summary.get("restore_capture")
        candidate_snapshot = extract_snapshot(Path(candidate_capture)) if candidate_capture and candidate_capture != "n/a" else {}
        restore_snapshot = extract_snapshot(Path(restore_capture)) if restore_capture and restore_capture != "n/a" else {}
        scaffold = load_scaffold(candidate_capture) if candidate_capture else None
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
        restore_ready = (
            restore_snapshot.get("runtimeFamily") == "direct-reality"
            and restore_snapshot.get("status") == "running"
            and restore_snapshot.get("activationState") == "active"
        )
        completed_rows[int(index)] = {
            "index": int(index),
            "status": "completed",
            "tag": tag,
            "serverName": server_name or None,
            "cidrBucket": cidr_bucket or None,
            "source": source or None,
            "runDir": str(run_path),
            "completedAt": completed_at,
            "controlCapture": control_capture,
            "candidateCapture": candidate_capture,
            "restoreCapture": restore_capture,
            "controlCaptureSource": session_summary.get("control_capture_source"),
            "candidateRequestSource": session_summary.get("candidate_request_source"),
            "compareOutput": session_summary.get("compare_output"),
            "reportOutput": session_summary.get("report_output"),
            "checklistOutput": session_summary.get("checklist_output"),
            "observedRuntimeFamily": observed_runtime_family,
            "observedActivationState": observed_activation,
            "observedSniHint": observed_sni,
            "observedCidrHint": observed_cidr,
            "observedHintSource": observed_source,
            "observedHintTag": observed_tag,
            "candidateStatus": candidate_snapshot.get("status"),
            "lastFailureCode": candidate_snapshot.get("lastFailureCode"),
            "restoreRuntimeFamily": restore_snapshot.get("runtimeFamily"),
            "restoreActivationState": restore_snapshot.get("activationState"),
            "restoreStatus": restore_snapshot.get("status"),
            "restoreReady": restore_ready,
        }

current_index = int(state.get("currentIndex") or 0)
current_run_dir = state.get("currentRunDir") or None
batch_status = state.get("status") or "unknown"

runs = []
for index, hint in enumerate(selected_hints, start=1):
    if index in completed_rows:
        row = completed_rows[index]
        row["selectedIndex"] = index
        runs.append(row)
        continue
    status = "pending"
    if batch_status != "completed" and current_index == index:
        status = "waiting_for_launch"
    runs.append(
        {
            "index": index,
            "selectedIndex": index,
            "status": status,
            "tag": hint.get("tag"),
            "serverName": hint.get("serverName"),
            "cidrBucket": hint.get("cidrBucket"),
            "source": hint.get("source"),
            "runDir": current_run_dir if status == "waiting_for_launch" else None,
        }
    )

completed_count = sum(1 for run in runs if run["status"] == "completed")
current_hint = None
if 0 < current_index <= len(selected_hints):
    current_hint = selected_hints[current_index - 1]

results_payload = {
    "kind": "odin-one-reality-whitelist-manual-batch-results-v1",
    "outputDir": output_dir,
    "sourceFile": selected_payload.get("sourceFile"),
    "filters": selected_payload.get("filters"),
    "state": state,
    "selectedHints": selected_hints,
    "runs": runs,
    "counts": {
        "selectedHints": len(selected_hints),
        "completedRuns": completed_count,
        "pendingRuns": len(selected_hints) - completed_count,
    },
    "currentHint": current_hint,
    "currentHintMarkdown": str(current_hint_md_path),
}
results_json_path.write_text(json.dumps(results_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Android REALITY Whitelist Manual Batch",
    "",
    f"- Batch directory: `{output_dir}`",
    f"- Curated hints file: `{selected_payload.get('sourceFile')}`",
    f"- Selected hint count: `{len(selected_hints)}`",
    f"- Completed runs: `{completed_count}/{len(selected_hints)}`",
    f"- Batch status: `{batch_status}`",
    f"- State JSON: `{state_path}`",
    f"- Results JSON: `{results_json_path}`",
    f"- Current hint markdown: `{current_hint_md_path}`",
]

if current_hint and batch_status != "completed":
    current_hint_tag = current_hint.get("tag") or f"hint-{current_index}"
    summary_lines.extend(
        [
            "",
            "## Current Hint",
            "",
            f"- Hint index: `{current_index}/{len(selected_hints)}`",
            f"- Tag: `{current_hint_tag}`",
            f"- `serverName`: `{current_hint.get('serverName') or 'n/a'}`",
            f"- `cidrBucket`: `{current_hint.get('cidrBucket') or 'leave empty'}`",
            f"- `source`: `{current_hint.get('source') or 'n/a'}`",
            f"- Run directory: `{current_run_dir or 'n/a'}`",
        ]
    )

summary_lines.extend(["", "## Runs", ""])
for run in runs:
    run_tag = run.get("tag") or f"hint-{run['index']}"
    if run["status"] == "completed":
        summary_lines.append(
            "- "
            f"`{run_tag}` | status=`completed` | "
            f"candidate=`{run.get('observedRuntimeFamily') or 'n/a'}/{run.get('observedActivationState') or 'n/a'}` | "
            f"restore=`{run.get('restoreRuntimeFamily') or 'n/a'}/{run.get('restoreStatus') or 'n/a'}` | "
            f"request=`{run.get('candidateRequestSource') or 'n/a'}` | "
            f"dir=`{run.get('runDir') or 'n/a'}`"
        )
    else:
        summary_lines.append(
            "- "
            f"`{run_tag}` | status=`{run['status']}` | "
            f"server=`{run.get('serverName') or 'n/a'}` | "
            f"cidr=`{run.get('cidrBucket') or 'n/a'}` | "
            f"dir=`{run.get('runDir') or 'n/a'}`"
        )

warnings = []
for run in runs:
    if run["status"] != "completed":
        continue
    if run.get("observedRuntimeFamily") != "reality-whitelist-assisted":
        warnings.append(f"Completed run `{run.get('tag')}` did not surface `reality-whitelist-assisted`.")
    if not run.get("restoreReady"):
        warnings.append(f"Completed run `{run.get('tag')}` did not end with `direct-reality / active / running`.")
if warnings:
    summary_lines.extend(["", "## Warnings", ""])
    summary_lines.extend([f"- {warning}" for warning in warnings])

summary_md_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY
}

prepare_run_for_index() {
  local current_index="$1"
  local selected_count="$2"
  local hint_json
  hint_json="$(selected_hint_json "$current_index")"
  local run_label
  run_label="$(HINT_JSON="$hint_json" "$PYTHON_BIN" - <<'PY'
import json
import os
import re

hint = json.loads(os.environ["HINT_JSON"])
tag = str(hint.get("tag") or "").strip().lower()
tag = re.sub(r"[^a-z0-9._-]+", "-", tag)
tag = re.sub(r"-{2,}", "-", tag).strip("-")
print(tag or "hint")
PY
)"
  local run_dir="${RUNS_DIR%/}/$(printf '%02d-%s' "$current_index" "$run_label")"
  log_section "Prepare Hint ${current_index}/${selected_count}"
  "$MANUAL_SESSION_SCRIPT" begin \
    --output-dir "$run_dir" \
    --wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --wait-poll-seconds "$WAIT_POLL_SECONDS"
  state_set currentIndex "$current_index" int
  state_set currentRunDir "$run_dir"
  state_set currentHint "$hint_json" json
  state_set status "waiting_for_launch"
  state_set updatedAt "$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_current_hint_files "$hint_json" "$current_index" "$selected_count" "$run_dir"
  rebuild_outputs
  printf 'Prepared current hint markdown at %s\n' "$CURRENT_HINT_MD"
}

case "$SUBCOMMAND" in
  begin)
    if [[ -z "$HINTS_FILE" ]]; then
      echo "Provide --hints-file or set ODIN_ONE_REALITY_HINTS_FILE." >&2
      exit 1
    fi
    if [[ ! -f "$HINTS_FILE" ]]; then
      echo "Hints file not found: $HINTS_FILE" >&2
      exit 1
    fi
    log_section "Initialize Manual Batch"
    selected_count="$(select_hints)"
    state_set kind "odin-one-reality-whitelist-manual-batch-v1"
    state_set batchDir "$OUTPUT_DIR"
    state_set hintsFile "$HINTS_FILE"
    state_set selectedCount "$selected_count" int
    state_set createdAt "$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ')"
    prepare_run_for_index 1 "$selected_count"
    printf 'Manual batch initialized at %s\n' "$OUTPUT_DIR"
    ;;
  advance)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No batch state file found at $STATE_FILE" >&2
      exit 1
    fi
    current_index="$(state_get currentIndex 2>/dev/null || true)"
    selected_count="$(state_get selectedCount 2>/dev/null || true)"
    batch_status="$(state_get status 2>/dev/null || true)"
    current_run_dir="$(state_get currentRunDir 2>/dev/null || true)"
    current_hint_json="$(state_get currentHint 2>/dev/null || true)"
    if [[ "$batch_status" == "completed" ]]; then
      echo "Manual batch is already completed." >&2
      exit 1
    fi
    if [[ -z "$current_index" || -z "$current_run_dir" || -z "$current_hint_json" ]]; then
      echo "Batch state is missing the current hint context." >&2
      exit 1
    fi
    log_section "Advance Hint ${current_index}/${selected_count}"
    "$MANUAL_SESSION_SCRIPT" candidate \
      --output-dir "$current_run_dir" \
      --wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
      --wait-poll-seconds "$WAIT_POLL_SECONDS"
    "$MANUAL_SESSION_SCRIPT" restore \
      --output-dir "$current_run_dir" \
      --wait-timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
      --wait-poll-seconds "$WAIT_POLL_SECONDS"
    "$MANUAL_SESSION_SCRIPT" finalize --output-dir "$current_run_dir"
    record_completed_run "$current_index" "$current_hint_json" "$current_run_dir"
    next_index=$(( current_index + 1 ))
    if [[ "$next_index" -le "$selected_count" ]]; then
      prepare_run_for_index "$next_index" "$selected_count"
    else
      state_set currentIndex 0 int
      state_set currentRunDir ""
      state_set currentHint "{}" json
      state_set status "completed"
      state_set completedAt "$("$DATE_BIN" -u '+%Y-%m-%dT%H:%M:%SZ')"
      write_completed_hint_note
      rebuild_outputs
      printf 'Manual batch completed at %s\n' "$OUTPUT_DIR"
    fi
    ;;
  status)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No batch state file found at $STATE_FILE" >&2
      exit 1
    fi
    cat "$STATE_FILE"
    ;;
esac
