#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

CONFIG_PATH=""
HINTS_FILE=""
OUTPUT_PATH=""
IN_PLACE="0"
LIMIT=""
SURFACE="any"
typeset -a SERVER_NAMES=()
typeset -a HINT_TAGS=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-patch-xray-config.sh [options]

Options:
  --config <path>           Input xray server config JSON.
  --hints-file <path>       Dataset JSON produced by whitelist curators.
  --server-name <name>      Extra serverName to merge. May be repeated.
  --hint-tag <tag>          Restrict dataset entries to matching tags. May be repeated.
  --surface <any|cidr|sni>  Filter dataset entries by surface class. Default: any
  --limit <count>           Limit merged hint count after filtering.
  --output <path>           Output file path. Defaults to stdout.
  --in-place                Rewrite --config in place.
  -h, --help                Show this help.

Behavior:
  - merges names into every vless+reality inbound's realitySettings.serverNames
  - preserves the existing stable serverName entries
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --hints-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINTS_FILE="$2"
      shift 2
      ;;
    --server-name)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SERVER_NAMES+=("$2")
      shift 2
      ;;
    --hint-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HINT_TAGS+=("$2")
      shift 2
      ;;
    --surface)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SURFACE="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --in-place)
      IN_PLACE="1"
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
if [[ -z "$CONFIG_PATH" ]]; then
  echo "Provide --config." >&2
  exit 1
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config not found: $CONFIG_PATH" >&2
  exit 1
fi
if [[ -n "$HINTS_FILE" && ! -f "$HINTS_FILE" ]]; then
  echo "Hints file not found: $HINTS_FILE" >&2
  exit 1
fi
if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be a positive integer" >&2
  exit 1
fi
case "$SURFACE" in
  any|cidr|sni)
    ;;
  *)
    echo "Unsupported --surface value: $SURFACE" >&2
    exit 1
    ;;
esac
if [[ "$IN_PLACE" == "1" && -n "$OUTPUT_PATH" ]]; then
  echo "Use either --in-place or --output, not both." >&2
  exit 1
fi

SERVER_NAMES_JOINED="$(printf '%s\n' "${SERVER_NAMES[@]}")"
HINT_TAGS_JOINED="$(printf '%s\n' "${HINT_TAGS[@]}")"

SERVER_NAMES_JOINED="$SERVER_NAMES_JOINED" \
HINT_TAGS_JOINED="$HINT_TAGS_JOINED" \
"$PYTHON_BIN" - "$CONFIG_PATH" "$HINTS_FILE" "$SURFACE" "$LIMIT" "$IN_PLACE" "$OUTPUT_PATH" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
hints_path = Path(sys.argv[2]).expanduser() if sys.argv[2] else None
surface = sys.argv[3].strip() or "any"
limit_raw = sys.argv[4].strip()
in_place = sys.argv[5].strip() == "1"
output_path = Path(sys.argv[6]).expanduser() if sys.argv[6] else None

limit = int(limit_raw) if limit_raw else None

HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def classify_surface(hint):
    return "cidr" if hint.get("cidrBucket") else "sni"


hint_tags = {
    line.strip()
    for line in os.environ.get("HINT_TAGS_JOINED", "").splitlines()
    if line.strip()
}

server_names = [
    normalize_hostname(line)
    for line in os.environ.get("SERVER_NAMES_JOINED", "").splitlines()
    if normalize_hostname(line)
]

if hints_path is not None:
    payload = json.loads(hints_path.read_text(encoding="utf-8"))
    raw_hints = payload.get("hints")
    if not isinstance(raw_hints, list):
        raise SystemExit(f"hints file has no top-level hints array: {hints_path}")
    for entry in raw_hints:
        if not isinstance(entry, dict):
            continue
        server_name = normalize_hostname(entry.get("serverName") or "")
        if not server_name or not HOST_RE.match(server_name):
            continue
        tag = str(entry.get("tag") or "").strip()
        if hint_tags and tag not in hint_tags:
            continue
        hint = {
            "serverName": server_name,
            "cidrBucket": str(entry.get("cidrBucket") or "").strip() or None,
        }
        if surface != "any" and classify_surface(hint) != surface:
            continue
        server_names.append(server_name)

ordered_names = []
seen = set()
for server_name in server_names:
    if server_name in seen:
        continue
    seen.add(server_name)
    ordered_names.append(server_name)

if limit is not None:
    ordered_names = ordered_names[:limit]

if not ordered_names:
    raise SystemExit("no serverName values were selected")

config = json.loads(config_path.read_text(encoding="utf-8"))
inbounds = config.get("inbounds")
if not isinstance(inbounds, list):
    raise SystemExit(f"xray config has no inbounds array: {config_path}")

patched = 0
for inbound in inbounds:
    if not isinstance(inbound, dict):
        continue
    if str(inbound.get("protocol") or "").strip() != "vless":
        continue
    stream_settings = inbound.get("streamSettings")
    if not isinstance(stream_settings, dict):
        continue
    if str(stream_settings.get("security") or "").strip() != "reality":
        continue
    reality_settings = stream_settings.get("realitySettings")
    if not isinstance(reality_settings, dict):
        continue
    existing = reality_settings.get("serverNames")
    if not isinstance(existing, list):
        existing = []
    merged = []
    merged_seen = set()
    for entry in existing + ordered_names:
        normalized = normalize_hostname(entry)
        if not normalized:
            continue
        if normalized in merged_seen:
            continue
        merged_seen.add(normalized)
        merged.append(normalized)
    reality_settings["serverNames"] = merged
    patched += 1

if patched == 0:
    raise SystemExit("no vless+reality inbound was found to patch")

rendered = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
if in_place:
    config_path.write_text(rendered, encoding="utf-8")
    print(config_path)
elif output_path is not None:
    output_path.write_text(rendered, encoding="utf-8")
    print(output_path)
else:
    sys.stdout.write(rendered)
PY
