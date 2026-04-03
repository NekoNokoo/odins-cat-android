#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h:h}"

DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
ZSH_BIN="/bin/zsh"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"

DECODE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-decode-vless.sh"
LOCAL_SMOKE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-local-smoke.sh"

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

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-relay-autoselect.sh [options]

Inputs:
  --qr-image <path>          QR image pointing to a remote subscription URL or one vless:// URI.
  --subscription-url <url>   Remote text subscription with VLESS URIs.
  --subscription-file <path> Local text subscription with VLESS URIs.
  --source-label <label>     Optional operator label for summary/output metadata.

Selection:
  --decode-limit <count>     Limit how many URIs to decode. Default: 0 (all)
  --smoke-limit <count>      Max candidates to smoke in this wave. Default: 8
  --top-count <count>        How many best entries to export. Default: 3
  --max-per-sni <count>      Max preselected candidates per SNI. Default: 2
  --min-pass-count <count>   Stop early once owner probe passes and at least this
                             many probes pass in total. Default: 2
  --russian-latency-threshold-ms <n>
                             Prefer Russian-labelled entries at or below this
                             TCP latency before falling back globally. Default: 300
  --latency-timeout-ms <n>   TCP latency measurement timeout. Default: 1200
  --engine <name>            Smoke engine: auto, xray, sing-box. Default: sing-box
  --allow-without-owner-pass Allow fallback selection when no candidate passes the owner probe.
  --probe <label>|<url>|<code>|<weight>
                             Add one smoke target. May be repeated.
                             Default targets:
                               owner|https://95-81-120-226.sslip.io/_odin_probe_204|204|100
                               googlevideo|https://redirector.googlevideo.com/generate_204|204|60
                               gstatic|https://www.gstatic.com/generate_204|204|30

State:
  --history-file <path>      Persistent rolling history JSON.
                             Default: <repo>/tmp/reality-whitelist-relay-autoselect-history.json
  --reset-history            Ignore and overwrite the previous history file for this run.
  --output-dir <dir>         Output directory. Default: /tmp/odin-one-reality-whitelist-relay-autoselect/<stamp>
  -h, --help                 Show this help.

Behavior:
  - decodes the QR or subscription into structured `vless://` records
  - pre-ranks candidates with a churn-aware score
  - prefers Russian-labelled entries first and sorts them by TCP latency
  - if every Russian-labelled candidate is slower than 300 ms, falls back to the
    lowest-latency candidate across the full shortlist
  - reruns local isolated smoke candidate-by-candidate
  - stops as soon as one candidate becomes "good enough"
  - updates a rolling history so dead/flaky entries lose priority over time
  - exports the best candidate plus alternates as:
      - best-candidate.json
      - best-subscription.txt
      - alternates-subscription.txt
      - android-dataset.json
      - ranking.json
      - summary.md

This helper is owner-only and additive. It does not touch Android runtime state,
stable `direct-reality`, or remote services by itself.
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

decode_qr_message() {
  local image_path="$1"
  "$SWIFT_BIN" - "$image_path" <<'SWIFT'
import Foundation
import CoreImage

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
guard let image = CIImage(contentsOf: url) else {
    fputs("Failed to open image: \(path)\n", stderr)
    exit(1)
}
guard let detector = CIDetector(
    ofType: CIDetectorTypeQRCode,
    context: nil,
    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
) else {
    fputs("Failed to initialize QR detector\n", stderr)
    exit(1)
}

let messages = detector.features(in: image).compactMap { feature -> String? in
    (feature as? CIQRCodeFeature)?.messageString?.trimmingCharacters(in: .whitespacesAndNewlines)
}.filter { !$0.isEmpty }

guard let first = messages.first else {
    fputs("No QR payload found in image: \(path)\n", stderr)
    exit(1)
}
print(first)
SWIFT
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
require_script "$DECODE_SCRIPT"
require_script "$LOCAL_SMOKE_SCRIPT"

if [[ -n "$QR_IMAGE" ]]; then
  require_bin "$SWIFT_BIN" "swift"
fi

input_count=0
[[ -n "$QR_IMAGE" ]] && input_count=$((input_count + 1))
[[ -n "$SUBSCRIPTION_URL" ]] && input_count=$((input_count + 1))
[[ -n "$SUBSCRIPTION_FILE" ]] && input_count=$((input_count + 1))
if [[ "$input_count" -ne 1 ]]; then
  echo "Provide exactly one of --qr-image, --subscription-url, or --subscription-file." >&2
  exit 1
fi

if [[ -n "$QR_IMAGE" && ! -f "$QR_IMAGE" ]]; then
  echo "QR image not found: $QR_IMAGE" >&2
  exit 1
fi
if [[ -n "$SUBSCRIPTION_FILE" && ! -f "$SUBSCRIPTION_FILE" ]]; then
  echo "Subscription file not found: $SUBSCRIPTION_FILE" >&2
  exit 1
fi

for value in "$DECODE_LIMIT" "$SMOKE_LIMIT" "$TOP_COUNT" "$MAX_PER_SNI" "$MIN_PASS_COUNT"; do
  if [[ ! "$value" =~ '^[0-9]+$' ]]; then
    echo "Numeric options must be integers." >&2
    exit 1
  fi
done

case "$ENGINE" in
  auto|xray|sing-box)
    ;;
  *)
    echo "--engine must be one of: auto, xray, sing-box" >&2
    exit 1
    ;;
esac

if [[ ${#PROBE_SPECS[@]} -eq 0 ]]; then
  PROBE_SPECS+=("owner|https://95-81-120-226.sslip.io/_odin_probe_204|204|100")
  PROBE_SPECS+=("googlevideo|https://redirector.googlevideo.com/generate_204|204|60")
  PROBE_SPECS+=("gstatic|https://www.gstatic.com/generate_204|204|30")
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-reality-whitelist-relay-autoselect/$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

if [[ -z "$HISTORY_FILE" ]]; then
  HISTORY_FILE="${REPO_ROOT}/tmp/reality-whitelist-relay-autoselect-history.json"
fi
"$MKDIR_BIN" -p "${HISTORY_FILE:h}"

DECODED_QR_PATH="${OUTPUT_DIR}/qr-decoded.txt"
SOURCE_KIND=""
SOURCE_VALUE=""
if [[ -n "$QR_IMAGE" ]]; then
  qr_message="$(decode_qr_message "$QR_IMAGE")"
  printf '%s\n' "$qr_message" > "$DECODED_QR_PATH"
  if [[ "$qr_message" == vless://* ]]; then
    SOURCE_KIND="qr-uri"
    SOURCE_VALUE="$qr_message"
    SUBSCRIPTION_FILE="${OUTPUT_DIR}/qr-subscription.txt"
    printf '%s\n' "$qr_message" > "$SUBSCRIPTION_FILE"
  elif [[ "$qr_message" == http://* || "$qr_message" == https://* ]]; then
    SOURCE_KIND="qr-url"
    SOURCE_VALUE="$qr_message"
    SUBSCRIPTION_URL="$qr_message"
  else
    echo "Unsupported QR payload: $qr_message" >&2
    exit 1
  fi
elif [[ -n "$SUBSCRIPTION_URL" ]]; then
  SOURCE_KIND="subscription-url"
  SOURCE_VALUE="$SUBSCRIPTION_URL"
else
  SOURCE_KIND="subscription-file"
  SOURCE_VALUE="$SUBSCRIPTION_FILE"
fi

if [[ -z "$SOURCE_LABEL" ]]; then
  SOURCE_LABEL="$SOURCE_KIND"
fi

DECODE_DIR="${OUTPUT_DIR}/decoded"
PRESELECT_JSON="${OUTPUT_DIR}/preselected.json"
PRESELECT_SUBSCRIPTION="${OUTPUT_DIR}/preselected-subscription.txt"
CANDIDATE_ROOT_DIR="${OUTPUT_DIR}/candidates"
CANDIDATE_MANIFEST_JSON="${OUTPUT_DIR}/candidate-manifest.json"
CANDIDATE_MANIFEST_TSV="${OUTPUT_DIR}/candidate-manifest.tsv"
RANKING_JSON="${OUTPUT_DIR}/ranking.json"
BEST_CANDIDATE_JSON="${OUTPUT_DIR}/best-candidate.json"
BEST_SUBSCRIPTION_TXT="${OUTPUT_DIR}/best-subscription.txt"
ALTERNATES_SUBSCRIPTION_TXT="${OUTPUT_DIR}/alternates-subscription.txt"
ANDROID_DATASET_JSON="${OUTPUT_DIR}/android-dataset.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"
SMOKE_MANIFEST_JSON="${OUTPUT_DIR}/smoke-manifest.json"
"$MKDIR_BIN" -p "$CANDIDATE_ROOT_DIR"

decode_cmd=(
  "$ZSH_BIN" "$DECODE_SCRIPT"
  --output-dir "$DECODE_DIR"
  --mode summary
)
if [[ "$DECODE_LIMIT" != "0" ]]; then
  decode_cmd+=(--limit "$DECODE_LIMIT")
fi
if [[ -n "$SUBSCRIPTION_URL" ]]; then
  decode_cmd+=(--subscription-url "$SUBSCRIPTION_URL")
else
  decode_cmd+=(--subscription-file "$SUBSCRIPTION_FILE")
fi
"${decode_cmd[@]}" >/dev/null

PROBE_SPECS_JOINED="$(printf '%s\n' "${PROBE_SPECS[@]}")"
PROBE_SPECS_JOINED="$PROBE_SPECS_JOINED" \
"$PYTHON_BIN" - "$DECODE_DIR/decoded.json" "$PRESELECT_JSON" "$PRESELECT_SUBSCRIPTION" "$CANDIDATE_MANIFEST_JSON" "$CANDIDATE_MANIFEST_TSV" "$CANDIDATE_ROOT_DIR" "$HISTORY_FILE" "$RESET_HISTORY" "$SMOKE_LIMIT" "$MAX_PER_SNI" "$SOURCE_LABEL" "$SOURCE_KIND" "$SOURCE_VALUE" <<'PY'
import json
import os
import re
import sys
import urllib.parse
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

decoded_path = Path(sys.argv[1]).expanduser()
preselected_json_path = Path(sys.argv[2]).expanduser()
preselected_subscription_path = Path(sys.argv[3]).expanduser()
candidate_manifest_json_path = Path(sys.argv[4]).expanduser()
candidate_manifest_tsv_path = Path(sys.argv[5]).expanduser()
candidate_root_dir = Path(sys.argv[6]).expanduser()
history_path = Path(sys.argv[7]).expanduser()
reset_history = sys.argv[8].strip() == "1"
smoke_limit = int(sys.argv[9])
max_per_sni = int(sys.argv[10])
source_label = sys.argv[11].strip()
source_kind = sys.argv[12].strip()
source_value = sys.argv[13].strip()

probe_specs = [line.strip() for line in os.environ.get("PROBE_SPECS_JOINED", "").splitlines() if line.strip()]


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value or "").lower()).strip("-")[:80] or "candidate"


def is_russian_candidate(entry: dict) -> bool:
    text = " ".join(
        [
            str(entry.get("tag") or ""),
            str(entry.get("label") or ""),
            str(entry.get("uri") or ""),
        ]
    ).lower()
    return any(token in text for token in ("russia", "рос", "🇷🇺"))


def exact_key(entry: dict) -> str:
    parts = [
        normalize_hostname(entry.get("host")),
        str(entry.get("port") or ""),
        normalize_hostname(entry.get("sni") or entry.get("serverName") or ""),
        str(entry.get("transport") or ""),
        str(entry.get("security") or ""),
        str(entry.get("flow") or ""),
        str(entry.get("publicKey") or ""),
        str(entry.get("shortId") or ""),
    ]
    return "|".join(parts)


def family_key(entry: dict) -> str:
    return normalize_hostname(entry.get("sni") or entry.get("serverName") or "")


history = {
    "kind": "odin-one-reality-relay-autoselect-history-v1",
    "generatedAt": None,
    "entries": {},
    "families": {},
    "runs": [],
}
if history_path.exists() and not reset_history:
    try:
        loaded = json.loads(history_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            history.update(loaded)
            history["entries"] = loaded.get("entries") or {}
            history["families"] = loaded.get("families") or {}
            history["runs"] = loaded.get("runs") or []
    except Exception:
        pass

decoded_payload = json.loads(decoded_path.read_text(encoding="utf-8"))
entries = decoded_payload.get("entries") or []
available_per_sni = Counter(normalize_hostname(item.get("sni")) for item in entries if normalize_hostname(item.get("sni")))

ranked = []
for item in entries:
    transport = str(item.get("transport") or "").lower()
    security = str(item.get("security") or "").lower()
    sni = normalize_hostname(item.get("sni"))
    host = normalize_hostname(item.get("host"))
    if not host or not sni:
        continue
    if transport not in {"tcp", "grpc", "ws"}:
        continue
    if security not in {"reality", "tls"}:
        continue
    if security == "reality" and (not str(item.get("publicKey") or "").strip() or not str(item.get("shortId") or "").strip()):
        continue

    score = 0
    if security == "reality":
        score += 50
    else:
        score += 15
    if transport == "tcp":
        score += 25
    elif transport == "grpc":
        score += 16
    else:
        score += 10

    port = int(item.get("port") or 0)
    if port == 443:
        score += 12
    elif port in {8443, 7443}:
        score += 8

    if str(item.get("flow") or "") == "xtls-rprx-vision":
        score += 8
    if item.get("publicKey") and item.get("shortId"):
        score += 8

    score += min(available_per_sni[sni], 8)
    if is_russian_candidate(item):
        score += 60

    ex_hist = history["entries"].get(exact_key(item)) or {}
    fam_hist = history["families"].get(family_key(item)) or {}

    ex_pass = int(ex_hist.get("passCount") or 0)
    ex_fail = int(ex_hist.get("failCount") or 0)
    fam_pass = int(fam_hist.get("passCount") or 0)
    fam_fail = int(fam_hist.get("failCount") or 0)

    score += min(ex_pass * 4, 20)
    score -= min(ex_fail * 2, 12)
    score += min(fam_pass * 2, 12)
    score -= min(fam_fail, 8)

    normalized = dict(item)
    normalized["normalizedSni"] = sni
    normalized["regionBucket"] = "russia" if is_russian_candidate(item) else "other"
    normalized["history"] = {
        "exact": ex_hist,
        "family": fam_hist,
    }
    normalized["preScore"] = score
    ranked.append(normalized)

ranked.sort(
    key=lambda item: (
        -int(item.get("preScore") or 0),
        str(item.get("normalizedSni") or ""),
        int(item.get("port") or 0),
        str(item.get("host") or ""),
        int(item.get("index") or 0),
    )
)

selected = []
per_sni = Counter()
seen_keys = set()
for item in ranked:
    key = exact_key(item)
    sni = item.get("normalizedSni") or ""
    if key in seen_keys:
        continue
    if max_per_sni and per_sni[sni] >= max_per_sni:
        continue
    selected.append(item)
    seen_keys.add(key)
    per_sni[sni] += 1
    if smoke_limit and len(selected) >= smoke_limit:
        break

payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "sourceLabel": source_label,
    "sourceKind": source_kind,
    "sourceValue": source_value,
    "decodedJson": str(decoded_path),
    "historyFile": str(history_path),
    "probeSpecs": probe_specs,
    "selectedCount": len(selected),
    "entries": selected,
}

preselected_json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
preselected_subscription_path.write_text(
    "".join(str(item.get("uri") or "").strip() + "\n" for item in selected if str(item.get("uri") or "").strip()),
    encoding="utf-8",
)

candidate_root_dir.mkdir(parents=True, exist_ok=True)
manifest = []
tsv_lines = []
for index, item in enumerate(selected, start=1):
    slug = slugify(f"{item.get('normalizedSni')}-{item.get('host')}-{item.get('port')}")
    run_dir = candidate_root_dir / f"{index:02d}-{slug}"
    run_dir.mkdir(parents=True, exist_ok=True)
    subscription_path = run_dir / "subscription.txt"
    meta_path = run_dir / "candidate.json"
    uri = str(item.get("uri") or "").strip()
    subscription_path.write_text((uri + "\n") if uri else "", encoding="utf-8")
    meta_path.write_text(json.dumps(item, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest.append(
        {
            "index": index,
            "tag": item.get("tag"),
            "serverName": item.get("normalizedSni"),
            "host": item.get("host"),
            "port": item.get("port"),
            "regionBucket": item.get("regionBucket"),
            "runDir": str(run_dir),
            "subscriptionPath": str(subscription_path),
            "metaPath": str(meta_path),
        }
    )
    tsv_lines.append(
        "\t".join(
            [
                str(index),
                str(item.get("tag") or ""),
                str(run_dir),
                str(subscription_path),
            ]
        )
    )

candidate_manifest_json_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
candidate_manifest_tsv_path.write_text("\n".join(tsv_lines) + ("\n" if tsv_lines else ""), encoding="utf-8")
PY

"$PYTHON_BIN" - "$CANDIDATE_MANIFEST_JSON" "$CANDIDATE_MANIFEST_TSV" "$RUSSIAN_LATENCY_THRESHOLD_MS" "$LATENCY_TIMEOUT_MS" <<'PY'
import json
import socket
import sys
import time
from pathlib import Path

manifest_path = Path(sys.argv[1]).expanduser()
tsv_path = Path(sys.argv[2]).expanduser()
threshold_ms = int(sys.argv[3])
timeout_ms = int(sys.argv[4])

items = json.loads(manifest_path.read_text(encoding="utf-8"))


def tcp_latency_ms(host: str, port: int, timeout_ms: int):
    best = None
    timeout = max(timeout_ms / 1000.0, 0.2)
    for _ in range(2):
        started = time.perf_counter()
        try:
            with socket.create_connection((host, port), timeout=timeout):
                elapsed = int((time.perf_counter() - started) * 1000)
                best = elapsed if best is None else min(best, elapsed)
        except OSError:
            continue
    return best


for item in items:
    host = str(item.get("host") or "").strip()
    port = int(item.get("port") or 443)
    latency = tcp_latency_ms(host, port, timeout_ms) if host else None
    item["tcpLatencyMs"] = latency
    item["latencyReachable"] = latency is not None

russian_reachable = [
    item for item in items
    if item.get("regionBucket") == "russia" and isinstance(item.get("tcpLatencyMs"), int)
]
has_fast_russian = any(int(item["tcpLatencyMs"]) <= threshold_ms for item in russian_reachable)


def sort_key(item: dict):
    latency = item.get("tcpLatencyMs")
    latency_rank = latency if isinstance(latency, int) else 10**9
    if has_fast_russian:
        bucket = 0 if item.get("regionBucket") == "russia" and isinstance(latency, int) and latency <= threshold_ms else 1
    else:
        bucket = 0
    return (
        bucket,
        latency_rank,
        str(item.get("serverName") or ""),
        str(item.get("host") or ""),
        int(item.get("port") or 0),
    )


items.sort(key=sort_key)
for order, item in enumerate(items, start=1):
    item["smokeOrder"] = order
    item["preferredLatencyPhase"] = "russia-under-threshold" if has_fast_russian else "global-lowest-latency"

manifest_path.write_text(json.dumps(items, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tsv_path.write_text(
    "\n".join(
        "\t".join(
            [
                str(item.get("index") or ""),
                str(item.get("tag") or ""),
                str(item.get("runDir") or ""),
                str(item.get("subscriptionPath") or ""),
            ]
        )
        for item in items
    ) + ("\n" if items else ""),
    encoding="utf-8",
)
PY

STOPPED_AT_INDEX="0"
EARLY_STOP_REASON="exhausted-preselection"

while IFS=$'\t' read -r candidate_index candidate_tag candidate_dir candidate_subscription; do
  [[ -n "$candidate_index" ]] || continue

  candidate_owner_pass="0"
  candidate_pass_count="0"
  candidate_good="0"

  for spec in "${PROBE_SPECS[@]}"; do
    IFS='|' read -r probe_label probe_url probe_code probe_weight <<<"$spec"
    if [[ -z "$probe_label" || -z "$probe_url" || -z "$probe_code" || -z "$probe_weight" ]]; then
      echo "Invalid --probe value: $spec" >&2
      exit 1
    fi

    run_dir="${candidate_dir}/smoke-${probe_label}"
    if ! "$ZSH_BIN" "$LOCAL_SMOKE_SCRIPT" \
      --subscription "$candidate_subscription" \
      --engine "$ENGINE" \
      --test-url "$probe_url" \
      --expect-code "$probe_code" \
      --output-dir "$run_dir" >/dev/null 2>&1; then
      "$PYTHON_BIN" - "$run_dir" "$candidate_subscription" "$probe_label" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

run_dir = Path(sys.argv[1]).expanduser()
subscription_path = Path(sys.argv[2]).expanduser()
probe_label = sys.argv[3]

run_dir.mkdir(parents=True, exist_ok=True)
summary_path = run_dir / "summary.md"
results_path = run_dir / "results.json"

payload = {
    "kind": "odin-one-reality-whitelist-local-smoke-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "subscriptionPath": str(subscription_path),
    "results": [
        {
            "label": probe_label,
            "passed": False,
            "httpCode": None,
            "curlExit": None,
            "error": "local_smoke_failed",
            "runDir": str(run_dir),
        }
    ],
}

results_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
summary_path.write_text(
    "\n".join(
        [
            "# Relay Candidate Smoke Failure",
            "",
            f"- Probe: `{probe_label}`",
            f"- Subscription: `{subscription_path}`",
            "- Outcome: `local_smoke_failed`",
            "",
            "The candidate was skipped for selection after the local smoke helper exited non-zero.",
            "",
        ]
    ),
    encoding="utf-8",
)
PY
    fi

    probe_passed="$("$PYTHON_BIN" - "$run_dir/results.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
results = payload.get("results") or []
print("1" if results and results[0].get("passed") else "0")
PY
)"

    if [[ "$probe_passed" == "1" ]]; then
      candidate_pass_count=$((candidate_pass_count + 1))
      if [[ "$probe_label" == "owner" ]]; then
        candidate_owner_pass="1"
      fi
      if [[ "$candidate_owner_pass" == "1" && "$candidate_pass_count" -ge "$MIN_PASS_COUNT" ]]; then
        candidate_good="1"
        EARLY_STOP_REASON="found-good-candidate"
        break
      fi
    elif [[ "$probe_label" == "owner" && "$ALLOW_WITHOUT_OWNER_PASS" != "1" ]]; then
      EARLY_STOP_REASON="owner-probe-failed"
      break
    fi
  done

  if [[ "$candidate_good" == "1" ]]; then
    STOPPED_AT_INDEX="$candidate_index"
    break
  fi
done < "$CANDIDATE_MANIFEST_TSV"

PROBE_SPECS_JOINED="$(printf '%s\n' "${PROBE_SPECS[@]}")"
PROBE_SPECS_JOINED="$PROBE_SPECS_JOINED" \
"$PYTHON_BIN" - "$PRESELECT_JSON" "$CANDIDATE_MANIFEST_JSON" "$HISTORY_FILE" "$RESET_HISTORY" "$TOP_COUNT" "$ALLOW_WITHOUT_OWNER_PASS" "$MIN_PASS_COUNT" "$RUSSIAN_LATENCY_THRESHOLD_MS" "$STOPPED_AT_INDEX" "$EARLY_STOP_REASON" "$RANKING_JSON" "$BEST_CANDIDATE_JSON" "$BEST_SUBSCRIPTION_TXT" "$ALTERNATES_SUBSCRIPTION_TXT" "$ANDROID_DATASET_JSON" "$SUMMARY_MD" "$SMOKE_MANIFEST_JSON" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

preselected_path = Path(sys.argv[1]).expanduser()
candidate_manifest_path = Path(sys.argv[2]).expanduser()
history_path = Path(sys.argv[3]).expanduser()
reset_history = sys.argv[4].strip() == "1"
top_count = int(sys.argv[5])
allow_without_owner_pass = sys.argv[6].strip() == "1"
min_pass_count = int(sys.argv[7])
russian_latency_threshold_ms = int(sys.argv[8])
stopped_at_index = int(sys.argv[9] or "0")
early_stop_reason = sys.argv[10].strip()
ranking_json_path = Path(sys.argv[11]).expanduser()
best_candidate_path = Path(sys.argv[12]).expanduser()
best_subscription_path = Path(sys.argv[13]).expanduser()
alternates_subscription_path = Path(sys.argv[14]).expanduser()
android_dataset_path = Path(sys.argv[15]).expanduser()
summary_path = Path(sys.argv[16]).expanduser()
smoke_manifest_path = Path(sys.argv[17]).expanduser()

probe_specs = [line.strip() for line in os.environ.get("PROBE_SPECS_JOINED", "").splitlines() if line.strip()]


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value or "").lower()).strip("-")[:80] or "candidate"


def exact_key(entry: dict) -> str:
    parts = [
        normalize_hostname(entry.get("host")),
        str(entry.get("port") or ""),
        normalize_hostname(entry.get("normalizedSni") or entry.get("sni") or entry.get("serverName") or ""),
        str(entry.get("transport") or ""),
        str(entry.get("security") or ""),
        str(entry.get("flow") or ""),
        str(entry.get("publicKey") or ""),
        str(entry.get("shortId") or ""),
    ]
    return "|".join(parts)


def family_key(entry: dict) -> str:
    return normalize_hostname(entry.get("normalizedSni") or entry.get("sni") or entry.get("serverName") or "")


history = {
    "kind": "odin-one-reality-relay-autoselect-history-v1",
    "generatedAt": None,
    "entries": {},
    "families": {},
    "runs": [],
}
if history_path.exists() and not reset_history:
    try:
        loaded = json.loads(history_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            history.update(loaded)
            history["entries"] = loaded.get("entries") or {}
            history["families"] = loaded.get("families") or {}
            history["runs"] = loaded.get("runs") or []
    except Exception:
        pass

preselected = json.loads(preselected_path.read_text(encoding="utf-8"))
entries = preselected.get("entries") or []
candidate_manifest = json.loads(candidate_manifest_path.read_text(encoding="utf-8"))
candidate_by_index = {int(item.get("index") or 0): item for item in candidate_manifest}

probe_map = {}
for spec in probe_specs:
    label, url, code, weight = spec.split("|", 3)
    probe_map[label] = {
        "label": label,
        "url": url,
        "expectCode": int(code),
        "weight": int(weight),
    }

manifest = []
ranked = []
for index, entry in enumerate(entries, start=1):
    exact_hist = history["entries"].get(exact_key(entry)) or {}
    family_hist = history["families"].get(family_key(entry)) or {}
    current_results = {}
    score = int(entry.get("preScore") or 0)
    pass_count = 0
    owner_pass = False
    tested_count = 0
    run_meta = candidate_by_index.get(index) or {}
    candidate_dir = Path(run_meta.get("runDir") or "")

    for label, probe in probe_map.items():
      run_dir = candidate_dir / f"smoke-{label}" if candidate_dir else None
      results_path = run_dir / "results.json" if run_dir else None
      result = None
      if results_path and results_path.exists():
          payload = json.loads(results_path.read_text(encoding="utf-8"))
          results = payload.get("results") or []
          result = results[0] if results else None
          manifest.append(
              {
                  "candidateIndex": index,
                  "candidateTag": entry.get("tag"),
                  "label": label,
                  "url": probe["url"],
                  "expectCode": probe["expectCode"],
                  "weight": probe["weight"],
                  "resultsPath": str(results_path),
                  "summaryPath": str(run_dir / "summary.md"),
              }
          )

      if result is None:
          current_results[label] = {
              "passed": None,
              "httpCode": None,
              "curlExit": None,
              "error": None,
              "runDir": str(run_dir) if run_dir else None,
              "tested": False,
          }
          continue

      tested_count += 1
      passed = bool(result.get("passed"))
      if passed:
          score += probe["weight"] * 10
          pass_count += 1
          if label == "owner":
              owner_pass = True
      else:
          score -= min(probe["weight"], 40)

      current_results[label] = {
          "passed": passed,
          "httpCode": result.get("httpCode"),
          "curlExit": result.get("curlExit"),
          "error": result.get("error"),
          "runDir": result.get("runDir"),
          "tested": True,
      }

    ex_pass = int(exact_hist.get("passCount") or 0)
    ex_fail = int(exact_hist.get("failCount") or 0)
    fam_pass = int(family_hist.get("passCount") or 0)
    fam_fail = int(family_hist.get("failCount") or 0)
    score += min(ex_pass * 6, 30)
    score -= min(ex_fail * 3, 15)
    score += min(fam_pass * 2, 16)
    score -= min(fam_fail, 10)

    candidate = dict(entry)
    candidate["regionBucket"] = run_meta.get("regionBucket") or entry.get("regionBucket") or "other"
    candidate["tcpLatencyMs"] = run_meta.get("tcpLatencyMs")
    candidate["latencyReachable"] = bool(run_meta.get("latencyReachable"))
    candidate["smokeOrder"] = run_meta.get("smokeOrder")
    candidate["preferredLatencyPhase"] = run_meta.get("preferredLatencyPhase")
    candidate["selectionScore"] = score
    candidate["currentPassCount"] = pass_count
    candidate["ownerProbePassed"] = owner_pass
    candidate["goodEnough"] = owner_pass and pass_count >= min_pass_count
    candidate["testedProbeCount"] = tested_count
    candidate["currentProbeResults"] = current_results
    candidate["history"] = {
        "exact": exact_hist,
        "family": family_hist,
    }
    candidate["smokeVerified"] = tested_count > 0
    candidate["skippedAfterStop"] = bool(stopped_at_index and index > stopped_at_index)
    ranked.append(candidate)

ranked.sort(
    key=lambda item: (
        0 if item.get("goodEnough") else 1,
        0 if item.get("ownerProbePassed") else 1,
        -int(item.get("selectionScore") or 0),
        -int(item.get("currentPassCount") or 0),
        str(item.get("normalizedSni") or ""),
        int(item.get("port") or 0),
        str(item.get("host") or ""),
    )
)

eligible = [item for item in ranked if item.get("goodEnough")]
if not eligible and allow_without_owner_pass:
    eligible = [item for item in ranked if item.get("smokeVerified")] or list(ranked)
selected = eligible[:max(1, top_count)] if eligible else []
selected_uris = [str(item.get("uri") or "").strip() for item in selected if str(item.get("uri") or "").strip()]
best = selected[0] if selected else None

run_generated_at = datetime.now(timezone.utc).isoformat()
run_record = {
    "generatedAt": run_generated_at,
    "sourceLabel": preselected.get("sourceLabel"),
    "sourceKind": preselected.get("sourceKind"),
    "sourceValue": preselected.get("sourceValue"),
    "selectedTags": [item.get("tag") for item in selected],
    "bestTag": best.get("tag") if best else None,
    "stoppedAtIndex": stopped_at_index,
    "earlyStopReason": early_stop_reason,
}
history["generatedAt"] = run_generated_at
history["runs"] = (history.get("runs") or [])[-29:] + [run_record]

for item in ranked:
    key = exact_key(item)
    family = family_key(item)
    ex_hist = history["entries"].setdefault(key, {"passCount": 0, "failCount": 0, "probes": {}, "meta": {}})
    fam_hist = history["families"].setdefault(family, {"passCount": 0, "failCount": 0, "probes": {}, "meta": {}})
    passed_any = False
    failed_any = False
    for label, result in (item.get("currentProbeResults") or {}).items():
        if not result.get("tested"):
            continue
        passed = bool(result.get("passed"))
        target_hist = ex_hist["probes"].setdefault(label, {"passCount": 0, "failCount": 0, "lastOutcome": None, "lastSeen": None})
        fam_target_hist = fam_hist["probes"].setdefault(label, {"passCount": 0, "failCount": 0, "lastOutcome": None, "lastSeen": None})
        if passed:
            target_hist["passCount"] += 1
            fam_target_hist["passCount"] += 1
            passed_any = True
        else:
            target_hist["failCount"] += 1
            fam_target_hist["failCount"] += 1
            failed_any = True
        target_hist["lastOutcome"] = "passed" if passed else "failed"
        target_hist["lastSeen"] = run_generated_at
        fam_target_hist["lastOutcome"] = "passed" if passed else "failed"
        fam_target_hist["lastSeen"] = run_generated_at

    if passed_any:
        ex_hist["passCount"] = int(ex_hist.get("passCount") or 0) + 1
        fam_hist["passCount"] = int(fam_hist.get("passCount") or 0) + 1
    elif failed_any:
        ex_hist["failCount"] = int(ex_hist.get("failCount") or 0) + 1
        fam_hist["failCount"] = int(fam_hist.get("failCount") or 0) + 1

    ex_hist["meta"] = {
        "serverName": item.get("normalizedSni") or item.get("sni") or item.get("serverName"),
        "host": item.get("host"),
        "port": item.get("port"),
        "transport": item.get("transport"),
        "lastTag": item.get("tag"),
        "lastSource": item.get("source"),
        "lastSeen": run_generated_at,
    }
    fam_hist["meta"] = {
        "serverName": family,
        "lastHost": item.get("host"),
        "lastTag": item.get("tag"),
        "lastSource": item.get("source"),
        "lastSeen": run_generated_at,
    }

history_path.write_text(json.dumps(history, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

ranking_payload = {
    "kind": "odin-one-reality-relay-autoselect-ranking-v1",
    "generatedAt": run_generated_at,
    "sourceLabel": preselected.get("sourceLabel"),
    "sourceKind": preselected.get("sourceKind"),
    "sourceValue": preselected.get("sourceValue"),
    "historyFile": str(history_path),
    "probeManifest": manifest,
    "requireOwnerPass": not allow_without_owner_pass,
    "minPassCount": min_pass_count,
    "selectedCount": len(selected),
    "stoppedAtIndex": stopped_at_index,
    "earlyStopReason": early_stop_reason,
    "entries": ranked,
}
ranking_json_path.write_text(json.dumps(ranking_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if best:
    best_candidate_path.write_text(json.dumps(best, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    best_subscription_path.write_text((best.get("uri") or "").strip() + "\n", encoding="utf-8")
else:
    best_candidate_path.write_text("{}\n", encoding="utf-8")
    best_subscription_path.write_text("", encoding="utf-8")

alternates_subscription_path.write_text("\n".join(selected_uris) + ("\n" if selected_uris else ""), encoding="utf-8")

android_entries = []
for priority, item in enumerate(selected, start=1):
    sni = normalize_hostname(item.get("normalizedSni") or item.get("sni") or item.get("serverName"))
    host = normalize_hostname(item.get("host"))
    port = int(item.get("port") or 443)
    transport = str(item.get("transport") or "tcp").lower() or "tcp"
    flow = str(item.get("flow") or "xtls-rprx-vision").strip() or "xtls-rprx-vision"
    fingerprint = str(item.get("fingerprint") or "chrome").strip()
    label = str(item.get("tag") or item.get("label") or f"{sni}-{host}-{port}")
    tag = "auto-" + slugify(f"{sni}-{host}-{port}-{transport}")
    uri = str(item.get("uri") or "").strip()
    android_entries.append(
        {
            "priority": priority,
            "tag": tag,
            "mode": "external-reference",
            "serverName": sni,
            "port": port,
            "connectHost": host,
            "connectPort": port,
            "transport": transport,
            "fingerprint": fingerprint,
            "flow": flow,
            "source": f"owner-auto:{preselected.get('sourceLabel')}",
            "uuid": item.get("uuid"),
            "publicKey": item.get("publicKey"),
            "shortId": item.get("shortId"),
            "bootstrapServerName": sni,
            "bootstrapServerPort": port,
            "bootstrapServerHost": host,
            "selectionScore": item.get("selectionScore"),
            "currentPassCount": item.get("currentPassCount"),
            "ownerProbePassed": item.get("ownerProbePassed"),
            "goodEnough": item.get("goodEnough"),
            "smokeVerified": item.get("smokeVerified"),
            "tcpLatencyMs": item.get("tcpLatencyMs"),
            "regionBucket": item.get("regionBucket"),
            "uiLabel": label,
            "uri": uri,
        }
    )

android_dataset = {
    "kind": "odin-one-reality-external-relay-autoselect-dataset-v1",
    "generatedAt": run_generated_at,
    "sourceLabel": preselected.get("sourceLabel"),
    "sourceKind": preselected.get("sourceKind"),
    "sourceValue": preselected.get("sourceValue"),
    "historyFile": str(history_path),
    "count": len(android_entries),
    "entries": android_entries,
}
android_dataset_path.write_text(json.dumps(android_dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Reality Whitelist Relay Autoselect",
    "",
    f"- Generated at: `{run_generated_at}`",
    f"- Source label: `{preselected.get('sourceLabel')}`",
    f"- Source kind: `{preselected.get('sourceKind')}`",
    f"- Source value: `{preselected.get('sourceValue')}`",
    f"- Probe count: `{len(probe_map)}`",
    f"- Smoke candidate count: `{len(entries)}`",
    f"- Selected candidate count: `{len(selected)}`",
    f"- History file: `{history_path}`",
    f"- Require owner pass: `{str(not allow_without_owner_pass).lower()}`",
    f"- Min pass count: `{min_pass_count}`",
    f"- Early stop reason: `{early_stop_reason}`",
    f"- Stopped at candidate index: `{stopped_at_index or 'n/a'}`",
    "",
    "## Probe Manifest",
    "",
]
for item in probe_map.values():
    summary_lines.append(
        f"- `{item['label']}` -> `{item['url']}` | expect=`{item['expectCode']}` | weight=`{item['weight']}`"
    )

summary_lines.extend(["", "## Selection", ""])
if not selected:
    summary_lines.append("- No eligible candidate was selected in this wave.")
else:
    for item in selected:
        summary_lines.append(
            f"- `{item.get('normalizedSni')}` -> `{item.get('host')}:{item.get('port')}` | latencyMs=`{item.get('tcpLatencyMs') if item.get('tcpLatencyMs') is not None else 'n/a'}` | score=`{item.get('selectionScore')}` | owner=`{str(bool(item.get('ownerProbePassed'))).lower()}` | currentPasses=`{item.get('currentPassCount')}` | goodEnough=`{str(bool(item.get('goodEnough'))).lower()}`"
        )

summary_lines.extend(["", "## Best Candidate", ""])
if not best:
    summary_lines.append("- None")
else:
    summary_lines.append(f"- `serverName`: `{best.get('normalizedSni')}`")
    summary_lines.append(f"- `host:port`: `{best.get('host')}:{best.get('port')}`")
    summary_lines.append(f"- `tcpLatencyMs`: `{best.get('tcpLatencyMs') if best.get('tcpLatencyMs') is not None else 'n/a'}`")
    summary_lines.append(f"- `transport`: `{best.get('transport')}`")
    summary_lines.append(f"- `selectionScore`: `{best.get('selectionScore')}`")
    summary_lines.append(f"- `ownerProbePassed`: `{str(bool(best.get('ownerProbePassed'))).lower()}`")
    summary_lines.append(f"- `currentPassCount`: `{best.get('currentPassCount')}`")
    summary_lines.append(f"- `uri`: `{best.get('uri')}`")

summary_lines.extend(
    [
        "",
        "## Outputs",
        "",
        f"- Ranking JSON: `{ranking_json_path}`",
        f"- Best candidate JSON: `{best_candidate_path}`",
        f"- Best subscription: `{best_subscription_path}`",
        f"- Alternates subscription: `{alternates_subscription_path}`",
        f"- Android dataset: `{android_dataset_path}`",
        "",
        "## Notes",
        "",
        "- Rolling history is advisory, not a hard blacklist. A previously flaky family can recover if it passes current probes.",
        "- The owner probe is weighted highest so the selector prefers candidates that can already reach the current owner server endpoint.",
        f"- Candidate order prefers Russian-labelled entries with TCP latency <= `{russian_latency_threshold_ms}` ms before falling back to the global lowest-latency candidate.",
        "- Candidate smoke stops early once a good-enough entry is found, so later alternates may be pre-ranked but not smoke-verified yet.",
        "- This selection is still based on isolated smoke, so LTE field truth should be confirmed separately with the hidden Android hit-check.",
    ]
)
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
smoke_manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
