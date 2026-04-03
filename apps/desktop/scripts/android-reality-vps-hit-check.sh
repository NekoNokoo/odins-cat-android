#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SED_BIN="/usr/bin/sed"

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"

SERVICE_CONTROL_SCRIPT="${SCRIPT_DIR}/android-runtime-service-control.sh"
CAPTURE_SCRIPT="${SCRIPT_DIR}/android-reality-capture-run.sh"
COMPARE_SCRIPT="${SCRIPT_DIR}/android-runtime-compare-captures.sh"
REPORT_SCRIPT="${SCRIPT_DIR}/android-runtime-report-draft.sh"

DATASET_FILE=""
ENTRY_TAG=""
ENTRY_INDEX=""
TEST_URL="https://example.com"
OUTPUT_DIR=""
SETTLE_SECONDS="10"
POST_TEST_SETTLE_SECONDS="3"
WAIT_TIMEOUT_SECONDS="${ODIN_ONE_RUNTIME_WAIT_TIMEOUT_SECONDS:-35}"
WAIT_POLL_SECONDS="${ODIN_ONE_RUNTIME_WAIT_POLL_SECONDS:-1}"
TEST_TIMEOUT_SECONDS="45"
ENGINE_READY_TIMEOUT_SECONDS="${ODIN_ONE_REALITY_VPS_ENGINE_READY_TIMEOUT_SECONDS:-120}"
ENGINE_READY_POLL_SECONDS="${ODIN_ONE_REALITY_VPS_ENGINE_READY_POLL_SECONDS:-2}"
RESTORE_STABLE="1"
SKIP_SERVER_SS="0"

SERVER_HOST=""
SERVER_USER="${ODIN_ONE_REALITY_VPS_HIT_SSH_USER:-root}"
SERVER_KEY="${ODIN_ONE_REALITY_VPS_HIT_SSH_KEY:-$HOME/.ssh/afina_bot}"
SERVER_KNOWN_HOSTS="${ODIN_ONE_REALITY_VPS_HIT_KNOWN_HOSTS:-/tmp/odin-one-known-hosts}"
SERVER_SS_SECONDS="${ODIN_ONE_REALITY_VPS_HIT_SS_SECONDS:-18}"
SERVER_SS_INTERVAL_SECONDS="${ODIN_ONE_REALITY_VPS_HIT_SS_INTERVAL_SECONDS:-0.2}"
DEVICE_INTERFACE_OVERRIDE="${ODIN_ONE_REALITY_VPS_DEVICE_UNDERLYING_INTERFACE:-}"

SELECTED_JSON=""
REQUEST_TEMPLATE_JSON=""
STABLE_REQUEST_JSON=""
REQUEST_JSON=""
CAPTURE_DIR=""
CONTROL_CAPTURE=""
CANDIDATE_BEFORE_CAPTURE=""
CANDIDATE_AFTER_CAPTURE=""
RESTORE_CAPTURE=""
RUNNING_SNAPSHOT_JSON=""
PRETEST_SNAPSHOT_JSON=""
TEST_RESULT_SNAPSHOT_JSON=""
POSTTEST_SNAPSHOT_JSON=""
RESTORED_STABLE_SNAPSHOT_JSON=""
FINAL_SNAPSHOT_JSON=""
ENGINE_READY_SNAPSHOT_JSON=""
SERVER_RUNTEST_SS_LOG=""
SERVER_RUNTEST_SS_SUMMARY=""
SERVER_RAWPROBE_SS_LOG=""
SERVER_RAWPROBE_SS_SUMMARY=""
DEVICE_RAW_PROBE_LOG=""
COMPARE_MD=""
REPORT_MD=""
SUMMARY_MD=""
RESULTS_JSON=""

SELECTED_TAG="n/a"
SELECTED_SNI="n/a"
SELECTED_PORT="n/a"
SELECTED_CONNECT_HOST="n/a"
SELECTED_CONNECT_PORT="n/a"
SELECTED_ORIGIN_HOST="n/a"
SELECTED_ORIGIN_PORT="n/a"
SELECTED_TRANSPORT="n/a"
SELECTED_SOURCE="n/a"
RUN_TEST_STATUS="not-run"
RUN_TEST_ERROR="n/a"
RUN_TEST_OUTPUT="n/a"
SERVER_RUNTEST_CONFIRMATION="unknown"
SERVER_RUNTEST_MATCH_COUNT="0"
SERVER_RAWPROBE_CONFIRMATION="unknown"
SERVER_RAWPROBE_MATCH_COUNT="0"
ENGINE_READY_DETECTED="false"
DEVICE_INTERFACE_NAME="n/a"
DEVICE_RAW_PROBE_RESULT="n/a"
RESTORE_DONE="false"
LAST_SERVER_SS_PID=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-vps-hit-check.sh [options]

Required:
  --dataset <path>            Promoted VPS lab dataset JSON.

Selection:
  --tag <tag>                 Select one entry by tag.
  --index <n>                 Select one entry by 1-based index among non-stable entries.

Options:
  --test-url <url>            URL used by the Android VPN connectivity test. Default: https://example.com
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-android-reality-vps-hit-check/<stamp>
  --settle-seconds <n>        Wait after runtime reaches running. Default: 10
  --post-test-settle-seconds <n>
                              Wait after run-test completes before the post-test capture. Default: 3
  --wait-timeout-seconds <n>  Snapshot wait timeout. Default: 35
  --wait-poll-seconds <n>     Snapshot wait poll interval. Default: 1
  --test-timeout-seconds <n>  lastTest wait timeout. Default: 45
  --engine-ready-timeout-seconds <n>
                              Wait for `sing-box started` / `libbox startOrReloadService completed.`
                              to appear in the runtime log before run-test. Default: 120
  --engine-ready-poll-seconds <n>
                              Poll interval while waiting for engine readiness. Default: 2
  --server-host <host>        Override the SSH target host. Default: dataset.remoteHost/serverHost
  --skip-server-ss            Skip remote SSH `ss` sampling when the selected
                              candidate points at an external edge we do not control.
  --skip-restore              Leave the handset on the candidate lane at the end.
  -h, --help                  Show this help.

This helper is owner-only and additive:
  1. Captures the stable control lane.
  2. Starts one hidden `reality-vps-lab` candidate from the promoted dataset.
  3. Opens a bounded remote `ss` sampling window for the candidate port.
  4. Runs an explicit Android VPN connectivity test.
  5. Saves before/after handset captures and compare/report drafts.
  6. Runs a raw cellular interface probe to the same VPS lab port.
  7. Restores stable `direct-reality` unless --skip-restore is used.
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

capture_output_path_from_run() {
  printf '%s\n' "$1" | "$SED_BIN" -n 's/^Wrote handset dump to //p' | tail -n 1
}

run_ssh() {
  "$SSH_BIN" \
    -i "$SERVER_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$SERVER_KNOWN_HOSTS" \
    "${SERVER_USER}@${SERVER_HOST}" \
    "$@"
}

capture_snapshot_to_file() {
  local target="$1"
  "$SERVICE_CONTROL_SCRIPT" print-snapshot > "$target"
}

snapshot_has_engine_ready_marker() {
  local snapshot_file="$1"
  "$PYTHON_BIN" - "$snapshot_file" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
log_tail = snapshot.get("logTail") or []
markers = (
    "sing-box started",
    "libbox startOrReloadService completed.",
)
for line in log_tail:
    text = str(line)
    if any(marker in text for marker in markers):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_for_engine_ready_marker() {
  local output_path="$1"
  local timeout_seconds="$2"
  local poll_seconds="$3"
  local tmp_path="${output_path}.tmp"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    capture_snapshot_to_file "$tmp_path" || true
    if [[ -f "$tmp_path" ]] && snapshot_has_engine_ready_marker "$tmp_path"; then
      mv "$tmp_path" "$output_path"
      return 0
    fi
    sleep "$poll_seconds"
  done

  if [[ -f "$tmp_path" ]]; then
    mv "$tmp_path" "$output_path"
  else
    capture_snapshot_to_file "$output_path" || true
  fi
  return 1
}

extract_checked_at() {
  local snapshot_file="$1"
  "$PYTHON_BIN" - "$snapshot_file" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
last_test = snapshot.get("lastTest")
if isinstance(last_test, dict):
    print(str(last_test.get("checkedAt") or ""))
PY
}

extract_last_test_status() {
  local snapshot_file="$1"
  "$PYTHON_BIN" - "$snapshot_file" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
last_test = snapshot.get("lastTest")
if isinstance(last_test, dict):
    print(str(last_test.get("status") or ""))
PY
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

start_server_ss_sampler() {
  local output_path="$1"
  local port="$2"
  local duration_seconds="$3"
  local interval_seconds="$4"
  local iterations
  iterations="$("$PYTHON_BIN" - "$duration_seconds" "$interval_seconds" <<'PY'
import math
import sys

duration = float(sys.argv[1])
interval = float(sys.argv[2])
if interval <= 0:
    interval = 0.2
count = max(1, int(math.ceil(duration / interval)))
print(count)
PY
)"

  local remote_script
  remote_script="$(cat <<EOF
set -eu
echo "# serverHost=$SERVER_HOST"
echo "# port=$port"
echo "# startedAt=\$(date -u +%FT%TZ)"
echo "# serviceState=\$(systemctl is-active whitelist-xray.service 2>/dev/null || true)"
echo "# listenSnapshot"
ss -H -ltn "( sport = :$port )" || true
i=0
while [ "\$i" -lt "$iterations" ]; do
  printf '=== %s\\n' "\$(date -u +%FT%TZ)"
  ss -H -tn state all "( sport = :$port or dport = :$port )" || true
  i=\$((i+1))
  sleep "$interval_seconds"
done
echo "# finishedAt=\$(date -u +%FT%TZ)"
EOF
)"

  run_ssh "$remote_script" >"$output_path" 2>&1 &
  LAST_SERVER_SS_PID="$!"
}

build_server_ss_summary() {
  local input_path="$1"
  local output_path="$2"
  "$PYTHON_BIN" - "$input_path" "$output_path" <<'PY'
import json
import re
import sys
from collections import Counter
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
text = input_path.read_text(encoding="utf-8", errors="replace")
lines = [line.rstrip() for line in text.splitlines()]
samples = []
states = Counter()
peers = Counter()
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("==="):
        continue
    if stripped.startswith("LISTEN "):
        continue
    if re.match(r"^[A-Z0-9-]+\s", stripped):
        samples.append(stripped)
        state = stripped.split()[0]
        states[state] += 1
        fields = stripped.split()
        if len(fields) >= 5:
            peers[fields[4]] += 1

payload = {
    "matchCount": len(samples),
    "confirmation": "yes" if samples else "no",
    "states": dict(states),
    "peers": peers.most_common(10),
    "samples": samples[:20],
}
output_path.write_text(
    "# Reality VPS Server SS Summary\n\n"
    f"- Match count: `{payload['matchCount']}`\n"
    f"- Confirmation: `{payload['confirmation']}`\n"
    f"- States: `{json.dumps(payload['states'], ensure_ascii=False, sort_keys=True)}`\n"
    f"- Peers: `{json.dumps(payload['peers'], ensure_ascii=False)}`\n"
    + ("\n## Samples\n\n" + "\n".join(f"- `{sample}`" for sample in payload["samples"]) + "\n" if payload["samples"] else "\n## Samples\n\n- No matching `ss` lines captured.\n"),
    encoding="utf-8",
)
print(json.dumps(payload, ensure_ascii=False))
PY
}

run_device_raw_tcp_probe() {
  local output_path="$1"
  if [[ "$DEVICE_INTERFACE_NAME" == "n/a" || -z "$DEVICE_INTERFACE_NAME" || "$SELECTED_CONNECT_HOST" == "n/a" || "$SELECTED_CONNECT_PORT" == "n/a" ]]; then
    printf 'skipped\n' >"$output_path"
    printf 'skipped'
    return 0
  fi

  local exit_code=0
  if "$ADB_BIN" shell curl \
    --interface "$DEVICE_INTERFACE_NAME" \
    -sv \
    --connect-timeout 5 \
    --max-time 8 \
    -o /dev/null \
    "http://${SELECTED_CONNECT_HOST}:${SELECTED_CONNECT_PORT}/" >"$output_path" 2>&1
  then
    exit_code=0
  else
    exit_code=$?
  fi

  "$PYTHON_BIN" - "$output_path" "$exit_code" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
exit_code = sys.argv[2]
text = path.read_text(encoding="utf-8", errors="replace")
connected = "Connected to " in text or "Connected to" in text
timed_out = "timed out" in text.lower() or "timeout was reached" in text.lower() or "connect timeout" in text.lower()
if connected and exit_code == "0":
    print("connected (exit:0)")
elif connected:
    print(f"connected (exit:{exit_code})")
elif timed_out:
    print(f"timeout (exit:{exit_code})")
else:
    last = ""
    for line in reversed(text.splitlines()):
      stripped = line.strip()
      if stripped:
        last = stripped
        break
    if last:
        print(f"exit:{exit_code} ({last})")
    else:
        print(f"exit:{exit_code}")
PY
}

generate_request() {
  local template_path="$1"
  local entry_path="$2"
  local output_path="$3"

  "$PYTHON_BIN" - "$template_path" "$entry_path" "$output_path" <<'PY'
import json
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
entry_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

request = json.loads(template_path.read_text(encoding="utf-8"))
entry_payload = json.loads(entry_path.read_text(encoding="utf-8"))
entry = entry_payload.get("entry") if isinstance(entry_payload, dict) and isinstance(entry_payload.get("entry"), dict) else entry_payload
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DATASET_FILE="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_TAG="$2"
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_INDEX="$2"
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
    --post-test-settle-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      POST_TEST_SETTLE_SECONDS="$2"
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
    --engine-ready-timeout-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE_READY_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --engine-ready-poll-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE_READY_POLL_SECONDS="$2"
      shift 2
      ;;
    --server-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SERVER_HOST="$2"
      shift 2
      ;;
    --skip-server-ss)
      SKIP_SERVER_SS="1"
      shift
      ;;
    --skip-restore)
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

require_bin "$PYTHON_BIN" "python3"
require_bin "$ADB_BIN" "adb"
require_script "$SERVICE_CONTROL_SCRIPT"
require_script "$CAPTURE_SCRIPT"
require_script "$COMPARE_SCRIPT"
require_script "$REPORT_SCRIPT"
if [[ "$SKIP_SERVER_SS" != "1" ]]; then
  require_bin "$SSH_BIN" "ssh"
fi

if [[ -z "$DATASET_FILE" || ! -f "$DATASET_FILE" ]]; then
  echo "Dataset JSON not found: $DATASET_FILE" >&2
  exit 1
fi
if [[ -n "$ENTRY_INDEX" && ! "$ENTRY_INDEX" =~ '^[0-9]+$' ]]; then
  echo "--index must be a positive integer" >&2
  exit 1
fi
for value in "$SETTLE_SECONDS" "$POST_TEST_SETTLE_SECONDS" "$WAIT_TIMEOUT_SECONDS" "$WAIT_POLL_SECONDS" "$TEST_TIMEOUT_SECONDS" "$ENGINE_READY_TIMEOUT_SECONDS" "$ENGINE_READY_POLL_SECONDS" "$SERVER_SS_SECONDS"; do
  if ! [[ "$value" =~ '^[0-9]+$' ]]; then
    echo "Timing values must be integers" >&2
    exit 1
  fi
done

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-android-reality-vps-hit-check/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

SELECTED_JSON="${OUTPUT_DIR}/selected.json"
REQUEST_TEMPLATE_JSON="${OUTPUT_DIR}/request-template.json"
STABLE_REQUEST_JSON="${OUTPUT_DIR}/stable-request.json"
REQUEST_JSON="${OUTPUT_DIR}/request.json"
CAPTURE_DIR="${OUTPUT_DIR}/captures"
RUNNING_SNAPSHOT_JSON="${OUTPUT_DIR}/running-snapshot.json"
PRETEST_SNAPSHOT_JSON="${OUTPUT_DIR}/pre-test-snapshot.json"
TEST_RESULT_SNAPSHOT_JSON="${OUTPUT_DIR}/test-result-snapshot.json"
POSTTEST_SNAPSHOT_JSON="${OUTPUT_DIR}/post-test-snapshot.json"
RESTORED_STABLE_SNAPSHOT_JSON="${OUTPUT_DIR}/restored-stable-snapshot.json"
FINAL_SNAPSHOT_JSON="${OUTPUT_DIR}/final-snapshot.json"
ENGINE_READY_SNAPSHOT_JSON="${OUTPUT_DIR}/engine-ready-snapshot.json"
SERVER_RUNTEST_SS_LOG="${OUTPUT_DIR}/server-run-test-ss.txt"
SERVER_RUNTEST_SS_SUMMARY="${OUTPUT_DIR}/server-run-test-ss-summary.md"
SERVER_RAWPROBE_SS_LOG="${OUTPUT_DIR}/server-raw-probe-ss.txt"
SERVER_RAWPROBE_SS_SUMMARY="${OUTPUT_DIR}/server-raw-probe-ss-summary.md"
DEVICE_RAW_PROBE_LOG="${OUTPUT_DIR}/device-raw-probe.txt"
COMPARE_MD="${OUTPUT_DIR}/compare.md"
REPORT_MD="${OUTPUT_DIR}/report.md"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"
RESULTS_JSON="${OUTPUT_DIR}/results.json"
"$MKDIR_BIN" -p "$CAPTURE_DIR"

"$PYTHON_BIN" - "$DATASET_FILE" "$SELECTED_JSON" "$ENTRY_TAG" "$ENTRY_INDEX" <<'PY'
import json
import sys
from pathlib import Path

dataset_path = Path(sys.argv[1])
selected_path = Path(sys.argv[2])
wanted_tag = sys.argv[3].strip()
wanted_index = sys.argv[4].strip()

dataset = json.loads(dataset_path.read_text(encoding="utf-8"))
entries = [entry for entry in dataset.get("entries") or [] if isinstance(entry, dict) and str(entry.get("mode") or "") != "stable-control"]
if not entries:
    raise SystemExit("No non-stable entries found in dataset.")

selected = None
if wanted_tag:
    for entry in entries:
        if str(entry.get("tag") or "") == wanted_tag:
            selected = entry
            break
    if selected is None:
        raise SystemExit(f"Dataset entry not found for tag: {wanted_tag}")
elif wanted_index:
    index = int(wanted_index)
    if index < 1 or index > len(entries):
        raise SystemExit(f"Dataset index out of range: {index}")
    selected = entries[index - 1]
else:
    selected = entries[0]

payload = {
    "kind": "odin-one-android-reality-vps-hit-check-selection-v1",
    "datasetSource": str(dataset_path),
    "remoteHost": dataset.get("remoteHost"),
    "serverHost": dataset.get("serverHost"),
    "entry": {
        "priority": selected.get("priority"),
        "tag": selected.get("tag"),
        "mode": selected.get("mode"),
        "serverName": selected.get("serverName"),
        "port": selected.get("port"),
        "connectHost": selected.get("connectHost"),
        "connectPort": selected.get("connectPort"),
        "originHost": selected.get("originHost"),
        "originPort": selected.get("originPort"),
        "transport": selected.get("transport"),
        "fingerprint": "firefox" if str(selected.get("transport") or "").lower() == "grpc" else "chrome",
        "flow": selected.get("flow"),
        "grpcServiceName": selected.get("grpcServiceName"),
        "grpcAuthority": selected.get("grpcAuthority"),
        "source": selected.get("source") or "operator-curated:vps-lab",
        "uuid": selected.get("uuid"),
        "publicKey": selected.get("publicKey"),
        "shortId": selected.get("shortId"),
        "bootstrapServerName": selected.get("bootstrapServerName"),
        "bootstrapServerPort": selected.get("bootstrapServerPort"),
        "bootstrapServerHost": selected.get("bootstrapServerHost"),
        "uri": selected.get("uri"),
    },
}
selected_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

SELECTED_TAG="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("tag") or "candidate"))
PY
)"
SELECTED_SNI="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("serverName") or "n/a"))
PY
)"
SELECTED_PORT="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("port") or "n/a"))
PY
)"
SELECTED_CONNECT_HOST="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("connectHost") or payload.get("serverHost") or payload.get("remoteHost") or "n/a"))
PY
)"
SELECTED_CONNECT_PORT="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("connectPort") or entry.get("port") or "n/a"))
PY
)"
SELECTED_ORIGIN_HOST="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("originHost") or payload.get("serverHost") or payload.get("remoteHost") or "n/a"))
PY
)"
SELECTED_ORIGIN_PORT="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("originPort") or entry.get("port") or "n/a"))
PY
)"
SELECTED_TRANSPORT="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("transport") or "n/a"))
PY
)"
SELECTED_SOURCE="$("$PYTHON_BIN" - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
entry = payload.get("entry") or {}
print(str(entry.get("source") or "n/a"))
PY
)"
if [[ -z "$SERVER_HOST" ]]; then
  SERVER_HOST="$SELECTED_ORIGIN_HOST"
fi
if [[ "$SKIP_SERVER_SS" != "1" && -z "$SERVER_HOST" ]]; then
  echo "Unable to determine server host from dataset; pass --server-host." >&2
  exit 1
fi

if "$SERVICE_CONTROL_SCRIPT" print-request > "$STABLE_REQUEST_JSON" 2>/dev/null; then
  cp "$STABLE_REQUEST_JSON" "$REQUEST_TEMPLATE_JSON"
elif "$SERVICE_CONTROL_SCRIPT" print-attempted-request > "$REQUEST_TEMPLATE_JSON" 2>/dev/null; then
  derive_stable_request "$REQUEST_TEMPLATE_JSON" "$STABLE_REQUEST_JSON"
else
  echo "Unable to load either last_request or last_attempted_request from the device." >&2
  exit 1
fi

generate_request "$REQUEST_TEMPLATE_JSON" "$SELECTED_JSON" "$REQUEST_JSON"

control_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "stable-control" 2>/dev/null)"
CONTROL_CAPTURE="$(capture_output_path_from_run "$control_output")"
if [[ -z "$CONTROL_CAPTURE" || ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Failed to capture stable control lane." >&2
  exit 1
fi

"$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
sleep 2
ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-json-file "$REQUEST_JSON" >/dev/null
"$SERVICE_CONTROL_SCRIPT" wait-snapshot \
  --family reality-vps-lab \
  --status running \
  --activation active \
  --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
  --poll-seconds "$WAIT_POLL_SECONDS" > "$RUNNING_SNAPSHOT_JSON"

if wait_for_engine_ready_marker "$ENGINE_READY_SNAPSHOT_JSON" "$ENGINE_READY_TIMEOUT_SECONDS" "$ENGINE_READY_POLL_SECONDS"; then
  ENGINE_READY_DETECTED="true"
else
  ENGINE_READY_DETECTED="false"
fi

sleep "$SETTLE_SECONDS"
capture_snapshot_to_file "$PRETEST_SNAPSHOT_JSON"
previous_checked_at="$(extract_checked_at "$PRETEST_SNAPSHOT_JSON")"
candidate_before_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "reality-vps-before-test" 2>/dev/null)"
CANDIDATE_BEFORE_CAPTURE="$(capture_output_path_from_run "$candidate_before_output")"

if [[ "$SKIP_SERVER_SS" == "1" ]]; then
  printf '# skipped (--skip-server-ss)\n' >"$SERVER_RUNTEST_SS_LOG"
else
  start_server_ss_sampler "$SERVER_RUNTEST_SS_LOG" "$SELECTED_ORIGIN_PORT" "$SERVER_SS_SECONDS" "$SERVER_SS_INTERVAL_SECONDS"
fi
ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" run-test --url "$TEST_URL" >/dev/null
if ! "$SERVICE_CONTROL_SCRIPT" wait-test-result \
  --since "$previous_checked_at" \
  --timeout-seconds "$TEST_TIMEOUT_SECONDS" \
  --poll-seconds "$WAIT_POLL_SECONDS" > "$TEST_RESULT_SNAPSHOT_JSON"
then
  first_wait_checked_at="$(extract_checked_at "$TEST_RESULT_SNAPSHOT_JSON")"
  first_wait_status="$(extract_last_test_status "$TEST_RESULT_SNAPSHOT_JSON")"
  if [[ "$first_wait_status" == "idle" || "$first_wait_checked_at" == "$previous_checked_at" ]]; then
    ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" run-test --url "$TEST_URL" >/dev/null
    "$SERVICE_CONTROL_SCRIPT" wait-test-result \
      --since "$previous_checked_at" \
      --timeout-seconds "$TEST_TIMEOUT_SECONDS" \
      --poll-seconds "$WAIT_POLL_SECONDS" > "$TEST_RESULT_SNAPSHOT_JSON"
  else
    exit 1
  fi
fi
if [[ -n "$LAST_SERVER_SS_PID" ]]; then
  wait "$LAST_SERVER_SS_PID" || true
  LAST_SERVER_SS_PID=""
fi

sleep "$POST_TEST_SETTLE_SECONDS"
capture_snapshot_to_file "$POSTTEST_SNAPSHOT_JSON"
candidate_after_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "reality-vps-after-test" 2>/dev/null)"
CANDIDATE_AFTER_CAPTURE="$(capture_output_path_from_run "$candidate_after_output")"

RUN_TEST_STATUS="$("$PYTHON_BIN" - "$TEST_RESULT_SNAPSHOT_JSON" <<'PY'
import json
import sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
last_test = snapshot.get("lastTest") or {}
print(str(last_test.get("status") or "missing"))
PY
)"
RUN_TEST_ERROR="$("$PYTHON_BIN" - "$TEST_RESULT_SNAPSHOT_JSON" <<'PY'
import json
import sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
last_test = snapshot.get("lastTest") or {}
print(str(last_test.get("error") or "n/a"))
PY
)"
RUN_TEST_OUTPUT="$("$PYTHON_BIN" - "$TEST_RESULT_SNAPSHOT_JSON" <<'PY'
import json
import sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
last_test = snapshot.get("lastTest") or {}
print(str(last_test.get("output") or "n/a"))
PY
)"

server_run_summary_payload="$(build_server_ss_summary "$SERVER_RUNTEST_SS_LOG" "$SERVER_RUNTEST_SS_SUMMARY")"
SERVER_RUNTEST_CONFIRMATION="$("$PYTHON_BIN" - "$server_run_summary_payload" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("confirmation") or "unknown")
PY
)"
if [[ "$SKIP_SERVER_SS" == "1" ]]; then
  SERVER_RUNTEST_CONFIRMATION="skipped"
  SERVER_RUNTEST_MATCH_COUNT="0"
else
  SERVER_RUNTEST_MATCH_COUNT="$("$PYTHON_BIN" - "$server_run_summary_payload" <<'PY'
import json
import sys
print(str(json.loads(sys.argv[1]).get("matchCount") or 0))
PY
)"
fi

DEVICE_INTERFACE_NAME="$(resolve_device_interface "$CANDIDATE_AFTER_CAPTURE" 2>/dev/null || true)"
if [[ -z "$DEVICE_INTERFACE_NAME" ]]; then
  DEVICE_INTERFACE_NAME="n/a"
fi
if [[ "$DEVICE_INTERFACE_NAME" == "n/a" ]]; then
  printf 'skipped\n' >"$DEVICE_RAW_PROBE_LOG"
else
  if [[ "$SKIP_SERVER_SS" == "1" ]]; then
    printf '# skipped (--skip-server-ss)\n' >"$SERVER_RAWPROBE_SS_LOG"
  else
    start_server_ss_sampler "$SERVER_RAWPROBE_SS_LOG" "$SELECTED_ORIGIN_PORT" "8" "$SERVER_SS_INTERVAL_SECONDS"
  fi
  DEVICE_RAW_PROBE_RESULT="$(run_device_raw_tcp_probe "$DEVICE_RAW_PROBE_LOG")"
  if [[ -n "$LAST_SERVER_SS_PID" ]]; then
    wait "$LAST_SERVER_SS_PID" || true
    LAST_SERVER_SS_PID=""
  fi
fi
if [[ ! -f "$SERVER_RAWPROBE_SS_LOG" ]]; then
  printf '# skipped\n' >"$SERVER_RAWPROBE_SS_LOG"
fi
if [[ "$DEVICE_INTERFACE_NAME" == "n/a" ]]; then
  DEVICE_RAW_PROBE_RESULT="skipped (no underlying cellular interface detected)"
fi

server_raw_summary_payload="$(build_server_ss_summary "$SERVER_RAWPROBE_SS_LOG" "$SERVER_RAWPROBE_SS_SUMMARY")"
SERVER_RAWPROBE_CONFIRMATION="$("$PYTHON_BIN" - "$server_raw_summary_payload" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("confirmation") or "unknown")
PY
)"
if [[ "$SKIP_SERVER_SS" == "1" ]]; then
  SERVER_RAWPROBE_CONFIRMATION="skipped"
  SERVER_RAWPROBE_MATCH_COUNT="0"
else
  SERVER_RAWPROBE_MATCH_COUNT="$("$PYTHON_BIN" - "$server_raw_summary_payload" <<'PY'
import json
import sys
print(str(json.loads(sys.argv[1]).get("matchCount") or 0))
PY
)"
fi

if [[ -n "$CONTROL_CAPTURE" && -n "$CANDIDATE_AFTER_CAPTURE" && -f "$CONTROL_CAPTURE" && -f "$CANDIDATE_AFTER_CAPTURE" ]]; then
  "$COMPARE_SCRIPT" "$CONTROL_CAPTURE" "$CANDIDATE_AFTER_CAPTURE" > "$COMPARE_MD"
  "$REPORT_SCRIPT" "$CONTROL_CAPTURE" "$CANDIDATE_AFTER_CAPTURE" "$REPORT_MD"
fi

if [[ "$RESTORE_STABLE" == "1" ]]; then
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 2
  ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true "$SERVICE_CONTROL_SCRIPT" start-from-json-file "$STABLE_REQUEST_JSON" >/dev/null
  "$SERVICE_CONTROL_SCRIPT" wait-snapshot \
    --family direct-reality \
    --status running \
    --activation active \
    --timeout-seconds "$WAIT_TIMEOUT_SECONDS" \
    --poll-seconds "$WAIT_POLL_SECONDS" > "$RESTORED_STABLE_SNAPSHOT_JSON"
  restore_output="$(ODIN_ONE_ANDROID_DUMP_DIR="$CAPTURE_DIR" "$CAPTURE_SCRIPT" "stable-restored" 2>/dev/null)"
  RESTORE_CAPTURE="$(capture_output_path_from_run "$restore_output")"
  RESTORE_DONE="true"
fi

"$SERVICE_CONTROL_SCRIPT" print-snapshot > "$FINAL_SNAPSHOT_JSON" 2>/dev/null || true

ODIN_ONE_REALITY_VPS_HIT_DEVICE_INTERFACE="$DEVICE_INTERFACE_NAME" \
ODIN_ONE_REALITY_VPS_HIT_DEVICE_RAW_RESULT="$DEVICE_RAW_PROBE_RESULT" \
ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_CONFIRMATION="$SERVER_RUNTEST_CONFIRMATION" \
ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_MATCH_COUNT="$SERVER_RUNTEST_MATCH_COUNT" \
ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_CONFIRMATION="$SERVER_RAWPROBE_CONFIRMATION" \
ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_MATCH_COUNT="$SERVER_RAWPROBE_MATCH_COUNT" \
ODIN_ONE_REALITY_VPS_HIT_ENGINE_READY_DETECTED="$ENGINE_READY_DETECTED" \
ODIN_ONE_REALITY_VPS_HIT_RESTORE_DONE="$RESTORE_DONE" \
"$PYTHON_BIN" - "$SELECTED_JSON" "$TEST_RESULT_SNAPSHOT_JSON" "$POSTTEST_SNAPSHOT_JSON" "$FINAL_SNAPSHOT_JSON" "$RESULTS_JSON" "$SUMMARY_MD" "$COMPARE_MD" "$REPORT_MD" <<'PY'
import json
import os
import sys
from pathlib import Path

selected = json.load(open(sys.argv[1], encoding="utf-8"))
test_snapshot = json.load(open(sys.argv[2], encoding="utf-8"))
post_snapshot = json.load(open(sys.argv[3], encoding="utf-8"))
final_snapshot = json.load(open(sys.argv[4], encoding="utf-8"))
results_path = Path(sys.argv[5])
summary_path = Path(sys.argv[6])
compare_md = sys.argv[7]
report_md = sys.argv[8]

entry = selected.get("entry") or {}
last_test = test_snapshot.get("lastTest") or {}

payload = {
    "kind": "odin-one-android-reality-vps-hit-check-v1",
    "selection": selected,
    "testResultSnapshot": test_snapshot,
    "postTestSnapshot": post_snapshot,
    "finalSnapshot": final_snapshot,
    "deviceInterface": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_DEVICE_INTERFACE", "n/a"),
    "deviceRawProbeResult": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_DEVICE_RAW_RESULT", "n/a"),
    "serverRunTestConfirmation": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_CONFIRMATION", "unknown"),
    "serverRunTestMatchCount": int(os.environ.get("ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_MATCH_COUNT", "0")),
    "serverRawProbeConfirmation": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_CONFIRMATION", "unknown"),
    "serverRawProbeMatchCount": int(os.environ.get("ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_MATCH_COUNT", "0")),
    "engineReadyDetected": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_ENGINE_READY_DETECTED", "false") == "true",
    "restoreDone": os.environ.get("ODIN_ONE_REALITY_VPS_HIT_RESTORE_DONE", "false") == "true",
    "comparePath": compare_md if compare_md else None,
    "reportPath": report_md if report_md else None,
}
results_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Android Reality VPS Hit Check",
    "",
    f"- Dataset: `{selected.get('datasetSource')}`",
    f"- Origin SSH host: `{selected.get('remoteHost') or selected.get('serverHost')}`",
    f"- Selected tag: `{entry.get('tag')}`",
    f"- Selected SNI: `{entry.get('serverName')}`",
    f"- Selected origin port: `{entry.get('port')}`",
    f"- Selected connect host: `{entry.get('connectHost') or selected.get('serverHost') or selected.get('remoteHost')}`",
    f"- Selected connect port: `{entry.get('connectPort') or entry.get('port')}`",
    f"- Selected origin host: `{entry.get('originHost') or selected.get('serverHost') or selected.get('remoteHost')}`",
    f"- Selected origin sample port: `{entry.get('originPort') or entry.get('port')}`",
    f"- Selected transport: `{entry.get('transport')}`",
    f"- Selected source: `{entry.get('source')}`",
    f"- Runtime family: `{post_snapshot.get('runtimeFamily')}`",
    f"- Activation state: `{post_snapshot.get('activationState')}`",
    f"- Runtime status: `{post_snapshot.get('status')}`",
    f"- Engine readiness detected: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_ENGINE_READY_DETECTED', 'false')}`",
    f"- Test status: `{last_test.get('status') or 'missing'}`",
    f"- Test error: `{last_test.get('error') or 'n/a'}`",
    f"- Test output: `{last_test.get('output') or 'n/a'}`",
    f"- Server run-test confirmation: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_CONFIRMATION', 'unknown')}`",
    f"- Server run-test match count: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_SERVER_RUN_MATCH_COUNT', '0')}`",
    f"- Device interface: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_DEVICE_INTERFACE', 'n/a')}`",
    f"- Device raw probe result: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_DEVICE_RAW_RESULT', 'n/a')}`",
    f"- Server raw-probe confirmation: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_CONFIRMATION', 'unknown')}`",
    f"- Server raw-probe match count: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_SERVER_RAW_MATCH_COUNT', '0')}`",
    f"- Restore done: `{os.environ.get('ODIN_ONE_REALITY_VPS_HIT_RESTORE_DONE', 'false')}`",
    "",
    "## Key Files",
    "",
    f"- request: `{Path(sys.argv[6]).parent / 'request.json'}`",
    f"- running snapshot: `{Path(sys.argv[6]).parent / 'running-snapshot.json'}`",
    f"- engine-ready snapshot: `{Path(sys.argv[6]).parent / 'engine-ready-snapshot.json'}`",
    f"- test-result snapshot: `{Path(sys.argv[6]).parent / 'test-result-snapshot.json'}`",
    f"- post-test snapshot: `{Path(sys.argv[6]).parent / 'post-test-snapshot.json'}`",
    f"- final snapshot: `{Path(sys.argv[6]).parent / 'final-snapshot.json'}`",
    f"- captures dir: `{Path(sys.argv[6]).parent / 'captures'}`",
    f"- server run-test ss: `{Path(sys.argv[6]).parent / 'server-run-test-ss.txt'}`",
    f"- server run-test summary: `{Path(sys.argv[6]).parent / 'server-run-test-ss-summary.md'}`",
    f"- server raw-probe ss: `{Path(sys.argv[6]).parent / 'server-raw-probe-ss.txt'}`",
    f"- server raw-probe summary: `{Path(sys.argv[6]).parent / 'server-raw-probe-ss-summary.md'}`",
    f"- device raw probe: `{Path(sys.argv[6]).parent / 'device-raw-probe.txt'}`",
]
if compare_md:
    summary_lines.append(f"- compare: `{compare_md}`")
if report_md:
    summary_lines.append(f"- report: `{report_md}`")
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

if [[ "$RESTORE_STABLE" != "1" ]]; then
  "$SERVICE_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
fi

echo "$OUTPUT_DIR"
