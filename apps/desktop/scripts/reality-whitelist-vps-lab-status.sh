#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"

REMOTE_USER="root"
REMOTE_HOST=""
SSH_KEY=""
REMOTE_CONFIG_PATH="/opt/whitelist/config/xray-server.json"
REMOTE_OWNER_PROFILE_PATH="/opt/whitelist/profiles/owner-profile.json"
OUTPUT_DIR=""
INCLUDE_STABLE="0"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-status.sh [options]

Required:
  --host <server-host>        VPS hostname or IP.
  --ssh-key <path>            SSH private key for the VPS.

Options:
  --remote-user <user>        SSH username. Default: root
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-reality-vps-lab-status/<stamp>
  --include-stable            Also export the stable `reality-in` entry into subscription.txt.
  -h, --help                  Show this help.

Outputs:
  - remote-xray-server.json
  - remote-owner-profile.json
  - inventory.json
  - summary.md
  - subscription.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_HOST="$2"
      shift 2
      ;;
    --ssh-key)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SSH_KEY="$2"
      shift 2
      ;;
    --remote-user)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_USER="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --include-stable)
      INCLUDE_STABLE="1"
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
if [[ -z "$SSH_BIN" || ! -x "$SSH_BIN" ]]; then
  echo "ssh not found" >&2
  exit 1
fi
if [[ -z "$REMOTE_HOST" ]]; then
  echo "Provide --host." >&2
  exit 1
fi
if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab-status/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

SSH_OPTS=(
  -i "$SSH_KEY"
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
)
REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

REMOTE_CONFIG_LOCAL="${OUTPUT_DIR}/remote-xray-server.json"
REMOTE_OWNER_LOCAL="${OUTPUT_DIR}/remote-owner-profile.json"
INVENTORY_LOCAL="${OUTPUT_DIR}/inventory.json"
SUMMARY_LOCAL="${OUTPUT_DIR}/summary.md"
SUBSCRIPTION_LOCAL="${OUTPUT_DIR}/subscription.txt"

"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_CONFIG_PATH'" > "$REMOTE_CONFIG_LOCAL"
"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_OWNER_PROFILE_PATH'" > "$REMOTE_OWNER_LOCAL"

"$PYTHON_BIN" - "$REMOTE_CONFIG_LOCAL" "$REMOTE_OWNER_LOCAL" "$INVENTORY_LOCAL" "$SUMMARY_LOCAL" "$SUBSCRIPTION_LOCAL" "$INCLUDE_STABLE" "$REMOTE_HOST" <<'PY'
import json
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
owner_path = Path(sys.argv[2]).expanduser()
inventory_path = Path(sys.argv[3]).expanduser()
summary_path = Path(sys.argv[4]).expanduser()
subscription_path = Path(sys.argv[5]).expanduser()
include_stable = sys.argv[6].strip() == "1"
remote_host = sys.argv[7].strip()

config = json.loads(config_path.read_text(encoding="utf-8"))
owner = json.loads(owner_path.read_text(encoding="utf-8"))
stable = ((owner.get("stagedFallbacks") or {}).get("vlessReality")) or {}
if not isinstance(stable, dict):
    raise SystemExit(f"owner profile has no stagedFallbacks.vlessReality: {owner_path}")

server_host = str(owner.get("serverHost") or remote_host).strip() or remote_host
uuid = str(stable.get("uuid") or "").strip()
pbk = str(stable.get("publicKey") or "").strip()
sid = str(stable.get("shortId") or "").strip()
stable_server_name = str(stable.get("serverName") or "").strip()

if not (uuid and pbk and sid and server_host):
    raise SystemExit("owner profile is missing required reality identity fields")

entries = []
stable_entry = None
for inbound in (config.get("inbounds") or []):
    if not isinstance(inbound, dict):
        continue
    if str(inbound.get("protocol") or "").strip() != "vless":
        continue
    stream = inbound.get("streamSettings")
    if not isinstance(stream, dict):
        continue
    if str(stream.get("security") or "").strip() != "reality":
        continue
    reality = stream.get("realitySettings")
    if not isinstance(reality, dict):
        continue

    tag = str(inbound.get("tag") or "").strip()
    port = int(inbound.get("port") or 0)
    network = str(stream.get("network") or "tcp").strip() or "tcp"
    server_names = [str(v).strip() for v in (reality.get("serverNames") or []) if str(v).strip()]
    server_name = server_names[0] if server_names else ""
    dest = str(reality.get("dest") or "").strip()
    grpc = stream.get("grpcSettings") if isinstance(stream.get("grpcSettings"), dict) else {}
    settings = inbound.get("settings") if isinstance(inbound.get("settings"), dict) else {}
    clients = settings.get("clients") if isinstance(settings.get("clients"), list) else []
    flow = ""
    if clients and isinstance(clients[0], dict):
        flow = str(clients[0].get("flow") or "").strip()
    fp = "chrome"
    if network == "grpc":
        fp = "firefox"

    query = {
        "encryption": "none",
        "type": network,
        "security": "reality",
        "sni": server_name,
        "fp": fp,
        "pbk": pbk,
        "sid": sid,
    }
    if flow:
        query["flow"] = flow
    if network == "grpc":
        if str(grpc.get("serviceName") or "").strip():
            query["serviceName"] = str(grpc.get("serviceName")).strip()
        if str(grpc.get("authority") or "").strip():
            query["authority"] = str(grpc.get("authority")).strip()
        if bool(grpc.get("multiMode")):
            query["mode"] = "multi"

    uri = f"vless://{uuid}@{server_host}:{port}?{urllib.parse.urlencode(query)}#{urllib.parse.quote('Odin One VPS Live | ' + (server_name or tag or str(port)) + ' | ' + network)}"
    entry = {
        "tag": tag,
        "port": port,
        "network": network,
        "serverName": server_name,
        "dest": dest,
        "uri": uri,
        "isStable": tag == "reality-in",
        "grpcServiceName": str(grpc.get("serviceName") or "").strip() or None,
        "grpcAuthority": str(grpc.get("authority") or "").strip() or None,
        "grpcMultiMode": bool(grpc.get("multiMode")),
        "flow": flow or None,
    }
    if tag == "reality-in":
        stable_entry = entry
    elif tag.startswith("reality-lab-"):
        entries.append(entry)

entries.sort(key=lambda item: (item["network"], item["port"], item["serverName"]))

subscription_entries = []
if include_stable and stable_entry is not None:
    subscription_entries.append(stable_entry["uri"])
subscription_entries.extend(entry["uri"] for entry in entries)
subscription_path.write_text("\n".join(subscription_entries) + ("\n" if subscription_entries else ""), encoding="utf-8")

inventory = {
    "kind": "odin-one-reality-whitelist-vps-lab-status-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "remoteHost": remote_host,
    "serverHost": server_host,
    "stable": stable_entry,
    "entries": entries,
}
inventory_path.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Reality Whitelist VPS Lab Status",
    "",
    f"- Generated at: `{inventory['generatedAt']}`",
    f"- Remote host: `{remote_host}`",
    f"- Live lab inbounds: `{len(entries)}`",
    f"- Include stable in subscription: `{str(include_stable).lower()}`",
    "",
    "## Live Entries",
    "",
]
if not entries:
    summary_lines.append("- No live `reality-lab-*` inbounds found.")
else:
    for entry in entries:
        extra = ""
        if entry["network"] == "grpc" and entry["grpcServiceName"]:
            extra = f" | service=`{entry['grpcServiceName']}`"
        summary_lines.append(
            f"- `{entry['tag']}` -> `:{entry['port']}` | transport=`{entry['network']}` | sni=`{entry['serverName']}`{extra}"
        )
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
