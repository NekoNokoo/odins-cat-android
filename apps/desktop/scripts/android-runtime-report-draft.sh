#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-runtime-report-draft.sh <control-capture.txt> <candidate-capture.txt> [output.md]

Builds a short markdown report draft from two saved handset captures produced by:
  apps/desktop/scripts/android-reality-capture-run.sh

If output.md is omitted, the report is written to stdout.
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

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 1
fi

CONTROL_CAPTURE="$1"
CANDIDATE_CAPTURE="$2"
OUTPUT_PATH="${3:-}"

if [[ ! -f "$CONTROL_CAPTURE" ]]; then
  echo "Control capture not found: $CONTROL_CAPTURE" >&2
  exit 1
fi
if [[ ! -f "$CANDIDATE_CAPTURE" ]]; then
  echo "Candidate capture not found: $CANDIDATE_CAPTURE" >&2
  exit 1
fi

require_bin "$PYTHON_BIN" "python3"

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
fi

"$PYTHON_BIN" - "$CONTROL_CAPTURE" "$CANDIDATE_CAPTURE" "$OUTPUT_PATH" <<'PY'
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
        "basename": path.name,
        "text": text,
        "package": next((line.split(": ", 1)[1] for line in lines if line.startswith("Package: ")), None),
        "device": next((line.split(": ", 1)[1] for line in lines if line.startswith("Device: ")), None),
        "android": next((line.split(": ", 1)[1] for line in lines if line.startswith("Android: ")), None),
        "sdk": next((line.split(": ", 1)[1] for line in lines if line.startswith("SDK: ")), None),
        "build_type": next((line.split(": ", 1)[1] for line in lines if line.startswith("Build type: ")), None),
        "snapshot": parse_snapshot_summary(text),
    }
    scenario_match = re.match(r"(?P<stamp>\d{8}-\d{6})-(?P<label>.+)\.txt$", path.name)
    if scenario_match:
        info["stamp"] = scenario_match.group("stamp")
        info["scenario_label"] = scenario_match.group("label")
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
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None or value == "":
        return "n/a"
    return str(value)


def markdown_escape(value):
    return render_value(value).replace("|", "\\|")


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


def probe_status(entries, label: str):
    for entry in entries:
        if isinstance(entry, dict) and entry.get("label") == label:
            return entry.get("status")
    return None


def any_probe_passed(entries):
    return any(isinstance(entry, dict) and entry.get("status") == "passed" for entry in entries)


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
    control_probe = probe_matrix_summary(control)
    candidate_probe = probe_matrix_summary(candidate)
    if control_probe != candidate_probe:
        changed.append(("probeMatrix", control_probe, candidate_probe))
    return changed


def infer_result(candidate_snapshot: dict, probe_entries) -> str:
    status = candidate_snapshot.get("status")
    activation_state = candidate_snapshot.get("activationState")
    failure_code = candidate_snapshot.get("lastFailureCode")
    last_test_status = nested_value(candidate_snapshot, "lastTest.status")
    if activation_state == "scaffold_only" and failure_code == "scaffold_only":
        return "soft-pass"
    if probe_status(probe_entries, "generic_primary") == "passed":
        return "pass"
    if any_probe_passed(probe_entries):
        return "warn"
    if status == "running" and last_test_status == "passed":
        return "pass"
    if status == "running" and last_test_status == "failed":
        return "warn"
    if status == "running" and not failure_code:
        return "pass"
    return "fail"


def infer_next_action(candidate_snapshot: dict, probe_entries) -> str:
    status = candidate_snapshot.get("status")
    activation_state = candidate_snapshot.get("activationState")
    failure_code = candidate_snapshot.get("lastFailureCode")
    runtime_family = candidate_snapshot.get("runtimeFamily")
    last_test_status = nested_value(candidate_snapshot, "lastTest.status")
    if activation_state == "scaffold_only" and failure_code == "scaffold_only":
        if runtime_family == "reality-whitelist-assisted":
            return "Keep the family hidden, preserve direct-reality as control, and continue curating SNI/CIDR hints with blocked-direct handset validation."
        return "Keep the family hidden, preserve direct-reality as control, and continue toward owner-only WS/TLS activation with blocked-direct validation."
    if runtime_family == "reality-whitelist-assisted" and probe_status(probe_entries, "hint_https") == "passed" and probe_status(probe_entries, "generic_primary") != "passed":
        return "Keep direct-reality as the control lane, treat this hint as partially promising, and retry it with a wider URL set before promoting it beyond owner-only lab mode."
    if runtime_family == "reality-whitelist-assisted" and status == "running" and last_test_status == "failed":
        return "Keep direct-reality as the control lane, mark this hint as lab-only for now, and inspect lastTest plus logTail before treating it as a usable whitelist candidate."
    if runtime_family == "cdn-anti-whitelist" and status == "running":
        return "Proceed to blocked-direct and Wi-Fi/LTE validation while keeping direct-reality as the control sample."
    return "Keep direct-reality as the control lane and inspect candidate artifacts before any wider rollout."


def summarize_changes(changed):
    lines = []
    for key, left, right in changed[:8]:
        lines.append(f"- `{key}`: control=`{render_value(left)}` -> candidate=`{render_value(right)}`")
    return lines or ["- No snapshot-field differences detected."]


def summarize_artifacts(control: dict, candidate: dict):
    left = set((control.get("artifacts") or {}).keys())
    right = set((candidate.get("artifacts") or {}).keys())
    lines = []
    only_control = sorted(left - right)
    only_candidate = sorted(right - left)
    if only_control:
        lines.append("- Only in control artifacts: " + ", ".join(f"`{name}`" for name in only_control))
    if only_candidate:
        lines.append("- Only in candidate artifacts: " + ", ".join(f"`{name}`" for name in only_candidate))
    if not lines:
        lines.append("- Artifact file sets match.")
    return lines


def build_report(control: dict, candidate: dict) -> str:
    control_snapshot = control.get("snapshot") or {}
    candidate_snapshot = candidate.get("snapshot") or {}
    candidate_probe_entries = probe_matrix_entries(candidate)
    changed = diff_snapshot(control, candidate)
    result = infer_result(candidate_snapshot, candidate_probe_entries)
    next_action = infer_next_action(candidate_snapshot, candidate_probe_entries)
    scenario = candidate.get("scenario_label") or candidate.get("basename") or "candidate-run"
    date_value = candidate.get("stamp") or control.get("stamp") or "unknown"
    artifact_dir = candidate.get("artifact_dir") or "n/a"
    lines = [
        "# Android Runtime Comparison Report Draft",
        "",
        "## Run metadata",
        f"- Date: {markdown_escape(date_value)}",
        f"- Scenario: {markdown_escape(scenario)}",
        f"- Device model: {markdown_escape(candidate.get('device') or control.get('device'))}",
        f"- Android version / SDK: {markdown_escape(candidate.get('android') or control.get('android'))} / {markdown_escape(candidate.get('sdk') or control.get('sdk'))}",
        f"- App build: {markdown_escape(candidate.get('build_type') or control.get('build_type'))}",
        f"- Control capture: `{control['capture_path']}`",
        f"- Candidate capture: `{candidate['capture_path']}`",
        f"- Candidate artifacts: `{artifact_dir}`",
        "",
        "## Control summary",
        f"- `runtimeFamily`: `{markdown_escape(control_snapshot.get('runtimeFamily'))}`",
        f"- `status`: `{markdown_escape(control_snapshot.get('status'))}`",
        f"- `configMode`: `{markdown_escape(control_snapshot.get('configMode'))}`",
        f"- `activeFeatures`: `{markdown_escape(control_snapshot.get('activeFeatures'))}`",
        "",
        "## Candidate summary",
        f"- `runtimeFamily`: `{markdown_escape(candidate_snapshot.get('runtimeFamily'))}`",
        f"- `activationState`: `{markdown_escape(candidate_snapshot.get('activationState'))}`",
        f"- `status`: `{markdown_escape(candidate_snapshot.get('status'))}`",
        f"- `artifactIdentitySource`: `{markdown_escape(candidate.get('artifact_identity_source'))}`",
        f"- `requestIdentitySource`: `{markdown_escape(candidate.get('request_identity_source'))}`",
        f"- `frontHost`: `{markdown_escape(candidate_snapshot.get('frontHost'))}`",
        f"- `frontConnectHost`: `{markdown_escape(candidate_snapshot.get('frontConnectHost'))}`",
        f"- `frontConnectPort`: `{markdown_escape(candidate_snapshot.get('frontConnectPort'))}`",
        f"- `frontPath`: `{markdown_escape(candidate_snapshot.get('frontPath'))}`",
        f"- `frontTag`: `{markdown_escape(candidate_snapshot.get('frontTag'))}`",
        f"- `cdnRoutingDnsQueryStrategy`: `{markdown_escape(candidate_snapshot.get('cdnRoutingDnsQueryStrategy'))}`",
        f"- `cdnRoutingDomainStrategy`: `{markdown_escape(candidate_snapshot.get('cdnRoutingDomainStrategy'))}`",
        f"- `cdnRoutingDomainMatcher`: `{markdown_escape(candidate_snapshot.get('cdnRoutingDomainMatcher'))}`",
        f"- `cdnRoutingDirectRuleCount`: `{markdown_escape(candidate_snapshot.get('cdnRoutingDirectRuleCount'))}`",
        f"- `cdnRoutingBlockRuleCount`: `{markdown_escape(candidate_snapshot.get('cdnRoutingBlockRuleCount'))}`",
        f"- `cdnRoutingBlockSelectedFrontHost`: `{markdown_escape(candidate_snapshot.get('cdnRoutingBlockSelectedFrontHost'))}`",
        f"- `cdnDnsLocalResolverEnabled`: `{markdown_escape(candidate_snapshot.get('cdnDnsLocalResolverEnabled'))}`",
        f"- `selectedSniHint`: `{markdown_escape(candidate_snapshot.get('selectedSniHint'))}`",
        f"- `selectedCidrHint`: `{markdown_escape(candidate_snapshot.get('selectedCidrHint'))}`",
        f"- `whitelistHintSource`: `{markdown_escape(candidate_snapshot.get('whitelistHintSource'))}`",
        f"- `whitelistHintTag`: `{markdown_escape(candidate_snapshot.get('whitelistHintTag'))}`",
        f"- `configMode`: `{markdown_escape(candidate_snapshot.get('configMode'))}`",
        f"- `lastTest.status`: `{markdown_escape(nested_value(candidate_snapshot, 'lastTest.status'))}`",
        f"- `lastTest.output`: `{markdown_escape(nested_value(candidate_snapshot, 'lastTest.output'))}`",
        f"- `lastTest.error`: `{markdown_escape(nested_value(candidate_snapshot, 'lastTest.error'))}`",
        f"- `probeMatrix`: `{markdown_escape(probe_matrix_summary(candidate))}`",
        f"- `lastFailureCode`: `{markdown_escape(candidate_snapshot.get('lastFailureCode'))}`",
        f"- `reloadCount`: `{markdown_escape(candidate_snapshot.get('reloadCount'))}`",
        f"- `restoreCount`: `{markdown_escape(candidate_snapshot.get('restoreCount'))}`",
        "",
        "## Key differences",
    ]
    lines.extend(summarize_changes(changed))
    lines.append("")
    lines.append("## Artifact differences")
    lines.extend(summarize_artifacts(control, candidate))
    lines.append("")
    lines.append("## Notes")
    lines.append("- What changed from the control sample:")
    lines.extend(["  " + line for line in summarize_changes(changed)])
    lines.append("- Hostile-network notes:")
    lines.append("  - Confirm whether the candidate kept the stable direct-reality lane available before and after the run.")
    lines.append("- Fronting notes:")
    lines.append("  - Confirm whether frontHost / frontConnectHost / frontConnectPort / frontPath / frontTag or selectedSniHint / selectedCidrHint matched the intended hidden preset and blocked-direct expectations.")
    lines.append("  - For CDN candidates, confirm the projected routing policy looked intentional: DNS strategy, domain strategy, direct/block rule counts, and local resolver enablement.")
    lines.append("")
    lines.append("## Assessment")
    lines.append(f"- Result: `{result}`")
    lines.append("- Estimated SPI movement from this finding: pending operator review")
    lines.append(f"- Next action: {next_action}")
    lines.append("")
    return "\n".join(lines)


control = load_capture(sys.argv[1])
candidate = load_capture(sys.argv[2])
output_path = sys.argv[3].strip() if len(sys.argv) > 3 else ""
report = build_report(control, candidate)

if output_path:
    Path(output_path).write_text(report + "\n", encoding="utf-8")
    print(output_path)
else:
    print(report)
PY

if [[ -n "$OUTPUT_PATH" ]]; then
  echo "Wrote report draft to $OUTPUT_PATH"
fi
