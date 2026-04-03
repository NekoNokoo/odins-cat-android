#!/bin/zsh
set -euo pipefail

ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
PACKAGE_NAME="${ODIN_ONE_ANDROID_PACKAGE:-com.odinone.desktop.vk}"
ANDROID_SERIAL="${ODIN_ONE_ANDROID_SERIAL:-}"
SCRIPT_DIR="${0:A:h}"
PRESET_HELPER="${SCRIPT_DIR}/android-reality-profile-preset.sh"

TMP_DIR="${TMPDIR:-/tmp}"
PRESET_FILE="${TMP_DIR%/}/odin-one-android-reality-preset.json"
CREDENTIAL_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-credential.xml"
DEVICE_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-device.xml"
UPDATED_CREDENTIAL_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-credential-updated.xml"
UPDATED_DEVICE_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-device-updated.xml"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-apply-preset.sh <preset>

Examples:
  apps/desktop/scripts/android-reality-apply-preset.sh dot-google
  apps/desktop/scripts/android-reality-apply-preset.sh doh-cloudflare

This helper patches the debug app's persisted Android REALITY request on the
connected handset using one of the documented preset blocks. It force-stops the
package after the write so the next launch is a clean validation run.
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
    "$PRESET_FILE" \
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
  local remote_tmp="/data/local/tmp/odin-one-apply-preset-$$-${remote_path:t}"
  adb_cmd push "$source_file" "$remote_tmp" >/dev/null
  adb_cmd exec-out run-as "$PACKAGE_NAME" cp "$remote_tmp" "$remote_path" >/dev/null
  adb_cmd shell rm -f "$remote_tmp" >/dev/null
}

preset="${1:-}"
if [[ -z "$preset" || "$preset" == "-h" || "$preset" == "--help" ]]; then
  usage
  exit 0
fi

require_bin "$ADB_BIN" "adb"
require_bin "$PYTHON_BIN" "python3"

if [[ ! -x "$PRESET_HELPER" ]]; then
  echo "Preset helper not found: ${PRESET_HELPER}" >&2
  exit 1
fi

zsh "$PRESET_HELPER" "$preset" >"$PRESET_FILE"

# Stop the package before touching prefs so a live runtime cannot flush
# stale stable state over the newly patched hidden preset during shutdown.
adb_cmd shell am force-stop "$PACKAGE_NAME" >/dev/null || true

credential_remote="/data/data/${PACKAGE_NAME}/shared_prefs/odin_one_vpn_runtime.xml"
device_remote="/data/user_de/0/${PACKAGE_NAME}/shared_prefs/odin_one_vpn_runtime.xml"

if ! capture_run_as_file "$credential_remote" "$CREDENTIAL_PREFS_FILE"; then
  echo "Unable to read ${credential_remote} via run-as." >&2
  exit 1
fi

if ! capture_run_as_file "$device_remote" "$DEVICE_PREFS_FILE"; then
  : >"$DEVICE_PREFS_FILE"
fi

"$PYTHON_BIN" - "$preset" "$PRESET_FILE" "$CREDENTIAL_PREFS_FILE" "$DEVICE_PREFS_FILE" "$UPDATED_CREDENTIAL_PREFS_FILE" "$UPDATED_DEVICE_PREFS_FILE" <<'PY'
import copy
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

preset_name = sys.argv[1]
preset_path = Path(sys.argv[2])
credential_path = Path(sys.argv[3])
device_path = Path(sys.argv[4])
updated_credential_path = Path(sys.argv[5])
updated_device_path = Path(sys.argv[6])

DERIVED_KEYS = [
    "configMode",
    "runtimeFamily",
    "activationState",
    "dnsMode",
    "strictRoute",
    "disableMultiplex",
    "tlsFragment",
    "recordFragment",
    "bootRestoreEnabled",
    "allowPrivateNetworkBypass",
    "privateBypassCidrs",
    "networkReloadOnChange",
    "networkReloadDebounceMs",
    "dnsServer",
    "dnsServerPort",
    "dnsServerName",
    "dnsDohPath",
    "dnsStrategy",
    "dnsDisableCache",
    "dnsIndependentCache",
    "includePackages",
    "excludePackages",
    "activeFeatures",
    "profileHash",
    "startSource",
    "frontHost",
    "frontConnectHost",
    "frontConnectPort",
    "frontPath",
    "frontProvider",
    "frontTag",
    "selectedSniHint",
    "selectedCidrHint",
    "whitelistHintSource",
    "whitelistHintTag",
    "whitelistHintSelection",
    "whitelistHintPoolSize",
    "whitelistBootstrapMode",
    "cdnProvider",
    "cdnTransport",
    "cdnFrontHost",
    "cdnFrontPort",
    "cdnFrontPath",
    "cdnConnectHost",
    "cdnConnectPort",
    "cdnTlsServerName",
    "cdnHttpHostHeader",
    "cdnFrontTag",
    "cdnFrontSelection",
    "cdnFrontPoolSize",
    "cdnOriginHost",
    "cdnOriginPort",
    "cdnOriginScheme",
    "cdnOriginPath",
    "cdnBootstrapMode",
]

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

def read_boolean(root, name, default=False):
    child = find_child(root, "boolean", name)
    if child is None:
        return default
    return child.attrib.get("value", "false").lower() == "true"

def deep_merge(base, overlay):
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        return copy.deepcopy(overlay)
    result = copy.deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result

def ensure_android_runtime(profile):
    android_runtime = profile.setdefault("androidRuntime", {})
    if not isinstance(android_runtime, dict):
        android_runtime = {}
        profile["androidRuntime"] = android_runtime
    return android_runtime

def boot_restore_enabled_from_profile(profile):
    android_runtime = profile.get("androidRuntime", {})
    if (
        isinstance(android_runtime, dict)
        and isinstance(android_runtime.get("cdnAntiWhitelist"), dict)
        and android_runtime["cdnAntiWhitelist"].get("enabled", False)
    ):
        return False
    if (
        isinstance(android_runtime, dict)
        and isinstance(android_runtime.get("realityWhitelistHints"), dict)
        and android_runtime["realityWhitelistHints"].get("enabled", False)
    ):
        return False
    return bool(
        profile.get("androidRuntime", {})
        .get("reality", {})
        .get("autoRestoreOnBoot", False)
    )

def patch_request(raw_request: str, preset_raw: str):
    request = json.loads(raw_request)
    preset_profile = json.loads(preset_raw)
    profile_raw = request.get("profileJson")
    existing_profile = json.loads(profile_raw) if isinstance(profile_raw, str) and profile_raw.strip() else {}
    merged_profile = deep_merge(existing_profile, preset_profile)
    android_runtime = ensure_android_runtime(merged_profile)
    cdn_runtime = android_runtime.setdefault("cdnAntiWhitelist", {})
    if not isinstance(cdn_runtime, dict):
        cdn_runtime = {}
        android_runtime["cdnAntiWhitelist"] = cdn_runtime
    whitelist_runtime = android_runtime.setdefault("realityWhitelistHints", {})
    if not isinstance(whitelist_runtime, dict):
        whitelist_runtime = {}
        android_runtime["realityWhitelistHints"] = whitelist_runtime
    if preset_name.startswith("cdn-"):
        cdn_runtime["enabled"] = True
        whitelist_runtime["enabled"] = False
        reality_runtime = android_runtime.setdefault("reality", {})
        if not isinstance(reality_runtime, dict):
            reality_runtime = {}
            android_runtime["reality"] = reality_runtime
        reality_runtime["autoRestoreOnBoot"] = False
    elif preset_name.startswith("reality-whitelist-"):
        whitelist_runtime["enabled"] = True
        cdn_runtime["enabled"] = False
        reality_runtime = android_runtime.setdefault("reality", {})
        if not isinstance(reality_runtime, dict):
            reality_runtime = {}
            android_runtime["reality"] = reality_runtime
        reality_runtime["autoRestoreOnBoot"] = False
    else:
        cdn_runtime["enabled"] = False
        whitelist_runtime["enabled"] = False
    request["profileJson"] = json.dumps(merged_profile, ensure_ascii=False, separators=(",", ":"))
    for key in DERIVED_KEYS:
        request.pop(key, None)
    if preset_name == "baseline":
        request.pop("debugRealityPreset", None)
        request["preserveHiddenRealityOverrides"] = False
    else:
        request["debugRealityPreset"] = preset_name
        request["preserveHiddenRealityOverrides"] = True
    return request, boot_restore_enabled_from_profile(merged_profile)

preset_raw = preset_path.read_text(encoding="utf-8")
credential_root = load_or_create_map(credential_path)
last_request_child = find_child(credential_root, "string", "last_request")
if last_request_child is None or not (last_request_child.text or "").strip():
    raise SystemExit("The current debug install does not have a persisted Android REALITY last_request yet.")

patched_request, boot_restore_enabled = patch_request(last_request_child.text, preset_raw)
patched_request_raw = json.dumps(patched_request, ensure_ascii=False, separators=(",", ":"))

set_string(credential_root, "last_request", patched_request_raw)
set_boolean(credential_root, "boot_restore_enabled", boot_restore_enabled)
ET.ElementTree(credential_root).write(updated_credential_path, encoding="utf-8", xml_declaration=True)

device_root = load_or_create_map(device_path)
set_string(device_root, "last_request", patched_request_raw)
set_boolean(device_root, "boot_restore_enabled", boot_restore_enabled)
set_boolean(device_root, "resume_eligible", read_boolean(credential_root, "resume_eligible", True))
ET.ElementTree(device_root).write(updated_device_path, encoding="utf-8", xml_declaration=True)
PY

upload_run_as_file "$UPDATED_CREDENTIAL_PREFS_FILE" "$credential_remote"
upload_run_as_file "$UPDATED_DEVICE_PREFS_FILE" "$device_remote"
adb_cmd shell am force-stop "$PACKAGE_NAME" >/dev/null

echo "Applied preset ${preset} to ${PACKAGE_NAME}"
echo "force-stopped ${PACKAGE_NAME}; launch the app again for a clean validation run."

if [[ "$preset" == cdn-* ]]; then
  "$PYTHON_BIN" - "$PRESET_FILE" <<'PY'
import json
import sys
from pathlib import Path

preset_path = Path(sys.argv[1])
payload = json.loads(preset_path.read_text(encoding="utf-8"))
runtime = ((payload.get("androidRuntime") or {}).get("cdnAntiWhitelist") or {})
front_pool = runtime.get("frontPool") or []
front_host = ((front_pool[0] or {}).get("host") if front_pool else "") or ""
origin_host = ((runtime.get("origin") or {}).get("host") or "")

if front_host.endswith(".example.com") or origin_host.endswith(".example.com"):
    print("warning: cdn preset still uses placeholder front/origin hosts; override them before the real owner-lab network test.", file=sys.stderr)
PY
fi

if [[ "$preset" == reality-whitelist-* ]]; then
  "$PYTHON_BIN" - "$PRESET_FILE" <<'PY'
import json
import sys
from pathlib import Path

preset_path = Path(sys.argv[1])
payload = json.loads(preset_path.read_text(encoding="utf-8"))
runtime = ((payload.get("androidRuntime") or {}).get("realityWhitelistHints") or {})
hints = runtime.get("hints") or []
selected_server_name = ((hints[0] or {}).get("serverName") if hints else "") or ""

if selected_server_name.endswith(".example.com"):
    print("warning: reality-whitelist preset still uses placeholder SNI hints; override them before the real owner-lab network test.", file=sys.stderr)
PY
fi
