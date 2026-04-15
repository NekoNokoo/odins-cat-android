#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
SCP_BIN="${SCP_BIN:-$(command -v scp || true)}"

SCRIPT_DIR="${0:A:h}"
PLAN_HELPER="${SCRIPT_DIR}/android-cdn-origin-lab.sh"
PRESET_HELPER="${SCRIPT_DIR}/android-reality-profile-preset.sh"

EDGE_USER="flatron109"
EDGE_HOST=""
EDGE_SSH_KEY=""
EDGE_PUBLIC_HOST=""
EDGE_PUBLIC_PORT="443"
EDGE_BIND_HOST=""
EDGE_CAMOUFLAGE_HOST=""
EDGE_CONFIG_ROOT="/opt/whitelist-edge-cdn-lab"
EDGE_SERVICE_NAME="whitelist-cdn-yandex-edge-lab.service"
EDGE_CADDY_BIN="/usr/bin/caddy"
OUTPUT_DIR=""
PREPARE_ONLY="0"

SOURCE_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-yandex-edge-rollout.sh (--preset <preset> | --profile-json <file> | --scaffold-json <file>) [options]

Required:
  One source selector:
    --preset <preset>
    --profile-json <file>
    --scaffold-json <file>

  For live deploy:
    --edge-host <host>
    --edge-ssh-key <path>

Options:
  --edge-user <user>              SSH username. Default: flatron109
  --edge-public-host <host>       Public hostname the handset should dial. Default: <edge-host>.sslip.io
  --edge-public-port <port>       Public HTTPS port. Default: 443
  --edge-bind-host <host>         Bind host for the front service. Default: edge public host
  --edge-camouflage-host <host>   Optional first-hop camouflage host such as ya.ru. Enables insecure catch-all TLS on the edge for lab validation.
  --edge-config-root <path>       Remote config root. Default: /opt/whitelist-edge-cdn-lab
  --edge-service-name <name>      systemd service name. Default: whitelist-cdn-yandex-edge-lab.service
  --edge-caddy-bin <path>         Remote caddy binary path. Default: /usr/bin/caddy
  --output-dir <dir>              Output directory. Default: /tmp/odin-one-android-cdn-yandex-edge-rollout/<stamp>-<label>
  --prepare-only                  Only generate plan/profile/service artifacts locally.
  --plan-file <file>              Forwarded to android-cdn-origin-lab.sh
  --plan-tag <tag>                Forwarded to android-cdn-origin-lab.sh
  --plan-index <n>                Forwarded to android-cdn-origin-lab.sh
  -h, --help                      Show this help.

Behavior:
  - normalizes the current cdn-anti-whitelist owner-lab plan
  - rewrites the visible front to a Yandex edge hostname while preserving the VPS origin front as the upstream
  - can optionally replace the first-hop TLS SNI / Host header with a camouflage hostname for lab validation
  - emits a patched owner profile that can drive the handset through the Yandex VM
  - optionally deploys a dedicated Caddy front + systemd service to the Yandex VM
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
    --edge-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_HOST="$2"
      shift 2
      ;;
    --edge-ssh-key)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_SSH_KEY="$2"
      shift 2
      ;;
    --edge-user)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_USER="$2"
      shift 2
      ;;
    --edge-public-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_PUBLIC_HOST="$2"
      shift 2
      ;;
    --edge-public-port)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_PUBLIC_PORT="$2"
      shift 2
      ;;
    --edge-bind-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_BIND_HOST="$2"
      shift 2
      ;;
    --edge-camouflage-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_CAMOUFLAGE_HOST="$2"
      shift 2
      ;;
    --edge-config-root)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_CONFIG_ROOT="$2"
      shift 2
      ;;
    --edge-service-name)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_SERVICE_NAME="$2"
      shift 2
      ;;
    --edge-caddy-bin)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_CADDY_BIN="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --prepare-only)
      PREPARE_ONLY="1"
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

if [[ ${#SOURCE_ARGS[@]} -lt 2 ]]; then
  echo "Provide one source selector." >&2
  usage >&2
  exit 1
fi

require_bin "$PYTHON_BIN" "python3"
require_bin "$DATE_BIN" "date"
require_bin "$MKDIR_BIN" "mkdir"

if [[ -z "$OUTPUT_DIR" ]]; then
  label="$("$PYTHON_BIN" - "${SOURCE_ARGS[@]}" <<'PY'
import re
import sys

label = "cdn-yandex-edge"
args = sys.argv[1:]
for index, value in enumerate(args[:-1]):
    if value in {"--preset", "--profile-json", "--scaffold-json"}:
        candidate = args[index + 1]
        label = candidate.rsplit("/", 1)[-1].rsplit(".", 1)[0] or label
        break
label = re.sub(r"[^a-z0-9._-]+", "-", label.lower()).strip("-") or "cdn-yandex-edge"
print(label[:64])
PY
)"
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-android-cdn-yandex-edge-rollout/${stamp}-${label}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

PACKAGE_DIR="${OUTPUT_DIR}/package"
EDGE_PLAN_LOCAL="${OUTPUT_DIR}/yandex-edge-plan.json"
PATCHED_PROFILE_LOCAL="${OUTPUT_DIR}/owner-profile.yandex-edge.json"
EDGE_CADDY_LOCAL="${OUTPUT_DIR}/Caddyfile"
EDGE_SERVICE_LOCAL="${OUTPUT_DIR}/${EDGE_SERVICE_NAME}"
SUMMARY_LOCAL="${OUTPUT_DIR}/summary.md"
ROLLBACK_LOCAL="${OUTPUT_DIR}/rollback.sh"
PRESET_PROFILE_LOCAL="${OUTPUT_DIR}/source-profile.json"

zsh "$PLAN_HELPER" "${SOURCE_ARGS[@]}" --output-dir "$PACKAGE_DIR" >/dev/null
PLAN_JSON="${PACKAGE_DIR}/plan.json"
require_file "$PLAN_JSON" "normalized plan"

SOURCE_KIND=""
SOURCE_PATH=""
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

if [[ -z "$EDGE_PUBLIC_HOST" && -n "$EDGE_HOST" ]]; then
  EDGE_PUBLIC_HOST="${EDGE_HOST//./-}.sslip.io"
fi
if [[ -z "$EDGE_BIND_HOST" ]]; then
  EDGE_BIND_HOST="$EDGE_PUBLIC_HOST"
fi

if [[ "$SOURCE_KIND" == "preset" ]]; then
  zsh "$PRESET_HELPER" "$SOURCE_PATH" > "$PRESET_PROFILE_LOCAL"
  SOURCE_KIND="profile-json"
  SOURCE_PATH="$PRESET_PROFILE_LOCAL"
fi

"$PYTHON_BIN" - "$PLAN_JSON" "$EDGE_PLAN_LOCAL" "$PATCHED_PROFILE_LOCAL" "$EDGE_CADDY_LOCAL" "$EDGE_SERVICE_LOCAL" "$SUMMARY_LOCAL" "$SOURCE_KIND" "$SOURCE_PATH" "$EDGE_HOST" "$EDGE_PUBLIC_HOST" "$EDGE_PUBLIC_PORT" "$EDGE_BIND_HOST" "$EDGE_CAMOUFLAGE_HOST" "$EDGE_CONFIG_ROOT" "$EDGE_SERVICE_NAME" "$EDGE_CADDY_BIN" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

plan_path = Path(sys.argv[1]).expanduser()
edge_plan_path = Path(sys.argv[2]).expanduser()
patched_profile_path = Path(sys.argv[3]).expanduser()
edge_caddy_path = Path(sys.argv[4]).expanduser()
edge_service_path = Path(sys.argv[5]).expanduser()
summary_path = Path(sys.argv[6]).expanduser()
source_kind = sys.argv[7].strip()
source_path_value = sys.argv[8].strip()
edge_host = sys.argv[9].strip()
edge_public_host = sys.argv[10].strip()
edge_public_port = int(sys.argv[11])
edge_bind_host = sys.argv[12].strip()
edge_camouflage_host = sys.argv[13].strip()
edge_config_root = sys.argv[14].strip()
edge_service_name = sys.argv[15].strip()
edge_caddy_bin = sys.argv[16].strip()

if not edge_public_host:
    raise SystemExit("edge public host is required")
if not edge_bind_host:
    edge_bind_host = edge_public_host

plan = json.loads(plan_path.read_text(encoding="utf-8"))
source_payload = None
source_runtime = {}
if source_kind == "profile-json" and source_path_value:
    source_payload = json.loads(Path(source_path_value).expanduser().read_text(encoding="utf-8"))
    source_runtime = ((source_payload.get("androidRuntime") or {}).get("cdnAntiWhitelist") or {})
if not edge_camouflage_host and isinstance(source_runtime, dict):
    edge_camouflage_host = str(source_runtime.get("camouflageHost") or "").strip()
edge_site_address = f"https://{edge_bind_host}"
if edge_public_port != 443:
    edge_site_address = f"{edge_site_address}:{edge_public_port}"
if edge_camouflage_host:
    edge_site_address = f":{edge_public_port}"
origin_front_host = str(plan.get("frontHost") or "").strip()
origin_front_port = int(plan.get("frontPort") or 443)
origin_front_path = str(plan.get("frontPath") or "/").strip() or "/"
origin_tls_server_name = origin_front_host
origin_host_header = origin_front_host
transport = str(source_runtime.get("transport") or plan.get("transport") or "websocket").strip().lower()

edge_plan = dict(plan)
edge_plan["transport"] = transport
edge_plan["provider"] = "yandex-edge"
edge_plan["frontHost"] = edge_public_host
edge_plan["frontPort"] = edge_public_port
edge_plan["connectHost"] = edge_host or edge_public_host
edge_plan["connectPort"] = edge_public_port
edge_plan["tlsServerName"] = edge_camouflage_host or edge_public_host
edge_plan["httpHostHeader"] = edge_camouflage_host or edge_public_host
edge_plan["tlsAllowInsecure"] = bool(edge_camouflage_host)
edge_plan["frontTag"] = f"yandex-edge-{edge_public_host.replace('.', '-')}"
if edge_camouflage_host:
    edge_plan["camouflageHost"] = edge_camouflage_host
edge_plan["upstreamFront"] = {
    "host": origin_front_host,
    "port": origin_front_port,
    "path": origin_front_path,
    "tlsServerName": origin_tls_server_name,
    "hostHeader": origin_host_header,
}
edge_plan_path.write_text(json.dumps(edge_plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if source_payload is not None:
    android_runtime = source_payload.setdefault("androidRuntime", {})
    cdn_runtime = android_runtime.setdefault("cdnAntiWhitelist", {})
    cdn_runtime["transport"] = transport
    cdn_runtime["frontHost"] = edge_public_host
    cdn_runtime["frontPort"] = edge_public_port
    cdn_runtime["connectHost"] = edge_plan["connectHost"]
    cdn_runtime["connectPort"] = edge_public_port
    cdn_runtime["frontPath"] = edge_plan["frontPath"]
    cdn_runtime["tlsServerName"] = edge_camouflage_host or edge_public_host
    cdn_runtime["hostHeader"] = edge_camouflage_host or edge_public_host
    cdn_runtime["frontTag"] = edge_plan["frontTag"]
    front_pool = cdn_runtime.get("frontPool")
    if not isinstance(front_pool, list) or not front_pool:
      front_pool = [{}]
      cdn_runtime["frontPool"] = front_pool
    selected = front_pool[0]
    selected["provider"] = "yandex-edge"
    selected["host"] = edge_public_host
    selected["port"] = edge_public_port
    selected["path"] = edge_plan["frontPath"]
    selected["tlsServerName"] = edge_camouflage_host or edge_public_host
    selected["hostHeader"] = edge_camouflage_host or edge_public_host
    selected["tlsAllowInsecure"] = bool(edge_camouflage_host)
    selected["connectHost"] = edge_plan["connectHost"]
    selected["connectPort"] = edge_public_port
    selected["tag"] = edge_plan["frontTag"]
    if edge_camouflage_host:
        cdn_runtime["camouflageHost"] = edge_camouflage_host
        cdn_runtime["tlsAllowInsecure"] = True
    else:
        cdn_runtime["tlsAllowInsecure"] = False
    patched_profile_path.write_text(json.dumps(source_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

tls_block = "    tls internal\n\n" if edge_camouflage_host else ""

edge_caddy = f"""{{
    admin off
}}

{edge_site_address} {{
{tls_block}\
    log {{
        output stdout
        format json
    }}

    @odin_front path {edge_plan['frontPath']} {edge_plan['frontPath']}/*
    handle @odin_front {{
        reverse_proxy https://{origin_front_host}:{origin_front_port} {{
            flush_interval -1
            header_up Host {origin_host_header}
            header_up X-Forwarded-Host {{host}}
            header_up X-Forwarded-Proto https
            header_up X-Odin-Edge yandex
            header_up X-Odin-Edge-Host {edge_public_host}
            transport http {{
                tls_server_name {origin_tls_server_name}
            }}
        }}
    }}

    respond "not found" 404
}}
"""
edge_caddy_path.write_text(edge_caddy, encoding="utf-8")

service_body = f"""[Unit]
Description=Odin One Yandex CDN edge front
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={edge_caddy_bin} run --config {edge_config_root}/Caddyfile --adapter caddyfile
ExecReload={edge_caddy_bin} reload --config {edge_config_root}/Caddyfile --adapter caddyfile
Restart=always
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"""
edge_service_path.write_text(service_body, encoding="utf-8")

generated_at = datetime.now(timezone.utc).isoformat()
summary_lines = [
    "# Android CDN Yandex Edge Rollout",
    "",
    f"- Generated at: `{generated_at}`",
    f"- Edge host: `{edge_host or edge_public_host}`",
    f"- Edge public host: `{edge_public_host}`",
    f"- Edge public port: `{edge_public_port}`",
    f"- Transport: `{transport}`",
    f"- Camouflage host: `{edge_camouflage_host or 'disabled'}`",
    f"- Visible handset front: `https://{edge_public_host}:{edge_public_port}{edge_plan['frontPath']}`",
    f"- Upstream front: `https://{origin_front_host}:{origin_front_port}{origin_front_path}`",
    "",
    "## Artifacts",
    f"- Package directory: `{plan_path.parent}`",
    f"- Yandex edge plan: `{edge_plan_path}`",
    f"- Patched owner profile: `{patched_profile_path if patched_profile_path.exists() else 'n/a (scaffold source)'}`",
    f"- Edge Caddyfile: `{edge_caddy_path}`",
    f"- Edge service: `{edge_service_path}`",
    "",
    "## Notes",
    "- This keeps the stable direct REALITY and Yandex edge proxy lanes untouched.",
    "- The Yandex VM becomes the visible HTTPS front while the VPS stays the upstream origin front.",
    "- When a camouflage host is set, the handset uses that host for TLS SNI / HTTP Host while still dialing the Yandex IP directly.",
    "- `xhttp` can already be exercised server-side through this edge, even if the current Android runtime still needs `httpupgrade` as the runnable transport.",
]
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

if [[ "$PREPARE_ONLY" == "1" ]]; then
  cat > "$ROLLBACK_LOCAL" <<'EOF'
#!/bin/zsh
set -euo pipefail
echo "Prepare-only mode: nothing was deployed."
EOF
  chmod +x "$ROLLBACK_LOCAL"
  echo "Prepared Android CDN Yandex edge rollout artifacts."
  echo "Summary: $SUMMARY_LOCAL"
  exit 0
fi

require_bin "$SSH_BIN" "ssh"
require_bin "$SCP_BIN" "scp"
require_file "$EDGE_SSH_KEY" "edge SSH key"
if [[ -z "$EDGE_HOST" ]]; then
  echo "Provide --edge-host for live deploy." >&2
  exit 1
fi

SSH_OPTS=(
  -i "$EDGE_SSH_KEY"
  -o StrictHostKeyChecking=yes
)
EDGE_TARGET="${EDGE_USER}@${EDGE_HOST}"

REMOTE_CADDY_PATH="${EDGE_CONFIG_ROOT}/Caddyfile"
REMOTE_SERVICE_PATH="/etc/systemd/system/${EDGE_SERVICE_NAME}"
REMOTE_BACKUP_DIR="${EDGE_CONFIG_ROOT}/backups"
REMOTE_BACKUP_PATH="${REMOTE_BACKUP_DIR}/Caddyfile.bak-$("$DATE_BIN" '+%Y%m%d-%H%M%S')"

"$SCP_BIN" "${SSH_OPTS[@]}" "$EDGE_CADDY_LOCAL" "${EDGE_TARGET}:/tmp/odin-one-cdn-yandex-edge.Caddyfile"
"$SCP_BIN" "${SSH_OPTS[@]}" "$EDGE_SERVICE_LOCAL" "${EDGE_TARGET}:/tmp/${EDGE_SERVICE_NAME}"

remote_apply_script="$(cat <<EOF
set -euo pipefail
sudo install -d -m 755 '${EDGE_CONFIG_ROOT}' '${REMOTE_BACKUP_DIR}'
if ! command -v caddy >/dev/null 2>&1 && [[ ! -x '${EDGE_CADDY_BIN}' ]]; then
  sudo apt-get update
  sudo apt-get install -y caddy
fi
if [[ -f '${REMOTE_CADDY_PATH}' ]]; then
  sudo cp '${REMOTE_CADDY_PATH}' '${REMOTE_BACKUP_PATH}'
fi
sudo install -m 644 /tmp/odin-one-cdn-yandex-edge.Caddyfile '${REMOTE_CADDY_PATH}'
sudo install -m 644 /tmp/${EDGE_SERVICE_NAME} '${REMOTE_SERVICE_PATH}'
sudo '${EDGE_CADDY_BIN}' validate --config '${REMOTE_CADDY_PATH}' --adapter caddyfile
sudo systemctl daemon-reload
sudo systemctl enable --now '${EDGE_SERVICE_NAME}'
sudo systemctl restart '${EDGE_SERVICE_NAME}'
sudo systemctl is-active '${EDGE_SERVICE_NAME}'
sudo ss -H -ltn | grep -Eq '(^|\\]|:)${EDGE_PUBLIC_PORT}\$'
rm -f /tmp/odin-one-cdn-yandex-edge.Caddyfile /tmp/${EDGE_SERVICE_NAME}
EOF
)"
"$SSH_BIN" "${SSH_OPTS[@]}" "$EDGE_TARGET" "$remote_apply_script"

cat > "$ROLLBACK_LOCAL" <<EOF
#!/bin/zsh
set -euo pipefail
ssh -i "$EDGE_SSH_KEY" -o StrictHostKeyChecking=yes "$EDGE_TARGET" 'if [[ -f "$REMOTE_BACKUP_PATH" ]]; then sudo cp "$REMOTE_BACKUP_PATH" "$REMOTE_CADDY_PATH"; sudo systemctl restart "$EDGE_SERVICE_NAME"; fi'
EOF
chmod +x "$ROLLBACK_LOCAL"

echo "Android CDN Yandex edge rollout complete."
echo "Summary: $SUMMARY_LOCAL"
