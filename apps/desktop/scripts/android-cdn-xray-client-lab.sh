#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

SCRIPT_DIR="${0:A:h}"
PLAN_HELPER="${SCRIPT_DIR}/android-cdn-origin-lab.sh"
PRESET_HELPER="${SCRIPT_DIR}/android-reality-profile-preset.sh"

SOURCE_ARGS=()
OUTPUT_DIR=""
OWNER_PROFILE_JSON="${ODIN_ONE_CDN_OWNER_PROFILE_JSON:-}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-xray-client-lab.sh (--preset <preset> | --profile-json <file> | --scaffold-json <file>) [options]

Required:
  One source selector:
    --preset <preset>
    --profile-json <file>
    --scaffold-json <file>

Options:
  --output-dir <dir>      Output directory. Default: /tmp/odin-one-android-cdn-xray-client/<stamp>-<label>
  --owner-profile-json    Full owner/access profile JSON carrying stagedFallbacks.vlessReality.
  --plan-file <file>      Forwarded to android-cdn-origin-lab.sh
  --plan-tag <tag>        Forwarded to android-cdn-origin-lab.sh
  --plan-index <n>        Forwarded to android-cdn-origin-lab.sh
  -h, --help              Show this help.

Behavior:
  - normalizes the hidden CDN owner-lab plan via android-cdn-origin-lab.sh
  - emits a concrete Xray client config for websocket/xhttp/httpupgrade
  - keeps the current Android libbox/httpupgrade lane untouched
  - prepares the next additive step toward a native Android Xray xhttp lane
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
    --preset|--profile-json|--scaffold-json|--plan-file|--plan-tag|--plan-index|--owner-profile-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      if [[ "$1" == "--owner-profile-json" ]]; then
        OWNER_PROFILE_JSON="$2"
      else
        SOURCE_ARGS+=("$1" "$2")
      fi
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

label = "cdn-xray-client"
args = sys.argv[1:]
for index, value in enumerate(args[:-1]):
    if value in {"--preset", "--profile-json", "--scaffold-json"}:
        candidate = args[index + 1]
        label = candidate.rsplit("/", 1)[-1].rsplit(".", 1)[0] or label
        break
label = re.sub(r"[^a-z0-9._-]+", "-", label.lower()).strip("-") or "cdn-xray-client"
print(label[:64])
PY
)"
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-android-cdn-xray-client/${stamp}-${label}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

PACKAGE_DIR="${OUTPUT_DIR}/package"
PLAN_JSON="${PACKAGE_DIR}/plan.json"
PROFILE_JSON="${OUTPUT_DIR}/profile.json"
XRAY_CONFIG_JSON="${OUTPUT_DIR}/xray-client.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

zsh "$PLAN_HELPER" "${SOURCE_ARGS[@]}" --output-dir "$PACKAGE_DIR" >/dev/null
require_file "$PLAN_JSON" "normalized plan"

SOURCE_KIND=""
SOURCE_PATH=""
index=1
while [[ $index -le ${#SOURCE_ARGS[@]} ]]; do
  flag="${SOURCE_ARGS[$index]}"
  if [[ "$flag" == "--preset" || "$flag" == "--profile-json" || "$flag" == "--scaffold-json" ]]; then
    SOURCE_KIND="${flag#--}"
    next_index=$((index + 1))
    SOURCE_PATH="${SOURCE_ARGS[$next_index]}"
    break
  fi
  index=$((index + 1))
done

if [[ "$SOURCE_KIND" == "preset" ]]; then
  zsh "$PRESET_HELPER" "$SOURCE_PATH" > "$PROFILE_JSON"
elif [[ "$SOURCE_KIND" == "profile-json" ]]; then
  cp "$SOURCE_PATH" "$PROFILE_JSON"
fi

OWNER_PROFILE_LOCAL="${OUTPUT_DIR}/owner-profile.full.json"
if [[ -n "$OWNER_PROFILE_JSON" ]]; then
  cp "$OWNER_PROFILE_JSON" "$OWNER_PROFILE_LOCAL"
fi

"$PYTHON_BIN" - "$PLAN_JSON" "$PROFILE_JSON" "$OWNER_PROFILE_LOCAL" "$XRAY_CONFIG_JSON" "$SUMMARY_MD" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

plan_path = Path(sys.argv[1]).expanduser()
profile_path = Path(sys.argv[2]).expanduser()
owner_profile_path = Path(sys.argv[3]).expanduser()
config_path = Path(sys.argv[4]).expanduser()
summary_path = Path(sys.argv[5]).expanduser()

plan = json.loads(plan_path.read_text(encoding="utf-8"))
profile = {}
if profile_path.is_file():
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
owner_profile = {}
if owner_profile_path.is_file():
    owner_profile = json.loads(owner_profile_path.read_text(encoding="utf-8"))
runtime = ((profile.get("androidRuntime") or {}).get("cdnAntiWhitelist") or {})
front_pool = runtime.get("frontPool") or []
selected_front = front_pool[0] if front_pool else {}

fallbacks = (owner_profile.get("stagedFallbacks") or profile.get("stagedFallbacks") or {})
reality = (fallbacks.get("vlessReality") or {})
if not reality:
    raise SystemExit("owner profile does not contain stagedFallbacks.vlessReality; pass --owner-profile-json with a full owner/access profile")

uuid = str(reality.get("uuid") or "").strip()
public_key = str(reality.get("publicKey") or "").strip()
short_id = str(reality.get("shortId") or "").strip()
server_name = str(reality.get("serverName") or "").strip()
flow = str(reality.get("flow") or "").strip()
if not all([uuid, public_key, short_id, server_name]):
    raise SystemExit("vlessReality fallback is missing required REALITY fields")

transport = str(runtime.get("transport") or plan.get("transport") or "websocket").strip().lower()
xhttp_mode = str(runtime.get("xhttpMode") or plan.get("xhttpMode") or "").strip().lower()
tla = runtime.get("tlsAlpn") or plan.get("tlsAlpn") or []
tls_alpn = [str(item).strip().lower() for item in tla if str(item).strip()]
xmux_max_concurrency = runtime.get("xmuxMaxConcurrency") or plan.get("xmuxMaxConcurrency")
xmux_hmax_request_times = runtime.get("xmuxHMaxRequestTimes") or plan.get("xmuxHMaxRequestTimes")
xmux_hmax_reusable_secs = runtime.get("xmuxHMaxReusableSecs") or plan.get("xmuxHMaxReusableSecs")
front_host = str(selected_front.get("host") or runtime.get("frontHost") or plan.get("frontHost") or "").strip()
connect_host = str(selected_front.get("connectHost") or runtime.get("connectHost") or plan.get("connectHost") or front_host).strip()
connect_port = int(selected_front.get("connectPort") or runtime.get("connectPort") or plan.get("connectPort") or plan.get("frontPort") or 443)
front_path = str(selected_front.get("path") or runtime.get("frontPath") or plan.get("frontPath") or "/").strip() or "/"
tls_server_name = str(selected_front.get("tlsServerName") or runtime.get("tlsServerName") or plan.get("tlsServerName") or front_host).strip() or front_host
http_host_header = str(selected_front.get("hostHeader") or runtime.get("httpHostHeader") or plan.get("httpHostHeader") or front_host).strip() or front_host
tls_allow_insecure = bool(
    selected_front.get("tlsAllowInsecure")
    if "tlsAllowInsecure" in selected_front
    else selected_front.get("allowInsecure")
    if "allowInsecure" in selected_front
    else runtime.get("tlsAllowInsecure")
    if "tlsAllowInsecure" in runtime
    else runtime.get("allowInsecure")
    if "allowInsecure" in runtime
    else plan.get("tlsAllowInsecure")
    if "tlsAllowInsecure" in plan
    else plan.get("allowInsecure")
)
server_host = str(owner_profile.get("serverHost") or profile.get("serverHost") or "").strip()

if transport == "xhttp":
    stream_settings = {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
            "serverName": tls_server_name,
            "allowInsecure": tls_allow_insecure,
        },
        "xhttpSettings": {
            "path": front_path,
            "host": http_host_header,
        },
    }
    if xhttp_mode:
        stream_settings["xhttpSettings"]["mode"] = xhttp_mode
    if tls_alpn:
        stream_settings["tlsSettings"]["alpn"] = tls_alpn
    xmux = {}
    if xmux_max_concurrency:
        xmux["maxConcurrency"] = int(xmux_max_concurrency)
    if xmux_hmax_request_times:
        xmux["hMaxRequestTimes"] = int(xmux_hmax_request_times)
    if xmux_hmax_reusable_secs:
        xmux["hMaxReusableSecs"] = int(xmux_hmax_reusable_secs)
    if xmux:
        stream_settings["xhttpSettings"]["xmux"] = xmux
elif transport == "httpupgrade":
    stream_settings = {
        "network": "httpupgrade",
        "security": "tls",
        "tlsSettings": {
            "serverName": tls_server_name,
            "allowInsecure": tls_allow_insecure,
        },
        "httpupgradeSettings": {
            "path": front_path,
            "host": http_host_header,
        },
    }
else:
    stream_settings = {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
            "serverName": tls_server_name,
            "allowInsecure": tls_allow_insecure,
        },
        "wsSettings": {
            "path": front_path,
            "headers": {
                "Host": http_host_header,
            },
        },
    }

xray_config = {
    "log": {
        "loglevel": "warning",
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": 58371,
            "protocol": "socks",
            "settings": {
                "udp": True,
            },
        }
    ],
    "outbounds": [
        {
            "tag": "main-out",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": connect_host,
                        "port": connect_port,
                        "users": [
                            {
                                "id": uuid,
                                "encryption": "none",
                            }
                        ],
                    }
                ]
            },
            "streamSettings": stream_settings,
        }
    ],
}
config_path.write_text(json.dumps(xray_config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

generated_at = datetime.now(timezone.utc).isoformat()
summary = "\n".join(
    [
        "# Android CDN Xray Client Lab",
        "",
        f"- Generated at: `{generated_at}`",
        f"- Transport: `{transport}`",
        f"- XHTTP mode: `{xhttp_mode or 'default'}`",
        f"- TLS ALPN: `{','.join(tls_alpn) if tls_alpn else 'default'}`",
        f"- XMUX maxConcurrency: `{xmux_max_concurrency or 'default'}`",
        f"- XMUX hMaxRequestTimes: `{xmux_hmax_request_times or 'default'}`",
        f"- XMUX hMaxReusableSecs: `{xmux_hmax_reusable_secs or 'default'}`",
        f"- Visible front: `{front_host}:{plan.get('frontPort')}`",
        f"- Dial target: `{connect_host}:{connect_port}`",
        f"- Front path: `{front_path}`",
        f"- TLS serverName: `{tls_server_name}`",
        f"- TLS allowInsecure: `{str(tls_allow_insecure).lower()}`",
        f"- HTTP Host: `{http_host_header}`",
        f"- Stable origin host: `{server_host or 'n/a'}`",
        "",
        "## Artifacts",
        f"- Normalized plan: `{plan_path}`",
        f"- Source preset/profile: `{profile_path if profile_path.is_file() else 'n/a (scaffold source)'}`",
        f"- Owner profile: `{owner_profile_path if owner_profile_path.is_file() else 'n/a'}`",
        f"- Xray client config: `{config_path}`",
        "",
        "## Notes",
        "- This is an owner-lab Xray-native artifact for the next Android xhttp step.",
        "- It does not replace the current runnable libbox/httpupgrade lane.",
        "- Use it to validate Xray-side transport schema before wiring a native Android Xray process.",
    ]
)
summary_path.write_text(summary + "\n", encoding="utf-8")
PY

echo "Prepared Android CDN Xray client lab artifacts."
echo "Summary: $SUMMARY_MD"
