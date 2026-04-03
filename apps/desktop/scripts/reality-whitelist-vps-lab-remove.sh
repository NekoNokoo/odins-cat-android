#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
SCP_BIN="${SCP_BIN:-$(command -v scp || true)}"

REMOTE_USER="root"
REMOTE_HOST=""
SSH_KEY=""
REMOTE_CONFIG_PATH="/opt/whitelist/config/xray-server.json"
REMOTE_SERVICE_NAME="whitelist-xray.service"
TAG=""
PORT=""
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-remove.sh [options]

Required:
  --host <server-host>        VPS hostname or IP.
  --ssh-key <path>            SSH private key for the VPS.
  --tag <name>                Lab inbound tag to remove.

Options:
  --remote-user <user>        SSH username. Default: root
  --port <port>               Safety check: expect the removed inbound to use this port.
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-reality-vps-lab-remove/<stamp>-<tag>
  -h, --help                  Show this help.

Safety:
  - only removes tags starting with `reality-lab-`
  - validates the new xray config before restart
  - creates a remote backup and a local rollback helper
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
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TAG="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PORT="$2"
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
if [[ -z "$SCP_BIN" || ! -x "$SCP_BIN" ]]; then
  echo "scp not found" >&2
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
if [[ -z "$TAG" ]]; then
  echo "Provide --tag." >&2
  exit 1
fi
if [[ "$TAG" != reality-lab-* ]]; then
  echo "Refusing to remove non-lab tag: $TAG" >&2
  exit 1
fi
if [[ -n "$PORT" && ! "$PORT" =~ '^[0-9]+$' ]]; then
  echo "--port must be an integer" >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  safe_tag="${TAG//[^A-Za-z0-9._-]/-}"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab-remove/${stamp}-${safe_tag}"
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
UPDATED_CONFIG_LOCAL="${OUTPUT_DIR}/xray-server.removed.json"
SUMMARY_LOCAL="${OUTPUT_DIR}/summary.md"
ROLLBACK_LOCAL="${OUTPUT_DIR}/rollback.sh"
METADATA_LOCAL="${OUTPUT_DIR}/remove-metadata.json"

"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_CONFIG_PATH'" > "$REMOTE_CONFIG_LOCAL"

"$PYTHON_BIN" - "$REMOTE_CONFIG_LOCAL" "$UPDATED_CONFIG_LOCAL" "$SUMMARY_LOCAL" "$METADATA_LOCAL" "$TAG" "$PORT" "$REMOTE_HOST" "$REMOTE_CONFIG_PATH" "$REMOTE_SERVICE_NAME" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser()
updated_path = Path(sys.argv[2]).expanduser()
summary_path = Path(sys.argv[3]).expanduser()
metadata_path = Path(sys.argv[4]).expanduser()
tag = sys.argv[5].strip()
port_raw = sys.argv[6].strip()
remote_host = sys.argv[7].strip()
remote_config_path = sys.argv[8].strip()
remote_service_name = sys.argv[9].strip()

expect_port = int(port_raw) if port_raw else None
config = json.loads(config_path.read_text(encoding="utf-8"))
inbounds = config.get("inbounds")
if not isinstance(inbounds, list):
    raise SystemExit(f"xray config has no inbounds array: {config_path}")

removed = None
kept = []
for inbound in inbounds:
    if isinstance(inbound, dict) and str(inbound.get("tag") or "").strip() == tag:
        removed = inbound
        continue
    kept.append(inbound)
if removed is None:
    raise SystemExit(f"lab tag not found: {tag}")
removed_port = int(removed.get("port") or 0)
if expect_port is not None and removed_port != expect_port:
    raise SystemExit(f"tag {tag!r} uses port {removed_port}, not expected port {expect_port}")

config["inbounds"] = kept
updated_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
backup_path = f"{remote_config_path}.bak-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"

metadata = {
    "kind": "odin-one-reality-whitelist-vps-lab-remove-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "remoteHost": remote_host,
    "remoteConfigPath": remote_config_path,
    "remoteServiceName": remote_service_name,
    "remoteBackupPath": backup_path,
    "removed": {
        "tag": tag,
        "port": removed_port,
        "network": ((removed.get("streamSettings") or {}).get("network")),
        "security": ((removed.get("streamSettings") or {}).get("security")),
    },
}
metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Reality Whitelist VPS Lab Remove",
    "",
    f"- Generated at: `{metadata['generatedAt']}`",
    f"- Remote host: `{remote_host}`",
    f"- Removed tag: `{tag}`",
    f"- Removed port: `{removed_port}`",
    f"- Remote backup path: `{backup_path}`",
]
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

REMOTE_TMP_CONFIG="/tmp/odin-one-xray-server.removed.json"
"$SCP_BIN" "${SSH_OPTS[@]}" "$UPDATED_CONFIG_LOCAL" "${REMOTE_TARGET}:${REMOTE_TMP_CONFIG}"

REMOTE_BACKUP_PATH="$("$PYTHON_BIN" - "$METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload["remoteBackupPath"])
PY
)"
REMOVED_PORT="$("$PYTHON_BIN" - "$METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload["removed"]["port"])
PY
)"

remote_apply_script="$(cat <<EOF
set -euo pipefail
test -x /opt/whitelist/bin/xray
/opt/whitelist/bin/xray run -test -config '${REMOTE_TMP_CONFIG}'
cp '${REMOTE_CONFIG_PATH}' '${REMOTE_BACKUP_PATH}'
install -m 600 '${REMOTE_TMP_CONFIG}' '${REMOTE_CONFIG_PATH}'
systemctl restart '${REMOTE_SERVICE_NAME}'
systemctl is-active '${REMOTE_SERVICE_NAME}'
if ss -H -ltn | grep -Fq ':${REMOVED_PORT}'; then
  echo 'removed port still listening: ${REMOVED_PORT}' >&2
  exit 1
fi
rm -f '${REMOTE_TMP_CONFIG}'
EOF
)"
"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "$remote_apply_script"

cat > "$ROLLBACK_LOCAL" <<EOF
#!/bin/zsh
set -euo pipefail
ssh -i "$SSH_KEY" -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$REMOTE_TARGET" 'cp "$REMOTE_BACKUP_PATH" "$REMOTE_CONFIG_PATH" && systemctl restart "$REMOTE_SERVICE_NAME" && systemctl is-active "$REMOTE_SERVICE_NAME"'
EOF
chmod +x "$ROLLBACK_LOCAL"

echo "$OUTPUT_DIR"
