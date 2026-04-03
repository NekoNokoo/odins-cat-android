#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_SCRIPT="${SCRIPT_DIR}/reality-whitelist-vps-lab-status.sh"
LOCAL_SMOKE_SCRIPT="${SCRIPT_DIR}/reality-whitelist-local-smoke.sh"

REMOTE_HOST=""
SSH_KEY=""
REMOTE_USER="root"
OUTPUT_DIR=""
SMOKE_ENGINE="sing-box"
INCLUDE_STABLE_CONTROL="1"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/reality-whitelist-vps-lab-verify.sh [options]

Required:
  --host <server-host>        VPS hostname or IP.
  --ssh-key <path>            SSH private key for the VPS.

Options:
  --remote-user <user>        SSH username. Default: root
  --output-dir <dir>          Output directory. Default: /tmp/odin-one-reality-vps-lab-verify/<stamp>
  --smoke-engine <engine>     Local smoke engine. Default: sing-box
  --skip-stable-control       Do not include stable `reality-in` in the verification smoke run.
  -h, --help                  Show this help.

Outputs:
  - status/inventory.json
  - smoke/results.json
  - verify.json
  - summary.md
  - phone-subscription.txt
  - phone-subscription-with-stable.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_HOST="$2"
      shift 2
      ;;
    --ssh-key)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SSH_KEY="$2"
      shift 2
      ;;
    --remote-user)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      REMOTE_USER="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --smoke-engine)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SMOKE_ENGINE="$2"
      shift 2
      ;;
    --skip-stable-control)
      INCLUDE_STABLE_CONTROL="0"
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
if [[ -z "$REMOTE_HOST" ]]; then
  echo "Provide --host." >&2
  exit 1
fi
if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
  echo "SSH key not found: $SSH_KEY" >&2
  exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  OUTPUT_DIR="/tmp/odin-one-reality-vps-lab-verify/${stamp}"
fi
"$MKDIR_BIN" -p "$OUTPUT_DIR"

STATUS_DIR="${OUTPUT_DIR}/status"
SMOKE_DIR="${OUTPUT_DIR}/smoke"
VERIFY_JSON="${OUTPUT_DIR}/verify.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"
PHONE_SUBSCRIPTION="${OUTPUT_DIR}/phone-subscription.txt"
PHONE_SUBSCRIPTION_WITH_STABLE="${OUTPUT_DIR}/phone-subscription-with-stable.txt"

status_args=(
  --host "$REMOTE_HOST"
  --ssh-key "$SSH_KEY"
  --remote-user "$REMOTE_USER"
  --output-dir "$STATUS_DIR"
)
if [[ "$INCLUDE_STABLE_CONTROL" == "1" ]]; then
  status_args+=(--include-stable)
fi
/bin/zsh "$STATUS_SCRIPT" "${status_args[@]}" >/dev/null

/bin/zsh "$LOCAL_SMOKE_SCRIPT" \
  --subscription "${STATUS_DIR}/subscription.txt" \
  --engine "$SMOKE_ENGINE" \
  --output-dir "$SMOKE_DIR" >/dev/null

"$PYTHON_BIN" - "${STATUS_DIR}/inventory.json" "${SMOKE_DIR}/results.json" "$VERIFY_JSON" "$SUMMARY_MD" "$PHONE_SUBSCRIPTION" "$PHONE_SUBSCRIPTION_WITH_STABLE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

inventory_path = Path(sys.argv[1]).expanduser()
smoke_path = Path(sys.argv[2]).expanduser()
verify_path = Path(sys.argv[3]).expanduser()
summary_path = Path(sys.argv[4]).expanduser()
phone_subscription_path = Path(sys.argv[5]).expanduser()
phone_subscription_with_stable_path = Path(sys.argv[6]).expanduser()

inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
smoke = json.loads(smoke_path.read_text(encoding="utf-8"))

entries = []
stable = inventory.get("stable")
for entry in inventory.get("entries") or []:
    if isinstance(entry, dict):
        entries.append(dict(entry))
if isinstance(stable, dict):
    stable = dict(stable)

smoke_map = {}
for result in smoke.get("results") or []:
    if not isinstance(result, dict):
        continue
    key = (
        str(result.get("host") or "").strip(),
        int(result.get("port") or 0),
        str(result.get("transport") or "").strip(),
        str(result.get("serverName") or "").strip(),
    )
    smoke_map[key] = result

def attach(entry, *, is_stable=False):
    key = (
        inventory.get("serverHost") or inventory.get("remoteHost") or "",
        int(entry.get("port") or 0),
        str(entry.get("network") or "").strip(),
        str(entry.get("serverName") or "").strip(),
    )
    result = smoke_map.get(key)
    attached = dict(entry)
    attached["smoke"] = result
    attached["smokePassed"] = bool(result and result.get("passed"))
    attached["isStable"] = is_stable
    return attached

verified_entries = [attach(entry) for entry in entries]
verified_stable = attach(stable, is_stable=True) if stable else None

passed_lab_uris = [entry["uri"] for entry in verified_entries if entry.get("smokePassed")]
phone_subscription_path.write_text("\n".join(passed_lab_uris) + ("\n" if passed_lab_uris else ""), encoding="utf-8")

phone_with_stable = []
if verified_stable and verified_stable.get("smokePassed"):
    phone_with_stable.append(verified_stable["uri"])
phone_with_stable.extend(passed_lab_uris)
phone_subscription_with_stable_path.write_text(
    "\n".join(phone_with_stable) + ("\n" if phone_with_stable else ""),
    encoding="utf-8",
)

verify = {
    "kind": "odin-one-reality-whitelist-vps-lab-verify-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "inventory": inventory,
    "stable": verified_stable,
    "entries": verified_entries,
    "passedLabCount": len(passed_lab_uris),
}
verify_path.write_text(json.dumps(verify, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Reality Whitelist VPS Lab Verify",
    "",
    f"- Generated at: `{verify['generatedAt']}`",
    f"- Remote host: `{inventory.get('remoteHost')}`",
    f"- Smoke engine: `{smoke.get('engine')}`",
    f"- Stable control passed: `{str(bool(verified_stable and verified_stable.get('smokePassed'))).lower()}`",
    f"- Passed lab entries: `{len(passed_lab_uris)}` / `{len(verified_entries)}`",
    "",
    "## Results",
    "",
]
if verified_stable:
    stable_smoke = verified_stable.get("smoke") or {}
    summary_lines.append(
        f"- stable `{verified_stable.get('serverName')}` -> `:{verified_stable.get('port')}` | "
        f"`{'passed' if verified_stable.get('smokePassed') else 'failed'}`"
        + (f" | curlExit=`{stable_smoke.get('curlExit')}` | http=`{stable_smoke.get('httpCode')}`" if stable_smoke else "")
    )
for entry in verified_entries:
    smoke_result = entry.get("smoke") or {}
    summary_lines.append(
        f"- `{entry.get('tag')}` -> `:{entry.get('port')}` | transport=`{entry.get('network')}` | sni=`{entry.get('serverName')}` | "
        f"`{'passed' if entry.get('smokePassed') else 'failed'}`"
        + (f" | curlExit=`{smoke_result.get('curlExit')}` | http=`{smoke_result.get('httpCode')}`" if smoke_result else "")
    )

summary_lines.extend([
    "",
    "## Phone Packs",
    "",
    f"- Passed-only labs: `{phone_subscription_path}`",
    f"- Passed labs with stable control: `{phone_subscription_with_stable_path}`",
])
summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY

echo "$OUTPUT_DIR"
