#!/bin/zsh
set -euo pipefail

ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
PACKAGE_NAME="${ODIN_ONE_ANDROID_PACKAGE:-com.odinone.desktop.vk}"
ANDROID_SERIAL="${ODIN_ONE_ANDROID_SERIAL:-}"

TMP_DIR="${TMPDIR:-/tmp}"
CREDENTIAL_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-credential.xml"
DEVICE_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-device.xml"
UPDATED_CREDENTIAL_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-credential-updated.xml"
UPDATED_DEVICE_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-device-updated.xml"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-boot-restore-toggle.sh on
  apps/desktop/scripts/android-reality-boot-restore-toggle.sh off

This helper only modifies the debug app's persisted Android REALITY request on the
connected handset. It force-stops the package after the write so the next launch
observes the updated restore prefs from a fresh process.
It does not change repository config or production defaults.
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

adb_cmd() {
  if [[ -n "$ANDROID_SERIAL" ]]; then
    "$ADB_BIN" -s "$ANDROID_SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

cleanup() {
  rm -f \
    "$CREDENTIAL_PREFS_FILE" \
    "$DEVICE_PREFS_FILE" \
    "$UPDATED_CREDENTIAL_PREFS_FILE" \
    "$UPDATED_DEVICE_PREFS_FILE"
}
trap cleanup EXIT INT TERM

capture_run_as_file() {
  local remote_path="$1"
  local target_file="$2"
  adb_cmd exec-out run-as "$PACKAGE_NAME" cat "$remote_path" >"$target_file" 2>/dev/null || return 1
  [[ -s "$target_file" ]] || return 1
  if /usr/bin/grep -qiE '^(cat:|run-as:|error:)' "$target_file"; then
    return 1
  fi
  return 0
}

upload_run_as_file() {
  local source_file="$1"
  local remote_path="$2"
  local remote_tmp="/data/local/tmp/odin-one-boot-restore-toggle-$$-${remote_path:t}"
  adb_cmd push "$source_file" "$remote_tmp" >/dev/null
  adb_cmd exec-out run-as "$PACKAGE_NAME" cp "$remote_tmp" "$remote_path" >/dev/null
  adb_cmd shell rm -f "$remote_tmp" >/dev/null
}

mode="${1:-}"
case "$mode" in
  on)
    target_enabled=true
    ;;
  off)
    target_enabled=false
    ;;
  ""|"-h"|"--help")
    usage
    exit 0
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac

require_bin "$ADB_BIN" "adb"
require_bin "$PYTHON_BIN" "python3"

credential_remote="/data/data/${PACKAGE_NAME}/shared_prefs/odin_one_vpn_runtime.xml"
device_remote="/data/user_de/0/${PACKAGE_NAME}/shared_prefs/odin_one_vpn_runtime.xml"

if ! capture_run_as_file "$credential_remote" "$CREDENTIAL_PREFS_FILE"; then
  echo "Unable to read ${credential_remote} via run-as." >&2
  exit 1
fi

if ! capture_run_as_file "$device_remote" "$DEVICE_PREFS_FILE"; then
  : >"$DEVICE_PREFS_FILE"
fi

"$PYTHON_BIN" - "$target_enabled" "$CREDENTIAL_PREFS_FILE" "$DEVICE_PREFS_FILE" "$UPDATED_CREDENTIAL_PREFS_FILE" "$UPDATED_DEVICE_PREFS_FILE" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

target_enabled = sys.argv[1].lower() == "true"
credential_path = Path(sys.argv[2])
device_path = Path(sys.argv[3])
updated_credential_path = Path(sys.argv[4])
updated_device_path = Path(sys.argv[5])

def load_or_create_map(path: Path):
    raw = path.read_text(encoding="utf-8", errors="replace").strip() if path.exists() else ""
    if not raw:
        return ET.Element("map")
    return ET.fromstring(raw)

def find_child(root, tag, name):
    for child in root:
        if child.tag == tag and child.attrib.get("name") == name:
            return child
    return None

def set_string(root, name, value):
    child = find_child(root, "string", name)
    if child is None:
        child = ET.SubElement(root, "string", {"name": name})
    child.text = value

def set_boolean(root, name, value):
    child = find_child(root, "boolean", name)
    if child is None:
        child = ET.SubElement(root, "boolean", {"name": name})
    child.attrib["value"] = "true" if value else "false"

def patch_request(raw_request: str, enabled: bool) -> str:
    request = json.loads(raw_request)
    request["bootRestoreEnabled"] = enabled
    profile_json = request.get("profileJson")
    if isinstance(profile_json, str) and profile_json.strip():
        try:
            profile = json.loads(profile_json)
        except Exception:
            profile = None
        if isinstance(profile, dict):
            reality = profile.setdefault("androidRuntime", {}).setdefault("reality", {})
            reality["autoRestoreOnBoot"] = enabled
            request["profileJson"] = json.dumps(profile, ensure_ascii=False, indent=2)
    return json.dumps(request, ensure_ascii=False, separators=(",", ":"))

credential_root = load_or_create_map(credential_path)
last_request_child = find_child(credential_root, "string", "last_request")
if last_request_child is None or not (last_request_child.text or "").strip():
    raise SystemExit("The current debug install does not have a persisted Android REALITY last_request yet.")

patched_request = patch_request(last_request_child.text, target_enabled)

set_string(credential_root, "last_request", patched_request)
set_boolean(credential_root, "boot_restore_enabled", target_enabled)
ET.ElementTree(credential_root).write(updated_credential_path, encoding="utf-8", xml_declaration=True)

device_root = load_or_create_map(device_path)
set_string(device_root, "last_request", patched_request)
set_boolean(device_root, "boot_restore_enabled", target_enabled)
resume_child = find_child(credential_root, "boolean", "resume_eligible")
if resume_child is not None:
    set_boolean(device_root, "resume_eligible", resume_child.attrib.get("value", "false").lower() == "true")
ET.ElementTree(device_root).write(updated_device_path, encoding="utf-8", xml_declaration=True)
PY

upload_run_as_file "$UPDATED_CREDENTIAL_PREFS_FILE" "$credential_remote"
upload_run_as_file "$UPDATED_DEVICE_PREFS_FILE" "$device_remote"
adb_cmd shell am force-stop "$PACKAGE_NAME" >/dev/null

echo "boot_restore_enabled set to ${target_enabled} for ${PACKAGE_NAME}"
echo "force-stopped ${PACKAGE_NAME}; launch the app again to validate cold-start restore behavior."
