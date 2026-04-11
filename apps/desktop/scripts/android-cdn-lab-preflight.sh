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
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset <preset> [--plan-file <file>] [--plan-tag <tag>] [--plan-index <n>] [--strict]
  apps/desktop/scripts/android-cdn-lab-preflight.sh --profile-json <file> [--strict]
  apps/desktop/scripts/android-cdn-lab-preflight.sh --scaffold-json <file> [--strict]

Examples:
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-ws-lab
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-xhttp-lab
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-httpupgrade-lab
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-ws-lab --plan-file /tmp/odin-one-cdn-plan.json --plan-tag front-primary
  ODIN_ONE_CDN_FRONT_HOST=edge.example.com \
  ODIN_ONE_CDN_ORIGIN_HOST=origin.example.com \
    apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-ws-lab --strict

Checks host-side DNS/TCP/TLS/HTTP reachability for the owner-lab whitelist-front plan.
This is a preflight only; it does not prove Russian whitelist reachability by itself.
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
STRICT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="profile"
      PRESET_NAME="$2"
      SOURCE_PATH=""
      shift 2
      ;;
    --profile-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="profile"
      SOURCE_PATH="$2"
      shift 2
      ;;
    --scaffold-json)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SOURCE_KIND="scaffold"
      SOURCE_PATH="$2"
      shift 2
      ;;
    --strict)
      STRICT="true"
      shift
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
  PRESET_FILE="$(make_temp_file "odin-one-android-cdn-lab-preflight-preset")"
  zsh "$PRESET_HELPER" "$PRESET_NAME" >"$PRESET_FILE"
  SOURCE_PATH="$PRESET_FILE"
fi
if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "Source file not found: $SOURCE_PATH" >&2
  exit 1
fi

"$PYTHON_BIN" - "$SOURCE_KIND" "$SOURCE_PATH" "$STRICT" <<'PY'
import http.client
import ipaddress
import json
import socket
import ssl
import subprocess
import sys
from pathlib import Path

source_kind = sys.argv[1]
source_path = Path(sys.argv[2]).resolve()
strict = sys.argv[3].lower() == "true"


def normalize_path(value: str, default: str) -> str:
    raw = (value or "").strip()
    if not raw:
        raw = default
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
        "originHost": (origin.get("host") or runtime.get("originHost") or "").strip(),
        "originPort": int(origin.get("port") or runtime.get("originPort") or 443),
        "originScheme": ((origin.get("scheme") or runtime.get("originScheme") or "https").strip().lower()),
        "originPath": normalize_path(origin.get("path") or runtime.get("originPath") or selected.get("path") or "/", "/"),
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
        "originHost": (raw.get("originHost") or "").strip(),
        "originPort": int(raw.get("originPort") or 443),
        "originScheme": (raw.get("originScheme") or "https").strip().lower(),
        "originPath": normalize_path(raw.get("originPath") or "/", "/"),
    }


def is_placeholder_host(host: str) -> bool:
    host = (host or "").strip().lower()
    return (not host) or host.endswith(".example.com")


def format_ok(label: str, value: str) -> str:
    return f"- {label}: ok ({value})"


def format_fail(label: str, value: str) -> str:
    return f"- {label}: fail ({value})"


def format_warn(label: str, value: str) -> str:
    return f"- {label}: warn ({value})"


def resolve_host(host: str, port: int) -> tuple[bool, str]:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except Exception as exc:
        return False, str(exc)
    resolved = []
    seen = set()
    for info in infos:
        addr = info[4][0]
        if addr not in seen:
            seen.add(addr)
            resolved.append(addr)
    return True, ", ".join(resolved) if resolved else "no addresses"


def probe_tcp(host: str, port: int, timeout: float = 5.0) -> tuple[bool, str]:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, f"{host}:{port}"
    except Exception as exc:
        return False, str(exc)


def probe_tls(
    host: str,
    port: int,
    server_name: str,
    timeout: float = 5.0,
    verify: bool = True,
) -> tuple[bool, str]:
    context = ssl.create_default_context() if verify else ssl._create_unverified_context()
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with context.wrap_socket(sock, server_hostname=server_name) as tls_sock:
                cipher = tls_sock.cipher()
                tls_version = tls_sock.version()
                cipher_label = cipher[0] if cipher else "unknown-cipher"
                return True, f"{tls_version} {cipher_label}"
    except Exception as exc:
        return False, str(exc)


def probe_http(
    scheme: str,
    connect_host: str,
    connect_port: int,
    path: str,
    host_header: str,
    timeout: float = 8.0,
    verify: bool = True,
) -> tuple[bool, str]:
    connection_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    kwargs = {"timeout": timeout}
    if scheme == "https":
        kwargs["context"] = ssl.create_default_context() if verify else ssl._create_unverified_context()
    try:
        connection = connection_cls(connect_host, connect_port, **kwargs)
        connection.request("HEAD", path, headers={"Host": host_header, "User-Agent": "odin-one-cdn-preflight/1"})
        response = connection.getresponse()
        status = response.status
        reason = response.reason or ""
        response.read()
        connection.close()
        return True, f"{status} {reason}".strip()
    except Exception as exc:
        return False, str(exc)


def is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address((host or "").strip())
        return True
    except ValueError:
        return False


def parse_http_status_line(raw: str) -> str:
    for line in (raw or "").splitlines():
        value = line.strip()
        if value.upper().startswith("HTTP/"):
            parts = value.split(None, 2)
            if len(parts) >= 3:
                return f"{parts[1]} {parts[2]}".strip()
            if len(parts) == 2:
                return parts[1]
    return "HTTP response received"


def probe_https_via_resolve(
    url_host: str,
    connect_host: str,
    connect_port: int,
    path: str,
    host_header: str,
    timeout: float = 8.0,
) -> tuple[bool, str]:
    command = [
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-D",
        "-",
        "--max-time",
        str(int(timeout)),
        "--resolve",
        f"{url_host}:{connect_port}:{connect_host}",
        "-I",
    ]
    if host_header and host_header != url_host:
        command.extend(["-H", f"Host: {host_header}"])
    command.append(f"https://{url_host}{path}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except Exception as exc:
        return False, str(exc)
    if result.returncode == 0:
        return True, parse_http_status_line(result.stdout)
    detail = (result.stderr or result.stdout or f"curl exited with status {result.returncode}").strip()
    return False, detail


def is_certificate_verify_failure(detail: str) -> bool:
    normalized = (detail or "").strip().lower()
    return "certificate verify failed" in normalized or "certificate_verify_failed" in normalized


raw = json.loads(source_path.read_text(encoding="utf-8", errors="replace"))
plan = extract_from_scaffold(raw) if source_kind == "scaffold" or raw.get("kind") == "odin-one-android-cdn-anti-whitelist-scaffold" else extract_from_profile(raw)

front_placeholder = is_placeholder_host(plan["frontHost"])
connect_placeholder = is_placeholder_host(plan["connectHost"])
origin_placeholder = is_placeholder_host(plan["originHost"])
front_server_name = plan["tlsServerName"] or plan["frontHost"] or plan["connectHost"]
front_host_header = plan["httpHostHeader"] or plan["frontHost"] or front_server_name or plan["connectHost"]

visible_front_dns_ok, visible_front_dns_detail = resolve_host(plan["frontHost"], plan["frontPort"]) if not front_placeholder else (False, "placeholder host")
front_dns_ok, front_dns_detail = resolve_host(plan["connectHost"], plan["connectPort"]) if not connect_placeholder else (False, "placeholder host")
front_tcp_ok, front_tcp_detail = probe_tcp(plan["connectHost"], plan["connectPort"]) if front_dns_ok else (False, "skipped")
front_tls_ok, front_tls_detail = probe_tls(plan["connectHost"], plan["connectPort"], front_server_name) if front_tcp_ok else (False, "skipped")
front_tls_warning = ""
if not front_tls_ok and is_certificate_verify_failure(front_tls_detail):
    front_tls_relaxed_ok, front_tls_relaxed_detail = probe_tls(
        plan["connectHost"],
        plan["connectPort"],
        front_server_name,
        verify=False,
    )
    if front_tls_relaxed_ok:
        front_tls_ok = True
        front_tls_warning = (
            "TLS handshake reached the front, but local Python certificate validation failed; "
            f"unverified handshake: {front_tls_relaxed_detail}; verify error: {front_tls_detail}"
        )
        front_tls_detail = front_tls_warning

front_resolve_override = (
    is_ip_literal(plan["connectHost"])
    and bool(front_server_name.strip())
    and front_server_name.strip() != (plan["connectHost"] or "").strip()
)
front_resolve_override_warning = ""
front_resolve_override_status = ""
if front_tcp_ok and front_resolve_override and not front_tls_ok:
    front_resolve_ok, front_resolve_detail = probe_https_via_resolve(
        front_server_name,
        plan["connectHost"],
        plan["connectPort"],
        plan["frontPath"],
        front_host_header,
    )
    if front_resolve_ok:
        front_tls_ok = True
        front_tls_detail = f"verified via curl --resolve ({front_resolve_detail})"
        front_resolve_override_status = front_resolve_detail
        front_resolve_override_warning = (
            "Front HTTPS was verified via curl --resolve because Python IP+SNI probing against the dial target was inconclusive"
        )

front_http_ok, front_http_detail = probe_http(
    "https",
    plan["connectHost"],
    plan["connectPort"],
    plan["frontPath"],
    front_host_header,
) if front_tls_ok and not front_tls_warning else (False, "skipped")
front_http_warning = ""
if front_tls_warning:
    front_http_relaxed_ok, front_http_relaxed_detail = probe_http(
        "https",
        plan["connectHost"],
        plan["connectPort"],
        plan["frontPath"],
        front_host_header,
        verify=False,
    )
    if front_http_relaxed_ok:
        front_http_ok = True
        front_http_warning = (
            "HTTPS response reached the front, but local Python certificate validation failed; "
            f"unverified response: {front_http_relaxed_detail}"
        )
        front_http_detail = front_http_warning
    else:
        front_http_detail = front_http_relaxed_detail

if front_resolve_override and not front_http_ok:
    front_resolve_ok, front_resolve_detail = probe_https_via_resolve(
        front_server_name,
        plan["connectHost"],
        plan["connectPort"],
        plan["frontPath"],
        front_host_header,
    )
    if front_resolve_ok:
        front_resolve_override_status = front_resolve_detail

if front_resolve_override_status:
    front_http_ok = True
    front_http_detail = f"verified via curl --resolve ({front_resolve_override_status})"
    if not front_http_warning:
        front_http_warning = front_resolve_override_warning

origin_dns_ok, origin_dns_detail = resolve_host(plan["originHost"], plan["originPort"]) if not origin_placeholder else (False, "placeholder host")
origin_tcp_ok, origin_tcp_detail = probe_tcp(plan["originHost"], plan["originPort"]) if origin_dns_ok else (False, "skipped")
origin_http_ok, origin_http_detail = probe_http(
    plan["originScheme"],
    plan["originHost"],
    plan["originPort"],
    plan["originPath"],
    front_host_header,
) if origin_tcp_ok else (False, "skipped")
origin_http_warning = ""
if (
    not origin_http_ok
    and plan["originScheme"] == "https"
    and is_certificate_verify_failure(origin_http_detail)
):
    origin_http_relaxed_ok, origin_http_relaxed_detail = probe_http(
        plan["originScheme"],
        plan["originHost"],
        plan["originPort"],
        plan["originPath"],
        front_host_header,
        verify=False,
    )
    if origin_http_relaxed_ok:
        origin_http_ok = True
        origin_http_warning = (
            "HTTPS response reached the origin, but local Python certificate validation failed; "
            f"unverified response: {origin_http_relaxed_detail}; verify error: {origin_http_detail}"
        )
        origin_http_detail = origin_http_warning

placeholder_failures = []
if front_placeholder:
    placeholder_failures.append("frontHost still uses a placeholder value")
if connect_placeholder:
    placeholder_failures.append("connectHost still uses a placeholder value")
if origin_placeholder:
    placeholder_failures.append("originHost still uses a placeholder value")

print("# Android CDN Owner-Lab Preflight")
print("")
print("## Plan")
print(f"- runtimeFamily: `{plan['runtimeFamily']}`")
print(f"- configMode: `{plan['configMode']}`")
print(f"- activationState: `{plan['activationState']}`")
print(f"- provider: `{plan['provider']}`")
print(f"- transport: `{plan['transport']}`")
print(f"- frontHost: `{plan['frontHost'] or '<missing>'}`")
print(f"- frontPort: `{plan['frontPort']}`")
print(f"- connectHost: `{plan['connectHost'] or '<missing>'}`")
print(f"- connectPort: `{plan['connectPort']}`")
print(f"- frontPath: `{plan['frontPath']}`")
print(f"- tlsServerName: `{plan['tlsServerName'] or '<missing>'}`")
print(f"- httpHostHeader: `{plan['httpHostHeader'] or '<missing>'}`")
print(f"- originHost: `{plan['originHost'] or '<missing>'}`")
print(f"- originPort: `{plan['originPort']}`")
print(f"- originScheme: `{plan['originScheme']}`")
print(f"- originPath: `{plan['originPath']}`")
print("")
print("## Placeholder Check")
if placeholder_failures:
    for item in placeholder_failures:
        print(f"- fail: {item}")
else:
    print("- ok: front/origin hosts look non-placeholder")
print("")
print("## Front Checks")
print(format_ok("visibleFrontDns", visible_front_dns_detail) if visible_front_dns_ok else format_warn("visibleFrontDns", visible_front_dns_detail))
print(format_ok("dialDns", front_dns_detail) if front_dns_ok else format_fail("dialDns", front_dns_detail))
print(format_ok("dialTcp", front_tcp_detail) if front_tcp_ok else format_fail("dialTcp", front_tcp_detail))
print(format_warn("dialTls", front_tls_detail) if front_tls_warning else (format_ok("dialTls", front_tls_detail) if front_tls_ok else format_fail("dialTls", front_tls_detail)))
print(format_warn("dialHttp", front_http_detail) if front_http_warning else (format_ok("dialHttp", front_http_detail) if front_http_ok else format_fail("dialHttp", front_http_detail)))
print("")
print("## Origin Checks")
print(format_ok("dns", origin_dns_detail) if origin_dns_ok else format_fail("dns", origin_dns_detail))
print(format_ok("tcp", origin_tcp_detail) if origin_tcp_ok else format_fail("tcp", origin_tcp_detail))
print(format_warn("http", origin_http_detail) if origin_http_warning else (format_ok("http", origin_http_detail) if origin_http_ok else format_fail("http", origin_http_detail)))
print("")

print("## Notes")
print("- Host-side success does not prove Russian whitelist reachability; it only reduces obvious operator errors before the handset run.")
print("- Dial probes use `connectHost` / `connectPort` when present, while TLS SNI and HTTP Host still follow the visible front values.")
print("- For the origin HTTP probe, the script sends the front Host header to the origin path to mimic the planned reverse-proxy flow.")
print("- For WebSocket fronts, `400`, `403`, `404`, or `426` can still be a useful signal that HTTPS reached the expected lane.")
if front_resolve_override_warning:
    print("- Literal-IP dial targets with separate TLS SNI / Host headers are re-checked via `curl --resolve` because Python's HTTPS probing can mis-handle that combination.")
if front_tls_warning or front_http_warning or origin_http_warning:
    print("- This machine's Python certificate store may be incomplete; the script retried HTTPS without verification to separate local trust-store issues from raw reachability.")

failures = []
warnings = []
if placeholder_failures:
    failures.extend(placeholder_failures)
if not front_dns_ok:
    failures.append("front dial DNS failed")
if not front_tcp_ok:
    failures.append("front dial TCP failed")
if not front_tls_ok:
    failures.append("front dial TLS failed")
if not front_http_ok:
    failures.append("front dial HTTP failed")
if strict:
    if not origin_dns_ok:
        failures.append("origin DNS failed")
    if not origin_tcp_ok:
        failures.append("origin TCP failed")
    if not origin_http_ok:
        failures.append("origin HTTP failed")
if front_tls_warning:
    warnings.append("front TLS reached the edge but local Python certificate validation failed")
if front_http_warning:
    warnings.append("front HTTPS reached the edge but local Python certificate validation failed")
if front_resolve_override_warning:
    warnings.append("front IP+SNI path was verified via curl --resolve")
if origin_http_warning:
    warnings.append("origin HTTPS reached the origin but local Python certificate validation failed")
if not visible_front_dns_ok and not front_placeholder:
    warnings.append("visible front DNS lookup did not resolve on the host")

print("")
print("## Result")
if failures:
    print("- status: fail")
    print(f"- strict: {'on' if strict else 'off'}")
    for item in failures:
        print(f"- issue: {item}")
    sys.exit(1 if strict or placeholder_failures or not front_http_ok else 0)
else:
    print(f"- status: {'warn' if warnings else 'pass'}")
    print(f"- strict: {'on' if strict else 'off'}")
    for item in warnings:
        print(f"- warning: {item}")
PY
