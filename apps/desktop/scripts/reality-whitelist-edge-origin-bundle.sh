#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

DATASET_FILE=""
EDGE_HOST=""
EDGE_PORT="443"
ORIGIN_HOST=""
BIND_HOST="0.0.0.0"
OUTPUT_DIR=""
LIMIT=""
INCLUDE_STABLE="0"

typeset -a ENTRY_TAGS=()
typeset -a ENTRY_SERVER_NAMES=()
typeset -a ENTRY_INDICES=()

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-edge-origin-bundle.sh [options]

Required:
  --dataset <path>            Promoted VPS lab dataset JSON.
  --edge-host <host>          Controlled edge dial host or IP used by clients.

Selection:
  --tag <tag>                 Select one dataset entry by tag. May be repeated.
  --server-name <name>        Select one dataset entry by SNI/serverName. May be repeated.
  --index <n>                 Select one dataset entry by 1-based index. May be repeated.

Options:
  --edge-port <port>          Client-facing edge port. Default: 443
  --origin-host <host>        Override the backend origin host. Default: dataset.serverHost/dataset.remoteHost
  --bind-host <host>          Edge listener bind host for generated configs. Default: 0.0.0.0
  --limit <count>             Limit entries after filtering.
  --include-stable            Keep the stable control entry when present.
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-reality-edge-origin-bundle/<stamp>
  -h, --help                  Show this help.

Outputs:
  - bundle.json
  - android-dataset.json
  - routes.json
  - subscription.txt
  - haproxy.cfg
  - nginx.stream.conf
  - summary.md
  - rollout-checklist.md

Behavior:
  - rewrites selected `vless://` URIs to dial the controlled edge host/port
  - keeps the original REALITY/SNI/pbk/sid shape intact
  - generates TCP pass-through edge configs that route by TLS SNI to origin lab ports
  - emits an Android-oriented dataset with `connectHost/connectPort` and `originHost/originPort`
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DATASET_FILE="$2"
      shift 2
      ;;
    --edge-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_HOST="$2"
      shift 2
      ;;
    --edge-port)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EDGE_PORT="$2"
      shift 2
      ;;
    --origin-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ORIGIN_HOST="$2"
      shift 2
      ;;
    --bind-host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      BIND_HOST="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_TAGS+=("$2")
      shift 2
      ;;
    --server-name)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_SERVER_NAMES+=("$2")
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ENTRY_INDICES+=("$2")
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
      ;;
    --include-stable)
      INCLUDE_STABLE="1"
      shift
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

require_bin "$PYTHON_BIN" "python3"

if [[ -z "$DATASET_FILE" || ! -f "$DATASET_FILE" ]]; then
  echo "Dataset JSON not found: $DATASET_FILE" >&2
  exit 1
fi
if [[ -z "$EDGE_HOST" ]]; then
  echo "--edge-host is required" >&2
  exit 1
fi
if ! [[ "$EDGE_PORT" =~ '^[0-9]+$' ]] || (( EDGE_PORT < 1 || EDGE_PORT > 65535 )); then
  echo "--edge-port must be a valid TCP port" >&2
  exit 1
fi
if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be a positive integer" >&2
  exit 1
fi
for index in "${ENTRY_INDICES[@]}"; do
  if ! [[ "$index" =~ '^[0-9]+$' ]]; then
    echo "--index values must be positive integers" >&2
    exit 1
  fi
done

if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-edge-origin-bundle/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

ENTRY_TAGS_JOINED="$(printf '%s\n' "${ENTRY_TAGS[@]}")"
ENTRY_SERVER_NAMES_JOINED="$(printf '%s\n' "${ENTRY_SERVER_NAMES[@]}")"
ENTRY_INDICES_JOINED="$(printf '%s\n' "${ENTRY_INDICES[@]}")"

ENTRY_TAGS_JOINED="$ENTRY_TAGS_JOINED" \
ENTRY_SERVER_NAMES_JOINED="$ENTRY_SERVER_NAMES_JOINED" \
ENTRY_INDICES_JOINED="$ENTRY_INDICES_JOINED" \
"$PYTHON_BIN" - "$DATASET_FILE" "$OUTPUT_DIR" "$EDGE_HOST" "$EDGE_PORT" "$ORIGIN_HOST" "$BIND_HOST" "$LIMIT" "$INCLUDE_STABLE" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse, quote, unquote

dataset_path = Path(sys.argv[1]).expanduser()
output_dir = Path(sys.argv[2]).expanduser()
edge_host = sys.argv[3].strip()
edge_port = int(sys.argv[4])
origin_host_override = sys.argv[5].strip()
bind_host = sys.argv[6].strip() or "0.0.0.0"
limit_raw = sys.argv[7].strip()
include_stable = sys.argv[8].strip() == "1"
limit = int(limit_raw) if limit_raw else None

dataset = json.loads(dataset_path.read_text(encoding="utf-8"))
all_entries = [entry for entry in (dataset.get("entries") or []) if isinstance(entry, dict)]
if not include_stable:
    all_entries = [entry for entry in all_entries if str(entry.get("mode") or "") != "stable-control"]
if not all_entries:
    raise SystemExit("No dataset entries available after filtering.")

wanted_tags = [line.strip() for line in os.environ.get("ENTRY_TAGS_JOINED", "").splitlines() if line.strip()]
wanted_names = [line.strip().lower() for line in os.environ.get("ENTRY_SERVER_NAMES_JOINED", "").splitlines() if line.strip()]
wanted_indices = [int(line.strip()) for line in os.environ.get("ENTRY_INDICES_JOINED", "").splitlines() if line.strip()]


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-") or "candidate"


def normalize_origin_host(entry: dict) -> str:
    return (
        str(entry.get("originHost") or "").strip()
        or origin_host_override
        or str(dataset.get("serverHost") or "").strip()
        or str(dataset.get("remoteHost") or "").strip()
    )


def rewrite_uri(raw_uri: str, connect_host: str, connect_port: int, label_suffix: str) -> str:
    parsed = urlparse(raw_uri)
    username = parsed.username or ""
    password = parsed.password
    userinfo = quote(username, safe="")
    if password is not None:
        userinfo += ":" + quote(password, safe="")
    netloc = f"{userinfo}@{connect_host}:{connect_port}"
    params = parse_qsl(parsed.query, keep_blank_values=True)
    encoded_query = urlencode(params, doseq=True)
    label = unquote(parsed.fragment or "")
    label = f"{label} | {label_suffix}" if label else label_suffix
    return urlunparse((parsed.scheme, netloc, parsed.path, "", encoded_query, quote(label, safe="| ")))


selected = []
seen = set()
if wanted_tags or wanted_names or wanted_indices:
    for tag in wanted_tags:
        for entry in all_entries:
            if str(entry.get("tag") or "") == tag:
                key = str(entry.get("tag") or "")
                if key not in seen:
                    selected.append(entry)
                    seen.add(key)
                break
        else:
            raise SystemExit(f"Dataset entry not found for tag: {tag}")
    for name in wanted_names:
        matches = [entry for entry in all_entries if str(entry.get("serverName") or "").strip().lower() == name]
        if not matches:
            raise SystemExit(f"Dataset entry not found for serverName: {name}")
        for entry in matches:
            key = str(entry.get("tag") or entry.get("serverName") or "")
            if key not in seen:
                selected.append(entry)
                seen.add(key)
    for index in wanted_indices:
        if index < 1 or index > len(all_entries):
            raise SystemExit(f"Dataset index out of range: {index}")
        entry = all_entries[index - 1]
        key = str(entry.get("tag") or entry.get("serverName") or "")
        if key not in seen:
            selected.append(entry)
            seen.add(key)
else:
    selected = list(all_entries)

if limit is not None:
    selected = selected[:limit]

routes = []
android_entries = []
subscription_lines = []
seen_sni_routes = {}

for index, entry in enumerate(selected, start=1):
    server_name = str(entry.get("serverName") or "").strip()
    if not server_name:
        raise SystemExit(f"Selected entry {index} is missing serverName.")
    origin_host = normalize_origin_host(entry)
    if not origin_host:
        raise SystemExit(f"Selected entry {server_name} is missing origin host context.")
    origin_port = int(entry.get("originPort") or entry.get("port") or 0)
    if origin_port <= 0:
        raise SystemExit(f"Selected entry {server_name} is missing a valid origin port.")
    transport = str(entry.get("transport") or "").strip().lower()
    fingerprint = str(entry.get("fingerprint") or "").strip() or ("firefox" if transport == "grpc" else "chrome")
    tag = str(entry.get("tag") or f"candidate-{index}").strip()
    route_key = server_name.lower()
    route_target = (origin_host, origin_port)
    previous = seen_sni_routes.get(route_key)
    if previous and previous != route_target:
        raise SystemExit(
            f"Conflicting origin targets for SNI {server_name}: {previous[0]}:{previous[1]} vs {origin_host}:{origin_port}"
        )
    seen_sni_routes[route_key] = route_target

    original_uri = str(entry.get("uri") or "").strip()
    rewritten_uri = None
    if original_uri:
        rewritten_uri = rewrite_uri(original_uri, edge_host, edge_port, f"via {edge_host}:{edge_port}")
        subscription_lines.append(rewritten_uri)

    route = {
        "index": index,
        "tag": tag,
        "serverName": server_name,
        "transport": transport,
        "fingerprint": fingerprint,
        "flow": entry.get("flow"),
        "grpcServiceName": entry.get("grpcServiceName"),
        "grpcAuthority": entry.get("grpcAuthority"),
        "connectHost": edge_host,
        "connectPort": edge_port,
        "originHost": origin_host,
        "originPort": origin_port,
        "source": entry.get("source") or "operator-curated:vps-lab",
        "mode": entry.get("mode") or "vps-lab",
        "originalUri": original_uri or None,
        "uri": rewritten_uri,
    }
    routes.append(route)
    android_entries.append(
        {
            "priority": entry.get("priority") or index,
            "tag": tag,
            "mode": "edge-origin-lab",
            "serverName": server_name,
            "port": origin_port,
            "connectHost": edge_host,
            "connectPort": edge_port,
            "originHost": origin_host,
            "originPort": origin_port,
            "transport": transport,
            "fingerprint": fingerprint,
            "flow": entry.get("flow"),
            "grpcServiceName": entry.get("grpcServiceName"),
            "grpcAuthority": entry.get("grpcAuthority"),
            "source": "operator-curated:vps-edge-origin",
            "originalSource": entry.get("source") or "operator-curated:vps-lab",
            "uri": rewritten_uri,
            "originalUri": original_uri or None,
        }
    )

generated_at = datetime.now(timezone.utc).isoformat()

bundle = {
    "kind": "odin-one-reality-whitelist-edge-origin-bundle-v1",
    "generatedAt": generated_at,
    "datasetSource": str(dataset_path),
    "edge": {
        "connectHost": edge_host,
        "connectPort": edge_port,
        "bindHost": bind_host,
    },
    "origin": {
        "defaultHost": origin_host_override or dataset.get("serverHost") or dataset.get("remoteHost"),
    },
    "count": len(routes),
    "routes": routes,
}

android_dataset = {
    "kind": "odin-one-reality-vps-lab-edge-dataset-v1",
    "generatedAt": generated_at,
    "remoteHost": origin_host_override or dataset.get("remoteHost") or dataset.get("serverHost"),
    "serverHost": origin_host_override or dataset.get("serverHost") or dataset.get("remoteHost"),
    "edgeHost": edge_host,
    "edgePort": edge_port,
    "datasetSource": str(dataset_path),
    "count": len(android_entries),
    "entries": android_entries,
}


def haproxy_backend_name(route: dict) -> str:
    return f"be_{slugify(route['tag'])}"


haproxy_lines = [
    "global",
    "  daemon",
    "  log /dev/log local0",
    "",
    "defaults",
    "  log global",
    "  mode tcp",
    "  timeout connect 10s",
    "  timeout client 60s",
    "  timeout server 60s",
    "",
    "frontend reality_edge_in",
    f"  bind {bind_host}:{edge_port}",
    "  mode tcp",
    "  tcp-request inspect-delay 5s",
    "  tcp-request content accept if { req.ssl_hello_type 1 }",
]
for route in routes:
    acl_name = f"sni_{slugify(route['serverName'])}"
    haproxy_lines.append(f"  acl {acl_name} req.ssl_sni -i {route['serverName']}")
    haproxy_lines.append(f"  use_backend {haproxy_backend_name(route)} if {acl_name}")
haproxy_lines.extend([""])
for route in routes:
    haproxy_lines.extend(
        [
            f"backend {haproxy_backend_name(route)}",
            "  mode tcp",
            f"  server {slugify(route['tag'])} {route['originHost']}:{route['originPort']} check",
            "",
        ]
    )

nginx_upstreams = [
    "stream {",
    "  map $ssl_preread_server_name $reality_backend {",
]
for route in routes:
    nginx_upstreams.append(f"    {route['serverName']} {slugify(route['tag'])};")
nginx_upstreams.append("    default reality_drop;")
nginx_upstreams.extend(
    [
        "  }",
        "",
        "  upstream reality_drop {",
        "    server 127.0.0.1:9;",
        "  }",
        "",
    ]
)
for route in routes:
    nginx_upstreams.extend(
        [
            f"  upstream {slugify(route['tag'])} {{",
            f"    server {route['originHost']}:{route['originPort']};",
            "  }",
            "",
        ]
    )
nginx_upstreams.extend(
    [
        "  server {",
        f"    listen {bind_host}:{edge_port};",
        "    proxy_connect_timeout 5s;",
        "    proxy_timeout 60s;",
        "    ssl_preread on;",
        "    proxy_pass $reality_backend;",
        "  }",
        "}",
    ]
)

summary_lines = [
    "# Reality Whitelist Edge / Origin Bundle",
    "",
    f"- Generated at: `{generated_at}`",
    f"- Source dataset: `{dataset_path}`",
    f"- Edge dial host: `{edge_host}`",
    f"- Edge dial port: `{edge_port}`",
    f"- Edge bind host: `{bind_host}`",
    f"- Selected entries: `{len(routes)}`",
    "",
    "## Routes",
    "",
]
for route in routes:
    summary_lines.append(
        f"- `{route['serverName']}` via `{edge_host}:{edge_port}` -> `{route['originHost']}:{route['originPort']}` | transport=`{route['transport']}` | tag=`{route['tag']}`"
    )
summary_lines.extend(
    [
        "",
        "## Output",
        "",
        "- `subscription.txt` rewrites the client dial host/port to the controlled edge while preserving REALITY params.",
        "- `android-dataset.json` keeps the origin port in `port` and adds `connectHost` / `connectPort` for future hidden Android passes.",
        "- `haproxy.cfg` and `nginx.stream.conf` route by TLS SNI without terminating REALITY.",
    ]
)

checklist_lines = [
    "# Reality Whitelist Edge / Origin Rollout Checklist",
    "",
    f"- [ ] Confirm the future edge surface `{edge_host}:{edge_port}` is actually whitelist-reachable on handset LTE.",
    f"- [ ] Deploy either `haproxy.cfg` or `nginx.stream.conf` to the controlled edge listener on `{bind_host}:{edge_port}`.",
    "- [ ] Verify the edge only does TCP pass-through and does not terminate TLS/REALITY.",
]
for route in routes:
    checklist_lines.append(
        f"- [ ] Confirm `{route['serverName']}` routes to `{route['originHost']}:{route['originPort']}` and that the origin port already passes local smoke."
    )
checklist_lines.extend(
    [
        "- [ ] Use the rewritten `subscription.txt` in an external client smoke before touching Odin Android runtime.",
        "- [ ] If external smoke passes, feed `android-dataset.json` into the hidden Android VPS lab helpers after the connect-host pass is installed.",
        "- [ ] Keep stable `direct-reality` as the control and default lane throughout the edge experiment.",
    ]
)

(output_dir / "bundle.json").write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output_dir / "routes.json").write_text(json.dumps(routes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output_dir / "android-dataset.json").write_text(json.dumps(android_dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output_dir / "subscription.txt").write_text("\n".join(subscription_lines) + ("\n" if subscription_lines else ""), encoding="utf-8")
(output_dir / "haproxy.cfg").write_text("\n".join(haproxy_lines) + "\n", encoding="utf-8")
(output_dir / "nginx.stream.conf").write_text("\n".join(nginx_upstreams) + "\n", encoding="utf-8")
(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
(output_dir / "rollout-checklist.md").write_text("\n".join(checklist_lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
