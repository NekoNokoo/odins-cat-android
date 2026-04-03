#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
CURL_BIN="${CURL_BIN:-$(command -v curl || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

SUBSCRIPTION=""
OUTPUT_DIR=""
ENGINE="${ENGINE:-auto}"
XRAY_BIN="${XRAY_BIN:-$HOME/Library/Caches/odin-one/bin/xray-darwin-arm64}"
SING_BOX_BIN="${SING_BOX_BIN:-$HOME/Library/Caches/odin-one/bin/sing-box-darwin-arm64}"
TEST_URL="https://www.gstatic.com/generate_204"
EXPECT_CODE="204"
MAX_TIME="12"
LIMIT=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-local-smoke.sh [options]

Options:
  --subscription <path>     Subscription file with vless:// entries.
  --output-dir <dir>        Output directory. Default: /tmp/odin-one-reality-whitelist-live-smoke/<stamp>
  --engine <name>           Client engine: auto, xray, sing-box. Default: auto
  --xray-bin <path>         xray binary path.
  --sing-box-bin <path>     sing-box binary path.
  --test-url <url>          URL to fetch through the local SOCKS proxy.
  --expect-code <code>      Expected HTTP status code. Default: 204
  --max-time <seconds>      curl timeout. Default: 12
  --limit <count>           Limit how many entries to test.
  -h, --help                Show this help.

Behavior:
  - starts a user-space client on 127.0.0.1:<ephemeral-port>
  - sends traffic only through curl --proxy socks5h://127.0.0.1:<port>
  - does not modify system routes or disconnect the current macOS VPN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SUBSCRIPTION="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENGINE="$2"
      shift 2
      ;;
    --xray-bin)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      XRAY_BIN="$2"
      shift 2
      ;;
    --sing-box-bin)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SING_BOX_BIN="$2"
      shift 2
      ;;
    --test-url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TEST_URL="$2"
      shift 2
      ;;
    --expect-code)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EXPECT_CODE="$2"
      shift 2
      ;;
    --max-time)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_TIME="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
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
if [[ -z "$CURL_BIN" || ! -x "$CURL_BIN" ]]; then
  echo "curl not found" >&2
  exit 1
fi
if [[ -z "$SUBSCRIPTION" || ! -f "$SUBSCRIPTION" ]]; then
  echo "Provide --subscription and ensure the file exists." >&2
  exit 1
fi
if [[ ! "$EXPECT_CODE" =~ '^[0-9]+$' ]]; then
  echo "--expect-code must be numeric" >&2
  exit 1
fi
if [[ ! "$MAX_TIME" =~ '^[0-9]+$' ]]; then
  echo "--max-time must be numeric" >&2
  exit 1
fi
if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be numeric" >&2
  exit 1
fi
case "$ENGINE" in
  auto|xray|sing-box)
    ;;
  *)
    echo "--engine must be one of: auto, xray, sing-box" >&2
    exit 1
    ;;
esac
if [[ "$ENGINE" == "xray" || "$ENGINE" == "auto" ]]; then
  if [[ ! -x "$XRAY_BIN" && "$ENGINE" == "xray" ]]; then
    echo "xray binary not executable: $XRAY_BIN" >&2
    exit 1
  fi
fi
if [[ "$ENGINE" == "sing-box" || "$ENGINE" == "auto" ]]; then
  if [[ ! -x "$SING_BOX_BIN" && "$ENGINE" == "sing-box" ]]; then
    echo "sing-box binary not executable: $SING_BOX_BIN" >&2
    exit 1
  fi
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-whitelist-live-smoke/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

"$PYTHON_BIN" - "$SUBSCRIPTION" "$OUTPUT_DIR" "$ENGINE" "$XRAY_BIN" "$SING_BOX_BIN" "$CURL_BIN" "$TEST_URL" "$EXPECT_CODE" "$MAX_TIME" "$LIMIT" <<'PY'
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

subscription_path = Path(sys.argv[1]).expanduser()
output_dir = Path(sys.argv[2]).expanduser()
requested_engine = sys.argv[3]
xray_bin = str(Path(sys.argv[4]).expanduser())
sing_box_bin = str(Path(sys.argv[5]).expanduser())
curl_bin = str(Path(sys.argv[6]).expanduser())
test_url = sys.argv[7]
expect_code = int(sys.argv[8])
max_time = int(sys.argv[9])
limit_raw = sys.argv[10].strip()
limit = int(limit_raw) if limit_raw else None


def alloc_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        return int(sock.getsockname()[1])


def wait_port(port: int, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.25)
            try:
                sock.connect(("127.0.0.1", port))
                return True
            except OSError:
                time.sleep(0.1)
    return False


def parse_subscription(path: Path):
    items = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parsed = urllib.parse.urlsplit(line)
        if parsed.scheme != "vless":
            continue
        uuid = urllib.parse.unquote(parsed.username or "")
        host = parsed.hostname or ""
        port = parsed.port or 443
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        transport = ((query.get("type") or ["tcp"])[0] or "tcp").strip()
        security = ((query.get("security") or [""])[0] or "").strip()
        server_name = ((query.get("sni") or [""])[0] or "").strip()
        ws_host = ((query.get("host") or [""])[0] or "").strip()
        ws_path = urllib.parse.unquote(((query.get("path") or [""])[0] or "").strip())
        grpc_service_name = ((query.get("serviceName") or [""])[0] or "").strip()
        grpc_authority = ((query.get("authority") or [""])[0] or "").strip()
        insecure_value = ((query.get("allowInsecure") or query.get("insecure") or [""])[0] or "").strip().lower()
        item = {
            "uri": line,
            "label": urllib.parse.unquote(parsed.fragment or host),
            "uuid": uuid,
            "host": host,
            "port": int(port),
            "type": transport,
            "security": security,
            "flow": ((query.get("flow") or [""])[0] or "").strip(),
            "fingerprint": (query.get("fp") or ["chrome"])[0],
            "publicKey": (query.get("pbk") or [""])[0],
            "shortId": (query.get("sid") or [""])[0],
            "serverName": server_name,
            "wsHost": ws_host,
            "wsPath": ws_path,
            "grpcServiceName": grpc_service_name,
            "grpcAuthority": grpc_authority,
            "allowInsecure": insecure_value in {"1", "true", "yes"},
        }
        if not item["uuid"] or not item["host"] or not item["serverName"]:
            continue
        if item["security"] == "reality" and (not item["publicKey"] or not item["shortId"]):
            continue
        items.append(item)
    if limit is not None:
        items = items[:limit]
    return items


def build_xray_config(entry, socks_port: int):
    if entry["security"] != "reality" or entry["type"] != "tcp":
        raise ValueError("xray helper currently supports only tcp + reality")
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {"udp": True},
            }
        ],
        "outbounds": [
            {
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": entry["host"],
                            "port": entry["port"],
                            "users": [
                                {
                                    "id": entry["uuid"],
                                    "encryption": "none",
                                    "flow": entry["flow"],
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": entry["security"],
                    "realitySettings": {
                        "serverName": entry["serverName"],
                        "fingerprint": entry["fingerprint"],
                        "publicKey": entry["publicKey"],
                        "shortId": entry["shortId"],
                        "spiderX": "/",
                    },
                },
            }
        ],
    }


def build_sing_box_config(entry, socks_port: int):
    tls = {
        "enabled": True,
        "server_name": entry["serverName"],
        "utls": {"enabled": True, "fingerprint": entry["fingerprint"]},
    }
    if entry["allowInsecure"]:
        tls["insecure"] = True
    if entry["security"] == "reality":
        tls["reality"] = {
            "enabled": True,
            "public_key": entry["publicKey"],
            "short_id": entry["shortId"],
        }
    elif entry["security"] != "tls":
        raise ValueError(f"unsupported sing-box security: {entry['security']}")

    outbound = {
        "type": "vless",
        "tag": "vless-out",
        "server": entry["host"],
        "server_port": entry["port"],
        "uuid": entry["uuid"],
        "network": "tcp",
        "tls": tls,
    }
    if entry["flow"]:
        outbound["flow"] = entry["flow"]
    if entry["type"] == "ws":
        transport = {"type": "ws"}
        if entry["wsPath"]:
            transport["path"] = entry["wsPath"]
        if entry["wsHost"]:
            transport["headers"] = {"Host": entry["wsHost"]}
        outbound["transport"] = transport
    elif entry["type"] == "grpc":
        transport = {"type": "grpc"}
        if entry["grpcServiceName"]:
            transport["service_name"] = entry["grpcServiceName"]
        outbound["transport"] = transport
    elif entry["type"] != "tcp":
        raise ValueError(f"unsupported sing-box transport: {entry['type']}")

    return {
        "log": {"level": "warn"},
        "inbounds": [
            {
                "type": "socks",
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "listen_port": socks_port,
            }
        ],
        "outbounds": [outbound],
        "route": {"final": "vless-out", "auto_detect_interface": True},
    }


def pick_engine():
    if requested_engine == "xray":
        return "xray"
    if requested_engine == "sing-box":
        return "sing-box"
    if os.path.exists(sing_box_bin) and os.access(sing_box_bin, os.X_OK):
        return "sing-box"
    if os.path.exists(xray_bin) and os.access(xray_bin, os.X_OK):
        return "xray"
    raise SystemExit("no executable client engine found")


entries = parse_subscription(subscription_path)
if not entries:
    raise SystemExit(f"no usable vless:// entries found in {subscription_path}")

engine = pick_engine()
results = []

for index, entry in enumerate(entries, start=1):
    run_dir = output_dir / f"{index:02d}-{entry['serverName'].replace('.', '-')}"
    run_dir.mkdir(parents=True, exist_ok=True)
    socks_port = alloc_port()
    config_path = run_dir / "client-config.json"
    log_path = run_dir / "client.log"
    curl_stdout_path = run_dir / "curl.stdout"
    curl_stderr_path = run_dir / "curl.stderr"

    proc = None
    launch_cmd = None
    build_error = None
    try:
        if engine == "sing-box":
            config = build_sing_box_config(entry, socks_port)
            launch_cmd = [sing_box_bin, "run", "-c", str(config_path)]
        else:
            config = build_xray_config(entry, socks_port)
            launch_cmd = [xray_bin, "run", "-c", str(config_path)]
    except Exception as exc:
        build_error = str(exc)
        config = None

    if config is not None:
        config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    else:
        config_path.write_text(json.dumps({"error": build_error}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    started = False
    if launch_cmd is not None:
        with log_path.open("w", encoding="utf-8") as log_file:
            proc = subprocess.Popen(
                launch_cmd,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
            )
        started = wait_port(socks_port)
    curl_exit = None
    http_code = ""
    error = None if build_error is None else f"build_error:{build_error}"

    try:
        if build_error is not None:
            pass
        elif not started:
            error = "local_socks_not_ready"
        else:
            curl_cmd = [
                curl_bin,
                "--proxy",
                f"socks5h://127.0.0.1:{socks_port}",
                "-sS",
                "-m",
                str(max_time),
                test_url,
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
            ]
            curl_proc = subprocess.run(curl_cmd, capture_output=True, text=True)
            curl_exit = int(curl_proc.returncode)
            http_code = (curl_proc.stdout or "").strip()
            curl_stdout_path.write_text(curl_proc.stdout or "", encoding="utf-8")
            curl_stderr_path.write_text(curl_proc.stderr or "", encoding="utf-8")
            if curl_exit != 0:
                error = f"curl_exit_{curl_exit}"
            elif http_code != str(expect_code):
                error = f"http_code_{http_code or 'empty'}"
    finally:
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                    proc.wait(timeout=3)
                except Exception:
                    pass

    passed = build_error is None and started and curl_exit == 0 and http_code == str(expect_code)
    results.append(
        {
            "index": index,
            "label": entry["label"],
            "serverName": entry["serverName"],
            "host": entry["host"],
            "port": entry["port"],
            "transport": entry["type"],
            "security": entry["security"],
            "wsHost": entry["wsHost"] or None,
            "wsPath": entry["wsPath"] or None,
            "grpcServiceName": entry["grpcServiceName"] or None,
            "grpcAuthority": entry["grpcAuthority"] or None,
            "engine": engine,
            "localSocksPort": socks_port,
            "passed": passed,
            "startupReady": started,
            "curlExit": curl_exit,
            "httpCode": http_code or None,
            "error": error,
            "buildError": build_error,
            "runDir": str(run_dir),
            "configPath": str(config_path),
            "logPath": str(log_path),
        }
    )

summary_lines = [
    "# Reality Whitelist Local Smoke",
    "",
    f"- Generated at: `{datetime.now(timezone.utc).isoformat()}`",
    f"- Subscription: `{subscription_path}`",
    f"- Client engine: `{engine}`",
    f"- Client binary: `{sing_box_bin if engine == 'sing-box' else xray_bin}`",
    f"- Test URL: `{test_url}`",
    f"- Expected HTTP code: `{expect_code}`",
    f"- Max time: `{max_time}s`",
    f"- Entries tested: `{len(results)}`",
    f"- Passed: `{sum(1 for item in results if item['passed'])}`",
    "",
    "## Notes",
    "",
    "- Each test starts a local SOCKS listener on `127.0.0.1` and routes only the `curl --proxy` request through it.",
    "- This smoke test does not modify macOS system routes and does not require disconnecting the current VPN.",
    "",
    "## Results",
    "",
]

for item in results:
    status = "passed" if item["passed"] else f"failed:{item['error'] or 'unknown'}"
    summary_lines.append(
        f"- `{item['serverName']}` -> `{item['host']}:{item['port']}` | transport=`{item['transport']}` | security=`{item['security']}` | `{status}` | http=`{item['httpCode'] or 'n/a'}` | curlExit=`{item['curlExit'] if item['curlExit'] is not None else 'n/a'}`"
    )

(output_dir / "results.json").write_text(
    json.dumps(
        {
            "kind": "odin-one-reality-whitelist-local-smoke-v1",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "subscription": str(subscription_path),
            "engine": engine,
            "clientBin": sing_box_bin if engine == "sing-box" else xray_bin,
            "testUrl": test_url,
            "expectCode": expect_code,
            "maxTime": max_time,
            "results": results,
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

print(output_dir)
PY
