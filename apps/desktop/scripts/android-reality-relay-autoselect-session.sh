#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
ZSH_BIN="/bin/zsh"
SED_BIN="/usr/bin/sed"

AUTOSELECT_SCRIPT="${SCRIPT_DIR}/reality-whitelist-relay-autoselect.sh"
HIT_CHECK_SCRIPT="${SCRIPT_DIR}/android-reality-vps-hit-check.sh"

QR_IMAGE=""
SUBSCRIPTION_URL=""
SUBSCRIPTION_FILE=""
SOURCE_LABEL=""
OUTPUT_DIR=""
HISTORY_FILE=""
ENGINE="sing-box"
DECODE_LIMIT="0"
SMOKE_LIMIT="8"
TOP_COUNT="3"
MAX_PER_SNI="2"
MIN_PASS_COUNT="2"
RUSSIAN_LATENCY_THRESHOLD_MS="300"
LATENCY_TIMEOUT_MS="1200"
RESET_HISTORY="0"
ALLOW_WITHOUT_OWNER_PASS="0"
typeset -a PROBE_SPECS=()
typeset -a TEST_URLS=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-relay-autoselect-session.sh [options]

Inputs:
  --qr-image <path>          QR image pointing to a subscription URL or one vless:// URI.
  --subscription-url <url>   Remote text subscription with VLESS URIs.
  --subscription-file <path> Local text subscription with VLESS URIs.
  --source-label <label>     Optional operator label for output metadata.

Selection:
  --history-file <path>      Rolling selector history file.
  --decode-limit <count>     Limit how many URIs to decode. Default: 0 (all)
  --smoke-limit <count>      Max preselected candidates before early-stop. Default: 8
  --top-count <count>        How many best entries to export. Default: 3
  --max-per-sni <count>      Max preselected candidates per SNI. Default: 2
  --min-pass-count <count>   Candidate is good when owner probe plus at least this
                             many probes pass in total. Default: 2
  --russian-latency-threshold-ms <n>
                             Prefer Russian-labelled entries under this TCP latency. Default: 300
  --latency-timeout-ms <n>   TCP latency measurement timeout. Default: 1200
  --engine <name>            Local smoke engine: auto, xray, sing-box. Default: sing-box
  --probe <label>|<url>|<code>|<weight>
                             Override/add selector probes. May be repeated.
  --allow-without-owner-pass Allow selector fallback when owner probe never passes.
  --reset-history            Reset selector history for this run.

Android tests:
  --test-url <url>           Android hit-check URL. May be repeated.
                             Default:
                               https://95-81-120-226.sslip.io/_odin_probe_204
                               https://redirector.googlevideo.com/generate_204
                               https://www.youtube.com/

State:
  --output-dir <dir>         Output directory. Default:
                             /tmp/odin-one-android-reality-relay-autoselect-session/<stamp>
  -h, --help                 Show this help.

Behavior:
  1. Runs reality-whitelist-relay-autoselect.sh on the QR/subscription.
  2. Uses the resulting best Android dataset entry.
  3. Runs android-reality-vps-hit-check.sh against each requested Android test URL.
  4. Writes one session-summary.md tying selection and handset results together.

This helper is owner-only and additive. It does not change stable defaults or
deploy anything server-side by itself.
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

slugify_value() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | "$SED_BIN" 's#https\{0,1\}://##g; s#[^a-z0-9._/-]#-#g; s#/#-#g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qr-image)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      QR_IMAGE="$2"
      shift 2
      ;;
    --subscription-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SUBSCRIPTION_URL="$2"
      shift 2
      ;;
    --subscription-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SUBSCRIPTION_FILE="$2"
      shift 2
      ;;
    --source-label)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_LABEL="$2"
      shift 2
      ;;
    --history-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HISTORY_FILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE="$2"
      shift 2
      ;;
    --decode-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DECODE_LIMIT="$2"
      shift 2
      ;;
    --smoke-limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SMOKE_LIMIT="$2"
      shift 2
      ;;
    --top-count)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TOP_COUNT="$2"
      shift 2
      ;;
    --max-per-sni)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_PER_SNI="$2"
      shift 2
      ;;
    --min-pass-count)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MIN_PASS_COUNT="$2"
      shift 2
      ;;
    --russian-latency-threshold-ms)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RUSSIAN_LATENCY_THRESHOLD_MS="$2"
      shift 2
      ;;
    --latency-timeout-ms)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LATENCY_TIMEOUT_MS="$2"
      shift 2
      ;;
    --probe)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PROBE_SPECS+=("$2")
      shift 2
      ;;
    --allow-without-owner-pass)
      ALLOW_WITHOUT_OWNER_PASS="1"
      shift
      ;;
    --reset-history)
      RESET_HISTORY="1"
      shift
      ;;
    --test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_URLS+=("$2")
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

require_bin "$PYTHON_BIN" "python3"
require_bin "$ZSH_BIN" "zsh"
require_script "$AUTOSELECT_SCRIPT"
require_script "$HIT_CHECK_SCRIPT"

input_count=0
[[ -n "$QR_IMAGE" ]] && input_count=$((input_count + 1))
[[ -n "$SUBSCRIPTION_URL" ]] && input_count=$((input_count + 1))
[[ -n "$SUBSCRIPTION_FILE" ]] && input_count=$((input_count + 1))
if [[ "$input_count" -ne 1 ]]; then
  echo "Provide exactly one of --qr-image, --subscription-url, or --subscription-file." >&2
  exit 1
fi

for value in "$DECODE_LIMIT" "$SMOKE_LIMIT" "$TOP_COUNT" "$MAX_PER_SNI" "$MIN_PASS_COUNT" "$RUSSIAN_LATENCY_THRESHOLD_MS" "$LATENCY_TIMEOUT_MS"; do
  if [[ ! "$value" =~ '^[0-9]+$' ]]; then
    echo "Numeric options must be integers." >&2
    exit 1
  fi
done

if [[ ${#TEST_URLS[@]} -eq 0 ]]; then
  TEST_URLS+=("https://95-81-120-226.sslip.io/_odin_probe_204")
  TEST_URLS+=("https://redirector.googlevideo.com/generate_204")
  TEST_URLS+=("https://www.youtube.com/")
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-reality-relay-autoselect-session/$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

SELECTOR_DIR="${OUTPUT_DIR}/selection"
TESTS_ROOT="${OUTPUT_DIR}/tests"
SUMMARY_MD="${OUTPUT_DIR}/session-summary.md"
RESULTS_JSON="${OUTPUT_DIR}/session-results.json"
"$MKDIR_BIN" -p "$TESTS_ROOT"

selector_cmd=(
  "$ZSH_BIN" "$AUTOSELECT_SCRIPT"
  --output-dir "$SELECTOR_DIR"
  --engine "$ENGINE"
  --decode-limit "$DECODE_LIMIT"
  --smoke-limit "$SMOKE_LIMIT"
  --top-count "$TOP_COUNT"
  --max-per-sni "$MAX_PER_SNI"
  --min-pass-count "$MIN_PASS_COUNT"
  --russian-latency-threshold-ms "$RUSSIAN_LATENCY_THRESHOLD_MS"
  --latency-timeout-ms "$LATENCY_TIMEOUT_MS"
)
[[ -n "$SOURCE_LABEL" ]] && selector_cmd+=(--source-label "$SOURCE_LABEL")
[[ -n "$HISTORY_FILE" ]] && selector_cmd+=(--history-file "$HISTORY_FILE")
[[ "$ALLOW_WITHOUT_OWNER_PASS" == "1" ]] && selector_cmd+=(--allow-without-owner-pass)
[[ "$RESET_HISTORY" == "1" ]] && selector_cmd+=(--reset-history)
if [[ -n "$QR_IMAGE" ]]; then
  selector_cmd+=(--qr-image "$QR_IMAGE")
elif [[ -n "$SUBSCRIPTION_URL" ]]; then
  selector_cmd+=(--subscription-url "$SUBSCRIPTION_URL")
else
  selector_cmd+=(--subscription-file "$SUBSCRIPTION_FILE")
fi
for spec in "${PROBE_SPECS[@]}"; do
  selector_cmd+=(--probe "$spec")
done

"${selector_cmd[@]}" >/dev/null

ANDROID_DATASET="${SELECTOR_DIR}/android-dataset.json"
BEST_CANDIDATE_JSON="${SELECTOR_DIR}/best-candidate.json"
if [[ ! -f "$ANDROID_DATASET" ]]; then
  echo "Selector did not produce android-dataset.json: $ANDROID_DATASET" >&2
  exit 1
fi

entry_count="$("$PYTHON_BIN" - "$ANDROID_DATASET" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(int(payload.get("count") or 0))
PY
)"
if [[ "$entry_count" -le 0 ]]; then
  echo "Selector did not produce any Android candidate entries." >&2
  exit 1
fi

typeset -a TEST_OUTPUT_DIRS=()
typeset -a TEST_EXIT_CODES=()
for test_url in "${TEST_URLS[@]}"; do
  slug="$(slugify_value "$test_url")"
  [[ -n "$slug" ]] || slug="test"
  test_dir="${TESTS_ROOT}/${slug}"
  set +e
  "$ZSH_BIN" "$HIT_CHECK_SCRIPT" \
    --dataset "$ANDROID_DATASET" \
    --index 1 \
    --skip-server-ss \
    --test-url "$test_url" \
    --output-dir "$test_dir" >/dev/null
  exit_code="$?"
  set -e
  printf '%s\n' "$exit_code" > "${test_dir}/hit-check-exit-code.txt"
  TEST_OUTPUT_DIRS+=("$test_dir")
  TEST_EXIT_CODES+=("$exit_code")
done

TEST_URLS_JOINED="$(printf '%s\n' "${TEST_URLS[@]}")"
TEST_OUTPUT_DIRS_JOINED="$(printf '%s\n' "${TEST_OUTPUT_DIRS[@]}")"
TEST_EXIT_CODES_JOINED="$(printf '%s\n' "${TEST_EXIT_CODES[@]}")"
TEST_URLS_JOINED="$TEST_URLS_JOINED" \
TEST_OUTPUT_DIRS_JOINED="$TEST_OUTPUT_DIRS_JOINED" \
TEST_EXIT_CODES_JOINED="$TEST_EXIT_CODES_JOINED" \
"$PYTHON_BIN" - "$BEST_CANDIDATE_JSON" "$ANDROID_DATASET" "$SELECTOR_DIR/summary.md" "$SUMMARY_MD" "$RESULTS_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

best_candidate_path = Path(sys.argv[1]).expanduser()
dataset_path = Path(sys.argv[2]).expanduser()
selector_summary_path = Path(sys.argv[3]).expanduser()
summary_path = Path(sys.argv[4]).expanduser()
results_path = Path(sys.argv[5]).expanduser()

test_urls = [line.strip() for line in os.environ.get("TEST_URLS_JOINED", "").splitlines() if line.strip()]
test_output_dirs = [Path(line.strip()).expanduser() for line in os.environ.get("TEST_OUTPUT_DIRS_JOINED", "").splitlines() if line.strip()]
test_exit_codes = [line.strip() for line in os.environ.get("TEST_EXIT_CODES_JOINED", "").splitlines()]

best = json.loads(best_candidate_path.read_text(encoding="utf-8")) if best_candidate_path.exists() else {}
dataset = json.loads(dataset_path.read_text(encoding="utf-8"))

tests = []
for url, test_dir, exit_code in zip(test_urls, test_output_dirs, test_exit_codes):
    summary_file = test_dir / "summary.md"
    result_file = test_dir / "results.json"
    snapshot_file = test_dir / "test-result-snapshot.json"
    result_payload = {}
    last_test = {}
    if result_file.exists():
        try:
            result_payload = json.loads(result_file.read_text(encoding="utf-8"))
            last_test = ((result_payload.get("testResultSnapshot") or {}).get("lastTest") or {})
        except Exception:
            result_payload = {}
    if not last_test and snapshot_file.exists():
        try:
            snapshot_payload = json.loads(snapshot_file.read_text(encoding="utf-8"))
            result_payload.setdefault("testResultSnapshot", snapshot_payload)
            last_test = (snapshot_payload.get("lastTest") or {})
        except Exception:
            pass
    tests.append(
        {
            "url": url,
            "outputDir": str(test_dir),
            "summaryPath": str(summary_file),
            "resultsPath": str(result_file) if result_file.exists() else None,
            "snapshotPath": str(snapshot_file) if snapshot_file.exists() else None,
            "exitCode": int(exit_code) if str(exit_code).strip() else None,
            "status": (last_test.get("status") or "unknown"),
            "result": result_payload,
        }
    )

payload = {
    "kind": "odin-one-android-reality-relay-autoselect-session-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "selectorSummary": str(selector_summary_path),
    "dataset": str(dataset_path),
    "bestCandidate": best,
    "tests": tests,
}
results_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

lines = [
    "# Android Reality Relay Autoselect Session",
    "",
    f"- Generated at: `{payload['generatedAt']}`",
    f"- Selector summary: `{selector_summary_path}`",
    f"- Dataset: `{dataset_path}`",
    f"- Candidate count: `{dataset.get('count')}`",
    "",
    "## Best Relay",
    "",
]
if best:
    lines.extend(
        [
            f"- `serverName`: `{best.get('normalizedSni') or best.get('sni') or best.get('serverName')}`",
            f"- `host:port`: `{best.get('host')}:{best.get('port')}`",
            f"- `tcpLatencyMs`: `{best.get('tcpLatencyMs') if best.get('tcpLatencyMs') is not None else 'n/a'}`",
            f"- `selectionScore`: `{best.get('selectionScore')}`",
            f"- `ownerProbePassed`: `{str(bool(best.get('ownerProbePassed'))).lower()}`",
            f"- `currentPassCount`: `{best.get('currentPassCount')}`",
            f"- `uri`: `{best.get('uri')}`",
        ]
    )
else:
    lines.append("- No best candidate selected.")

lines.extend(["", "## Android Tests", ""])
for item in tests:
    result = item["result"]
    last_test = ((result.get("testResultSnapshot") or {}).get("lastTest") or {})
    run_status = last_test.get("status") or "unknown"
    run_output = last_test.get("output") or "n/a"
    run_error = "n/a" if last_test.get("ok") else (last_test.get("output") or "n/a")
    lines.append(
        f"- `{item['url']}` -> status=`{run_status}` | output=`{run_output}` | error=`{run_error}` | exit=`{item.get('exitCode')}` | dir=`{item['outputDir']}`"
    )

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
