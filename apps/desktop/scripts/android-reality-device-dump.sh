#!/bin/zsh
set -euo pipefail

ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
PACKAGE_NAME="${ODIN_ONE_ANDROID_PACKAGE:-com.odinone.desktop.vk}"
ANDROID_SERIAL="${ODIN_ONE_ANDROID_SERIAL:-}"
LOG_LINES="${ODIN_ONE_ANDROID_LOG_LINES:-200}"

TMP_DIR="${TMPDIR:-/tmp}"
ARTIFACT_DIR="${ODIN_ONE_ANDROID_ARTIFACT_DIR:-}"
PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime.xml"
DEVICE_PROTECTED_PREFS_FILE="${TMP_DIR%/}/odin-one-android-vpn-runtime-device-protected.xml"
REALITY_CONFIG_FILE="${TMP_DIR%/}/odin-one-android-active-vless-reality.json"
REALITY_WHITELIST_SCAFFOLD_FILE="${TMP_DIR%/}/odin-one-android-reality-whitelist-assisted-scaffold.json"
CDN_ACTIVE_CONFIG_FILE="${TMP_DIR%/}/odin-one-android-active-cdn-anti-whitelist.json"
CDN_SCAFFOLD_FILE="${TMP_DIR%/}/odin-one-android-cdn-anti-whitelist-scaffold.json"
VPS_ACTIVE_CONFIG_FILE="${TMP_DIR%/}/odin-one-android-active-vless-reality-vps-lab.json"
VPS_SCAFFOLD_FILE="${TMP_DIR%/}/odin-one-android-reality-vps-lab-scaffold.json"

section() {
  echo
  echo "=== $1 ==="
}

note() {
  echo "$1"
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
  rm -f "$PREFS_FILE" "$DEVICE_PROTECTED_PREFS_FILE" "$REALITY_CONFIG_FILE" "$REALITY_WHITELIST_SCAFFOLD_FILE" "$CDN_ACTIVE_CONFIG_FILE" "$CDN_SCAFFOLD_FILE" "$VPS_ACTIVE_CONFIG_FILE" "$VPS_SCAFFOLD_FILE"
}
trap cleanup EXIT INT TERM

stage_artifact() {
  local source_file="$1"
  local artifact_name="$2"
  if [[ -z "$ARTIFACT_DIR" ]]; then
    return 0
  fi
  mkdir -p "$ARTIFACT_DIR"
  cp "$source_file" "${ARTIFACT_DIR%/}/$artifact_name"
}

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

pretty_print_runtime_xml() {
  local source_file="$1"
  "$PYTHON_BIN" - "$source_file" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

source = sys.argv[1]
raw = open(source, "r", encoding="utf-8", errors="replace").read().strip()
if not raw:
    print("No odin_one_vpn_runtime shared prefs content found.")
    raise SystemExit(0)

try:
    root = ET.fromstring(raw)
except Exception as exc:
    print(f"Failed to parse shared prefs XML: {exc}")
    print(raw)
    raise SystemExit(0)
values = {}
for child in root:
    name = child.attrib.get("name")
    if not name:
        continue
    if child.tag == "string":
        values[name] = child.text or ""
    elif child.tag == "boolean":
        values[name] = child.attrib.get("value", "false")
    elif child.tag == "int":
        values[name] = child.attrib.get("value", "")
    elif child.tag == "long":
        values[name] = child.attrib.get("value", "")

snapshot_raw = values.get("snapshot")
if snapshot_raw:
    try:
        snapshot = json.loads(snapshot_raw)
        print("Snapshot summary:")
        for key in [
            "status",
            "runtimeFamily",
            "activationState",
            "frontHost",
            "frontConnectHost",
            "frontConnectPort",
            "frontPath",
            "frontProvider",
            "frontTag",
            "cdnRoutingDnsQueryStrategy",
            "cdnRoutingDomainStrategy",
            "cdnRoutingDomainMatcher",
            "cdnRoutingDirectRuleCount",
            "cdnRoutingBlockRuleCount",
            "cdnRoutingBlockSelectedFrontHost",
            "cdnDnsLocalResolverEnabled",
            "selectedSniHint",
            "selectedCidrHint",
            "whitelistHintSource",
            "whitelistHintTag",
            "startSource",
            "profileHash",
            "configMode",
            "alwaysOnEnabled",
            "lockdownEnabled",
            "resumeEligible",
            "lastNetworkEvent",
            "lastStartupStage",
            "lastFailureStage",
            "lastFailureCode",
            "networkChangeCount",
            "reloadCount",
            "restoreCount",
            "lastRecoveryAction",
        ]:
            if key in snapshot:
                print(f"  {key}: {snapshot[key]}")
        active = snapshot.get("activeFeatures") or []
        if active:
            print("  activeFeatures:")
            for feature in active:
                print(f"    - {feature}")
        print("")
        print("Snapshot JSON:")
        print(json.dumps(snapshot, indent=2, ensure_ascii=False))
    except Exception as exc:
        print(f"Failed to parse snapshot JSON: {exc}")
        print(snapshot_raw)
else:
    print("Snapshot summary: missing")

last_request_raw = values.get("last_request")
last_attempted_request_raw = values.get("last_attempted_request")
print("")
print(f"resume_eligible: {values.get('resume_eligible', 'missing')}")
print(f"boot_restore_enabled: {values.get('boot_restore_enabled', 'missing')}")
print("")
if last_request_raw:
    try:
        last_request = json.loads(last_request_raw)
        print("Last request JSON:")
        print(json.dumps(last_request, indent=2, ensure_ascii=False))
    except Exception as exc:
        print(f"Failed to parse last_request JSON: {exc}")
        print(last_request_raw)
else:
    print("Last request JSON: missing")
print("")
if last_attempted_request_raw:
    try:
        last_attempted_request = json.loads(last_attempted_request_raw)
        print("Last attempted request JSON:")
        print(json.dumps(last_attempted_request, indent=2, ensure_ascii=False))
    except Exception as exc:
        print(f"Failed to parse last_attempted_request JSON: {exc}")
        print(last_attempted_request_raw)
else:
    print("Last attempted request JSON: missing")
PY
}

pretty_print_json_file() {
  local source_file="$1"
  "$PYTHON_BIN" - "$source_file" <<'PY'
import json
import sys

source = sys.argv[1]
raw = open(source, "r", encoding="utf-8", errors="replace").read().strip()
if not raw:
    print("No JSON content found.")
    raise SystemExit(0)
try:
    print(json.dumps(json.loads(raw), indent=2, ensure_ascii=False))
except Exception as exc:
    print(f"Failed to pretty-print JSON: {exc}")
    print(raw)
PY
}

require_bin "$ADB_BIN" "adb"
require_bin "$PYTHON_BIN" "python3"

section "Android Device"
adb_cmd start-server >/dev/null 2>&1 || true
adb_cmd get-state >/dev/null
note "Package: ${PACKAGE_NAME}"
if [[ -n "$ANDROID_SERIAL" ]]; then
  note "Serial: ${ANDROID_SERIAL}"
else
  note "Serial: auto"
fi
note "Device: $(adb_cmd shell getprop ro.product.model | tr -d '\r')"
note "Android: $(adb_cmd shell getprop ro.build.version.release | tr -d '\r')"
note "SDK: $(adb_cmd shell getprop ro.build.version.sdk | tr -d '\r')"
note "Build type: $(adb_cmd shell getprop ro.build.type | tr -d '\r')"

section "VPN / Always-on Summary"
connectivity_dump="$(adb_cmd shell dumpsys connectivity 2>/dev/null || true)"
summary_lines="$(printf '%s\n' "$connectivity_dump" | /usr/bin/grep -iE 'vpn|always|lockdown|'"$PACKAGE_NAME"'' || true)"
if [[ -n "$summary_lines" ]]; then
  printf '%s\n' "$summary_lines" | /usr/bin/sed -n '1,120p'
else
  note "No connectivity summary lines matched."
fi

section "Always-on Secure Settings"
note "always_on_vpn_app: $(adb_cmd shell settings get secure always_on_vpn_app 2>/dev/null | tr -d '\r')"
note "always_on_vpn_lockdown: $(adb_cmd shell settings get secure always_on_vpn_lockdown 2>/dev/null | tr -d '\r')"

section "Runtime Shared Prefs"
if capture_run_as_file "shared_prefs/odin_one_vpn_runtime.xml" "$PREFS_FILE"; then
  stage_artifact "$PREFS_FILE" "odin-one-vpn-runtime.xml"
  pretty_print_runtime_xml "$PREFS_FILE"
else
  note "Unable to read shared_prefs/odin_one_vpn_runtime.xml via run-as."
  note "Hint: this usually means the installed build is not debuggable or the package name differs."
fi

section "Device-Protected Restore Shared Prefs"
if capture_run_as_file "/data/user_de/0/${PACKAGE_NAME}/shared_prefs/odin_one_vpn_runtime.xml" "$DEVICE_PROTECTED_PREFS_FILE"; then
  stage_artifact "$DEVICE_PROTECTED_PREFS_FILE" "odin-one-vpn-runtime-device-protected.xml"
  pretty_print_runtime_xml "$DEVICE_PROTECTED_PREFS_FILE"
else
  note "Unable to read device-protected odin_one_vpn_runtime prefs via run-as."
  note "Hint: this is expected until the app has mirrored restore state into device-protected storage on a fresh run."
fi

section "Runtime Config Artifacts"
if capture_run_as_file "files/vpn-runtime/active-vless-reality.json" "$REALITY_CONFIG_FILE"; then
  note "Artifact: active-vless-reality.json"
  stage_artifact "$REALITY_CONFIG_FILE" "active-vless-reality.json"
  pretty_print_json_file "$REALITY_CONFIG_FILE"
else
  note "No active-vless-reality.json was readable via run-as."
fi

echo
if capture_run_as_file "files/vpn-runtime/reality-whitelist-assisted-scaffold.json" "$REALITY_WHITELIST_SCAFFOLD_FILE"; then
  note "Artifact: reality-whitelist-assisted-scaffold.json"
  stage_artifact "$REALITY_WHITELIST_SCAFFOLD_FILE" "reality-whitelist-assisted-scaffold.json"
  pretty_print_json_file "$REALITY_WHITELIST_SCAFFOLD_FILE"
else
  note "No reality-whitelist-assisted-scaffold.json was readable via run-as."
fi

echo
if capture_run_as_file "files/vpn-runtime/active-cdn-anti-whitelist.json" "$CDN_ACTIVE_CONFIG_FILE"; then
  note "Artifact: active-cdn-anti-whitelist.json"
  stage_artifact "$CDN_ACTIVE_CONFIG_FILE" "active-cdn-anti-whitelist.json"
  pretty_print_json_file "$CDN_ACTIVE_CONFIG_FILE"
else
  note "No active-cdn-anti-whitelist.json was readable via run-as."
fi

echo
if capture_run_as_file "files/vpn-runtime/cdn-anti-whitelist-scaffold.json" "$CDN_SCAFFOLD_FILE"; then
  note "Artifact: cdn-anti-whitelist-scaffold.json"
  stage_artifact "$CDN_SCAFFOLD_FILE" "cdn-anti-whitelist-scaffold.json"
  pretty_print_json_file "$CDN_SCAFFOLD_FILE"
else
  note "No cdn-anti-whitelist-scaffold.json was readable via run-as."
fi

echo
if capture_run_as_file "files/vpn-runtime/active-vless-reality-vps-lab.json" "$VPS_ACTIVE_CONFIG_FILE"; then
  note "Artifact: active-vless-reality-vps-lab.json"
  stage_artifact "$VPS_ACTIVE_CONFIG_FILE" "active-vless-reality-vps-lab.json"
  pretty_print_json_file "$VPS_ACTIVE_CONFIG_FILE"
else
  note "No active-vless-reality-vps-lab.json was readable via run-as."
fi

echo
if capture_run_as_file "files/vpn-runtime/reality-vps-lab-scaffold.json" "$VPS_SCAFFOLD_FILE"; then
  note "Artifact: reality-vps-lab-scaffold.json"
  stage_artifact "$VPS_SCAFFOLD_FILE" "reality-vps-lab-scaffold.json"
  pretty_print_json_file "$VPS_SCAFFOLD_FILE"
else
  note "No reality-vps-lab-scaffold.json was readable via run-as."
fi

section "Filtered Logcat"
adb_cmd logcat -d -t "$LOG_LINES" -v brief VpnRuntimeService:I '*:S' 2>/dev/null || note "No VpnRuntimeService logcat lines were available."

if [[ -n "$ARTIFACT_DIR" ]]; then
  section "Saved Raw Artifacts"
  note "Artifact directory: $ARTIFACT_DIR"
  /bin/ls -1 "$ARTIFACT_DIR" 2>/dev/null | /usr/bin/sed 's/^/  - /' || note "No raw artifacts were written."
fi

section "How To Use"
note "1. Run this after each stable or experimental handset scenario."
note "2. Save the output together with the exact hidden runtime block used for the run."
note "3. Compare runtimeFamily, front metadata, activeFeatures, lastRecoveryAction, restoreCount, reloadCount, and any rendered runtime artifacts."
