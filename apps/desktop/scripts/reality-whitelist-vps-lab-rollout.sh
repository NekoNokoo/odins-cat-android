#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
SCP_BIN="${SCP_BIN:-$(command -v scp || true)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SMOKE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-local-smoke.sh"

REMOTE_USER="root"
REMOTE_HOST=""
SSH_KEY=""
REMOTE_CONFIG_PATH="/opt/whitelist/config/xray-server.json"
REMOTE_OWNER_PROFILE_PATH="/opt/whitelist/profiles/owner-profile.json"
REMOTE_SERVICE_NAME="whitelist-xray.service"

CANDIDATE_URI=""
LAB_PORT=""
DEST_OVERRIDE=""
TAG_OVERRIDE=""
LABEL_PREFIX="Odin One VPS Lab"
FP_OVERRIDE=""
OUTPUT_DIR=""
SMOKE_ENGINE="sing-box"
SKIP_SMOKE="0"
LISTEN_WAIT_SECONDS="10"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-rollout.sh [options]

Required:
  --host <server-host>        VPS hostname or IP.
  --ssh-key <path>            SSH private key for the VPS.
  --candidate-uri <uri>       Public vless:// candidate to copy onto our VPS.

Options:
  --remote-user <user>        SSH username. Default: root
  --lab-port <port>           Port to expose on our VPS. Default: candidate port
  --dest <host:port>          Override REALITY dest. Default: <serverName>:443
  --tag <name>                Override inbound tag.
  --fp <name>                 Override exported fp query value.
  --label-prefix <label>      Exported URI label prefix. Default: Odin One VPS Lab
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-reality-vps-lab/<stamp>-<slug>
  --smoke-engine <engine>     Local smoke engine. Default: sing-box
  --listen-wait-seconds <n>   Wait for the new lab port after restart. Default: 10
  --skip-smoke                Skip the local isolated smoke test.
  -h, --help                  Show this help.

Behavior:
  - fetches live xray config and owner profile from the VPS
  - adds or updates one additive vless+reality lab inbound on a new port
  - preserves the stable REALITY lane on port 443
  - exports a single local subscription.txt for the new lab inbound
  - optionally runs a local loopback SOCKS smoke test without touching system routes

Current supported shapes:
  - vless + reality + tcp
  - vless + reality + grpc

Not yet supported:
  - ws + tls
  - xhttp
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
    --candidate-uri)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CANDIDATE_URI="$2"
      shift 2
      ;;
    --remote-user)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_USER="$2"
      shift 2
      ;;
    --lab-port)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LAB_PORT="$2"
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DEST_OVERRIDE="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TAG_OVERRIDE="$2"
      shift 2
      ;;
    --fp)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      FP_OVERRIDE="$2"
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
    --smoke-engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SMOKE_ENGINE="$2"
      shift 2
      ;;
    --listen-wait-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LISTEN_WAIT_SECONDS="$2"
      shift 2
      ;;
    --skip-smoke)
      SKIP_SMOKE="1"
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
if [[ -z "$CANDIDATE_URI" ]]; then
  echo "Provide --candidate-uri." >&2
  exit 1
fi
if [[ -n "$LAB_PORT" && ! "$LAB_PORT" =~ '^[0-9]+$' ]]; then
  echo "--lab-port must be an integer" >&2
  exit 1
fi
if [[ ! "$LISTEN_WAIT_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "--listen-wait-seconds must be an integer" >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  slug="$("$PYTHON_BIN" - "$CANDIDATE_URI" <<'PY'
import re
import sys
import urllib.parse

uri = sys.argv[1].strip()
parsed = urllib.parse.urlparse(uri)
params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
server_name = ""
for key in ("sni", "serverName"):
    values = params.get(key)
    if values and str(values[0]).strip():
        server_name = str(values[0]).strip().lower().rstrip(".")
        break
if not server_name:
    server_name = parsed.hostname or "candidate"
print(re.sub(r"[^a-z0-9]+", "-", server_name.lower()).strip("-")[:48] or "candidate")
PY
)"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab/${stamp}-${slug}"
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
LAB_CONFIG_LOCAL="${OUTPUT_DIR}/xray-server.lab.json"
LAB_METADATA_LOCAL="${OUTPUT_DIR}/lab-metadata.json"
SUBSCRIPTION_LOCAL="${OUTPUT_DIR}/subscription.txt"
ROLLBACK_LOCAL="${OUTPUT_DIR}/rollback.sh"
SUMMARY_LOCAL="${OUTPUT_DIR}/summary.md"

"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_CONFIG_PATH'" > "$REMOTE_CONFIG_LOCAL"
"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "cat '$REMOTE_OWNER_PROFILE_PATH'" > "$REMOTE_OWNER_LOCAL"

"$PYTHON_BIN" - "$CANDIDATE_URI" "$REMOTE_CONFIG_LOCAL" "$REMOTE_OWNER_LOCAL" "$LAB_CONFIG_LOCAL" "$LAB_METADATA_LOCAL" "$SUBSCRIPTION_LOCAL" "$SUMMARY_LOCAL" "$LAB_PORT" "$DEST_OVERRIDE" "$TAG_OVERRIDE" "$LABEL_PREFIX" "$FP_OVERRIDE" "$REMOTE_HOST" "$REMOTE_CONFIG_PATH" "$REMOTE_SERVICE_NAME" <<'PY'
import json
import re
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

candidate_uri = sys.argv[1].strip()
remote_config_path = Path(sys.argv[2]).expanduser()
owner_profile_path = Path(sys.argv[3]).expanduser()
lab_config_path = Path(sys.argv[4]).expanduser()
lab_metadata_path = Path(sys.argv[5]).expanduser()
subscription_path = Path(sys.argv[6]).expanduser()
summary_path = Path(sys.argv[7]).expanduser()
lab_port_raw = sys.argv[8].strip()
dest_override = sys.argv[9].strip()
tag_override = sys.argv[10].strip()
label_prefix = sys.argv[11].strip() or "Odin One VPS Lab"
fp_override = sys.argv[12].strip()
remote_host = sys.argv[13].strip()
remote_config_remote_path = sys.argv[14].strip()
remote_service_name = sys.argv[15].strip()

HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48] or "candidate"


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def first(params, key, default=""):
    values = params.get(key)
    if not values:
        return default
    return str(values[0] or default)


parsed = urllib.parse.urlparse(candidate_uri)
if parsed.scheme != "vless":
    raise SystemExit("candidate URI must use vless://")
if parsed.hostname is None or parsed.port is None:
    raise SystemExit("candidate URI must include host and port")
params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

security = first(params, "security", "").strip().lower()
transport = first(params, "type", "tcp").strip().lower() or "tcp"
if security != "reality":
    raise SystemExit(f"unsupported candidate security: {security}")
if transport not in {"tcp", "grpc"}:
    raise SystemExit(f"unsupported candidate transport for VPS lab rollout: {transport}")

server_name = normalize_hostname(first(params, "sni", "") or first(params, "serverName", ""))
if not server_name and parsed.hostname:
    server_name = normalize_hostname(parsed.hostname)
if not server_name or not HOST_RE.match(server_name):
    raise SystemExit("candidate URI must include a valid SNI/serverName")

candidate_port = parsed.port
lab_port = int(lab_port_raw) if lab_port_raw else candidate_port
if lab_port <= 1024:
    raise SystemExit(f"lab port must be >1024 for additive rollout: {lab_port}")

dest = dest_override or f"{server_name}:443"
flow = first(params, "flow", "xtls-rprx-vision").strip() or "xtls-rprx-vision"
fingerprint = (fp_override or first(params, "fp", "chrome")).strip() or "chrome"
grpc_service_name = first(params, "serviceName", "").strip()
grpc_authority = first(params, "authority", "").strip()
grpc_multi_mode = first(params, "mode", "").strip().lower() == "multi"

owner = json.loads(owner_profile_path.read_text(encoding="utf-8"))
stable = ((owner.get("stagedFallbacks") or {}).get("vlessReality")) or {}
if not isinstance(stable, dict):
    raise SystemExit(f"owner profile has no stagedFallbacks.vlessReality block: {owner_profile_path}")
owner_server_host = str(owner.get("serverHost") or "").strip()
owner_uuid = str(stable.get("uuid") or "").strip()
owner_public_key = str(stable.get("publicKey") or "").strip()
owner_short_id = str(stable.get("shortId") or "").strip()
owner_flow = str(stable.get("flow") or flow).strip() or flow
lab_flow = owner_flow if transport == "tcp" else ""
missing_owner = [name for name, value in (
    ("serverHost", owner_server_host),
    ("uuid", owner_uuid),
    ("publicKey", owner_public_key),
    ("shortId", owner_short_id),
) if not value]
if missing_owner:
    raise SystemExit(f"owner profile missing required reality fields: {', '.join(missing_owner)}")

config = json.loads(remote_config_path.read_text(encoding="utf-8"))
inbounds = config.get("inbounds")
if not isinstance(inbounds, list):
    raise SystemExit(f"remote xray config has no inbounds array: {remote_config_path}")

stable_reality = None
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
    stable_reality = {
        "privateKey": str(reality_settings.get("privateKey") or "").strip(),
        "shortIds": [str(value).strip() for value in (reality_settings.get("shortIds") or []) if str(value).strip()],
        "tag": str(inbound.get("tag") or "").strip() or "reality-in",
        "port": int(inbound.get("port") or 0),
    }
    break

if stable_reality is None or not stable_reality["privateKey"]:
    raise SystemExit("remote xray config has no usable stable vless+reality inbound")

private_key = stable_reality["privateKey"]
short_ids = stable_reality["shortIds"] or [owner_short_id]
tag = tag_override or f"reality-lab-{slugify(server_name)}-{transport}"

for inbound in inbounds:
    if not isinstance(inbound, dict):
        continue
    inbound_tag = str(inbound.get("tag") or "").strip()
    inbound_port = int(inbound.get("port") or 0)
    if inbound_port == lab_port and inbound_tag != tag:
        raise SystemExit(f"lab port {lab_port} is already used by inbound tag {inbound_tag!r}")

lab_inbound = {
    "tag": tag,
    "listen": "0.0.0.0",
    "port": lab_port,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": owner_uuid,
            }
        ],
        "decryption": "none",
    },
    "sniffing": {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"],
    },
    "streamSettings": {
        "network": transport,
        "security": "reality",
        "realitySettings": {
            "dest": dest,
            "privateKey": private_key,
            "serverNames": [server_name],
            "shortIds": short_ids,
            "show": False,
            "xver": 0,
        },
    },
}
if lab_flow:
    lab_inbound["settings"]["clients"][0]["flow"] = lab_flow
if transport == "grpc":
    grpc_settings = {}
    if grpc_service_name:
        grpc_settings["serviceName"] = grpc_service_name
    if grpc_authority:
        grpc_settings["authority"] = grpc_authority
    if grpc_multi_mode:
        grpc_settings["multiMode"] = True
    if grpc_settings:
        lab_inbound["streamSettings"]["grpcSettings"] = grpc_settings

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
lab_config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

query = {
    "encryption": "none",
    "type": transport,
    "security": "reality",
    "sni": server_name,
    "fp": fingerprint,
    "pbk": owner_public_key,
    "sid": owner_short_id,
}
if transport == "grpc":
    if grpc_service_name:
        query["serviceName"] = grpc_service_name
    if grpc_authority:
        query["authority"] = grpc_authority
    if grpc_multi_mode:
        query["mode"] = "multi"
if lab_flow:
    query["flow"] = lab_flow
query_text = urllib.parse.urlencode(query)
label = f"{label_prefix} | {server_name} | {transport}"
uri = f"vless://{owner_uuid}@{owner_server_host or remote_host}:{lab_port}?{query_text}#{urllib.parse.quote(label)}"
subscription_path.write_text(uri + "\n", encoding="utf-8")

generated_at = datetime.now(timezone.utc).isoformat()
backup_name = f"{remote_config_remote_path}.bak-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
metadata = {
    "kind": "odin-one-reality-whitelist-vps-lab-v1",
    "generatedAt": generated_at,
    "remoteHost": remote_host,
    "remoteConfigPath": remote_config_remote_path,
    "remoteServiceName": remote_service_name,
    "remoteBackupPath": backup_name,
    "candidate": {
        "uri": candidate_uri,
        "serverName": server_name,
        "host": parsed.hostname,
        "port": candidate_port,
        "transport": transport,
        "security": security,
        "flow": flow,
        "fingerprint": fingerprint,
        "grpcServiceName": grpc_service_name or None,
        "grpcAuthority": grpc_authority or None,
        "labFlow": lab_flow or None,
    },
    "lab": {
        "tag": tag,
        "port": lab_port,
        "dest": dest,
        "uri": uri,
        "flow": lab_flow or None,
    },
    "ownerReality": {
        "serverHost": owner_server_host,
        "uuid": owner_uuid,
        "publicKey": owner_public_key,
        "shortId": owner_short_id,
        "flow": owner_flow or None,
    },
}
lab_metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Reality Whitelist VPS Lab Rollout",
    "",
    f"- Generated at: `{generated_at}`",
    f"- Remote host: `{remote_host}`",
    f"- Candidate serverName: `{server_name}`",
    f"- Candidate transport: `{transport}`",
    f"- Candidate original endpoint: `{parsed.hostname}:{candidate_port}`",
    f"- Lab inbound tag: `{tag}`",
    f"- Lab inbound port: `{lab_port}`",
    f"- Lab dest: `{dest}`",
    f"- Remote config path: `{remote_config_remote_path}`",
    f"- Remote backup path: `{backup_name}`",
    "",
    "## Export",
    "",
    f"- Subscription: `{subscription_path}`",
    f"- Metadata: `{lab_metadata_path}`",
    "",
    "## Rollback",
    "",
    "```bash",
    f"cp {backup_name} {remote_config_remote_path} && systemctl restart {remote_service_name}",
    "```",
]
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

REMOTE_TMP_CONFIG="/tmp/odin-one-xray-server.lab.json"
"$SCP_BIN" "${SSH_OPTS[@]}" "$LAB_CONFIG_LOCAL" "${REMOTE_TARGET}:${REMOTE_TMP_CONFIG}"

REMOTE_BACKUP_PATH="$("$PYTHON_BIN" - "$LAB_METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload["remoteBackupPath"])
PY
)"
LAB_PORT_EFFECTIVE="$("$PYTHON_BIN" - "$LAB_METADATA_LOCAL" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding='utf-8'))
print(payload["lab"]["port"])
PY
)"
LISTEN_WAIT_ATTEMPTS="$LISTEN_WAIT_SECONDS"
if [[ "$LISTEN_WAIT_ATTEMPTS" -le 0 ]]; then
  LISTEN_WAIT_ATTEMPTS="1"
fi
cat > "$ROLLBACK_LOCAL" <<EOF
#!/bin/zsh
set -euo pipefail
ssh -i "$SSH_KEY" -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$REMOTE_TARGET" 'cp "$REMOTE_BACKUP_PATH" "$REMOTE_CONFIG_PATH" && systemctl restart "$REMOTE_SERVICE_NAME" && systemctl is-active "$REMOTE_SERVICE_NAME"'
EOF
chmod +x "$ROLLBACK_LOCAL"

remote_apply_script="$(cat <<EOF
set -euo pipefail
test -x /opt/whitelist/bin/xray
/opt/whitelist/bin/xray run -test -config '${REMOTE_TMP_CONFIG}'
cp '${REMOTE_CONFIG_PATH}' '${REMOTE_BACKUP_PATH}'
install -m 600 '${REMOTE_TMP_CONFIG}' '${REMOTE_CONFIG_PATH}'
systemctl restart '${REMOTE_SERVICE_NAME}'
systemctl is-active '${REMOTE_SERVICE_NAME}'
for _attempt in \$(seq 1 ${LISTEN_WAIT_ATTEMPTS}); do
  if ss -H -ltn | grep -Fq ':${LAB_PORT_EFFECTIVE}'; then
    break
  fi
  sleep 1
done
ss -H -ltn | grep -Fq ':${LAB_PORT_EFFECTIVE}'
rm -f '${REMOTE_TMP_CONFIG}'
EOF
)"
"$SSH_BIN" "${SSH_OPTS[@]}" "$REMOTE_TARGET" "$remote_apply_script"

if [[ "$SKIP_SMOKE" != "1" ]]; then
  SMOKE_EXIT=0
  if "$LOCAL_SMOKE_SCRIPT" \
    --subscription "$SUBSCRIPTION_LOCAL" \
    --engine "$SMOKE_ENGINE" \
    --limit 1 \
    --output-dir "${OUTPUT_DIR}/smoke"; then
    :
  else
    SMOKE_EXIT="$?"
    echo "Local smoke failed; rollout artifacts were still written." >&2
  fi
fi

echo "Reality whitelist VPS lab rollout complete."
echo "Summary: $SUMMARY_LOCAL"
echo "Subscription: $SUBSCRIPTION_LOCAL"
if [[ "$SKIP_SMOKE" != "1" ]]; then
  echo "Smoke summary: ${OUTPUT_DIR}/smoke/summary.md"
fi
if [[ "${SMOKE_EXIT:-0}" -ne 0 ]]; then
  exit "$SMOKE_EXIT"
fi
