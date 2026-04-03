#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
ZSH_BIN="/bin/zsh"
CURL_BIN="${CURL_BIN:-$(command -v curl || true)}"

RAW_DIR=""
OUTPUT_DIR=""
LIMIT="8"
MAX_PER_SNI="1"
MAX_PER_TRANSPORT="4"
RUN_SMOKE="1"
ENGINE="sing-box"
typeset -a RESULTS_FILES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SMOKE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-local-smoke.sh"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-igareck-next-queue.sh [options]

Options:
  --raw-dir <dir>             Raw source directory from a previous isolated MVP run.
  --results <path>            Previous smoke results.json. May be repeated.
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-igareck-next-queue/<stamp>
  --limit <count>             Max queue size. Default: 8
  --max-per-sni <count>       Max candidates per serverName. Default: 1
  --max-per-transport <count> Max candidates per transport. Default: 4
  --engine <name>             Engine for optional smoke rerun. Default: sing-box
  --skip-smoke                Only build the queue, do not immediately rerun smoke.
  -h, --help                  Show this help.

Behavior:
  - reparses the previous raw igareck sources
  - excludes exact configs already tested in any previous run
  - derives simple server/host families
  - prioritizes candidates from families that already showed at least one pass
  - demotes families with only failures
  - optionally reruns the local loopback smoke test on the new queue
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RAW_DIR="$2"
      shift 2
      ;;
    --results)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESULTS_FILES+=("$2")
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
    --max-per-sni)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_PER_SNI="$2"
      shift 2
      ;;
    --max-per-transport)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_PER_TRANSPORT="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE="$2"
      shift 2
      ;;
    --skip-smoke)
      RUN_SMOKE="0"
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

if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "python3 not found" >&2
  exit 1
fi
if [[ -z "$CURL_BIN" || ! -x "$CURL_BIN" ]]; then
  echo "curl not found" >&2
  exit 1
fi
if [[ -z "$RAW_DIR" || ! -d "$RAW_DIR" ]]; then
  echo "Provide --raw-dir pointing to a previous isolated MVP raw directory." >&2
  exit 1
fi
if [[ ${#RESULTS_FILES[@]} -eq 0 ]]; then
  echo "Provide at least one --results pointing to previous smoke results.json files." >&2
  exit 1
fi
for path in "${RESULTS_FILES[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Results file not found: $path" >&2
    exit 1
  fi
done
if [[ ! -x "$LOCAL_SMOKE_SCRIPT" ]]; then
  echo "Local smoke helper not executable: $LOCAL_SMOKE_SCRIPT" >&2
  exit 1
fi
if [[ ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be numeric" >&2
  exit 1
fi
if [[ ! "$MAX_PER_SNI" =~ '^[0-9]+$' ]]; then
  echo "--max-per-sni must be numeric" >&2
  exit 1
fi
if [[ ! "$MAX_PER_TRANSPORT" =~ '^[0-9]+$' ]]; then
  echo "--max-per-transport must be numeric" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-igareck-next-queue/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

RESULTS_FILES_JOINED="$(printf '%s\n' "${RESULTS_FILES[@]}")"

RESULTS_FILES_JOINED="$RESULTS_FILES_JOINED" \
"$PYTHON_BIN" - "$RAW_DIR" "$OUTPUT_DIR" "$LIMIT" "$MAX_PER_SNI" "$MAX_PER_TRANSPORT" <<'PY'
import json
import os
import re
import sys
import urllib.parse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

raw_dir = Path(sys.argv[1]).expanduser()
output_dir = Path(sys.argv[2]).expanduser()
limit = int(sys.argv[3])
max_per_sni = int(sys.argv[4])
max_per_transport = int(sys.argv[5])
results_paths = [Path(line.strip()).expanduser() for line in os.environ.get("RESULTS_FILES_JOINED", "").splitlines() if line.strip()]

source_map = {
    "WHITE-SNI-RU-all.txt": "igareck:white-sni",
    "WHITE-CIDR-RU-checked.txt": "igareck:white-cidr",
    "Vless-Reality-White-Lists-Rus-Mobile.txt": "igareck:mobile-vless",
}
source_rank = {
    "igareck:white-sni": 0,
    "igareck:white-cidr": 1,
    "igareck:mobile-vless": 2,
}
transport_rank = {"tcp": 0, "ws": 1, "grpc": 2}
HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")
IPV4_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def family_for(value: str | None):
    raw = normalize_hostname(value or "")
    if not raw:
        return None
    if IPV4_RE.match(raw):
        parts = raw.split(".")
        return ".".join(parts[:3]) + ".*"
    labels = raw.split(".")
    if len(labels) >= 2:
        return ".".join(labels[-2:])
    return raw


def exact_key(record):
    return (
        record.get("host"),
        int(record.get("port") or 0),
        record.get("transport"),
        record.get("security"),
        record.get("serverName"),
        record.get("uuid"),
        record.get("publicKey"),
        record.get("shortId"),
        record.get("wsHost"),
        record.get("wsPath"),
        record.get("grpcServiceName"),
    )


def parse_supported_candidates():
    items = []
    seen = set()
    for path in sorted(raw_dir.glob("*.txt")):
        source_name = source_map.get(path.name, path.name)
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                parsed = urllib.parse.urlsplit(line)
            except Exception:
                continue
            if parsed.scheme != "vless":
                continue
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            security = ((query.get("security") or [""])[0] or "").strip()
            transport = ((query.get("type") or ["tcp"])[0] or "tcp").strip()
            server_name = normalize_hostname((query.get("sni") or [""])[0])
            host = parsed.hostname or ""
            if security not in {"reality", "tls"}:
                continue
            if transport not in {"tcp", "ws", "grpc"}:
                continue
            if not host or not server_name or not HOST_RE.match(server_name):
                continue
            record = {
                "uri": line,
                "source": source_name,
                "sourceFile": path.name,
                "host": host,
                "port": parsed.port or 443,
                "transport": transport,
                "security": security,
                "serverName": server_name,
                "uuid": urllib.parse.unquote(parsed.username or ""),
                "flow": ((query.get("flow") or [""])[0] or "").strip(),
                "fingerprint": (query.get("fp") or ["chrome"])[0] or "chrome",
                "publicKey": (query.get("pbk") or [""])[0],
                "shortId": (query.get("sid") or [""])[0],
                "wsHost": ((query.get("host") or [""])[0] or "").strip() or None,
                "wsPath": urllib.parse.unquote(((query.get("path") or [""])[0] or "").strip()) or None,
                "grpcServiceName": ((query.get("serviceName") or [""])[0] or "").strip() or None,
                "grpcAuthority": ((query.get("authority") or [""])[0] or "").strip() or None,
                "allowInsecure": ((query.get("allowInsecure") or query.get("insecure") or [""])[0] or "").strip().lower() in {"1", "true", "yes"},
                "tag": urllib.parse.unquote(parsed.fragment or server_name),
            }
            if not record["uuid"]:
                continue
            if security == "reality" and (not record["publicKey"] or not record["shortId"]):
                continue
            key = exact_key(record)
            if key in seen:
                continue
            seen.add(key)
            record["serverFamily"] = family_for(record["serverName"])
            record["hostFamily"] = family_for(record["host"])
            items.append(record)
    return items


def read_results():
    results = []
    sources = []
    for path in results_paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        batch = payload.get("results") or []
        results.extend(batch)
        sources.append(str(path))
    tested_exact = set()
    success_server_families = Counter()
    success_host_families = Counter()
    success_server_names = Counter()
    success_transport_pairs = Counter()
    fail_server_families = Counter()
    fail_host_families = Counter()
    fail_server_names = Counter()
    fail_transport_pairs = Counter()
    for item in results:
        key = (
            item.get("host"),
            int(item.get("port") or 0),
            item.get("transport"),
            item.get("security"),
            item.get("serverName"),
            None,
            None,
            None,
            item.get("wsHost"),
            item.get("wsPath"),
            item.get("grpcServiceName"),
        )
        tested_exact.add(key)
        server_family = family_for(item.get("serverName"))
        host_family = family_for(item.get("host"))
        pair = (server_family, item.get("transport"), item.get("security"))
        if item.get("passed"):
            if server_family:
                success_server_families[server_family] += 1
            if host_family:
                success_host_families[host_family] += 1
            if item.get("serverName"):
                success_server_names[item["serverName"]] += 1
            success_transport_pairs[pair] += 1
        else:
            if server_family:
                fail_server_families[server_family] += 1
            if host_family:
                fail_host_families[host_family] += 1
            if item.get("serverName"):
                fail_server_names[item["serverName"]] += 1
            fail_transport_pairs[pair] += 1
    return {
        "testedExact": tested_exact,
        "successServerFamilies": success_server_families,
        "successHostFamilies": success_host_families,
        "successServerNames": success_server_names,
        "successTransportPairs": success_transport_pairs,
        "failServerFamilies": fail_server_families,
        "failHostFamilies": fail_host_families,
        "failServerNames": fail_server_names,
        "failTransportPairs": fail_transport_pairs,
        "rawResults": results,
        "resultSources": sources,
    }


def score_candidate(item, stats):
    score = 0
    reasons = []
    score += 30 - source_rank.get(item["source"], 9) * 5
    reasons.append(f"source:{item['source']}")
    if item["serverFamily"] and stats["successServerFamilies"][item["serverFamily"]]:
        delta = 140 + 10 * stats["successServerFamilies"][item["serverFamily"]]
        score += delta
        reasons.append(f"server_family_success:+{delta}")
    if item["hostFamily"] and stats["successHostFamilies"][item["hostFamily"]]:
        delta = 90 + 10 * stats["successHostFamilies"][item["hostFamily"]]
        score += delta
        reasons.append(f"host_family_success:+{delta}")
    pair = (item["serverFamily"], item["transport"], item["security"])
    if stats["successTransportPairs"][pair]:
        delta = 70 + 10 * stats["successTransportPairs"][pair]
        score += delta
        reasons.append(f"transport_pair_success:+{delta}")
    if stats["successServerNames"][item["serverName"]]:
        delta = 40 + 5 * stats["successServerNames"][item["serverName"]]
        score += delta
        reasons.append(f"server_name_success:+{delta}")
    if item["serverFamily"] and stats["failServerFamilies"][item["serverFamily"]] and not stats["successServerFamilies"][item["serverFamily"]]:
        delta = 90
        score -= delta
        reasons.append(f"server_family_fail:-{delta}")
    if item["hostFamily"] and stats["failHostFamilies"][item["hostFamily"]] and not stats["successHostFamilies"][item["hostFamily"]]:
        delta = 45
        score -= delta
        reasons.append(f"host_family_fail:-{delta}")
    if stats["failServerNames"][item["serverName"]] and not stats["successServerNames"][item["serverName"]]:
        delta = 20
        score -= delta
        reasons.append(f"server_name_fail:-{delta}")
    if item["transport"] == "tcp":
        score += 8
        reasons.append("transport_tcp:+8")
    elif item["transport"] == "grpc":
        score += 5
        reasons.append("transport_grpc:+5")
    elif item["transport"] == "ws":
        score += 3
        reasons.append("transport_ws:+3")
    if item["security"] == "reality":
        score += 6
        reasons.append("security_reality:+6")
    elif item["security"] == "tls":
        score += 3
        reasons.append("security_tls:+3")
    return score, reasons


all_candidates = parse_supported_candidates()
stats = read_results()

untested = []
excluded_tested = 0
for item in all_candidates:
    partial_key = (
        item["host"],
        int(item["port"]),
        item["transport"],
        item["security"],
        item["serverName"],
        None,
        None,
        None,
        item["wsHost"],
        item["wsPath"],
        item["grpcServiceName"],
    )
    if partial_key in stats["testedExact"]:
        excluded_tested += 1
        continue
    score, reasons = score_candidate(item, stats)
    item["score"] = score
    item["scoreReasons"] = reasons
    untested.append(item)

untested.sort(
    key=lambda item: (
        -item["score"],
        source_rank.get(item["source"], 99),
        transport_rank.get(item["transport"], 99),
        item["serverName"],
        item["host"],
        item["port"],
    )
)

selected = []
per_sni = Counter()
per_transport = Counter()
for item in untested:
    if per_sni[item["serverName"]] >= max_per_sni:
        continue
    if max_per_transport > 0 and per_transport[item["transport"]] >= max_per_transport:
        continue
    selected.append(item)
    per_sni[item["serverName"]] += 1
    per_transport[item["transport"]] += 1
    if len(selected) >= limit:
        break

if not selected:
    raise SystemExit("no next-queue candidates were produced")

(output_dir / "filtered-subscription.txt").write_text("\n".join(item["uri"] for item in selected) + "\n", encoding="utf-8")
(output_dir / "candidates.json").write_text(
    json.dumps(
        {
            "kind": "odin-one-igareck-next-queue-v1",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "rawDir": str(raw_dir),
            "resultsFiles": stats["resultSources"],
            "scope": {
                "limit": limit,
                "maxPerSni": max_per_sni,
                "maxPerTransport": max_per_transport,
            },
            "selected": selected,
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

summary = [
    "# Igareck Next Queue",
    "",
    f"- Generated at: `{datetime.now(timezone.utc).isoformat()}`",
    f"- Raw dir: `{raw_dir}`",
    f"- Previous result sets: `{len(stats['resultSources'])}`",
    f"- Exact tested configs excluded: `{excluded_tested}`",
    f"- Untested supported configs available: `{len(untested)}`",
    f"- Queue size: `{len(selected)}`",
    f"- Max per SNI: `{max_per_sni}`",
    f"- Max per transport: `{max_per_transport}`",
    "",
    "## Result sources",
    "",
]

for path in stats["resultSources"]:
    summary.append(f"- `{path}`")

summary.extend([
    "",
    "## Successful families seen in previous runs",
    "",
])

if stats["successServerFamilies"]:
    for family, count in stats["successServerFamilies"].most_common():
        summary.append(f"- server family `{family}` -> `{count}` pass")
else:
    summary.append("- none")

summary.extend([
    "",
    "## Top next candidates",
    "",
])
for item in selected:
    summary.append(
        f"- score=`{item['score']}` | `{item['serverName']}` via `{item['host']}:{item['port']}` | transport=`{item['transport']}` | security=`{item['security']}` | serverFamily=`{item['serverFamily']}` | hostFamily=`{item['hostFamily']}`"
    )
    summary.append(f"  reasons: `{', '.join(item['scoreReasons'])}`")

(output_dir / "summary.md").write_text("\n".join(summary) + "\n", encoding="utf-8")

print(output_dir)
PY

if [[ "$RUN_SMOKE" == "1" ]]; then
  PYTHON_BIN="$PYTHON_BIN" CURL_BIN="$CURL_BIN" "$ZSH_BIN" "$LOCAL_SMOKE_SCRIPT" \
    --subscription "${OUTPUT_DIR}/filtered-subscription.txt" \
    --engine "$ENGINE" \
    --limit "$LIMIT" \
    --output-dir "${OUTPUT_DIR}/smoke"
fi

echo "$OUTPUT_DIR"
