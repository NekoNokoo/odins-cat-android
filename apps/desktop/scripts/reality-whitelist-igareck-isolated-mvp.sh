#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
CURL_BIN="${CURL_BIN:-$(command -v curl || true)}"
DATE_BIN="/bin/date"

OUTPUT_DIR=""
SOURCE_SET="all"
ENGINE="sing-box"
LIMIT="12"
MAX_PER_SNI="1"
MAX_PER_TRANSPORT="0"
RUN_SMOKE="1"
SMOKE_EXPECT_CODE="204"
SMOKE_TEST_URL="https://www.gstatic.com/generate_204"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SMOKE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-local-smoke.sh"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-igareck-isolated-mvp.sh [options]

Options:
  --output-dir <dir>        Output directory. Default: /tmp/odin-one-igareck-isolated-mvp/<stamp>
  --source <name>           Source set: all, sni, cidr, mobile. Default: all
  --engine <name>           Local client engine for smoke tests. Default: sing-box
  --limit <count>           Max filtered candidates to keep. Default: 12
  --max-per-sni <count>     Max candidates per repeated SNI. Default: 1
  --max-per-transport <n>   Max candidates per transport. 0 means unlimited. Default: 0
  --smoke-test-url <url>    Probe URL for smoke tests.
  --smoke-expect-code <n>   Expected HTTP status code for smoke tests. Default: 204
  --skip-smoke              Only fetch and filter public configs, do not run the local smoke test.
  -h, --help                Show this help.

Behavior:
  - fetches public white-list config files from igareck/vpn-configs-for-russia
  - filters to the minimal isolated MVP scope:
      vless:// + security=reality|tls + type=tcp|ws|grpc
  - writes a filtered subscription and candidate metadata
  - optionally runs the local loopback SOCKS smoke test via reality-whitelist-local-smoke.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_SET="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE="$2"
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
    --smoke-test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SMOKE_TEST_URL="$2"
      shift 2
      ;;
    --smoke-expect-code)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SMOKE_EXPECT_CODE="$2"
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
if [[ ! -x "$LOCAL_SMOKE_SCRIPT" ]]; then
  echo "Local smoke helper not executable: $LOCAL_SMOKE_SCRIPT" >&2
  exit 1
fi
case "$SOURCE_SET" in
  all|sni|cidr|mobile)
    ;;
  *)
    echo "--source must be one of: all, sni, cidr, mobile" >&2
    exit 1
    ;;
esac
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
if [[ ! "$SMOKE_EXPECT_CODE" =~ '^[0-9]+$' ]]; then
  echo "--smoke-expect-code must be numeric" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-igareck-isolated-mvp/${stamp}"
fi

RAW_DIR="${OUTPUT_DIR}/raw"
mkdir -p "$RAW_DIR"

typeset -a FETCH_TARGETS=()
case "$SOURCE_SET" in
  all)
    FETCH_TARGETS+=("WHITE-SNI-RU-all.txt")
    FETCH_TARGETS+=("WHITE-CIDR-RU-checked.txt")
    FETCH_TARGETS+=("Vless-Reality-White-Lists-Rus-Mobile.txt")
    ;;
  sni)
    FETCH_TARGETS+=("WHITE-SNI-RU-all.txt")
    ;;
  cidr)
    FETCH_TARGETS+=("WHITE-CIDR-RU-checked.txt")
    ;;
  mobile)
    FETCH_TARGETS+=("Vless-Reality-White-Lists-Rus-Mobile.txt")
    ;;
esac

for file_name in "${FETCH_TARGETS[@]}"; do
  "$CURL_BIN" -fsSL "https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/${file_name}" -o "${RAW_DIR}/${file_name}"
done

"$PYTHON_BIN" - "$RAW_DIR" "$OUTPUT_DIR" "$LIMIT" "$MAX_PER_SNI" "$MAX_PER_TRANSPORT" <<'PY'
import json
import re
import sys
import urllib.parse
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

raw_dir = Path(sys.argv[1]).expanduser()
output_dir = Path(sys.argv[2]).expanduser()
limit = int(sys.argv[3])
max_per_sni = int(sys.argv[4])
max_per_transport = int(sys.argv[5])

source_map = {
    "WHITE-SNI-RU-all.txt": "igareck:white-sni",
    "WHITE-CIDR-RU-checked.txt": "igareck:white-cidr",
    "Vless-Reality-White-Lists-Rus-Mobile.txt": "igareck:mobile-vless",
}

HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def parse_candidates():
    raw_stats = []
    accepted = []
    seen = set()
    per_sni = Counter()
    per_transport = Counter()
    source_rank = {
        "igareck:white-sni": 0,
        "igareck:white-cidr": 1,
        "igareck:mobile-vless": 2,
    }
    for path in sorted(raw_dir.glob("*.txt")):
        lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")]
        stats = Counter()
        source_name = source_map.get(path.name, path.name)
        for line in lines:
            try:
                parsed = urllib.parse.urlsplit(line)
            except Exception:
                stats["parse_error"] += 1
                continue
            stats[f"scheme:{parsed.scheme or 'unknown'}"] += 1
            if parsed.scheme != "vless":
                stats["unsupported_scheme"] += 1
                continue
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            security = ((query.get("security") or [""])[0] or "").strip()
            transport = ((query.get("type") or ["tcp"])[0] or "tcp").strip()
            server_name = normalize_hostname((query.get("sni") or [""])[0])
            if security not in {"reality", "tls"}:
                stats["unsupported_security"] += 1
                continue
            if transport not in {"tcp", "ws", "grpc"}:
                stats[f"unsupported_transport:{transport}"] += 1
                continue
            if not parsed.hostname or not server_name or not HOST_RE.match(server_name):
                stats["invalid_host_or_sni"] += 1
                continue
            fingerprint = (query.get("fp") or ["chrome"])[0] or "chrome"
            ws_host = ((query.get("host") or [""])[0] or "").strip() or None
            ws_path = urllib.parse.unquote(((query.get("path") or [""])[0] or "").strip()) or None
            grpc_service_name = ((query.get("serviceName") or [""])[0] or "").strip() or None
            grpc_authority = ((query.get("authority") or [""])[0] or "").strip() or None
            allow_insecure_raw = ((query.get("allowInsecure") or query.get("insecure") or [""])[0] or "").strip().lower()
            record = {
                "uri": line,
                "source": source_name,
                "sourceFile": path.name,
                "host": parsed.hostname,
                "port": parsed.port or 443,
                "transport": transport,
                "security": security,
                "serverName": server_name,
                "uuid": urllib.parse.unquote(parsed.username or ""),
                "flow": ((query.get("flow") or [""])[0] or "").strip(),
                "fingerprint": fingerprint,
                "publicKey": (query.get("pbk") or [""])[0],
                "shortId": (query.get("sid") or [""])[0],
                "wsHost": ws_host,
                "wsPath": ws_path,
                "grpcServiceName": grpc_service_name,
                "grpcAuthority": grpc_authority,
                "allowInsecure": allow_insecure_raw in {"1", "true", "yes"},
                "tag": urllib.parse.unquote(parsed.fragment or server_name),
            }
            if not record["uuid"]:
                stats["missing_required_fields"] += 1
                continue
            if security == "reality" and (not record["publicKey"] or not record["shortId"]):
                stats["missing_required_fields"] += 1
                continue
            dedupe_key = (
                record["host"],
                record["port"],
                record["transport"],
                record["security"],
                record["serverName"],
                record["uuid"],
                record["publicKey"],
                record["shortId"],
                record["wsHost"],
                record["wsPath"],
                record["grpcServiceName"],
            )
            if dedupe_key in seen:
                stats["deduped"] += 1
                continue
            if per_sni[record["serverName"]] >= max_per_sni:
                stats["sni_capped"] += 1
                continue
            if max_per_transport > 0 and per_transport[record["transport"]] >= max_per_transport:
                stats["transport_capped"] += 1
                continue
            seen.add(dedupe_key)
            per_sni[record["serverName"]] += 1
            per_transport[record["transport"]] += 1
            accepted.append(record)
            stats["accepted"] += 1
        raw_stats.append(
            {
                "sourceFile": path.name,
                "source": source_name,
                "stats": dict(stats),
                "lineCount": len(lines),
            }
        )
    transport_rank = {"tcp": 0, "ws": 1, "grpc": 2}
    accepted.sort(key=lambda item: (source_rank.get(item["source"], 99), transport_rank.get(item["transport"], 99), item["serverName"], item["host"], item["port"]))
    accepted = accepted[:limit]
    return accepted, raw_stats


candidates, raw_stats = parse_candidates()
if not candidates:
    raise SystemExit("no supported igareck candidates found for isolated MVP")

subscription_path = output_dir / "filtered-subscription.txt"
subscription_path.write_text("\n".join(item["uri"] for item in candidates) + "\n", encoding="utf-8")

(output_dir / "candidates.json").write_text(
    json.dumps(
        {
            "kind": "odin-one-igareck-isolated-mvp-v1",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "scope": {
                "scheme": "vless",
                "security": "reality",
                "transport": "tcp",
                "maxPerSni": max_per_sni,
                "limit": limit,
            },
            "rawStats": raw_stats,
            "candidates": candidates,
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

summary_lines = [
    "# Igareck Isolated MVP",
    "",
    f"- Generated at: `{datetime.now(timezone.utc).isoformat()}`",
    f"- Raw directory: `{raw_dir}`",
    f"- Filtered subscription: `{subscription_path}`",
    f"- Scope: `vless + reality|tls + tcp|ws|grpc`",
    f"- Max per SNI: `{max_per_sni}`",
    f"- Max per transport: `{max_per_transport}`",
    f"- Candidate limit: `{limit}`",
    f"- Accepted candidates: `{len(candidates)}`",
    "",
    "## Raw source stats",
    "",
]

for item in raw_stats:
    summary_lines.append(f"- `{item['sourceFile']}` -> `{item['lineCount']}` lines")
    for key, value in sorted(item["stats"].items()):
        summary_lines.append(f"  - `{key}`: `{value}`")

summary_lines.extend([
    "",
    "## First candidates",
    "",
])

for item in candidates[:12]:
    summary_lines.append(
        f"- `{item['serverName']}` via `{item['host']}:{item['port']}` | transport=`{item['transport']}` | security=`{item['security']}` | source=`{item['source']}` | fp=`{item['fingerprint']}`"
    )

(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

print(output_dir)
PY

if [[ "$RUN_SMOKE" == "1" ]]; then
  zsh "$LOCAL_SMOKE_SCRIPT" \
    --subscription "${OUTPUT_DIR}/filtered-subscription.txt" \
    --engine "$ENGINE" \
    --limit "$LIMIT" \
    --test-url "$SMOKE_TEST_URL" \
    --expect-code "$SMOKE_EXPECT_CODE" \
    --output-dir "${OUTPUT_DIR}/smoke"
fi

echo "$OUTPUT_DIR"
