#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
SCP_BIN="${SCP_BIN:-$(command -v scp || true)}"

SCRIPT_DIR="${0:A:h}"
PACKAGE_HELPER="${SCRIPT_DIR}/android-cdn-origin-lab.sh"

REMOTE_USER="root"
REMOTE_HOST=""
SSH_KEY=""
REMOTE_CONFIG_PATH="/opt/whitelist/config/xray-server.json"
REMOTE_OWNER_PROFILE_PATH="/opt/whitelist/profiles/owner-profile.json"
REMOTE_SERVICE_NAME="whitelist-xray.service"

SOURCE_ARGS=()
OUTPUT_DIR=""
PREPARE_ONLY="0"
LISTEN_WAIT_SECONDS="10"
REMOTE_CONFIG_JSON=""
OWNER_PROFILE_JSON=""
LAB_TAG_OVERRIDE=""
SOURCE_KIND=""
SOURCE_PATH=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-origin-lab-rollout.sh (--preset <preset> | --profile-json <file> | --scaffold-json <file>) [options]

Required:
  One source selector:
    --preset <preset>
    --profile-json <file>
    --scaffold-json <file>

  One config source:
    remote apply mode
      --host <server-host>
      --ssh-key <path>
    or local prepare mode
      --remote-config-json <file>
      --owner-profile-json <file>

Options:
  --remote-user <user>              SSH username. Default: root
  --remote-config-path <path>       Remote xray config path. Default: /opt/whitelist/config/xray-server.json
  --remote-owner-profile-path <p>   Remote owner profile path. Default: /opt/whitelist/profiles/owner-profile.json
  --remote-service-name <name>      systemd service to restart. Default: whitelist-xray.service
  --output-dir <dir>                Output directory. Default: /tmp/odin-one-android-cdn-origin-rollout/<stamp>-<label>
  --listen-wait-seconds <n>         Wait for loopback listener after restart. Default: 10
  --prepare-only                    Do not upload/apply; only prepare patched config + rollback metadata.
  --lab-tag <name>                  Override the loopback inbound tag to replace an existing dedicated lab inbound.
  --plan-file <file>                Forwarded to android-cdn-origin-lab.sh
  --plan-tag <tag>                  Forwarded to android-cdn-origin-lab.sh
  --plan-index <n>                  Forwarded to android-cdn-origin-lab.sh
  -h, --help                        Show this help.

Behavior:
  - builds the normalized owner-lab package via android-cdn-origin-lab.sh
  - patches one additive loopback xray inbound for websocket/xhttp/httpupgrade
  - preserves the stable direct REALITY lane and existing public listener
  - writes rollback + summary artifacts

Supported transports:
  - websocket
  - xhttp
  - httpupgrade
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

require_file() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" || ! -f "$path" ]]; then
    echo "${label} not found: $path" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset|--profile-json|--scaffold-json|--plan-file|--plan-tag|--plan-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_ARGS+=("$1" "$2")
      shift 2
      ;;
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
    --remote-config-path)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_CONFIG_PATH="$2"
      shift 2
      ;;
    --remote-owner-profile-path)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_OWNER_PROFILE_PATH="$2"
      shift 2
      ;;
    --remote-service-name)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_SERVICE_NAME="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --listen-wait-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LISTEN_WAIT_SECONDS="$2"
      shift 2
      ;;
    --prepare-only)
      PREPARE_ONLY="1"
      shift
      ;;
    --lab-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LAB_TAG_OVERRIDE="$2"
      shift 2
      ;;
    --remote-config-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_CONFIG_JSON="$2"
      shift 2
      ;;
    --owner-profile-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OWNER_PROFILE_JSON="$2"
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

if [[ ${#SOURCE_ARGS[@]} -lt 2 ]]; then
  echo "Provide one source selector." >&2
  usage >&2
  exit 1
fi

if [[ ! "$LISTEN_WAIT_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "--listen-wait-seconds must be an integer" >&2
  exit 1
fi

require_bin "$PYTHON_BIN" "python3"
require_bin "$DATE_BIN" "date"
require_bin "$MKDIR_BIN" "mkdir"

if [[ -z "$OUTPUT_DIR" ]]; then
  label="$("$PYTHON_BIN" - "${SOURCE_ARGS[@]}" <<'PY'
import re
import sys

label = "cdn-origin-lab"
args = sys.argv[1:]
for index, value in enumerate(args[:-1]):
    if value in {"--preset", "--profile-json", "--scaffold-json"}:
        candidate = args[index + 1]
        label = candidate.rsplit("/", 1)[-1].rsplit(".", 1)[0] or label
        break
label = re.sub(r"[^a-z0-9._-]+", "-", label.lower()).strip("-") or "cdn-origin-lab"
print(label[:64])
PY
)"
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-android-cdn-origin-rollout/${stamp}-${label}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

PACKAGE_DIR="${OUTPUT_DIR}/package"
REMOTE_CONFIG_LOCAL="${OUTPUT_DIR}/remote-xray-server.json"
REMOTE_OWNER_LOCAL="${OUTPUT_DIR}/remote-owner-profile.json"
PATCHED_CONFIG_LOCAL="${OUTPUT_DIR}/xray-server.cdn-origin-lab.json"
ROLLOUT_METADATA_LOCAL="${OUTPUT_DIR}/rollout-metadata.json"
ROLLBACK_LOCAL="${OUTPUT_DIR}/rollback.sh"
SUMMARY_LOCAL="${OUTPUT_DIR}/summary.md"

zsh "$PACKAGE_HELPER" "${SOURCE_ARGS[@]}" --output-dir "$PACKAGE_DIR" >/dev/null
PLAN_JSON="${PACKAGE_DIR}/plan.json"
require_file "$PLAN_JSON" "normalized plan"

source_index=1
while [[ $source_index -le ${#SOURCE_ARGS[@]} ]]; do
  flag="${SOURCE_ARGS[$source_index]}"
  if [[ "$flag" == "--preset" || "$flag" == "--profile-json" || "$flag" == "--scaffold-json" ]]; then
    SOURCE_KIND="${flag#--}"
    next_index=$((source_index + 1))
    SOURCE_PATH="${SOURCE_ARGS[$next_index]}"
    break
  fi
  source_index=$((source_index + 1))
done

if [[ -n "$REMOTE_CONFIG_JSON" ]]; then
  require_file "$REMOTE_CONFIG_JSON" "remote config JSON"
  cp "$REMOTE_CONFIG_JSON" "$REMOTE_CONFIG_LOCAL"
fi
if [[ -n "$OWNER_PROFILE_JSON" ]]; then
  require_file "$OWNER_PROFILE_JSON" "owner profile JSON"
  cp "$OWNER_PROFILE_JSON" "$REMOTE_OWNER_LOCAL"
fi

if [[ -z "$REMOTE_CONFIG_JSON" || -z "$OWNER_PROFILE_JSON" ]]; then
  require_bin "$SSH_BIN" "ssh"
  if [[ "$PREPARE_ONLY" != "1" ]]; then
    require_bin "$SCP_BIN" "scp"
  fi
  if [[ -z "$REMOTE_HOST" ]]; then
    echo "Provide --host for remote fetch/apply mode." >&2
    exit 1
  fi
  require_file "$SSH_KEY" "SSH key"
  SSH_OPTS=(
    -i "$SSH_KEY"
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
  )
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
  "$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_CONFIG_PATH'" > "$REMOTE_CONFIG_LOCAL"
  "$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_OWNER_PROFILE_PATH'" > "$REMOTE_OWNER_LOCAL"
else
  SSH_OPTS=()
  REMOTE_TARGET=""
fi

"$PYTHON_BIN" - "$PLAN_JSON" "$REMOTE_CONFIG_LOCAL" "$REMOTE_OWNER_LOCAL" "$PATCHED_CONFIG_LOCAL" "$ROLLOUT_METADATA_LOCAL" "$SUMMARY_LOCAL" "$REMOTE_HOST" "$REMOTE_CONFIG_PATH" "$REMOTE_OWNER_PROFILE_PATH" "$REMOTE_SERVICE_NAME" "$OUTPUT_DIR" "$LAB_TAG_OVERRIDE" "$SOURCE_KIND" "$SOURCE_PATH" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

plan_path = Path(sys.argv[1]).expanduser()
remote_config_path = Path(sys.argv[2]).expanduser()
owner_profile_path = Path(sys.argv[3]).expanduser()
patched_config_path = Path(sys.argv[4]).expanduser()
metadata_path = Path(sys.argv[5]).expanduser()
summary_path = Path(sys.argv[6]).expanduser()
remote_host = sys.argv[7].strip()
remote_config_remote_path = sys.argv[8].strip()
remote_owner_remote_path = sys.argv[9].strip()
remote_service_name = sys.argv[10].strip()
output_dir = sys.argv[11].strip()
lab_tag_override = sys.argv[12].strip()
source_kind = sys.argv[13].strip()
source_path_value = sys.argv[14].strip()


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48] or "lab"


plan = json.loads(plan_path.read_text(encoding="utf-8"))
owner = json.loads(owner_profile_path.read_text(encoding="utf-8"))
config = json.loads(remote_config_path.read_text(encoding="utf-8"))
inbounds = config.get("inbounds")
if not isinstance(inbounds, list):
    raise SystemExit(f"xray config has no inbounds array: {remote_config_path}")

stable = ((owner.get("stagedFallbacks") or {}).get("vlessReality")) or {}
owner_uuid = str(stable.get("uuid") or "").strip()
if not owner_uuid:
    raise SystemExit(f"owner profile has no stagedFallbacks.vlessReality.uuid: {owner_profile_path}")

client_ids = [owner_uuid]
if source_kind in {"profile-json", "scaffold-json"} and source_path_value:
    try:
        source_payload = json.loads(Path(source_path_value).expanduser().read_text(encoding="utf-8"))
    except Exception:
        source_payload = {}
    if isinstance(source_payload, dict):
        candidate_ids = [
            ((source_payload.get("vlessReality") or {}).get("uuid")),
            (((source_payload.get("stagedFallbacks") or {}).get("vlessReality") or {}).get("uuid")),
        ]
        for candidate in candidate_ids:
            candidate_text = str(candidate or "").strip()
            if candidate_text and candidate_text not in client_ids:
                client_ids.append(candidate_text)

transport = str(plan.get("transport") or "").strip().lower()
if transport not in {"websocket", "xhttp", "httpupgrade"}:
    raise SystemExit(f"unsupported transport for CDN origin lab rollout: {transport}")

loopback_port = int(plan.get("coreLoopbackPort") or 0)
origin_path = str(plan.get("originPath") or "/").strip() or "/"
front_host = str(plan.get("frontHost") or "").strip()
front_tag = str(plan.get("frontTag") or "").strip()
transport_label = (
    "ws" if transport == "websocket"
    else "xhttp" if transport == "xhttp"
    else "httpupgrade"
)
tag = lab_tag_override or f"cdn-origin-lab-{transport_label}-{slugify(front_tag or front_host or origin_path)}-{loopback_port}"

for inbound in inbounds:
    if not isinstance(inbound, dict):
        continue
    inbound_tag = str(inbound.get("tag") or "").strip()
    inbound_port = int(inbound.get("port") or 0)
    inbound_listen = str(inbound.get("listen") or "").strip()
    if inbound_port == loopback_port and inbound_tag != tag and inbound_listen in {"127.0.0.1", "::1", "localhost", ""}:
        raise SystemExit(f"loopback port {loopback_port} is already used by inbound tag {inbound_tag!r}")

stream_settings = {
    "network": "ws" if transport == "websocket" else transport,
    "security": "none",
}
if transport == "websocket":
    stream_settings["wsSettings"] = {
        "path": origin_path,
    }
elif transport == "xhttp":
    stream_settings["xhttpSettings"] = {
        "path": origin_path,
    }
else:
    stream_settings["httpupgradeSettings"] = {
        "path": origin_path,
    }

existing_clients = []
for inbound in inbounds:
    if not isinstance(inbound, dict):
        continue
    if str(inbound.get("tag") or "").strip() != tag:
        continue
    for client in ((inbound.get("settings") or {}).get("clients") or []):
        if not isinstance(client, dict):
            continue
        client_id = str(client.get("id") or "").strip()
        if client_id and client_id not in client_ids and client_id not in existing_clients:
            existing_clients.append(client_id)

lab_inbound = {
    "tag": tag,
    "listen": "127.0.0.1",
    "port": loopback_port,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": client_id,
            } for client_id in [*client_ids, *existing_clients]
        ],
        "decryption": "none",
    },
    "sniffing": {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"],
    },
    "streamSettings": stream_settings,
}

updated_inbounds = []
replaced = False
for inbound in inbounds:
    if isinstance(inbound, dict) and str(inbound.get("tag") or "").strip() == tag:
        updated_inbounds.append(lab_inbound)
        replaced = True
    else:
        updated_inbounds.append(inbound)
if not replaced:
    updated_inbounds.append(lab_inbound)
config["inbounds"] = updated_inbounds
patched_config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

generated_at = datetime.now(timezone.utc).isoformat()
backup_name = ""
if remote_config_remote_path:
    backup_name = f"{remote_config_remote_path}.bak-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"

metadata = {
    "kind": "odin-one-android-cdn-origin-lab-rollout-v1",
    "generatedAt": generated_at,
    "remoteHost": remote_host or None,
    "remoteConfigPath": remote_config_remote_path or None,
    "remoteOwnerProfilePath": remote_owner_remote_path or None,
    "remoteServiceName": remote_service_name or None,
    "remoteBackupPath": backup_name or None,
    "plan": plan,
    "lab": {
        "tag": tag,
        "transport": transport,
        "listen": "127.0.0.1",
        "port": loopback_port,
        "path": origin_path,
        "ownerUuid": owner_uuid,
        "clientIds": [*client_ids, *existing_clients],
    },
}
metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Android CDN Origin Lab Rollout",
    "",
    f"- Generated at: `{generated_at}`",
    f"- Remote host: `{remote_host or 'prepare-only'}`",
    f"- Transport: `{transport}`",
    f"- Front host: `{front_host or 'n/a'}`",
    f"- Front path: `{plan.get('frontPath') or 'n/a'}`",
    f"- Origin path: `{origin_path}`",
    f"- Loopback port: `{loopback_port}`",
    f"- Inbound tag: `{tag}`",
    f"- Remote config path: `{remote_config_remote_path or 'n/a'}`",
    f"- Remote backup path: `{backup_name or 'n/a'}`",
    "",
    "## Artifacts",
    f"- Package directory: `{output_dir}/package`",
    f"- Patched config: `{patched_config_path}`",
    f"- Rollout metadata: `{metadata_path}`",
    "",
    "## Reverse Proxy",
    "- Use the generated `package/caddy.Caddyfile` or `package/nginx.conf` as the visible HTTPS front sample.",
    "- Keep TLS termination at the front layer; the loopback xray inbound stays additive and owner-only.",
    "",
    "## Rollback",
    "",
    "```bash",
    f"cp {backup_name or '<backup-path>'} {remote_config_remote_path or '<remote-config>'} && systemctl restart {remote_service_name or 'whitelist-xray.service'}",
    "```",
]
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

if [[ -n "$REMOTE_CONFIG_JSON" && -n "$OWNER_PROFILE_JSON" ]]; then
  cat > "$ROLLBACK_LOCAL" <<'EOF'
#!/bin/zsh
set -euo pipefail
echo "Local prepare mode only. Restore the original xray config manually from your saved source file."
EOF
  chmod +x "$ROLLBACK_LOCAL"
else
  REMOTE_BACKUP_PATH="$("$PYTHON_BIN" - "$ROLLOUT_METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload.get("remoteBackupPath") or "")
PY
)"
  LAB_PORT_EFFECTIVE="$("$PYTHON_BIN" - "$ROLLOUT_METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload["lab"]["port"])
PY
)"
  cat > "$ROLLBACK_LOCAL" <<EOF
#!/bin/zsh
set -euo pipefail
ssh -i "$SSH_KEY" -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$REMOTE_TARGET" 'cp "$REMOTE_BACKUP_PATH" "$REMOTE_CONFIG_PATH" && systemctl restart "$REMOTE_SERVICE_NAME" && systemctl is-active "$REMOTE_SERVICE_NAME"'
EOF
  chmod +x "$ROLLBACK_LOCAL"
fi

if [[ "$PREPARE_ONLY" == "1" ]]; then
  echo "Prepared CDN origin lab rollout artifacts."
  echo "Summary: $SUMMARY_LOCAL"
  echo "Patched config: $PATCHED_CONFIG_LOCAL"
  exit 0
fi

if [[ -n "$REMOTE_CONFIG_JSON" || -n "$OWNER_PROFILE_JSON" ]]; then
  echo "--prepare-only is required when using local --remote-config-json/--owner-profile-json inputs." >&2
  exit 1
fi

REMOTE_TMP_CONFIG="/tmp/odin-one-xray-server.cdn-origin-lab.json"
"$SCP_BIN" "${SSH_OPTS[@]}" "$PATCHED_CONFIG_LOCAL" "${REMOTE_TARGET}:${REMOTE_TMP_CONFIG}"

LISTEN_WAIT_ATTEMPTS="$LISTEN_WAIT_SECONDS"
if [[ "$LISTEN_WAIT_ATTEMPTS" -le 0 ]]; then
  LISTEN_WAIT_ATTEMPTS="1"
fi

remote_apply_script="$(cat <<EOF
set -euo pipefail
test -x /opt/whitelist/bin/xray
/opt/whitelist/bin/xray run -test -config '${REMOTE_TMP_CONFIG}'
cp '${REMOTE_CONFIG_PATH}' '${REMOTE_BACKUP_PATH}'
install -m 600 '${REMOTE_TMP_CONFIG}' '${REMOTE_CONFIG_PATH}'
systemctl restart '${REMOTE_SERVICE_NAME}'
systemctl is-active '${REMOTE_SERVICE_NAME}'
for _attempt in \$(seq 1 ${LISTEN_WAIT_ATTEMPTS}); do
  if ss -H -ltn | grep -Fq '127.0.0.1:${LAB_PORT_EFFECTIVE}'; then
    break
  fi
  sleep 1
done
ss -H -ltn | grep -Fq '127.0.0.1:${LAB_PORT_EFFECTIVE}'
rm -f '${REMOTE_TMP_CONFIG}'
EOF
)"
"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "$remote_apply_script"

echo "Android CDN origin lab rollout complete."
echo "Summary: $SUMMARY_LOCAL"
echo "Patched config: $PATCHED_CONFIG_LOCAL"
