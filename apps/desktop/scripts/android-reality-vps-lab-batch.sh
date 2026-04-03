#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SED_BIN="/usr/bin/sed"

SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
DEVICE_DUMP_SCRIPT="${SCRIPT_DIR}/android-reality-device-dump.sh"

DATASET_FILE=""
OUTPUT_DIR=""
LIMIT=""
TEST_URL="https://example.com"
SETTLE_SECONDS="10"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-35}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"
TEST_TIMEOUT_SECONDS="45"
RESTORE_STABLE="1"
SKIP_STABLE="1"

typeset -a ENTRY_TAGS=()
typeset -a ENTRY_INDICES=()
typeset -a ENTRY_B64_LIST=()

SELECTED_FILE=""
RESULTS_JSON=""
SUMMARY_MD=""
RUNS_DIR=""
REQUEST_TEMPLATE_JSON=""
STABLE_REQUEST_JSON=""
LAST_SNAPSHOT_JSON=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-vps-lab-batch.sh [options]

Required:
  --dataset <path>            Promoted VPS lab dataset JSON.

Options:
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-android-reality-vps-lab-batch/<stamp>
  --tag <tag>                 Select one entry by tag. May be repeated.
  --index <n>                 Select one entry by 1-based index. May be repeated.
  --limit <count>             Limit entries after filtering.
  --include-stable            Include the stable control entry when present.
  --test-url <url>            URL for the phone-side connectivity test. Default: https://example.com
  --settle-seconds <n>        Seconds to wait after runtime reaches running. Default: 10
  --wait-timeout-seconds <n>  Snapshot wait timeout. Default: 35
  --wait-poll-seconds <n>     Snapshot wait poll interval. Default: 1
  --test-timeout-seconds <n>  lastTest wait timeout. Default: 45
  --no-restore-stable         Stop the lab runtime at the end instead of restoring stable.
  -h, --help                  Show this help.

Outputs:
  - selected.json
  - results.json
  - summary.md
  - runs/<nn-tag>/{request.json,pre-test-snapshot.json,post-test-snapshot.json,device-dump.txt,artifacts/}
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

capture_snapshot_to_file() {
  local target="$1"
  "$SERVICE_CONTROL_SCRIPT" print-snapshot > "$target"
  LAST_SNAPSHOT_JSON="$(cat "$target")"
}

extract_checked_at() {
  local snapshot_file="$1"
  "$PYTHON_BIN" - "$snapshot_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
snapshot = json.loads(path.read_text(encoding="utf-8"))
last_test = snapshot.get("lastTest")
if isinstance(last_test, dict):
    value = last_test.get("checkedAt") or ""
    print(str(value))
PY
}

generate_request() {
  local template_path="$1"
  local entry_json="$2"
  local output_path="$3"

  "$PYTHON_BIN" - "$template_path" "$entry_json" "$output_path" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
entry = json.loads(sys.argv[2])
output_path = Path(sys.argv[3])

request = json.loads(template_path.read_text(encoding="utf-8"))
profile = json.loads(request["profileJson"])
android_runtime = profile.setdefault("androidRuntime", {})
vps = android_runtime.setdefault("realityVpsLab", {})

transport = str(entry.get("transport") or "").strip().lower()
fingerprint = str(entry.get("fingerprint") or "").strip() or ("firefox" if transport == "grpc" else "chrome")
flow = entry.get("flow")
grpc_service_name = entry.get("grpcServiceName")
grpc_authority = entry.get("grpcAuthority")
connect_host = entry.get("connectHost")
connect_port = entry.get("connectPort")
override_uuid = str(entry.get("uuid") or "").strip()
override_public_key = str(entry.get("publicKey") or "").strip()
override_short_id = str(entry.get("shortId") or "").strip()
bootstrap_server_name = str(entry.get("bootstrapServerName") or entry.get("serverName") or "").strip()
bootstrap_server_port = int(entry.get("bootstrapServerPort") or entry.get("connectPort") or entry.get("port") or 0)
bootstrap_server_host = str(entry.get("bootstrapServerHost") or connect_host or request.get("serverHost") or "").strip()

if override_uuid or override_public_key or override_short_id:
    staged = profile.setdefault("stagedFallbacks", {})
    staged_vless = staged.setdefault("vlessReality", {})
    top_vless = profile.setdefault("vlessReality", {})
    for target in (staged_vless, top_vless):
        if override_uuid:
            target["uuid"] = override_uuid
        if override_public_key:
            target["publicKey"] = override_public_key
        if override_short_id:
            target["shortId"] = override_short_id
        if bootstrap_server_name:
            target["serverName"] = bootstrap_server_name
        if bootstrap_server_port > 0:
            target["port"] = bootstrap_server_port
        if flow:
            target["flow"] = flow
        elif not target.get("flow"):
            target["flow"] = "xtls-rprx-vision"
    if bootstrap_server_host:
        profile["serverHost"] = bootstrap_server_host
        request["serverHost"] = bootstrap_server_host

vps.update({
    "enabled": True,
    "mode": "lab",
    "serverName": entry.get("serverName"),
    "port": entry.get("port"),
    "transport": transport,
    "fingerprint": fingerprint,
    "source": entry.get("source") or "operator-curated:vps-lab",
    "tag": entry.get("tag"),
})

if flow:
    vps["flow"] = flow
else:
    vps.pop("flow", None)
if grpc_service_name:
    vps["grpcServiceName"] = grpc_service_name
else:
    vps.pop("grpcServiceName", None)
if grpc_authority:
    vps["grpcAuthority"] = grpc_authority
else:
    vps.pop("grpcAuthority", None)
if connect_host:
    vps["connectHost"] = connect_host
else:
    vps.pop("connectHost", None)
if connect_port:
    vps["connectPort"] = connect_port
else:
    vps.pop("connectPort", None)

request["profileJson"] = json.dumps(profile, ensure_ascii=False, separators=(",", ":"))
request["runtimeFamily"] = "reality-vps-lab"
request["activationState"] = "active"
request["configMode"] = "lab"
request["startSource"] = "debug_bridge"
request["selectedSniHint"] = entry.get("serverName")
request["whitelistHintSource"] = entry.get("source") or "operator-curated:vps-lab"
request["whitelistHintTag"] = entry.get("tag")
request["vpsRealityPort"] = entry.get("port")
if connect_host:
    request["vpsRealityConnectHost"] = connect_host
else:
    request.pop("vpsRealityConnectHost", None)
if connect_port:
    request["vpsRealityConnectPort"] = connect_port
else:
    request.pop("vpsRealityConnectPort", None)
request["vpsRealityTransport"] = transport
request["vpsRealityFingerprint"] = fingerprint
if flow:
    request["vpsRealityFlow"] = flow
else:
    request.pop("vpsRealityFlow", None)

active_features = [feature for feature in (request.get("activeFeatures") or []) if isinstance(feature, str)]
filtered = []
for feature in active_features:
    if feature.startswith("family:") or feature.startswith("activation:") or feature.startswith("mode:"):
        continue
    if feature.startswith("reality-vps-"):
        continue
    filtered.append(feature)
filtered.extend([
    "family:reality-vps-lab",
    "activation:active",
    "mode:lab",
    f"reality-vps-sni:{entry.get('serverName')}",
    f"reality-vps-port:{entry.get('port')}",
    f"reality-vps-transport:{transport}",
    f"reality-vps-fingerprint:{fingerprint}",
    f"reality-vps-source:{entry.get('source') or 'operator-curated:vps-lab'}",
    f"reality-vps-tag:{entry.get('tag')}",
])
if flow:
    filtered.append(f"reality-vps-flow:{flow}")
request["activeFeatures"] = filtered

output_path.write_text(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

derive_stable_request() {
  local template_path="$1"
  local output_path="$2"

  "$PYTHON_BIN" - "$template_path" "$output_path" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

request = json.loads(template_path.read_text(encoding="utf-8"))
profile = json.loads(request["profileJson"])
android_runtime = profile.setdefault("androidRuntime", {})
reality = android_runtime.setdefault("reality", {})
reality["mode"] = "stable"
vps = android_runtime.get("realityVpsLab")
if isinstance(vps, dict):
    vps["enabled"] = False

request["profileJson"] = json.dumps(profile, ensure_ascii=False, separators=(",", ":"))
request["runtimeFamily"] = "direct-reality"
request["activationState"] = "active"
request["configMode"] = "stable"
request["startSource"] = "debug_bridge"

for key in [
    "selectedSniHint",
    "selectedCidrHint",
    "whitelistHintSource",
    "whitelistHintTag",
    "vpsRealityPort",
    "vpsRealityConnectHost",
    "vpsRealityConnectPort",
    "vpsRealityTransport",
    "vpsRealityFingerprint",
    "vpsRealityFlow",
]:
    request.pop(key, None)

active_features = [feature for feature in (request.get("activeFeatures") or []) if isinstance(feature, str)]
filtered = []
for feature in active_features:
    if feature.startswith("family:") or feature.startswith("activation:") or feature.startswith("mode:"):
        continue
    if feature.startswith("reality-vps-"):
        continue
    filtered.append(feature)
filtered.extend([
    "family:direct-reality",
    "activation:active",
    "mode:stable",
])
request["activeFeatures"] = filtered

output_path.write_text(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

refresh_outputs() {
  "$PYTHON_BIN" - "$SELECTED_FILE" "$RESULTS_JSON" "$SUMMARY_MD" "$RUNS_DIR" "$OUTPUT_DIR" <<'PY'
import json
import sys
from pathlib import Path

selected_path = Path(sys.argv[1])
results_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
runs_dir = Path(sys.argv[4])
output_dir = Path(sys.argv[5])

selected_payload = json.loads(selected_path.read_text(encoding="utf-8"))
entries = selected_payload.get("selectedEntries") or []

results = []
for entry in entries:
    run_dir = runs_dir / entry["runLabel"]
    snapshot_path = run_dir / "post-test-snapshot.json"
    dump_path = run_dir / "device-dump.txt"
    run_error_path = run_dir / "run-error.txt"
    snapshot = {}
    if snapshot_path.is_file():
      try:
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
      except Exception:
        snapshot = {}
    last_test = snapshot.get("lastTest") if isinstance(snapshot.get("lastTest"), dict) else {}
    run_error = ""
    if run_error_path.is_file():
        run_error = run_error_path.read_text(encoding="utf-8", errors="replace").strip()
    result = {
        "index": entry["index"],
        "tag": entry["tag"],
        "serverName": entry.get("serverName"),
        "port": entry.get("port"),
        "transport": entry.get("transport"),
        "fingerprint": entry.get("fingerprint"),
        "flow": entry.get("flow"),
        "source": entry.get("source"),
        "runDir": str(run_dir),
        "requestPath": str(run_dir / "request.json"),
        "dumpPath": str(dump_path),
        "snapshotPath": str(snapshot_path),
        "runtimeFamily": snapshot.get("runtimeFamily"),
        "activationState": snapshot.get("activationState"),
        "status": snapshot.get("status"),
        "startSource": snapshot.get("startSource"),
        "lastStartupStage": snapshot.get("lastStartupStage"),
        "lastFailureCode": snapshot.get("lastFailureCode"),
        "runError": run_error or None,
        "test": last_test or None,
    }
    results.append(result)

    entry["result"] = result

results_path.write_text(
    json.dumps({
        "kind": "odin-one-android-reality-vps-lab-batch-v1",
        "count": len(results),
        "results": results,
    }, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

summary_lines = [
    "# Android Reality VPS Lab Batch",
    "",
    f"- Output dir: `{output_dir}`",
    f"- Selected entries: `{len(results)}`",
    "",
    "## Results",
    "",
]
if not results:
    summary_lines.append("- No runs were selected.")
else:
    for result in results:
        test = result.get("test") or {}
        test_status = test.get("status") or "missing"
        test_error = test.get("error") or ""
        run_error = result.get("runError") or ""
        line = (
            f"- `{result['tag']}` | sni=`{result.get('serverName')}` | port=`{result.get('port')}` | "
            f"transport=`{result.get('transport')}` | runtime=`{result.get('status')}` | test=`{test_status}`"
        )
        if test_error:
            line += f" | error=`{test_error}`"
        if run_error:
            line += f" | runError=`{run_error}`"
        summary_lines.append(line)

summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DATASET_FILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_TAGS+=("$2")
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_INDICES+=("$2")
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --include-stable)
      SKIP_STABLE="0"
      shift
      ;;
    --test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_URL="$2"
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
    --test-timeout-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --no-restore-stable)
      RESTORE_STABLE="0"
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

require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$DEVICE_DUMP_SCRIPT"
require_python

if [[ -z "$DATASET_FILE" || ! -f "$DATASET_FILE" ]]; then
  echo "Dataset JSON not found: $DATASET_FILE" >&2
  exit 1
fi

if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be a positive integer" >&2
  exit 1
fi
if ! [[ "$SETTLE_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "--settle-seconds must be a non-negative integer" >&2
  exit 1
fi
if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ '^[0-9]+$' ]] || [[ "$WAIT_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--wait-timeout-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$WAIT_POLL_SECONDS" =~ '^[0-9]+$' ]] || [[ "$WAIT_POLL_SECONDS" -le 0 ]]; then
  echo "--wait-poll-seconds must be a positive integer" >&2
  exit 1
fi
if ! [[ "$TEST_TIMEOUT_SECONDS" =~ '^[0-9]+$' ]] || [[ "$TEST_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "--test-timeout-seconds must be a positive integer" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-android-reality-vps-lab-batch/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

SELECTED_FILE="${OUTPUT_DIR}/selected.json"
RESULTS_JSON="${OUTPUT_DIR}/results.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"
RUNS_DIR="${OUTPUT_DIR}/runs"
REQUEST_TEMPLATE_JSON="${OUTPUT_DIR}/request-template.json"
STABLE_REQUEST_JSON="${OUTPUT_DIR}/stable-request.json"
"$MKDIR_BIN" -p "$RUNS_DIR"

if "$SERVICE_CONTROL_SCRIPT" print-request > "$STABLE_REQUEST_JSON" 2>/dev/null; then
  cp "$STABLE_REQUEST_JSON" "$REQUEST_TEMPLATE_JSON"
elif "$SERVICE_CONTROL_SCRIPT" print-attempted-request > "$REQUEST_TEMPLATE_JSON" 2>/dev/null; then
  derive_stable_request "$REQUEST_TEMPLATE_JSON" "$STABLE_REQUEST_JSON"
else
  echo "Unable to load either last_request or last_attempted_request from the device." >&2
  exit 1
fi

"$PYTHON_BIN" - "$DATASET_FILE" "$SELECTED_FILE" "$SKIP_STABLE" "$LIMIT" "$(printf '%s\n' "${ENTRY_TAGS[@]-}")" "$(printf '%s\n' "${ENTRY_INDICES[@]-}")" <<'PY'
import json
import sys
from pathlib import Path

dataset_path = Path(sys.argv[1])
selected_path = Path(sys.argv[2])
skip_stable = sys.argv[3].strip() == "1"
limit_raw = sys.argv[4].strip()
raw_tags = [line.strip() for line in sys.argv[5].splitlines() if line.strip()]
raw_indices = [int(line.strip()) for line in sys.argv[6].splitlines() if line.strip()]
limit = int(limit_raw) if limit_raw else None

dataset = json.loads(dataset_path.read_text(encoding="utf-8"))
entries = [entry for entry in dataset.get("entries") or [] if isinstance(entry, dict)]
if skip_stable:
    entries = [entry for entry in entries if str(entry.get("mode") or "") != "stable-control"]

selected = []
seen = set()
if raw_tags:
    wanted = set(raw_tags)
    for entry in entries:
        tag = str(entry.get("tag") or "")
        if tag in wanted and tag not in seen:
            selected.append(entry)
            seen.add(tag)
elif raw_indices:
    for index in raw_indices:
        if 1 <= index <= len(entries):
            entry = entries[index - 1]
            tag = str(entry.get("tag") or "")
            if tag not in seen:
                selected.append(entry)
                seen.add(tag)
else:
    selected = list(entries)

if limit is not None:
    selected = selected[:limit]

normalized = []
for index, entry in enumerate(selected, start=1):
    normalized_entry = {
        "index": index,
        "priority": entry.get("priority"),
        "tag": entry.get("tag"),
        "mode": entry.get("mode"),
        "serverName": entry.get("serverName"),
        "port": entry.get("port"),
        "transport": entry.get("transport"),
        "fingerprint": "firefox" if str(entry.get("transport") or "").lower() == "grpc" else "chrome",
        "flow": entry.get("flow"),
        "grpcServiceName": entry.get("grpcServiceName"),
        "grpcAuthority": entry.get("grpcAuthority"),
        "connectHost": entry.get("connectHost"),
        "connectPort": entry.get("connectPort"),
        "uuid": entry.get("uuid"),
        "publicKey": entry.get("publicKey"),
        "shortId": entry.get("shortId"),
        "bootstrapServerName": entry.get("bootstrapServerName"),
        "bootstrapServerPort": entry.get("bootstrapServerPort"),
        "bootstrapServerHost": entry.get("bootstrapServerHost"),
        "uri": entry.get("uri"),
        "originHost": entry.get("originHost"),
        "originPort": entry.get("originPort"),
        "source": entry.get("source") or "operator-curated:vps-lab",
        "runLabel": f"{index:02d}-{str(entry.get('tag') or 'candidate').strip().lower()}",
    }
    normalized.append(normalized_entry)

payload = {
    "kind": "odin-one-android-reality-vps-lab-selected-v1",
    "datasetSource": str(dataset_path),
    "selectedEntries": normalized,
}
selected_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

refresh_outputs

ENTRY_B64_LIST=("${(@f)$("$PYTHON_BIN" - "$SELECTED_FILE" <<'PY'
import json
import sys
import base64
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for entry in payload.get("selectedEntries") or []:
    raw = json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    print(base64.b64encode(raw).decode("ascii"))
PY
)}")

for entry_b64 in "${ENTRY_B64_LIST[@]}"; do
  entry_json="$("$PYTHON_BIN" - "$entry_b64" <<'PY'
import base64
import sys

print(base64.b64decode(sys.argv[1]).decode("utf-8"))
PY
)"
  entry_tag="$("$PYTHON_BIN" - "$entry_json" <<'PY'
import json
import sys

entry = json.loads(sys.argv[1])
print(str(entry.get("tag") or ""))
PY
)"
  entry_run_label="$("$PYTHON_BIN" - "$entry_json" <<'PY'
import json
import sys

entry = json.loads(sys.argv[1])
print(str(entry.get("runLabel") or ""))
PY
)"
  run_dir="${RUNS_DIR}/${entry_run_label}"
  artifacts_dir="${run_dir}/artifacts"
  mkdir -p "$run_dir" "$artifacts_dir"

  request_path="${run_dir}/request.json"
  run_error_path="${run_dir}/run-error.txt"
  rm -f "$run_error_path"
  generate_request "$REQUEST_TEMPLATE_JSON" "$entry_json" "$request_path"

  run_failed="0"
  failure_label=""

  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 2

  if ! ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-json-file "$request_path" >/dev/null; then
    run_failed="1"
    failure_label="start-from-json-file"
  fi

  if [[ "$run_failed" == "0" ]]; then
    if ! "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
      --family reality-vps-lab \
      --status running \
      --activation active \
      --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
      --poll-seconds "$WAIT_POLL_SECONDS" > "${run_dir}/running-snapshot.json"; then
      run_failed="1"
      failure_label="wait-running"
    fi
  fi

  if [[ "$run_failed" == "0" ]]; then
    sleep "$SETTLE_SECONDS"
    capture_snapshot_to_file "${run_dir}/pre-test-snapshot.json"
    previous_checked_at="$(extract_checked_at "${run_dir}/pre-test-snapshot.json")"

    if ! ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" run-test --url "$TEST_URL" >/dev/null; then
      run_failed="1"
      failure_label="run-test"
    fi
  fi

  if [[ "$run_failed" == "0" ]]; then
    if ! "$SERVICE_CONTROL_SCRIPT" wait-test-result \
      --since "$previous_checked_at" \
      --timeout-seconds "$TEST_TIMEOUT_SECONDS" \
      --poll-seconds "$WAIT_POLL_SECONDS" > "${run_dir}/test-result-snapshot.json"; then
      run_failed="1"
      failure_label="wait-test-result"
    fi
  fi

  if [[ "$run_failed" == "1" ]]; then
    printf '%s\n' "$failure_label" > "$run_error_path"
  fi

  "$SERVICE_CONTROL_SCRIPT" print-snapshot > "${run_dir}/post-test-snapshot.json" 2>/dev/null || true
  ODIN_ONE_ANDROID_ARTIFACT_DIR="$artifacts_dir" "$DEVICE_DUMP_SCRIPT" > "${run_dir}/device-dump.txt" 2>/dev/null || true
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 2

  refresh_outputs
done

if [[ "$RESTORE_STABLE" == "1" ]]; then
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 2
  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-json-file "$STABLE_REQUEST_JSON" >/dev/null
  "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --family direct-reality \
    --status running \
    --activation active \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" > "${OUTPUT_DIR}/restored-stable-snapshot.json"
else
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
fi

refresh_outputs
echo "$OUTPUT_DIR"
