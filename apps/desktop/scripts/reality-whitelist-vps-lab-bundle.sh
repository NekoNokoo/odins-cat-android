#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

typeset -a LAB_DIRS=()
OUTPUT_DIR=""
ONLY_PASSED="0"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-bundle.sh [options]

Options:
  --lab-dir <dir>           Lab rollout directory. May be repeated.
  --output-dir <dir>        Output directory. Default: /tmp/odin-one-reality-vps-lab-bundle/<stamp>
  --only-passed-smoke       Include only lab dirs with a sibling manual smoke results.json that passed.
  -h, --help                Show this help.

Behavior:
  - reads subscription.txt and lab-metadata.json from each lab dir
  - optionally filters out candidates whose sibling `*-smoke-manual/results.json` has no pass
  - writes a combined subscription.txt and bundle summary
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lab-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LAB_DIRS+=("$2")
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --only-passed-smoke)
      ONLY_PASSED="1"
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
if (( ${#LAB_DIRS[@]} == 0 )); then
  echo "Provide at least one --lab-dir." >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab-bundle/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

LAB_DIRS_JOINED="$(printf '%s\n' "${LAB_DIRS[@]}")"

LAB_DIRS_JOINED="$LAB_DIRS_JOINED" \
"$PYTHON_BIN" - "$OUTPUT_DIR" "$ONLY_PASSED" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

output_dir = Path(sys.argv[1]).expanduser()
only_passed = sys.argv[2].strip() == "1"


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


lab_dirs = [Path(line.strip()).expanduser() for line in os.environ.get("LAB_DIRS_JOINED", "").splitlines() if line.strip()]
selected = []
seen_uris = set()

for lab_dir in lab_dirs:
    subscription_path = lab_dir / "subscription.txt"
    metadata_path = lab_dir / "lab-metadata.json"
    if not subscription_path.is_file() or not metadata_path.is_file():
        continue
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    uri = subscription_path.read_text(encoding="utf-8").strip()
    if not uri or uri in seen_uris:
        continue

    smoke_result = None
    if only_passed:
        smoke_dir = lab_dir.parent / f"{lab_dir.name}-smoke-manual"
        results_path = smoke_dir / "results.json"
        if not results_path.is_file():
          continue
        payload = json.loads(results_path.read_text(encoding="utf-8"))
        results = payload.get("results")
        if not isinstance(results, list) or not results:
            continue
        smoke_result = results[0]
        if not smoke_result.get("passed"):
            continue

    seen_uris.add(uri)
    selected.append({
        "labDir": str(lab_dir),
        "uri": uri,
        "tag": ((metadata.get("lab") or {}).get("tag")),
        "port": ((metadata.get("lab") or {}).get("port")),
        "dest": ((metadata.get("lab") or {}).get("dest")),
        "serverName": ((metadata.get("candidate") or {}).get("serverName")),
        "transport": ((metadata.get("candidate") or {}).get("transport")),
        "smoke": smoke_result,
    })

selected.sort(key=lambda item: (
    0 if (item.get("smoke") or {}).get("passed") else 1,
    str(item.get("transport") or ""),
    str(item.get("serverName") or ""),
))

(output_dir / "subscription.txt").write_text(
    "\n".join(item["uri"] for item in selected) + ("\n" if selected else ""),
    encoding="utf-8",
)
(output_dir / "bundle.json").write_text(
    json.dumps({
        "kind": "odin-one-reality-whitelist-vps-lab-bundle-v1",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "onlyPassedSmoke": only_passed,
        "count": len(selected),
        "entries": selected,
    }, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

summary_lines = [
    "# Reality Whitelist VPS Lab Bundle",
    "",
    f"- Generated at: `{datetime.now(timezone.utc).isoformat()}`",
    f"- Included lab dirs: `{len(selected)}`",
    f"- Only passed smoke: `{str(only_passed).lower()}`",
    "",
    "## Entries",
    "",
]
if not selected:
    summary_lines.append("- No entries were selected.")
else:
    for entry in selected:
        smoke = entry.get("smoke") or {}
        smoke_note = ""
        if smoke:
            smoke_note = f" | smoke=`{'passed' if smoke.get('passed') else 'failed'}`"
        summary_lines.append(
            f"- `{entry.get('serverName')}` -> `:{entry.get('port')}` | transport=`{entry.get('transport')}`{smoke_note}"
        )

(output_dir / "summary.md").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
