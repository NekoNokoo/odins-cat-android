#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SCRIPT_DIR="${0:A:h}"
PRESET_HELPER="${SCRIPT_DIR}/android-reality-profile-preset.sh"

TMP_DIR="${TMPDIR:-/tmp}"
PRESET_FILE=""
PLAN_FILE=""
PLAN_TAG=""
PLAN_INDEX=""
PRESET_NAME=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset <preset> [--plan-file <file>] [--plan-tag <tag>] [--plan-index <n>] [--output-dir <dir>]
  apps/desktop/scripts/android-cdn-origin-lab.sh --profile-json <file> [--output-dir <dir>]
  apps/desktop/scripts/android-cdn-origin-lab.sh --scaffold-json <file> [--output-dir <dir>]

Examples:
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-ws-lab
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-xhttp-lab
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-httpupgrade-lab
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-ws-lab --plan-file /tmp/odin-one-cdn-plan.json --plan-tag front-primary
  apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-ws-lab --output-dir /tmp/odin-one-android-cdn-origin-lab

Builds an owner-lab origin package for the hidden Android cdn-anti-whitelist family.
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

cleanup() {
  [[ -n "$PRESET_FILE" ]] && rm -f "$PRESET_FILE"
}
trap cleanup EXIT INT TERM

make_temp_file() {
  local prefix="$1"
  mktemp "${TMP_DIR%/}/${prefix}.XXXXXX"
}

SOURCE_KIND=""
SOURCE_PATH=""
SOURCE_LABEL=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="profile"
      PRESET_NAME="$2"
      SOURCE_LABEL="preset:$2"
      SOURCE_PATH=""
      shift 2
      ;;
    --profile-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="profile"
      SOURCE_PATH="$2"
      SOURCE_LABEL="$2"
      shift 2
      ;;
    --scaffold-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="scaffold"
      SOURCE_PATH="$2"
      SOURCE_LABEL="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --plan-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_FILE="$2"
      shift 2
      ;;
    --plan-tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_TAG="$2"
      shift 2
      ;;
    --plan-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PLAN_INDEX="$2"
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

if [[ -z "$SOURCE_KIND" || ( -z "$SOURCE_PATH" && -z "$PRESET_NAME" ) ]]; then
  usage >&2
  exit 1
fi

if [[ -n "$PLAN_FILE" ]]; then
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "Plan file not found: $PLAN_FILE" >&2
    exit 1
  fi
  export ODIN_ONE_CDN_PLAN_FILE="$PLAN_FILE"
fi
if [[ -n "$PLAN_TAG" ]]; then
  export ODIN_ONE_CDN_PLAN_SELECT_TAG="$PLAN_TAG"
fi
if [[ -n "$PLAN_INDEX" ]]; then
  export ODIN_ONE_CDN_PLAN_SELECT_INDEX="$PLAN_INDEX"
fi

require_bin "$PYTHON_BIN" "python3"
if [[ -n "$PRESET_NAME" ]]; then
  PRESET_FILE="$(make_temp_file "odin-one-android-cdn-origin-lab-preset")"
  zsh "$PRESET_HELPER" "$PRESET_NAME" >"$PRESET_FILE"
  SOURCE_PATH="$PRESET_FILE"
fi
if [[ "$SOURCE_KIND" == "profile" && ! -x "$PRESET_HELPER" && "$SOURCE_PATH" == "$PRESET_FILE" ]]; then
  echo "Preset helper not found: ${PRESET_HELPER}" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "Source file not found: $SOURCE_PATH" >&2
  exit 1
fi

if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

"$PYTHON_BIN" - "$SOURCE_KIND" "$SOURCE_PATH" "$SOURCE_LABEL" "$OUTPUT_DIR" <<'PY'
import json
import sys
from pathlib import Path


def normalize_path(value: str, default: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return default
    return raw if raw.startswith("/") else f"/{raw}"


def first_text(*values) -> str:
    for value in values:
        text = ("" if value is None else str(value)).strip()
        if text:
            return text
    return ""


def first_port(*values, default: int) -> int:
    for value in values:
        try:
            port = int(value)
        except (TypeError, ValueError):
            continue
        if port > 0:
            return port
    return default


def derive_core_loopback_port(origin_port: int, origin_scheme: str) -> int:
    if origin_port in {80, 443}:
        return 18080 if origin_scheme == "http" else 18443
    return origin_port


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8", errors="replace"))


def extract_from_profile(raw: dict) -> dict:
    runtime = ((raw.get("androidRuntime") or {}).get("cdnAntiWhitelist") or {})
    front_pool = runtime.get("frontPool") or []
    selected = front_pool[0] if front_pool else {}
    origin = runtime.get("origin") or {}
    mode = (runtime.get("mode") or "scaffold").strip().lower()
    transport = (runtime.get("transport") or "websocket").strip().lower()
    activation = "active" if mode == "lab" and transport in {"websocket", "xhttp", "httpupgrade"} else "scaffold_only"
    front_host = first_text(selected.get("host"), runtime.get("frontHost"))
    front_port = first_port(selected.get("port"), runtime.get("frontPort"), default=443)
    return {
        "runtimeFamily": "cdn-anti-whitelist",
        "configMode": mode,
        "activationState": activation,
        "provider": (selected.get("provider") or runtime.get("provider") or "generic").strip().lower(),
        "transport": transport,
        "xhttpMode": (runtime.get("xhttpMode") or ((runtime.get("xhttp") or {}).get("mode") if isinstance(runtime.get("xhttp"), dict) else "") or "").strip().lower(),
        "tlsAlpn": runtime.get("tlsAlpn") or (((runtime.get("xhttp") or {}).get("alpn")) if isinstance(runtime.get("xhttp"), dict) else []) or [],
        "xmuxMaxConcurrency": runtime.get("xmuxMaxConcurrency") or (((runtime.get("xmux") or {}).get("maxConcurrency")) if isinstance(runtime.get("xmux"), dict) else None),
        "xmuxHMaxRequestTimes": runtime.get("xmuxHMaxRequestTimes") or (((runtime.get("xmux") or {}).get("hMaxRequestTimes")) if isinstance(runtime.get("xmux"), dict) else None),
        "xmuxHMaxReusableSecs": runtime.get("xmuxHMaxReusableSecs") or (((runtime.get("xmux") or {}).get("hMaxReusableSecs")) if isinstance(runtime.get("xmux"), dict) else None),
        "frontHost": front_host,
        "frontPort": front_port,
        "connectHost": first_text(
            selected.get("connectHost"),
            selected.get("dialHost"),
            selected.get("serverHost"),
            selected.get("address"),
            selected.get("server"),
            runtime.get("frontConnectHost"),
            runtime.get("cdnConnectHost"),
            runtime.get("connectHost"),
            runtime.get("dialHost"),
            runtime.get("serverHost"),
            runtime.get("address"),
            front_host,
        ),
        "connectPort": first_port(
            selected.get("connectPort"),
            selected.get("dialPort"),
            selected.get("serverPort"),
            runtime.get("frontConnectPort"),
            runtime.get("cdnConnectPort"),
            runtime.get("connectPort"),
            runtime.get("dialPort"),
            runtime.get("serverPort"),
            front_port,
            default=front_port,
        ),
        "frontPath": normalize_path(selected.get("path") or runtime.get("frontPath") or "/", "/"),
        "tlsServerName": first_text(selected.get("tlsServerName"), runtime.get("tlsServerName"), front_host),
        "tlsAllowInsecure": bool(selected.get("tlsAllowInsecure", runtime.get("tlsAllowInsecure", runtime.get("allowInsecure", False)))),
        "httpHostHeader": first_text(selected.get("hostHeader"), selected.get("httpHostHeader"), runtime.get("hostHeader"), runtime.get("httpHostHeader"), front_host),
        "frontTag": (selected.get("tag") or runtime.get("frontTag") or "").strip(),
        "originHost": (origin.get("host") or runtime.get("originHost") or "origin.example.com").strip(),
        "originPort": int(origin.get("port") or runtime.get("originPort") or 443),
        "originScheme": ((origin.get("scheme") or runtime.get("originScheme") or "https").strip().lower()),
        "originPath": normalize_path(origin.get("path") or runtime.get("originPath") or selected.get("path") or "/", "/"),
        "bootstrap": (runtime.get("bootstrap") or "direct-reality").strip().lower(),
    }


def extract_from_scaffold(raw: dict) -> dict:
    selected = raw.get("selectedFront") or {}
    front_host = first_text(raw.get("frontHost"), selected.get("host"))
    front_port = first_port(raw.get("frontPort"), selected.get("port"), default=443)
    return {
        "runtimeFamily": (raw.get("runtimeFamily") or "cdn-anti-whitelist").strip(),
        "configMode": (raw.get("configMode") or "scaffold").strip().lower(),
        "activationState": (raw.get("activationState") or "scaffold_only").strip().lower(),
        "provider": (raw.get("provider") or selected.get("provider") or "generic").strip().lower(),
        "transport": (raw.get("transport") or "websocket").strip().lower(),
        "xhttpMode": (raw.get("xhttpMode") or "").strip().lower(),
        "tlsAlpn": raw.get("tlsAlpn") or [],
        "xmuxMaxConcurrency": raw.get("xmuxMaxConcurrency"),
        "xmuxHMaxRequestTimes": raw.get("xmuxHMaxRequestTimes"),
        "xmuxHMaxReusableSecs": raw.get("xmuxHMaxReusableSecs"),
        "frontHost": front_host,
        "frontPort": front_port,
        "connectHost": first_text(
            selected.get("connectHost"),
            selected.get("dialHost"),
            selected.get("serverHost"),
            selected.get("address"),
            selected.get("server"),
            raw.get("frontConnectHost"),
            raw.get("connectHost"),
            raw.get("cdnConnectHost"),
            raw.get("dialHost"),
            raw.get("serverHost"),
            raw.get("address"),
            front_host,
        ),
        "connectPort": first_port(
            selected.get("connectPort"),
            selected.get("dialPort"),
            selected.get("serverPort"),
            raw.get("frontConnectPort"),
            raw.get("connectPort"),
            raw.get("cdnConnectPort"),
            raw.get("dialPort"),
            raw.get("serverPort"),
            front_port,
            default=front_port,
        ),
        "frontPath": normalize_path(raw.get("frontPath") or selected.get("path") or "/", "/"),
        "tlsServerName": first_text(raw.get("tlsServerName"), selected.get("tlsServerName"), front_host),
        "tlsAllowInsecure": bool(raw.get("tlsAllowInsecure", selected.get("tlsAllowInsecure", selected.get("allowInsecure", False)))),
        "httpHostHeader": first_text(raw.get("httpHostHeader"), selected.get("httpHostHeader"), selected.get("hostHeader"), front_host),
        "frontTag": (raw.get("frontTag") or selected.get("tag") or "").strip(),
        "originHost": (raw.get("originHost") or "origin.example.com").strip(),
        "originPort": int(raw.get("originPort") or 443),
        "originScheme": (raw.get("originScheme") or "https").strip().lower(),
        "originPath": normalize_path(raw.get("originPath") or "/", "/"),
        "bootstrap": (raw.get("bootstrap") or "direct-reality").strip().lower(),
    }


def build_caddy(plan: dict) -> str:
    front_host = plan["frontHost"] or "REPLACE_FRONT_HOST"
    front_path = plan["frontPath"]
    origin_path = plan["originPath"]
    origin_port = plan["coreLoopbackPort"]
    host_header = plan["httpHostHeader"] or front_host
    front_tag = plan["frontTag"] or "owner-lab"
    transport = (plan.get("transport") or "").strip().lower()
    proxy_header_lines = [
        f"            header_up Host {host_header}",
        "            header_up X-Forwarded-Host {host}",
        "            header_up X-Forwarded-Proto https",
        f"            header_up X-Odin-Front-Tag {front_tag}",
    ]
    proxy_headers = "\n".join(proxy_header_lines)
    return f"""https://{front_host} {{
    log {{
        output stdout
        format json
    }}

    @odin_front path {front_path} {front_path}/*
    handle @odin_front {{
        uri replace {front_path} {origin_path}
        reverse_proxy 127.0.0.1:{origin_port} {{
            flush_interval -1
{proxy_headers}
        }}
    }}

    respond "not found" 404
}}
"""


def build_nginx(plan: dict) -> str:
    front_host = plan["frontHost"] or "REPLACE_FRONT_HOST"
    front_path = plan["frontPath"]
    origin_path = plan["originPath"]
    origin_port = plan["coreLoopbackPort"]
    host_header = plan["httpHostHeader"] or front_host
    transport = (plan.get("transport") or "").strip().lower()
    upgrade_block = ""
    if transport in {"websocket", "httpupgrade"}:
        upgrade_block = """        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
"""
    map_block = ""
    if transport in {"websocket", "httpupgrade"}:
        map_block = """map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

"""
    return f"""{map_block}server {{
    listen 443 ssl http2;
    server_name {front_host};

    ssl_certificate     /etc/letsencrypt/live/{front_host}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{front_host}/privkey.pem;

    location ^~ {front_path} {{
        rewrite ^{front_path}(.*)$ {origin_path}$1 break;
        proxy_pass http://127.0.0.1:{origin_port};
        proxy_set_header Host {host_header};
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
{upgrade_block}    }}

    location / {{
        return 404;
    }}
}}
"""


def build_core_requirements(plan: dict) -> str:
    lines = [
        "# Core Inbound Requirements",
        "",
        f"- Runtime family: `{plan['runtimeFamily']}`",
        f"- Lab mode: `{plan['configMode']}`",
        f"- Activation state: `{plan['activationState']}`",
        f"- Transport: `{plan['transport']}`",
        f"- Visible front: `{plan['frontHost']}:{plan['frontPort']}`",
        f"- Client dial target: `{plan['connectHost']}:{plan['connectPort']}`",
        f"- Public origin port stays `{plan['originPort']}` at the reverse-proxy layer.",
        f"- Bind a dedicated owner-only loopback inbound on `127.0.0.1:{plan['coreLoopbackPort']}`.",
        f"- Accept the hidden path `{plan['originPath']}` for the whitelist-front lane.",
        "- Use the same owner UUID as `stagedFallbacks.vlessReality.uuid` from the access profile.",
        "- Keep this inbound separate from the stable direct REALITY listener.",
        "- Terminate TLS at the reverse proxy / edge layer for the first lab pass.",
        "- Return 404 for unrelated paths and keep the front lane narrow.",
        "",
    ]
    if plan["transport"] == "xhttp":
        lines.append("- Treat this lane as plain HTTP-shaped tunneling; do not add WebSocket-only upgrade handling unless the edge really needs it.")
        lines.append("")
    if plan["transport"] == "httpupgrade":
        lines.append("- This lane expects HTTP Upgrade semantics at the front and `httpupgrade` on the loopback xray inbound.")
        lines.append("")
    if (plan["connectHost"], plan["connectPort"]) != (plan["frontHost"], plan["frontPort"]):
        lines.append("- The handset can dial a separate `connectHost` / `connectPort` while still presenting the visible front in TLS and HTTP metadata.")
        lines.append("")
    return "\n".join(lines)


def build_summary(plan: dict, source_label: str, output_dir: str) -> str:
    lines = [
        "# Android CDN Owner-Lab Origin Plan",
        "",
        "## Source",
        f"- Source: `{source_label}`",
        f"- Runtime family: `{plan['runtimeFamily']}`",
        f"- Mode: `{plan['configMode']}`",
        f"- Activation state: `{plan['activationState']}`",
        f"- Transport: `{plan['transport']}`",
        "",
        "## Front lane",
        f"- Front host: `{plan['frontHost']}`",
        f"- Front port: `{plan['frontPort']}`",
        f"- Client dial host: `{plan['connectHost']}`",
        f"- Client dial port: `{plan['connectPort']}`",
        f"- Front path: `{plan['frontPath']}`",
        f"- TLS SNI: `{plan['tlsServerName']}`",
        f"- HTTP Host header: `{plan['httpHostHeader']}`",
        f"- Front tag: `{plan['frontTag'] or 'n/a'}`",
        "",
        "## Origin lane",
        f"- Public origin host: `{plan['originHost']}`",
        f"- Public origin scheme: `{plan['originScheme']}`",
        f"- Public origin port: `{plan['originPort']}`",
        f"- Suggested core loopback bind: `127.0.0.1:{plan['coreLoopbackPort']}`",
        f"- Core path: `{plan['originPath']}`",
        "",
        "## Preflight",
        "- Keep stable `direct-reality` as the default and control lane.",
        "- Keep this owner-only lane hidden and opt-in.",
        "- Do not enable boot restore / system restore for this lab pass.",
        "- Confirm the chosen front host is reachable from the target Russian whitelist-restricted network.",
        "- Enable request-level access logging on the hidden front so handset runs can be correlated with server-side hits.",
        "- Save both `cdn-anti-whitelist-scaffold.json` and `active-cdn-anti-whitelist.json` after the handset run.",
        "- If `connectHost` / `connectPort` differ from the visible front, treat that as a client-side dial override rather than an edge bind change.",
    ]
    if output_dir:
        lines.extend([
            "",
            "## Generated files",
            f"- Summary: `{output_dir}/summary.md`",
            f"- Caddy sample: `{output_dir}/caddy.Caddyfile`",
            f"- Nginx sample: `{output_dir}/nginx.conf`",
            f"- Core requirements: `{output_dir}/core-requirements.md`",
            f"- Normalized plan: `{output_dir}/plan.json`",
        ])
    lines.append("")
    return "\n".join(lines)


source_kind = sys.argv[1]
source_path = Path(sys.argv[2]).resolve()
source_label = sys.argv[3]
output_dir = sys.argv[4].strip()

raw = read_json(source_path)
if source_kind == "scaffold" or raw.get("kind") == "odin-one-android-cdn-anti-whitelist-scaffold":
    plan = extract_from_scaffold(raw)
else:
    plan = extract_from_profile(raw)

plan["coreLoopbackPort"] = derive_core_loopback_port(plan["originPort"], plan["originScheme"])

summary = build_summary(plan, source_label, output_dir)
caddy = build_caddy(plan)
nginx = build_nginx(plan)
core_requirements = build_core_requirements(plan)
normalized_plan = json.dumps(plan, indent=2, ensure_ascii=False) + "\n"

if output_dir:
    target_dir = Path(output_dir).resolve()
    target_dir.mkdir(parents=True, exist_ok=True)
    (target_dir / "summary.md").write_text(summary + "\n", encoding="utf-8")
    (target_dir / "caddy.Caddyfile").write_text(caddy, encoding="utf-8")
    (target_dir / "nginx.conf").write_text(nginx, encoding="utf-8")
    (target_dir / "core-requirements.md").write_text(core_requirements, encoding="utf-8")
    (target_dir / "plan.json").write_text(normalized_plan, encoding="utf-8")
    print(target_dir)
else:
    print(summary)
    print("## Caddy Sample")
    print("```caddyfile")
    print(caddy.rstrip())
    print("```")
    print("")
    print("## Nginx Sample")
    print("```nginx")
    print(nginx.rstrip())
    print("```")
    print("")
    print(core_requirements)
PY

if [[ -n "$OUTPUT_DIR" ]]; then
  echo "Wrote owner-lab origin package to $OUTPUT_DIR"
fi
