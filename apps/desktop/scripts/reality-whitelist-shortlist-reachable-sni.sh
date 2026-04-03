#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

DECODED_JSON=""
PROBE_RESULTS=""
LIMIT="24"
MAX_PER_SNI="4"
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-shortlist-reachable-sni.sh [options]

Options:
  --decoded-json <path>    Decoded dataset from reality-whitelist-decode-vless.sh.
  --probe-results <path>   Raw LTE whitelist-front probe results.json.
  --limit <count>          Max selected entries. Default: 24
  --max-per-sni <count>    Max selected entries per reachable SNI. Default: 4
  --output-dir <dir>       Output directory. Default: /tmp/odin-one-reachable-sni-shortlist/<stamp>
  -h, --help               Show this help.

Behavior:
  - loads a decoded `vless://` dataset
  - loads raw cellular probe results and keeps only `reachable=true` hosts
  - matches entries where `sni` equals one of those reachable hosts
  - writes shortlist JSON, JSONL, plain subscription.txt, and summary.md

This helper is owner-only and additive. It does not touch Android runtime,
stable `direct-reality`, or any server-side lane.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --decoded-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DECODED_JSON="$2"
      shift 2
      ;;
    --probe-results)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PROBE_RESULTS="$2"
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
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
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

if [[ -z "$DECODED_JSON" || ! -f "$DECODED_JSON" ]]; then
  echo "Provide --decoded-json pointing to an existing decoded.json" >&2
  exit 1
fi
if [[ -z "$PROBE_RESULTS" || ! -f "$PROBE_RESULTS" ]]; then
  echo "Provide --probe-results pointing to an existing results.json" >&2
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

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reachable-sni-shortlist/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

"$PYTHON_BIN" - "$DECODED_JSON" "$PROBE_RESULTS" "$OUTPUT_DIR" "$LIMIT" "$MAX_PER_SNI" <<'PY'
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

decoded_path = Path(sys.argv[1]).expanduser()
probe_results_path = Path(sys.argv[2]).expanduser()
output_dir = Path(sys.argv[3]).expanduser()
limit = int(sys.argv[4])
max_per_sni = int(sys.argv[5])

json_path = output_dir / "shortlist.json"
jsonl_path = output_dir / "shortlist.jsonl"
subscription_path = output_dir / "subscription.txt"
summary_path = output_dir / "summary.md"


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def normalize_sni(value: str) -> str:
    host = normalize_hostname(value)
    if ":" in host:
        host = host.split(":", 1)[0]
    return host


decoded_payload = json.loads(decoded_path.read_text(encoding="utf-8"))
probe_payload = json.loads(probe_results_path.read_text(encoding="utf-8"))

reachable_hosts = {}
for item in probe_payload.get("results") or []:
    if not item.get("reachable"):
        continue
    host = normalize_hostname(item.get("host") or "")
    if not host:
        continue
    reachable_hosts[host] = {
        "host": host,
        "bestInterface": item.get("bestInterface") or "",
        "bestHttpCode": str(item.get("bestHttpCode") or ""),
        "bestRemoteIp": str(item.get("bestRemoteIp") or ""),
        "bestNote": str(item.get("bestNote") or ""),
        "sourceUrl": str(item.get("url") or ""),
    }

entries = decoded_payload.get("entries") or []
filtered = []
per_sni_selected = Counter()
available_per_sni = Counter()
transport_per_sni = defaultdict(Counter)
security_per_sni = defaultdict(Counter)
service_per_sni = defaultdict(Counter)

for item in entries:
    sni = normalize_sni(item.get("sni") or "")
    if sni not in reachable_hosts:
        continue
    available_per_sni[sni] += 1

ranked = []
for item in entries:
    sni = normalize_sni(item.get("sni") or "")
    if sni not in reachable_hosts:
        continue
    security = str(item.get("security") or "").lower()
    transport = str(item.get("transport") or "").lower()
    port = int(item.get("port") or 0)
    score = 0
    if security == "reality":
        score += 40
    elif security == "tls":
        score += 15
    if transport == "grpc":
        score += 18
    elif transport == "tcp":
        score += 14
    elif transport == "ws":
        score += 10
    elif transport == "xhttp":
        score += 8
    if port == 443:
        score += 8
    elif port in {7443, 8443}:
        score += 5
    if item.get("serviceName"):
        score += 3
    if item.get("publicKey") and item.get("shortId"):
        score += 4
    ranked.append((score, sni, item))

ranked.sort(
    key=lambda entry: (
        -entry[0],
        -available_per_sni[entry[1]],
        entry[1],
        int(entry[2].get("port") or 0),
        str(entry[2].get("host") or ""),
        int(entry[2].get("index") or 0),
    )
)

seen_uri = set()
for score, sni, item in ranked:
    uri = str(item.get("uri") or "").strip()
    if not uri or uri in seen_uri:
        continue
    if max_per_sni and per_sni_selected[sni] >= max_per_sni:
        continue
    filtered_item = dict(item)
    filtered_item["normalizedSni"] = sni
    filtered_item["shortlistScore"] = score
    filtered_item["reachability"] = reachable_hosts[sni]
    filtered.append(filtered_item)
    seen_uri.add(uri)
    per_sni_selected[sni] += 1
    transport_per_sni[sni][str(item.get("transport") or "").lower()] += 1
    security_per_sni[sni][str(item.get("security") or "").lower()] += 1
    if item.get("serviceName"):
        service_per_sni[sni][str(item.get("serviceName"))] += 1
    if limit and len(filtered) >= limit:
        break

payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "decodedJson": str(decoded_path),
    "probeResults": str(probe_results_path),
    "reachableSni": sorted(reachable_hosts.values(), key=lambda item: item["host"]),
    "selectedCount": len(filtered),
    "availablePerSni": dict(available_per_sni),
    "selectedPerSni": dict(per_sni_selected),
    "entries": filtered,
}

json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
jsonl_path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in filtered), encoding="utf-8")
subscription_path.write_text("".join(str(item.get("uri") or "").strip() + "\n" for item in filtered if str(item.get("uri") or "").strip()), encoding="utf-8")

lines = [
    "# Reachable SNI Shortlist",
    "",
    f"- Decoded JSON: `{decoded_path}`",
    f"- Probe results: `{probe_results_path}`",
    f"- Reachable SNI count: `{len(reachable_hosts)}`",
    f"- Selected entry count: `{len(filtered)}`",
    f"- JSON: `{json_path}`",
    f"- JSONL: `{jsonl_path}`",
    f"- Subscription: `{subscription_path}`",
    "",
    "## Reachable SNI",
    "",
]
for host in sorted(reachable_hosts):
    meta = reachable_hosts[host]
    lines.append(
        f"- `{host}`: interface=`{meta['bestInterface'] or 'n/a'}`, "
        f"http=`{meta['bestHttpCode'] or 'n/a'}`, remoteIp=`{meta['bestRemoteIp'] or 'n/a'}`, "
        f"sourceUrl=`{meta['sourceUrl'] or 'n/a'}`"
    )
lines.extend(["", "## Selection Summary", ""])
for sni, count in sorted(per_sni_selected.items(), key=lambda item: (-item[1], item[0])):
    transport_text = ", ".join(f"{name}={value}" for name, value in transport_per_sni[sni].most_common()) or "n/a"
    security_text = ", ".join(f"{name}={value}" for name, value in security_per_sni[sni].most_common()) or "n/a"
    service_text = ", ".join(f"{name}={value}" for name, value in service_per_sni[sni].most_common()) or "n/a"
    lines.append(
        f"- `{sni}`: selected=`{count}`, available=`{available_per_sni[sni]}`, "
        f"transport=`{transport_text}`, security=`{security_text}`, serviceName=`{service_text}`"
    )
lines.extend(["", "## Sample Entries", ""])
for item in filtered[:12]:
    lines.extend(
        [
            f"### #{item.get('index')} {item.get('tag') or item.get('normalizedSni')}",
            "",
            f"- SNI: `{item.get('normalizedSni') or 'n/a'}`",
            f"- Host: `{item.get('host')}:{item.get('port')}`",
            f"- Transport: `{item.get('transport') or 'n/a'}`",
            f"- Security: `{item.get('security') or 'n/a'}`",
            f"- serviceName: `{item.get('serviceName') or 'n/a'}`",
            f"- fingerprint: `{item.get('fingerprint') or 'n/a'}`",
            f"- shortId: `{item.get('shortId') or 'n/a'}`",
            f"- Reachability source URL: `{item.get('reachability', {}).get('sourceUrl') or 'n/a'}`",
            f"- Score: `{item.get('shortlistScore')}`",
            "",
        ]
    )

summary_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print(summary_path)
PY
