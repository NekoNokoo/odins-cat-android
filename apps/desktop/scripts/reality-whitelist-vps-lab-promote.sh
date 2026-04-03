#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

VERIFY_JSON=""
OUTPUT_DIR=""
INCLUDE_STABLE="1"
LIMIT=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-promote.sh [options]

Required:
  --verify <path>            Verify JSON produced by reality-whitelist-vps-lab-verify.sh

Options:
  --output-dir <dir>         Output directory. Default: /tmp/odin-one-reality-vps-lab-promote/<stamp>
  --skip-stable              Exclude the stable control lane from the promoted dataset/subscription.
  --limit <count>            Optional limit after ranking.
  -h, --help                 Show this help.

Outputs:
  - dataset.json
  - summary.md
  - subscription.txt

Behavior:
  - keeps only smoke-passed entries
  - ranks stable first, then grpc, then tcp by port/serverName
  - emits a reusable operator dataset for future Odin integration
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      VERIFY_JSON="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-stable)
      INCLUDE_STABLE="0"
      shift
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
if [[ -z "$VERIFY_JSON" || ! -f "$VERIFY_JSON" ]]; then
  echo "Verify JSON not found: $VERIFY_JSON" >&2
  exit 1
fi
if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be a positive integer" >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab-promote/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

"$PYTHON_BIN" - "$VERIFY_JSON" "$OUTPUT_DIR" "$INCLUDE_STABLE" "$LIMIT" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

verify_path = Path(sys.argv[1]).expanduser()
output_dir = Path(sys.argv[2]).expanduser()
include_stable = sys.argv[3].strip() == "1"
limit_raw = sys.argv[4].strip()
limit = int(limit_raw) if limit_raw else None

verify = json.loads(verify_path.read_text(encoding="utf-8"))
inventory = verify.get("inventory") or {}
stable = verify.get("stable")
entries = verify.get("entries") or []


def rank_key(entry):
    kind_rank = 0 if entry.get("isStable") else 1
    transport_rank = {"grpc": 0, "tcp": 1}.get(str(entry.get("network") or ""), 9)
    return (
        kind_rank,
        transport_rank,
        int(entry.get("port") or 0),
        str(entry.get("serverName") or ""),
    )


promoted = []
if include_stable and isinstance(stable, dict) and stable.get("smokePassed"):
    promoted.append({
        "priority": 1,
        "tag": stable.get("tag"),
        "mode": "stable-control",
        "serverName": stable.get("serverName"),
        "port": stable.get("port"),
        "transport": stable.get("network"),
        "dest": stable.get("dest"),
        "flow": stable.get("flow"),
        "grpcServiceName": stable.get("grpcServiceName"),
        "grpcAuthority": stable.get("grpcAuthority"),
        "grpcMultiMode": stable.get("grpcMultiMode"),
        "uri": stable.get("uri"),
        "source": "operator-curated:vps-lab",
        "smoke": stable.get("smoke"),
    })

lab_entries = [entry for entry in entries if isinstance(entry, dict) and entry.get("smokePassed")]
lab_entries.sort(key=rank_key)
for entry in lab_entries:
    promoted.append({
        "priority": len(promoted) + 1,
        "tag": entry.get("tag"),
        "mode": "vps-lab",
        "serverName": entry.get("serverName"),
        "port": entry.get("port"),
        "transport": entry.get("network"),
        "dest": entry.get("dest"),
        "flow": entry.get("flow"),
        "grpcServiceName": entry.get("grpcServiceName"),
        "grpcAuthority": entry.get("grpcAuthority"),
        "grpcMultiMode": entry.get("grpcMultiMode"),
        "uri": entry.get("uri"),
        "source": "operator-curated:vps-lab",
        "smoke": entry.get("smoke"),
    })

if limit is not None:
    promoted = promoted[:limit]
    for index, entry in enumerate(promoted, start=1):
        entry["priority"] = index

dataset = {
    "kind": "odin-one-reality-vps-lab-dataset-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "remoteHost": inventory.get("remoteHost"),
    "serverHost": inventory.get("serverHost"),
    "verifySource": str(verify_path),
    "count": len(promoted),
    "entries": promoted,
}

(output_dir / "dataset.json").write_text(
    json.dumps(dataset, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
(output_dir / "subscription.txt").write_text(
    "\n".join(entry["uri"] for entry in promoted if entry.get("uri")) + ("\n" if promoted else ""),
    encoding="utf-8",
)

summary_lines = [
    "# Reality Whitelist VPS Lab Promote",
    "",
    f"- Generated at: `{dataset['generatedAt']}`",
    f"- Remote host: `{dataset.get('remoteHost')}`",
    f"- Promoted entries: `{len(promoted)}`",
    f"- Included stable control: `{str(include_stable).lower()}`",
    "",
    "## Entries",
    "",
]
if not promoted:
    summary_lines.append("- No smoke-passed entries were promoted.")
else:
    for entry in promoted:
        summary_lines.append(
            f"- `P{entry['priority']}` `{entry['serverName']}` -> `:{entry['port']}` | transport=`{entry['transport']}` | mode=`{entry['mode']}`"
        )
(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
