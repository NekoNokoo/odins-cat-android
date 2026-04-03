#!/bin/zsh
set -euo pipefail

DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
SED_BIN="/usr/bin/sed"
AWK_BIN="/usr/bin/awk"

ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
OUTPUT_DIR=""
MAX_TIME_SECONDS="8"
CONNECT_TIMEOUT_SECONDS="4"

typeset -a URLS=()
typeset -a URL_FILES=()
typeset -a INTERFACES=()
typeset -a RESOLVE_ENTRIES=()
typeset -a RESOLVE_FILES=()

MANIFEST_PATH=""
RESULTS_PATH=""
SUMMARY_PATH=""
DEVICE_ROUTES_PATH=""
DEVICE_INTERFACES_PATH=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-whitelist-front-probe.sh [options]

Options:
  --url <url>                 URL to probe from the device cellular interface. May be repeated.
  --urls-file <path>          Text file with one URL per line. May be repeated.
  --interface <name>          Probe only the specified device interface. May be repeated.
  --resolve <host:port:ip>    Preload a curl --resolve mapping. May be repeated.
  --resolve-file <path>       Text file with one host:port:ip mapping per line. May be repeated.
  --max-time <seconds>        curl --max-time value. Default: 8
  --connect-timeout <seconds> curl --connect-timeout value. Default: 4
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-android-whitelist-front-probe/<stamp>
  -h, --help                  Show this help.

Environment:
  ODIN_ONE_DEVICE_UNDERLYING_INTERFACE
    Optional comma-separated fallback when --interface is not passed.

Behavior:
  - detects active cellular-looking interfaces from `adb shell ip route`
  - runs `adb shell curl --interface <iface> -k -I -L` for every URL
  - can preload host-side DNS answers through repeated `--resolve host:port:ip`
  - writes per-probe raw output plus summary.md and results.json

This helper is owner-only and additive. It does not touch the Android VPN runtime,
stable `direct-reality`, or any server-side surface. It only measures whether a
candidate visible front appears reachable from the handset's raw cellular path.
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

normalize_label() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | "$SED_BIN" 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

log_section() {
  echo
  echo "=== $1 ==="
}

unique_joined() {
  "$AWK_BIN" 'NF && !seen[$0]++ { print $0 }'
}

detect_interfaces() {
  local override="${ODIN_ONE_DEVICE_UNDERLYING_INTERFACE:-}"
  if [[ ${#INTERFACES[@]} -gt 0 ]]; then
    printf '%s\n' "${INTERFACES[@]}" | unique_joined
    return 0
  fi
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override" | tr ',' '\n' | unique_joined
    return 0
  fi
  if [[ -f "$DEVICE_ROUTES_PATH" ]]; then
    "$PYTHON_BIN" - "$DEVICE_ROUTES_PATH" <<'PY'
import re
import sys
from pathlib import Path

routes = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
preferred_prefixes = ("rmnet", "ccmni", "pdp", "wwan", "rmnet_data")
ignored = {"lo", "tun0", "wlan0", "ap0", "v4-rmnet", "v4-rmnet_data0"}
seen = []
for line in routes:
    match = re.search(r"\bdev ([^ ]+)", line)
    if not match:
        continue
    iface = match.group(1).strip()
    if not iface or iface in ignored:
        continue
    if iface.startswith(preferred_prefixes):
        if iface not in seen:
            seen.append(iface)
if not seen:
    raise SystemExit(1)
for iface in seen:
    print(iface)
PY
    return 0
  fi
  return 1
}

append_urls_from_file() {
  local file_path="$1"
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    URLS+=("$line")
  done <"$file_path"
}

append_resolve_entries_from_file() {
  local file_path="$1"
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    RESOLVE_ENTRIES+=("$line")
  done <"$file_path"
}

run_probe() {
  local url="$1"
  local iface="$2"
  local output_path="$3"
  local exit_code=0
  local curl_format='HTTP_CODE=%{http_code};REMOTE_IP=%{remote_ip};NUM_REDIRECTS=%{num_redirects};URL_EFFECTIVE=%{url_effective}\n'
  local remote_cmd
  remote_cmd="curl --interface ${(q)iface} -sS -k -I -L --connect-timeout ${(q)CONNECT_TIMEOUT_SECONDS} --max-time ${(q)MAX_TIME_SECONDS} -o /dev/null -D - -w ${(q)curl_format}"
  local resolve_entry
  for resolve_entry in "${RESOLVE_ENTRIES[@]}"; do
    remote_cmd="${remote_cmd} --resolve ${(q)resolve_entry}"
  done
  remote_cmd="${remote_cmd} ${(q)url}"
  if "$ADB_BIN" shell "$remote_cmd" >"$output_path" 2>&1
  then
    exit_code=0
  else
    exit_code=$?
  fi
  printf '\nEXIT_CODE=%s\n' "$exit_code" >>"$output_path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      URLS+=("$2")
      shift 2
      ;;
    --urls-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      URL_FILES+=("$2")
      shift 2
      ;;
    --interface)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      INTERFACES+=("$2")
      shift 2
      ;;
    --resolve)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESOLVE_ENTRIES+=("$2")
      shift 2
      ;;
    --resolve-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESOLVE_FILES+=("$2")
      shift 2
      ;;
    --max-time)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_TIME_SECONDS="$2"
      shift 2
      ;;
    --connect-timeout)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CONNECT_TIMEOUT_SECONDS="$2"
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

require_bin "$ADB_BIN" "adb"
require_bin "$PYTHON_BIN" "python3"

if [[ ! "$MAX_TIME_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "--max-time must be numeric" >&2
  exit 1
fi
if [[ ! "$CONNECT_TIMEOUT_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "--connect-timeout must be numeric" >&2
  exit 1
fi
for file_path in "${URL_FILES[@]}"; do
  if [[ ! -f "$file_path" ]]; then
    echo "URLs file not found: $file_path" >&2
    exit 1
  fi
  append_urls_from_file "$file_path"
done
for file_path in "${RESOLVE_FILES[@]}"; do
  if [[ ! -f "$file_path" ]]; then
    echo "Resolve file not found: $file_path" >&2
    exit 1
  fi
  append_resolve_entries_from_file "$file_path"
done
if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "Provide at least one --url or --urls-file." >&2
  exit 1
fi
for resolve_entry in "${RESOLVE_ENTRIES[@]}"; do
  if [[ ! "$resolve_entry" =~ '^[^:]+:[0-9]+:[^:]+$' ]]; then
    echo "Invalid --resolve entry: $resolve_entry" >&2
    exit 1
  fi
done

if ! "$ADB_BIN" get-state >/dev/null 2>&1; then
  echo "No adb device is ready" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-android-whitelist-front-probe/${SESSION_STAMP}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"
"$MKDIR_BIN" -p "$OUTPUT_DIR/probes"

MANIFEST_PATH="$OUTPUT_DIR/manifest.tsv"
RESULTS_PATH="$OUTPUT_DIR/results.json"
SUMMARY_PATH="$OUTPUT_DIR/summary.md"
DEVICE_ROUTES_PATH="$OUTPUT_DIR/device-ip-route.txt"
DEVICE_INTERFACES_PATH="$OUTPUT_DIR/device-interfaces.txt"

log_section "Capture device routes"
"$ADB_BIN" shell ip route >"$DEVICE_ROUTES_PATH"

typeset -a DETECTED_INTERFACES=()
detected_interfaces_raw="$(detect_interfaces || true)"
if [[ -n "$detected_interfaces_raw" ]]; then
  DETECTED_INTERFACES=("${(@f)detected_interfaces_raw}")
fi
if [[ ${#DETECTED_INTERFACES[@]} -eq 0 ]]; then
  echo "Could not detect any cellular-looking interface. Saved route snapshot to $DEVICE_ROUTES_PATH" >&2
  exit 1
fi
printf '%s\n' "${DETECTED_INTERFACES[@]}" | unique_joined >"$DEVICE_INTERFACES_PATH"

typeset -a UNIQUE_URLS=()
unique_urls_raw="$(printf '%s\n' "${URLS[@]}" | unique_joined)"
if [[ -n "$unique_urls_raw" ]]; then
  UNIQUE_URLS=("${(@f)unique_urls_raw}")
fi
printf '' >"$MANIFEST_PATH"

log_section "Run probes"
for url in "${UNIQUE_URLS[@]}"; do
  url_label="$(normalize_label "$url")"
  [[ -n "$url_label" ]] || url_label="probe"
  for iface in "${DETECTED_INTERFACES[@]}"; do
    probe_path="$OUTPUT_DIR/probes/${url_label}--${iface}.txt"
    echo "[$iface] $url"
    run_probe "$url" "$iface" "$probe_path"
    printf '%s\t%s\t%s\n' "$url" "$iface" "$probe_path" >>"$MANIFEST_PATH"
  done
done

log_section "Build summary"
"$PYTHON_BIN" - "$MANIFEST_PATH" "$RESULTS_PATH" "$SUMMARY_PATH" "$DEVICE_INTERFACES_PATH" "$MAX_TIME_SECONDS" "$CONNECT_TIMEOUT_SECONDS" <<'PY'
import json
import re
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

manifest_path = Path(sys.argv[1])
results_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
interfaces_path = Path(sys.argv[4])
max_time = sys.argv[5]
connect_timeout = sys.argv[6]

@dataclass
class Probe:
    url: str
    interface: str
    output_path: Path
    exit_code: int
    http_code: str
    remote_ip: str
    redirects: str
    effective_url: str
    note: str

    @property
    def reachable(self) -> bool:
        return self.exit_code == 0 and self.http_code not in {"", "000"}


def parse_probe(url: str, interface: str, output_path: Path) -> Probe:
    text = output_path.read_text(encoding="utf-8", errors="replace")
    values = {}
    for key in ("EXIT_CODE", "HTTP_CODE", "REMOTE_IP", "NUM_REDIRECTS", "URL_EFFECTIVE"):
        match = re.search(rf"{key}=([^;\n\r]*)", text)
        if match:
            values[key] = match.group(1).strip()
    note = ""
    stripped_lines = [line.strip() for line in text.splitlines() if line.strip()]
    for line in reversed(stripped_lines):
        if line.startswith(("HTTP_CODE=", "REMOTE_IP=", "NUM_REDIRECTS=", "URL_EFFECTIVE=", "EXIT_CODE=")):
            continue
        note = line
        break
    return Probe(
        url=url,
        interface=interface,
        output_path=output_path,
        exit_code=int(values.get("EXIT_CODE", "1")),
        http_code=values.get("HTTP_CODE", ""),
        remote_ip=values.get("REMOTE_IP", ""),
        redirects=values.get("NUM_REDIRECTS", ""),
        effective_url=values.get("URL_EFFECTIVE", ""),
        note=note,
    )


groups = {}
all_probes = []
for line in manifest_path.read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    url, interface, raw_path = line.split("\t")
    probe = parse_probe(url, interface, Path(raw_path))
    all_probes.append(probe)
    groups.setdefault(url, []).append(probe)

interfaces = [line.strip() for line in interfaces_path.read_text(encoding="utf-8").splitlines() if line.strip()]

result_items = []
for url, probes in sorted(groups.items()):
    best = sorted(
        probes,
        key=lambda item: (
            not item.reachable,
            item.exit_code,
            item.http_code == "000",
            item.interface,
        ),
    )[0]
    parsed = urllib.parse.urlsplit(url)
    result_items.append(
        {
            "url": url,
            "scheme": parsed.scheme,
            "host": parsed.hostname or "",
            "path": parsed.path or "/",
            "reachable": any(item.reachable for item in probes),
            "bestInterface": best.interface,
            "bestExitCode": best.exit_code,
            "bestHttpCode": best.http_code,
            "bestRemoteIp": best.remote_ip,
            "bestEffectiveUrl": best.effective_url,
            "bestNote": best.note,
            "probes": [
                {
                    "interface": item.interface,
                    "exitCode": item.exit_code,
                    "httpCode": item.http_code,
                    "remoteIp": item.remote_ip,
                    "effectiveUrl": item.effective_url,
                    "note": item.note,
                    "reachable": item.reachable,
                    "outputPath": str(item.output_path),
                }
                for item in probes
            ],
        }
    )

results_payload = {
    "cellularInterfaces": interfaces,
    "maxTimeSeconds": int(max_time),
    "connectTimeoutSeconds": int(connect_timeout),
    "results": result_items,
}
results_path.write_text(json.dumps(results_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

reachable_count = sum(1 for item in result_items if item["reachable"])
lines = [
    "# Android Whitelist Front Probe Summary",
    "",
    f"- Cellular interfaces: `{', '.join(interfaces) if interfaces else 'n/a'}`",
    f"- Candidate URL count: `{len(result_items)}`",
    f"- Reachable URL count: `{reachable_count}`",
    f"- curl max-time: `{max_time}`",
    f"- curl connect-timeout: `{connect_timeout}`",
    f"- Results JSON: `{results_path}`",
    "",
    "## Results",
    "",
]
for item in sorted(result_items, key=lambda value: (not value["reachable"], value["bestExitCode"], value["url"])):
    status = "reachable" if item["reachable"] else "unreachable"
    best_http = item["bestHttpCode"] or "n/a"
    best_ip = item["bestRemoteIp"] or "n/a"
    best_note = item["bestNote"] or "n/a"
    lines.extend(
        [
            f"### {item['url']}",
            "",
            f"- Status: `{status}`",
            f"- Best interface: `{item['bestInterface']}`",
            f"- Best exit code: `{item['bestExitCode']}`",
            f"- Best HTTP code: `{best_http}`",
            f"- Best remote IP: `{best_ip}`",
            f"- Best note: `{best_note}`",
        ]
    )
    for probe in item["probes"]:
        note = probe["note"] or "n/a"
        lines.append(
            f"- Probe `{probe['interface']}`: `exit={probe['exitCode']}`, "
            f"`http={probe['httpCode'] or 'n/a'}`, `remoteIp={probe['remoteIp'] or 'n/a'}`, "
            f"`reachable={'yes' if probe['reachable'] else 'no'}`, `note={note}`, "
            f"`raw={probe['outputPath']}`"
        )
    lines.append("")

summary_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print(summary_path)
PY

echo "Wrote whitelist probe summary to $SUMMARY_PATH"
