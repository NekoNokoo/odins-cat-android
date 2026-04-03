#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

OUTPUT_DIR=""
LIMIT="12"
typeset -a RESULTS_FILES=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-igareck-shortlist.sh [options]

Options:
  --results <path>         Smoke results.json file. May be repeated.
  --output-dir <dir>       Output directory. Default: /tmp/odin-one-igareck-shortlist/<stamp>
  --limit <count>          Max shortlist size. Default: 12
  -h, --help               Show this help.

Behavior:
  - reads one or more previous smoke result sets
  - keeps only passed candidates
  - groups them by simple server and host families
  - ranks repeated passes above one-off passes
  - writes a reusable operator shortlist dataset
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --results)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESULTS_FILES+=("$2")
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
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
if [[ ${#RESULTS_FILES[@]} -eq 0 ]]; then
  echo "Provide at least one --results file." >&2
  exit 1
fi
for path in "${RESULTS_FILES[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Results file not found: $path" >&2
    exit 1
  fi
done
if [[ ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be numeric" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-igareck-shortlist/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

RESULTS_FILES_JOINED="$(printf '%s\n' "${RESULTS_FILES[@]}")"

RESULTS_FILES_JOINED="$RESULTS_FILES_JOINED" \
"$PYTHON_BIN" - "$OUTPUT_DIR" "$LIMIT" <<'PY'
import json
import os
import re
import sys
import urllib.parse
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

output_dir = Path(sys.argv[1]).expanduser()
limit = int(sys.argv[2])
results_paths = [Path(line.strip()).expanduser() for line in os.environ.get("RESULTS_FILES_JOINED", "").splitlines() if line.strip()]
IPV4_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


def normalize_hostname(value: str) -> str:
    return str(value or "").strip().lower().rstrip(".")


def family_for(value: str | None):
    raw = normalize_hostname(value or "")
    if not raw:
        return None
    if IPV4_RE.match(raw):
        parts = raw.split(".")
        return ".".join(parts[:3]) + ".*"
    labels = raw.split(".")
    if len(labels) >= 2:
        return ".".join(labels[-2:])
    return raw


def exact_key(item):
    return (
        item.get("host"),
        int(item.get("port") or 0),
        item.get("transport"),
        item.get("security"),
        item.get("serverName"),
        item.get("wsHost"),
        item.get("wsPath"),
        item.get("grpcServiceName"),
    )


def infer_uri_from_config(item):
    config_path = item.get("configPath")
    if not config_path:
        return None
    path = Path(config_path).expanduser()
    if not path.is_file():
        return None
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    outbounds = cfg.get("outbounds") or []
    if not outbounds:
        return None
    outbound = outbounds[0]
    if outbound.get("type") != "vless":
        return None
    host = outbound.get("server")
    port = outbound.get("server_port")
    uuid = outbound.get("uuid")
    if not host or not port or not uuid:
        return None
    query = {"encryption": "none"}
    transport = item.get("transport") or "tcp"
    query["type"] = transport
    security = item.get("security") or "reality"
    query["security"] = security
    flow = outbound.get("flow") or item.get("flow") or ""
    if flow:
        query["flow"] = flow
    tls = outbound.get("tls") or {}
    server_name = (tls.get("server_name") or item.get("serverName") or "").strip()
    if server_name:
        query["sni"] = server_name
    utls = tls.get("utls") or {}
    fingerprint = (utls.get("fingerprint") or item.get("fingerprint") or "").strip()
    if fingerprint:
        query["fp"] = fingerprint
    if tls.get("insecure") or item.get("allowInsecure"):
        query["insecure"] = "1"
    if security == "reality":
        reality = tls.get("reality") or {}
        public_key = (reality.get("public_key") or item.get("publicKey") or "").strip()
        short_id = (reality.get("short_id") or item.get("shortId") or "").strip()
        if public_key:
            query["pbk"] = public_key
        if short_id:
            query["sid"] = short_id
    transport_cfg = outbound.get("transport") or {}
    if transport == "ws":
        path_value = (transport_cfg.get("path") or item.get("wsPath") or "").strip()
        if path_value:
            query["path"] = path_value
        headers = transport_cfg.get("headers") or {}
        host_header = (headers.get("Host") or item.get("wsHost") or "").strip()
        if host_header:
            query["host"] = host_header
    elif transport == "grpc":
        service_name = (transport_cfg.get("service_name") or item.get("grpcServiceName") or "").strip()
        if service_name:
            query["serviceName"] = service_name
    fragment = urllib.parse.quote(item.get("label") or item.get("serverName") or host, safe="")
    return f"vless://{uuid}@{host}:{int(port)}?{urllib.parse.urlencode(query, doseq=False, quote_via=urllib.parse.quote, safe='')}#{fragment}"


passed = []
server_family_pass = Counter()
host_family_pass = Counter()
server_name_pass = Counter()
transport_pass = Counter()

for path in results_paths:
    payload = json.loads(path.read_text(encoding="utf-8"))
    for item in payload.get("results") or []:
        if not item.get("passed"):
            continue
        item = dict(item)
        item["sourceResults"] = str(path)
        item["uri"] = infer_uri_from_config(item)
        item["serverFamily"] = family_for(item.get("serverName"))
        item["hostFamily"] = family_for(item.get("host"))
        passed.append(item)
        if item["serverFamily"]:
            server_family_pass[item["serverFamily"]] += 1
        if item["hostFamily"]:
            host_family_pass[item["hostFamily"]] += 1
        if item.get("serverName"):
            server_name_pass[item["serverName"]] += 1
        transport_pass[(item.get("transport"), item.get("security"))] += 1

if not passed:
    raise SystemExit("no passed candidates found in the provided results")

best_by_exact = {}
for item in passed:
    key = exact_key(item)
    score = 100
    score += server_family_pass[item["serverFamily"]] * 30
    score += host_family_pass[item["hostFamily"]] * 20
    score += server_name_pass[item["serverName"]] * 15
    score += transport_pass[(item["transport"], item["security"])] * 10
    if item["transport"] == "tcp":
        score += 8
    elif item["transport"] == "grpc":
        score += 6
    elif item["transport"] == "ws":
        score += 4
    if item["security"] == "reality":
        score += 6
    elif item["security"] == "tls":
        score += 3
    item["shortlistScore"] = score
    previous = best_by_exact.get(key)
    if previous is None or item["shortlistScore"] > previous["shortlistScore"]:
        best_by_exact[key] = item

selected = sorted(
    best_by_exact.values(),
    key=lambda item: (
        -item["shortlistScore"],
        -server_family_pass[item["serverFamily"]],
        -server_name_pass[item["serverName"]],
        item["serverName"],
        item["host"],
        int(item["port"] or 0),
    ),
)[:limit]

dataset = {
    "kind": "odin-one-igareck-operator-shortlist-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "resultSources": [str(path) for path in results_paths],
    "summary": {
        "passedObservations": len(passed),
        "uniqueShortlistCandidates": len(selected),
    },
    "candidates": selected,
}
(output_dir / "shortlist.json").write_text(json.dumps(dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output_dir / "subscription.txt").write_text("\n".join(item["uri"] for item in selected if item.get("uri")) + "\n", encoding="utf-8")

lines = [
    "# Igareck Operator Shortlist",
    "",
    f"- Generated at: `{dataset['generatedAt']}`",
    f"- Result sets: `{len(results_paths)}`",
    f"- Passed observations: `{len(passed)}`",
    f"- Unique shortlist candidates: `{len(selected)}`",
    "",
    "## Strongest families",
    "",
]
for family, count in server_family_pass.most_common():
    lines.append(f"- server family `{family}` -> `{count}` passes")

lines.extend([
    "",
    "## Shortlist",
    "",
])
for item in selected:
    lines.append(
        f"- score=`{item['shortlistScore']}` | `{item['serverName']}` via `{item['host']}:{item['port']}` | transport=`{item['transport']}` | security=`{item['security']}` | serverFamily=`{item['serverFamily']}` | hostFamily=`{item['hostFamily']}`"
    )

(output_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(output_dir)
PY
