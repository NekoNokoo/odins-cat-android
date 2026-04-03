#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-runtime-compare-captures.sh <control-capture.txt> <candidate-capture.txt>

Compares two saved handset captures produced by:
  apps/desktop/scripts/android-reality-capture-run.sh

The helper automatically reads sibling .artifacts directories when present.
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

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

CONTROL_CAPTURE="$1"
CANDIDATE_CAPTURE="$2"

if [[ ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Control capture not found: $CONTROL_CAPTURE" >&2
  exit 1
fi
if [[ ! -f "$CANDIDATE_CAPTURE" ]]; then
  echo "Candidate capture not found: $CANDIDATE_CAPTURE" >&2
  exit 1
fi

require_bin "$PYTHON_BIN" "python3"

"$PYTHON_BIN" - "$CONTROL_CAPTURE" "$CANDIDATE_CAPTURE" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SUMMARY_KEYS = [
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
    "profileHash",
    "configMode",
    "alwaysOnEnabled",
    "lockdownEnabled",
    "resumeEligible",
    "lastNetworkEvent",
    "lastStartupStage",
    "lastFailureStage",
    "lastFailureCode",
    "lastRecoveryAction",
    "networkChangeCount",
    "reloadCount",
    "restoreCount",
]

EXTRA_SNAPSHOT_FIELDS = [
    ("lastTest.status", "lastTestStatus"),
    ("lastTest.output", "lastTestOutput"),
    ("lastTest.error", "lastTestError"),
]


def parse_shared_prefs_xml(path: Path) -> dict:
    raw = path.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return {}
    root = ET.fromstring(raw)
    values = {}
    for child in root:
        name = child.attrib.get("name")
        if not name:
            continue
        if child.tag == "string":
            values[name] = child.text or ""
        elif child.tag in {"boolean", "int", "long"}:
            values[name] = child.attrib.get("value", "")
    result = {}
    snapshot_raw = values.get("snapshot")
    if snapshot_raw:
        try:
            result["snapshot"] = json.loads(snapshot_raw)
        except Exception:
            result["snapshot_raw"] = snapshot_raw
    last_request_raw = values.get("last_request")
    if last_request_raw:
        try:
            result["last_request"] = json.loads(last_request_raw)
        except Exception:
            result["last_request_raw"] = last_request_raw
    last_attempted_request_raw = values.get("last_attempted_request")
    if last_attempted_request_raw:
        try:
            result["last_attempted_request"] = json.loads(last_attempted_request_raw)
        except Exception:
            result["last_attempted_request_raw"] = last_attempted_request_raw
    result["prefs"] = values
    return result


def parse_json_file(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return None


def clean_value(value):
    if value is None:
        return None
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    return value


def infer_request_runtime_family(last_request: dict):
    direct_family = "direct-reality"
    explicit = clean_value((last_request or {}).get("runtimeFamily"))
    if explicit:
        return explicit
    profile_json_raw = clean_value((last_request or {}).get("profileJson"))
    if not profile_json_raw:
        return direct_family
    try:
        profile = json.loads(profile_json_raw)
    except Exception:
        return direct_family
    android_runtime = profile.get("androidRuntime") or {}
    whitelist_hints = android_runtime.get("realityWhitelistHints") or {}
    if whitelist_hints.get("enabled") is True:
        return "reality-whitelist-assisted"
    cdn_mode = android_runtime.get("cdnAntiWhitelist") or {}
    if cdn_mode.get("enabled") is True:
        return "cdn-anti-whitelist"
    return direct_family


def choose_identity_request(snapshot: dict, last_request: dict, last_attempted_request: dict):
    snapshot_family = clean_value((snapshot or {}).get("runtimeFamily"))
    attempted_family = infer_request_runtime_family(last_attempted_request or {})
    persisted_family = infer_request_runtime_family(last_request or {})
    activation_state = clean_value((snapshot or {}).get("activationState"))
    failure_code = clean_value((snapshot or {}).get("lastFailureCode"))

    if activation_state != "scaffold_only" and failure_code != "scaffold_only" and last_request:
        if snapshot_family and persisted_family == snapshot_family:
            return last_request, "last_request"
    if last_attempted_request:
        if snapshot_family and attempted_family == snapshot_family:
            return last_attempted_request, "last_attempted_request"
        if activation_state == "scaffold_only" or failure_code == "scaffold_only":
            return last_attempted_request, "last_attempted_request"
    if last_request:
        if snapshot_family and persisted_family == snapshot_family:
            return last_request, "last_request"
        if not last_attempted_request:
            return last_request, "last_request"
    if last_attempted_request:
        return last_attempted_request, "last_attempted_request"
    if last_request:
        return last_request, "last_request"
    return {}, None


def build_identity_overlay(artifact_name: str, payload):
    if not isinstance(payload, dict):
        return {}
    if artifact_name == "reality-vps-lab-scaffold.json":
        selected_endpoint = payload.get("selectedEndpoint") or {}
        overlay = {
            "runtimeFamily": payload.get("runtimeFamily") or "reality-vps-lab",
            "activationState": payload.get("activationState"),
            "configMode": payload.get("configMode"),
            "frontHost": selected_endpoint.get("serverName") or payload.get("serverName"),
            "frontConnectHost": selected_endpoint.get("connectHost") or payload.get("connectHost"),
            "frontConnectPort": selected_endpoint.get("connectPort") or payload.get("connectPort"),
            "frontTag": selected_endpoint.get("tag") or payload.get("tag"),
            "selectedSniHint": selected_endpoint.get("serverName") or payload.get("selectedSniHint"),
            "whitelistHintSource": selected_endpoint.get("source") or payload.get("whitelistHintSource"),
            "whitelistHintTag": selected_endpoint.get("tag") or payload.get("whitelistHintTag"),
        }
        return {key: value for key, value in overlay.items() if clean_value(value) is not None}
    if artifact_name == "reality-whitelist-assisted-scaffold.json":
        selected_hint = payload.get("selectedHint") or {}
        overlay = {
            "runtimeFamily": payload.get("runtimeFamily") or "reality-whitelist-assisted",
            "activationState": payload.get("activationState"),
            "configMode": payload.get("configMode"),
            "selectedSniHint": selected_hint.get("serverName"),
            "selectedCidrHint": selected_hint.get("cidrBucket"),
            "whitelistHintSource": selected_hint.get("source"),
            "whitelistHintTag": selected_hint.get("tag"),
        }
        return {key: value for key, value in overlay.items() if clean_value(value) is not None}
    if artifact_name == "cdn-anti-whitelist-scaffold.json":
        selected_front = payload.get("selectedFront") or {}
        routing_policy = payload.get("routingPolicyPlan") or {}
        direct_rule_count = len(routing_policy.get("directDomainKeywords") or []) + len(routing_policy.get("directDomains") or [])
        block_rule_count = len(routing_policy.get("blockedDomainKeywords") or []) + len(routing_policy.get("effectiveBlockedDomains") or [])
        overlay = {
            "runtimeFamily": payload.get("runtimeFamily") or "cdn-anti-whitelist",
            "activationState": payload.get("activationState"),
            "configMode": payload.get("configMode"),
            "frontHost": selected_front.get("host") or payload.get("frontHost"),
            "frontConnectHost": selected_front.get("connectHost") or payload.get("frontConnectHost") or payload.get("connectHost"),
            "frontConnectPort": selected_front.get("connectPort") or payload.get("frontConnectPort") or payload.get("connectPort"),
            "frontPath": selected_front.get("path") or payload.get("frontPath"),
            "frontProvider": selected_front.get("provider") or payload.get("provider"),
            "frontTag": selected_front.get("tag") or payload.get("frontTag"),
            "cdnRoutingDnsQueryStrategy": routing_policy.get("dnsQueryStrategy"),
            "cdnRoutingDomainStrategy": routing_policy.get("domainStrategy"),
            "cdnRoutingDomainMatcher": routing_policy.get("domainMatcher"),
            "cdnRoutingDirectRuleCount": direct_rule_count,
            "cdnRoutingBlockRuleCount": block_rule_count,
            "cdnRoutingBlockSelectedFrontHost": routing_policy.get("blockSelectedFrontHost"),
            "cdnDnsLocalResolverEnabled": direct_rule_count > 0,
        }
        return {key: value for key, value in overlay.items() if clean_value(value) is not None}
    return {}


def should_apply_identity_overlay(snapshot: dict, overlay: dict, last_request: dict) -> bool:
    if not overlay:
        return False
    runtime_family = clean_value(snapshot.get("runtimeFamily"))
    activation_state = clean_value(snapshot.get("activationState"))
    failure_code = clean_value(snapshot.get("lastFailureCode"))
    expected_family = clean_value(overlay.get("runtimeFamily"))
    requested_family = infer_request_runtime_family(last_request or {})
    if requested_family and expected_family and requested_family != expected_family:
        return False
    if failure_code == "scaffold_only":
        return True
    if activation_state == "scaffold_only":
        return True
    if runtime_family is None:
        return True
    if expected_family and runtime_family == expected_family:
        return True
    return False


def apply_identity_overlays(snapshot: dict, artifacts: dict, last_request: dict):
    effective = dict(snapshot or {})
    overlay_sources = []
    for artifact_name in [
        "reality-whitelist-assisted-scaffold.json",
        "cdn-anti-whitelist-scaffold.json",
    ]:
        overlay = build_identity_overlay(artifact_name, artifacts.get(artifact_name))
        if should_apply_identity_overlay(effective, overlay, last_request):
            effective.update(overlay)
            overlay_sources.append(artifact_name)
    return effective, overlay_sources


def extract_json_after_marker(text: str, marker: str):
    start = text.find(marker)
    if start < 0:
        return None
    brace_start = text.find("{", start)
    if brace_start < 0:
        return None
    depth = 0
    in_string = False
    escape = False
    for index in range(brace_start, len(text)):
        char = text[index]
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                raw = text[brace_start:index + 1]
                try:
                    return json.loads(raw)
                except Exception:
                    return None
    return None


def parse_snapshot_summary(text: str) -> dict:
    summary = {}
    active_features = []
    collecting_features = False
    for line in text.splitlines():
        if collecting_features:
            feature_match = re.match(r"^\s*-\s+(.*)$", line)
            if feature_match:
                active_features.append(feature_match.group(1).strip())
                continue
            collecting_features = False
        match = re.match(r"^\s*([A-Za-z][A-Za-z0-9]+):\s*(.*)$", line)
        if not match:
            continue
        key, raw_value = match.groups()
        if key == "activeFeatures":
            collecting_features = True
            inline_features = [item.strip() for item in raw_value.split(",") if item.strip()]
            if inline_features:
                active_features.extend(inline_features)
            continue
        if key in SUMMARY_KEYS:
            summary[key] = raw_value.strip()
    if active_features:
        summary["activeFeatures"] = active_features
    return summary


def find_artifact_dir(capture_path: Path):
    candidates = []
    if capture_path.suffix:
        candidates.append(capture_path.with_suffix(".artifacts"))
        candidates.append(capture_path.with_suffix(capture_path.suffix + ".artifacts"))
    else:
        candidates.append(Path(str(capture_path) + ".artifacts"))
    seen = set()
    for candidate in candidates:
        normalized = str(candidate)
        if normalized in seen:
            continue
        seen.add(normalized)
        if candidate.exists() and candidate.is_dir():
            return candidate
    return None


def parse_text_capture(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    info = {
        "capture_path": str(path),
        "text": text,
        "package": next((line.split(": ", 1)[1] for line in lines if line.startswith("Package: ")), None),
        "device": next((line.split(": ", 1)[1] for line in lines if line.startswith("Device: ")), None),
        "android": next((line.split(": ", 1)[1] for line in lines if line.startswith("Android: ")), None),
        "sdk": next((line.split(": ", 1)[1] for line in lines if line.startswith("SDK: ")), None),
        "build_type": next((line.split(": ", 1)[1] for line in lines if line.startswith("Build type: ")), None),
        "snapshot": parse_snapshot_summary(text),
    }
    snapshot = extract_json_after_marker(text, "Snapshot JSON:")
    if snapshot is not None:
        info["snapshot"] = snapshot
    last_request = extract_json_after_marker(text, "Last request JSON:")
    if last_request is not None:
        info["last_request"] = last_request
    last_attempted_request = extract_json_after_marker(text, "Last attempted request JSON:")
    if last_attempted_request is not None:
        info["last_attempted_request"] = last_attempted_request
    return info


def load_capture(path_str: str) -> dict:
    capture_path = Path(path_str).resolve()
    base = parse_text_capture(capture_path)
    artifact_dir = find_artifact_dir(capture_path)
    if artifact_dir is not None:
        base["artifact_dir"] = str(artifact_dir)
        prefs_path = artifact_dir / "odin-one-vpn-runtime.xml"
        if prefs_path.exists():
            base["shared_prefs"] = parse_shared_prefs_xml(prefs_path)
            base["snapshot"] = base["shared_prefs"].get("snapshot", base.get("snapshot"))
            base["last_request"] = base["shared_prefs"].get("last_request", base.get("last_request"))
            base["last_attempted_request"] = base["shared_prefs"].get("last_attempted_request", base.get("last_attempted_request"))
        device_prefs_path = artifact_dir / "odin-one-vpn-runtime-device-protected.xml"
        if device_prefs_path.exists():
            base["device_protected_prefs"] = parse_shared_prefs_xml(device_prefs_path)
        runtime_snapshot_path = artifact_dir / "runtime-snapshot.json"
        if runtime_snapshot_path.exists():
            runtime_snapshot = parse_json_file(runtime_snapshot_path)
            if isinstance(runtime_snapshot, dict) and runtime_snapshot:
                base["snapshot"] = runtime_snapshot
        artifacts = {}
        for name in [
            "active-vless-reality.json",
            "reality-whitelist-assisted-scaffold.json",
            "reality-whitelist-probe-matrix.json",
            "active-cdn-anti-whitelist.json",
            "cdn-anti-whitelist-scaffold.json",
            "runtime-snapshot.json",
        ]:
            artifact_path = artifact_dir / name
            if artifact_path.exists():
                artifacts[name] = parse_json_file(artifact_path)
        if artifacts:
            base["artifacts"] = artifacts
            identity_request, identity_request_source = choose_identity_request(
                base.get("snapshot") or {},
                base.get("last_request") or {},
                base.get("last_attempted_request") or {},
            )
            effective_snapshot, overlay_sources = apply_identity_overlays(
                base.get("snapshot") or {},
                artifacts,
                identity_request,
            )
            base["snapshot"] = effective_snapshot
            if overlay_sources:
                base["artifact_identity_source"] = ", ".join(overlay_sources)
    identity_request, identity_request_source = choose_identity_request(
        base.get("snapshot") or {},
        base.get("last_request") or {},
        base.get("last_attempted_request") or {},
    )
    if identity_request_source:
        base["request_identity_source"] = identity_request_source
    return base


def render_value(value):
    if isinstance(value, list):
        return ", ".join(str(item) for item in value) if value else "[]"
    if value is None or value == "":
        return "n/a"
    return str(value)


def nested_value(payload, path: str):
    value = payload
    for part in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(part)
        if value is None:
            return None
    return value


def probe_matrix_entries(capture: dict):
    matrix = ((capture.get("artifacts") or {}).get("reality-whitelist-probe-matrix.json"))
    return matrix if isinstance(matrix, list) else []


def probe_matrix_summary(capture: dict):
    entries = probe_matrix_entries(capture)
    if not entries:
        return None
    parts = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        label = render_value(entry.get("label"))
        status = render_value(entry.get("status"))
        error = render_value(entry.get("error"))
        output = render_value(entry.get("output"))
        if error != "n/a":
            parts.append(f"{label}={status} ({error})")
        elif output != "n/a":
            parts.append(f"{label}={status} ({output})")
        else:
            parts.append(f"{label}={status}")
    return "; ".join(parts) if parts else None


def emit_capture_summary(label: str, capture: dict):
    print(f"== {label} ==")
    print(f"Capture: {capture['capture_path']}")
    if capture.get("artifact_dir"):
        print(f"Artifacts: {capture['artifact_dir']}")
    if capture.get("artifact_identity_source"):
        print(f"Identity overlay: {capture['artifact_identity_source']}")
    if capture.get("request_identity_source"):
        print(f"Request identity source: {capture['request_identity_source']}")
    print(f"Device: {render_value(capture.get('device'))}")
    print(f"Android: {render_value(capture.get('android'))} / SDK {render_value(capture.get('sdk'))}")
    snapshot = capture.get("snapshot") or {}
    for key in SUMMARY_KEYS:
        print(f"{key}: {render_value(snapshot.get(key))}")
    for path, label in EXTRA_SNAPSHOT_FIELDS:
        print(f"{label}: {render_value(nested_value(snapshot, path))}")
    print(f"probeMatrix: {render_value(probe_matrix_summary(capture))}")
    active_features = snapshot.get("activeFeatures") or []
    print(f"activeFeatures: {render_value(active_features)}")
    artifacts = capture.get("artifacts") or {}
    if artifacts:
        print("artifactFiles:")
        for name in sorted(artifacts):
            print(f"  - {name}")
    print("")


def diff_snapshot(control: dict, candidate: dict):
    control_snapshot = control.get("snapshot") or {}
    candidate_snapshot = candidate.get("snapshot") or {}
    changed = []
    for key in SUMMARY_KEYS + ["activeFeatures"]:
        left = control_snapshot.get(key)
        right = candidate_snapshot.get(key)
        if left != right:
            changed.append((key, left, right))
    for path, label in EXTRA_SNAPSHOT_FIELDS:
        left = nested_value(control_snapshot, path)
        right = nested_value(candidate_snapshot, path)
        if left != right:
            changed.append((label, left, right))
    left_probe = probe_matrix_summary(control)
    right_probe = probe_matrix_summary(candidate)
    if left_probe != right_probe:
        changed.append(("probeMatrix", left_probe, right_probe))
    return changed


def diff_artifacts(control: dict, candidate: dict):
    left = set((control.get("artifacts") or {}).keys())
    right = set((candidate.get("artifacts") or {}).keys())
    return sorted(left - right), sorted(right - left)


def emit_diff(control: dict, candidate: dict):
    print("== Key Differences ==")
    changed = diff_snapshot(control, candidate)
    if not changed:
        print("No snapshot-field differences detected.")
    else:
        for key, left, right in changed:
            print(f"{key}:")
            print(f"  control:   {render_value(left)}")
            print(f"  candidate: {render_value(right)}")
    only_control, only_candidate = diff_artifacts(control, candidate)
    print("")
    print("== Artifact Presence ==")
    if not only_control and not only_candidate:
        print("Artifact file sets match.")
    else:
        if only_control:
            print("Only in control:")
            for name in only_control:
                print(f"  - {name}")
        if only_candidate:
            print("Only in candidate:")
            for name in only_candidate:
                print(f"  - {name}")
    print("")
    print("== Review Prompts ==")
    print("- Did the candidate keep the stable control lane available before and after the run?")
    print("- Did runtimeFamily / activationState match the intended family for each capture?")
    print("- If the candidate is whitelist-front or whitelist-assisted, do frontHost / frontConnectHost / frontConnectPort / frontPath / frontTag or selectedSniHint / selectedCidrHint match the expected hidden preset?")
    print("- For CDN candidates, do the routing policy diagnostics look right: dns strategy, domain strategy, direct rule count, block rule count, and local-resolver enablement?")
    print("- Did lastTestStatus / lastTestError or probeMatrix indicate a usable active lane, or only a runtime that came up but failed the quick probe?")
    print("- Did recovery counters move in a way that suggests regressions or hidden retries?")


control = load_capture(sys.argv[1])
candidate = load_capture(sys.argv[2])

emit_capture_summary("Control", control)
emit_capture_summary("Candidate", candidate)
emit_diff(control, candidate)
PY
