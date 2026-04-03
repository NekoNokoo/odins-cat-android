#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"

OWNER_PROFILE=""
HOST=""
HINTS_FILE=""
OUTPUT_DIR=""
LIMIT=""
FP="chrome"
LABEL_PREFIX="Odin One MVP"
SURFACE="any"
INCLUDE_STABLE="1"
REALITY_PORT_OVERRIDE=""
typeset -a SERVER_NAMES=()
typeset -a HINT_TAGS=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-export-subscription.sh [options]

Options:
  --owner-profile <path>    Explicit owner profile JSON path.
  --host <server-host>      Resolve owner profile from ~/Library/Caches/odin-one/profiles.
  --hints-file <path>       Dataset JSON produced by whitelist curators.
  --server-name <name>      Extra serverName to export. May be repeated.
  --hint-tag <tag>          Restrict dataset entries to matching tags. May be repeated.
  --surface <any|cidr|sni>  Filter dataset entries by surface class. Default: any
  --limit <count>           Limit exported hint count after filtering.
  --fp <name>               Reality fingerprint for exported URIs. Default: chrome
  --reality-port <port>     Override REALITY port from the owner profile.
  --label-prefix <label>    Prefix for generated URI labels. Default: Odin One MVP
  --output-dir <dir>        Output directory. Default: /tmp/odin-one-reality-whitelist-mvp/<stamp>
  --skip-stable             Do not include the current stable REALITY serverName control URI.
  -h, --help                Show this help.

Outputs:
  - subscription.txt
  - candidates.json
  - server-names.txt
  - summary.md

Current MVP scope:
  - exports VLESS + REALITY over TCP only
  - targets the existing server-side REALITY inbound
  - intended for external V2Ray-compatible clients first
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner-profile)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OWNER_PROFILE="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      HOST="$2"
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
    --fp)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      FP="$2"
      shift 2
      ;;
    --reality-port)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REALITY_PORT_OVERRIDE="$2"
      shift 2
      ;;
    --label-prefix)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LABEL_PREFIX="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-stable)
      INCLUDE_STABLE="0"
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

if [[ -z "$OWNER_PROFILE" && -n "$HOST" ]]; then
  OWNER_PROFILE="${HOME}/Library/Caches/odin-one/profiles/${HOST}-owner-profile.json"
fi

if [[ -z "$OWNER_PROFILE" ]]; then
  echo "Provide --owner-profile or --host." >&2
  exit 1
fi
if [[ ! -f "$OWNER_PROFILE" ]]; then
  echo "Owner profile not found: $OWNER_PROFILE" >&2
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
if [[ -n "$REALITY_PORT_OVERRIDE" && ! "$REALITY_PORT_OVERRIDE" =~ '^[0-9]+$' ]]; then
  echo "--reality-port must be an integer" >&2
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

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-whitelist-mvp/${stamp}"
fi
mkdir -p "$OUTPUT_DIR"

SERVER_NAMES_JOINED="$(printf '%s\n' "${SERVER_NAMES[@]}")"
HINT_TAGS_JOINED="$(printf '%s\n' "${HINT_TAGS[@]}")"

SERVER_NAMES_JOINED="$SERVER_NAMES_JOINED" \
HINT_TAGS_JOINED="$HINT_TAGS_JOINED" \
"$PYTHON_BIN" - "$OWNER_PROFILE" "$HINTS_FILE" "$OUTPUT_DIR" "$SURFACE" "$LIMIT" "$FP" "$LABEL_PREFIX" "$INCLUDE_STABLE" "$REALITY_PORT_OVERRIDE" <<'PY'
import json
import os
import re
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

owner_profile_path = Path(sys.argv[1]).expanduser()
hints_file = Path(sys.argv[2]).expanduser() if sys.argv[2] else None
output_dir = Path(sys.argv[3]).expanduser()
surface = sys.argv[4].strip() or "any"
limit_raw = sys.argv[5].strip()
fingerprint = sys.argv[6].strip() or "chrome"
label_prefix = sys.argv[7].strip() or "Odin One MVP"
include_stable = sys.argv[8].strip() != "0"
reality_port_override_raw = sys.argv[9].strip()

limit = int(limit_raw) if limit_raw else None
reality_port_override = int(reality_port_override_raw) if reality_port_override_raw else None

server_name_inputs = [
    line.strip().lower().rstrip(".")
    for line in os.environ.get("SERVER_NAMES_JOINED", "").splitlines()
    if line.strip()
]
hint_tags = {
    line.strip()
    for line in os.environ.get("HINT_TAGS_JOINED", "").splitlines()
    if line.strip()
}

HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48] or "hint"


def read_owner_profile(path: Path):
    payload = json.loads(path.read_text(encoding="utf-8"))
    stable = payload.get("vlessReality") or {}
    if not isinstance(stable, dict) or not stable.get("uuid"):
        stable = ((payload.get("stagedFallbacks") or {}).get("vlessReality")) or {}
    if not isinstance(stable, dict):
        raise SystemExit(f"owner profile has no usable VLESS + REALITY settings: {path}")
    required = {
        "serverHost": payload.get("serverHost"),
        "port": stable.get("port"),
        "publicKey": stable.get("publicKey"),
        "shortId": stable.get("shortId"),
        "uuid": stable.get("uuid"),
    }
    missing = [key for key, value in required.items() if not value]
    if missing:
        raise SystemExit(f"owner profile is missing required reality fields: {', '.join(missing)}")
    flow = str(stable.get("flow") or "xtls-rprx-vision").strip() or "xtls-rprx-vision"
    server_name = normalize_hostname(stable.get("serverName") or "")
    return {
        "serverHost": str(payload["serverHost"]).strip(),
        "port": reality_port_override if reality_port_override is not None else int(stable["port"]),
        "publicKey": str(stable["publicKey"]).strip(),
        "shortId": str(stable["shortId"]).strip(),
        "uuid": str(stable["uuid"]).strip(),
        "flow": flow,
        "stableServerName": server_name,
        "ownerPath": str(path),
    }


def classify_surface(hint):
    return "cidr" if hint.get("cidrBucket") else "sni"


def load_hint_candidates(path: Path | None):
    hints = []
    if path is not None:
      payload = json.loads(path.read_text(encoding="utf-8"))
      raw_hints = payload.get("hints")
      if not isinstance(raw_hints, list):
          raise SystemExit(f"hints file has no top-level hints array: {path}")
      for index, entry in enumerate(raw_hints, start=1):
          if not isinstance(entry, dict):
              continue
          server_name = normalize_hostname(entry.get("serverName") or "")
          if not server_name or not HOST_RE.match(server_name):
              continue
          hint = {
              "serverName": server_name,
              "tag": str(entry.get("tag") or f"candidate-{index:02d}-{slugify(server_name)}").strip(),
              "source": str(entry.get("source") or "dataset").strip() or "dataset",
              "cidrBucket": str(entry.get("cidrBucket") or "").strip() or None,
              "domainFamily": str(entry.get("domainFamily") or "").strip() or None,
          }
          hint["surfaceType"] = classify_surface(hint)
          if hint_tags and hint["tag"] not in hint_tags:
              continue
          if surface != "any" and hint["surfaceType"] != surface:
              continue
          hints.append(hint)
    for index, server_name in enumerate(server_name_inputs, start=1):
        if not HOST_RE.match(server_name):
            continue
        hint = {
            "serverName": server_name,
            "tag": f"manual-{index:02d}-{slugify(server_name)}",
            "source": "manual",
            "cidrBucket": None,
            "domainFamily": None,
            "surfaceType": "sni",
        }
        if surface != "any" and hint["surfaceType"] != surface:
            continue
        hints.append(hint)
    unique = []
    seen = set()
    for hint in hints:
        key = (hint["serverName"], hint["tag"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(hint)
    if limit is not None:
        unique = unique[:limit]
    return unique


def build_vless_uri(owner, server_name, label):
    query = urllib.parse.urlencode(
        {
            "encryption": "none",
            "type": "tcp",
            "security": "reality",
            "flow": owner["flow"],
            "fp": fingerprint,
            "pbk": owner["publicKey"],
            "sid": owner["shortId"],
            "sni": server_name,
        },
        doseq=False,
        quote_via=urllib.parse.quote,
        safe="",
    )
    fragment = urllib.parse.quote(label, safe="")
    return f"vless://{owner['uuid']}@{owner['serverHost']}:{owner['port']}?{query}#{fragment}"


owner = read_owner_profile(owner_profile_path)
hints = load_hint_candidates(hints_file)

candidates = []
server_names = []
seen_names = set()

if include_stable and owner["stableServerName"]:
    stable_name = owner["stableServerName"]
    seen_names.add(stable_name)
    server_names.append(stable_name)
    candidates.append(
        {
            "kind": "stable-control",
            "tag": "stable-control",
            "serverName": stable_name,
            "surfaceType": "stable",
            "source": "owner-profile",
            "cidrBucket": None,
            "domainFamily": None,
            "label": f"{label_prefix} Stable {stable_name}",
        }
    )

for hint in hints:
    if hint["serverName"] in seen_names:
        continue
    seen_names.add(hint["serverName"])
    server_names.append(hint["serverName"])
    label = f"{label_prefix} {hint['tag']} {hint['serverName']}"
    candidates.append(
        {
            "kind": "whitelist-hint",
            "tag": hint["tag"],
            "serverName": hint["serverName"],
            "surfaceType": hint["surfaceType"],
            "source": hint["source"],
            "cidrBucket": hint.get("cidrBucket"),
            "domainFamily": hint.get("domainFamily"),
            "label": label,
        }
    )

if not candidates:
    raise SystemExit("no export candidates were produced")

for candidate in candidates:
    candidate["uri"] = build_vless_uri(owner, candidate["serverName"], candidate["label"])

subscription_lines = [
    f"# profile-title: {label_prefix} | whitelist-assisted reality MVP",
    "# profile-update-interval: 0",
    f"# generated-at: {datetime.now(timezone.utc).isoformat()}",
    f"# server-host: {owner['serverHost']}",
    f"# reality-port: {owner['port']}",
    f"# fingerprint: {fingerprint}",
    f"# owner-profile: {owner['ownerPath']}",
    f"# count: {len(candidates)}",
    "",
]
subscription_lines.extend(candidate["uri"] for candidate in candidates)

summary_lines = [
    "# Reality Whitelist External MVP Export",
    "",
    f"- Output directory: `{output_dir}`",
    f"- Owner profile: `{owner['ownerPath']}`",
    f"- Server host: `{owner['serverHost']}`",
    f"- Reality port: `{owner['port']}`",
    f"- Stable control SNI: `{owner['stableServerName'] or 'n/a'}`",
    f"- Exported candidates: `{len(candidates)}`",
    f"- Requested surface filter: `{surface}`",
    f"- Reality fingerprint: `{fingerprint}`",
    "",
    "## Notes",
    "",
    "- This MVP exports only `type=tcp` + `security=reality`, because the current server-side inbound is the existing TCP REALITY path.",
    "- CIDR-labeled entries here reuse the current server IP and port. They are useful as operator candidates, but they do not turn the current Finland server into a true white-CIDR endpoint.",
    "- For non-stable `serverName` values to connect, the server-side xray REALITY inbound must accept those names in `realitySettings.serverNames`.",
    "",
    "## Files",
    "",
    "- `subscription.txt` ready for import into V2Ray-compatible clients.",
    "- `candidates.json` with export metadata.",
    "- `server-names.txt` with every serverName that must be accepted by the REALITY inbound.",
    "",
    "## First import targets",
    "",
]
for candidate in candidates[:8]:
    summary_lines.append(
        f"- `{candidate['tag']}` | `{candidate['serverName']}` | surface=`{candidate['surfaceType']}` | source=`{candidate['source']}`"
    )

(output_dir / "subscription.txt").write_text("\n".join(subscription_lines) + "\n", encoding="utf-8")
(output_dir / "candidates.json").write_text(
    json.dumps(
        {
            "kind": "odin-one-reality-whitelist-external-mvp-v1",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "ownerProfile": owner["ownerPath"],
            "serverHost": owner["serverHost"],
            "realityPort": owner["port"],
            "fingerprint": fingerprint,
            "candidates": candidates,
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
(output_dir / "server-names.txt").write_text("\n".join(server_names) + "\n", encoding="utf-8")
(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

print(output_dir)
PY
