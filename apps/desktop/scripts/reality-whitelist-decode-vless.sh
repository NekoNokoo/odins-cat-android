#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
CURL_BIN="${CURL_BIN:-$(command -v curl || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

OUTPUT_DIR=""
LIMIT="0"
OUTPUT_MODE="jsonl"
typeset -a URIS=()
SUBSCRIPTION_FILE=""
SUBSCRIPTION_URL=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-decode-vless.sh [options]

Options:
  --uri <vless://...>         Decode one VLESS URI. May be repeated.
  --subscription-file <path>  Text file with VLESS URIs, one per line.
  --subscription-url <url>    Remote text subscription with VLESS URIs.
  --limit <count>             Limit parsed entries. Default: 0 (all)
  --mode <json|jsonl|summary> Output mode. Default: jsonl
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-vless-decode/<stamp>
  -h, --help                  Show this help.

Behavior:
  - parses raw `vless://` links into structured JSON
  - keeps transport, security, SNI, host header, gRPC service, REALITY keys, tag
  - writes `decoded.json`, `decoded.jsonl`, and `summary.md`

This helper is owner-only and additive. It does not touch runtime profiles,
Android state, stable `direct-reality`, or any network service. It only
decodes subscription material into a reusable structured dataset.
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
    --uri)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      URIS+=("$2")
      shift 2
      ;;
    --subscription-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SUBSCRIPTION_FILE="$2"
      shift 2
      ;;
    --subscription-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SUBSCRIPTION_URL="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_MODE="$2"
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
require_bin "$CURL_BIN" "curl"

if [[ -n "$SUBSCRIPTION_FILE" && -n "$SUBSCRIPTION_URL" ]]; then
  echo "Use only one of --subscription-file or --subscription-url." >&2
  exit 1
fi
if [[ ${#URIS[@]} -eq 0 && -z "$SUBSCRIPTION_FILE" && -z "$SUBSCRIPTION_URL" ]]; then
  echo "Provide at least one --uri, --subscription-file, or --subscription-url." >&2
  exit 1
fi
if [[ -n "$SUBSCRIPTION_FILE" && ! -f "$SUBSCRIPTION_FILE" ]]; then
  echo "Subscription file not found: $SUBSCRIPTION_FILE" >&2
  exit 1
fi
if [[ ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be numeric" >&2
  exit 1
fi
case "$OUTPUT_MODE" in
  json|jsonl|summary)
    ;;
  *)
    echo "--mode must be one of: json, jsonl, summary" >&2
    exit 1
    ;;
esac

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-vless-decode/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

TEMP_SUBSCRIPTION="$OUTPUT_DIR/input-subscription.txt"
if [[ -n "$SUBSCRIPTION_URL" ]]; then
  "$CURL_BIN" -fsSL "$SUBSCRIPTION_URL" -o "$TEMP_SUBSCRIPTION"
  SUBSCRIPTION_FILE="$TEMP_SUBSCRIPTION"
fi

URIS_JOINED="$(printf '%s\n' "${URIS[@]}")"

URIS_JOINED="$URIS_JOINED" \
"$PYTHON_BIN" - "$OUTPUT_DIR" "$SUBSCRIPTION_FILE" "$LIMIT" "$OUTPUT_MODE" "$SUBSCRIPTION_URL" <<'PY'
import json
import os
import sys
import urllib.parse
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

output_dir = Path(sys.argv[1]).expanduser()
subscription_file = sys.argv[2].strip()
limit = int(sys.argv[3])
output_mode = sys.argv[4]
subscription_url = sys.argv[5].strip()

json_path = output_dir / "decoded.json"
jsonl_path = output_dir / "decoded.jsonl"
summary_path = output_dir / "summary.md"


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def trim_text(value: str) -> str:
    return str(value or "").strip()


def safe_int(value, default=None):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def first(query, key, default=""):
    values = query.get(key) or []
    return trim_text(values[0] if values else default)


def decode_uri(uri: str, index: int) -> dict:
    parsed = urllib.parse.urlsplit(uri)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    host = normalize_hostname(parsed.hostname or "")
    port = parsed.port or 443
    tag = urllib.parse.unquote(parsed.fragment or "").strip()
    record = {
        "index": index,
        "uri": uri,
        "host": host,
        "port": port,
        "uuid": urllib.parse.unquote(parsed.username or ""),
        "transport": first(query, "type", "tcp").lower() or "tcp",
        "security": first(query, "security").lower(),
        "encryption": first(query, "encryption"),
        "sni": normalize_hostname(first(query, "sni")),
        "serviceName": first(query, "serviceName"),
        "hostHeader": normalize_hostname(first(query, "host")),
        "path": urllib.parse.unquote(first(query, "path")),
        "mode": first(query, "mode"),
        "flow": first(query, "flow"),
        "fingerprint": first(query, "fp"),
        "allowInsecure": first(query, "allowInsecure") or first(query, "insecure"),
        "publicKey": first(query, "pbk"),
        "shortId": first(query, "sid"),
        "authority": first(query, "authority"),
        "alpn": first(query, "alpn"),
        "typeLabel": f"{first(query, 'security').lower() or 'unknown'}:{first(query, 'type', 'tcp').lower() or 'tcp'}",
        "tag": tag,
        "isReality": first(query, "security").lower() == "reality",
        "isGrpc": first(query, "type", "tcp").lower() == "grpc",
        "isWs": first(query, "type", "tcp").lower() == "ws",
        "isTcp": first(query, "type", "tcp").lower() == "tcp",
    }
    return record


items = []
raw_uris = [line.strip() for line in os.environ.get("URIS_JOINED", "").splitlines() if line.strip()]
if subscription_file:
    subscription_path = Path(subscription_file).expanduser()
    for raw_line in subscription_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.split("#", 1)[0].strip() if not raw_line.startswith("vless://") else raw_line.strip()
        if line.startswith("vless://"):
            raw_uris.append(line)

seen = set()
decoded = []
for raw_uri in raw_uris:
    uri = raw_uri.strip()
    if not uri.startswith("vless://"):
        continue
    if uri in seen:
        continue
    seen.add(uri)
    try:
        decoded.append(decode_uri(uri, len(decoded) + 1))
    except Exception:
        continue
    if limit and len(decoded) >= limit:
        break

transport = Counter(item["transport"] for item in decoded)
security = Counter(item["security"] for item in decoded)
sni = Counter(item["sni"] for item in decoded if item["sni"])
host = Counter(item["host"] for item in decoded if item["host"])
service = Counter(item["serviceName"] for item in decoded if item["serviceName"])

payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "subscriptionFile": subscription_file or None,
    "subscriptionUrl": subscription_url or None,
    "entryCount": len(decoded),
    "transportCounts": dict(transport),
    "securityCounts": dict(security),
    "topSni": [{"value": value, "count": count} for value, count in sni.most_common(20)],
    "topHost": [{"value": value, "count": count} for value, count in host.most_common(20)],
    "topServiceName": [{"value": value, "count": count} for value, count in service.most_common(20)],
    "entries": decoded,
}
json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
jsonl_path.write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in decoded), encoding="utf-8")

lines = [
    "# VLESS Decode Summary",
    "",
    f"- Entry count: `{len(decoded)}`",
    f"- Subscription file: `{subscription_file or 'n/a'}`",
    f"- Subscription URL: `{subscription_url or 'n/a'}`",
    f"- JSON: `{json_path}`",
    f"- JSONL: `{jsonl_path}`",
    "",
    "## Counts",
    "",
    f"- Transports: `{', '.join(f'{k}={v}' for k, v in transport.most_common()) or 'n/a'}`",
    f"- Security: `{', '.join(f'{k}={v}' for k, v in security.most_common()) or 'n/a'}`",
    "",
    "## Top SNI",
    "",
]
for value, count in sni.most_common(12):
    lines.append(f"- `{value}`: `{count}`")
if not sni:
    lines.append("- `n/a`: `0`")
lines.extend(["", "## Sample Entries", ""])
for item in decoded[:8]:
    lines.extend(
        [
            f"### #{item['index']} {item['tag'] or item['sni'] or item['host']}",
            "",
            f"- Host: `{item['host']}:{item['port']}`",
            f"- UUID: `{item['uuid']}`",
            f"- Transport: `{item['transport']}`",
            f"- Security: `{item['security']}`",
            f"- SNI: `{item['sni'] or 'n/a'}`",
            f"- serviceName: `{item['serviceName'] or 'n/a'}`",
            f"- hostHeader: `{item['hostHeader'] or 'n/a'}`",
            f"- path: `{item['path'] or 'n/a'}`",
            f"- fingerprint: `{item['fingerprint'] or 'n/a'}`",
            f"- shortId: `{item['shortId'] or 'n/a'}`",
            "",
        ]
    )
summary_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

if output_mode == "json":
    print(json_path)
elif output_mode == "summary":
    print(summary_path)
else:
    print(jsonl_path)
PY

