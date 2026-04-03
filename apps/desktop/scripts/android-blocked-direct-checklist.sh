#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-blocked-direct-checklist.sh <control-capture.txt> <candidate-capture.txt> [output.md]

Builds a short blocked-direct validation checklist from two saved handset captures.
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


def load_capture(path_str: str) -> dict:
    capture_path = Path(path_str).resolve()
    text = capture_path.read_text(encoding="utf-8", errors="replace")
    snapshot = parse_snapshot_summary(text)
    snapshot_json = extract_json_after_marker(text, "Snapshot JSON:")
    if snapshot_json:
        snapshot = snapshot_json
    last_request = extract_json_after_marker(text, "Last request JSON:") or {}
    last_attempted_request = extract_json_after_marker(text, "Last attempted request JSON:") or {}
    artifact_dir = find_artifact_dir(capture_path)
    artifacts = {}
    if artifact_dir is not None:
        prefs_path = artifact_dir / "odin-one-vpn-runtime.xml"
        if prefs_path.exists():
            prefs_payload = parse_shared_prefs_xml(prefs_path)
            prefs_snapshot = prefs_payload.get("snapshot")
            if prefs_snapshot:
                snapshot = prefs_snapshot
            prefs_last_request = prefs_payload.get("last_request")
            if prefs_last_request:
                last_request = prefs_last_request
            prefs_last_attempted_request = prefs_payload.get("last_attempted_request")
            if prefs_last_attempted_request:
                last_attempted_request = prefs_last_attempted_request
        runtime_snapshot_path = artifact_dir / "runtime-snapshot.json"
        if runtime_snapshot_path.exists():
            try:
                runtime_snapshot = json.loads(runtime_snapshot_path.read_text(encoding="utf-8", errors="replace"))
            except Exception:
                runtime_snapshot = None
            if isinstance(runtime_snapshot, dict) and runtime_snapshot:
                snapshot = runtime_snapshot
        for name in [
            "active-vless-reality.json",
            "reality-whitelist-assisted-scaffold.json",
            "active-cdn-anti-whitelist.json",
            "cdn-anti-whitelist-scaffold.json",
            "runtime-snapshot.json",
        ]:
            artifact_path = artifact_dir / name
            if artifact_path.exists():
                artifacts[name] = parse_json_file(artifact_path)
    overlay_sources = []
    identity_request, identity_request_source = choose_identity_request(snapshot, last_request, last_attempted_request)
    if artifacts:
        snapshot, overlay_sources = apply_identity_overlays(snapshot, artifacts, identity_request)
    return {
        "path": str(capture_path),
        "artifact_dir": str(artifact_dir) if artifact_dir is not None else None,
        "snapshot": snapshot,
        "artifacts": artifacts,
        "last_request": last_request,
        "last_attempted_request": last_attempted_request,
        "request_identity_source": identity_request_source,
        "artifact_identity_source": ", ".join(overlay_sources) if overlay_sources else None,
    }


def render(value):
    if isinstance(value, list):
        return ", ".join(str(v) for v in value) if value else "n/a"
    if value is None or value == "":
        return "n/a"
    return str(value)


def build_checklist(control: dict, candidate: dict) -> str:
    control_snapshot = control["snapshot"]
    candidate_snapshot = candidate["snapshot"]
    lines = [
        "# Blocked-Direct Validation Checklist",
        "",
        "## Target",
        f"- Control capture: `{control['path']}`",
        f"- Candidate capture: `{candidate['path']}`",
        f"- Candidate family: `{render(candidate_snapshot.get('runtimeFamily'))}`",
        f"- Candidate activation: `{render(candidate_snapshot.get('activationState'))}`",
        f"- Candidate identity source: `{render(candidate.get('artifact_identity_source'))}`",
        f"- Candidate request source: `{render(candidate.get('request_identity_source'))}`",
        f"- Candidate front host: `{render(candidate_snapshot.get('frontHost'))}`",
        f"- Candidate dial host: `{render(candidate_snapshot.get('frontConnectHost'))}`",
        f"- Candidate dial port: `{render(candidate_snapshot.get('frontConnectPort'))}`",
        f"- Candidate front path: `{render(candidate_snapshot.get('frontPath'))}`",
        f"- Candidate front tag: `{render(candidate_snapshot.get('frontTag'))}`",
        f"- Candidate CDN DNS strategy: `{render(candidate_snapshot.get('cdnRoutingDnsQueryStrategy'))}` / `{render(candidate_snapshot.get('cdnRoutingDomainStrategy'))}` / `{render(candidate_snapshot.get('cdnRoutingDomainMatcher'))}`",
        f"- Candidate CDN direct/block rules: `{render(candidate_snapshot.get('cdnRoutingDirectRuleCount'))}` / `{render(candidate_snapshot.get('cdnRoutingBlockRuleCount'))}`",
        f"- Candidate CDN local resolver / front block: `{render(candidate_snapshot.get('cdnDnsLocalResolverEnabled'))}` / `{render(candidate_snapshot.get('cdnRoutingBlockSelectedFrontHost'))}`",
        f"- Candidate SNI hint: `{render(candidate_snapshot.get('selectedSniHint'))}`",
        f"- Candidate CIDR hint: `{render(candidate_snapshot.get('selectedCidrHint'))}`",
        f"- Candidate hint source/tag: `{render(candidate_snapshot.get('whitelistHintSource'))}` / `{render(candidate_snapshot.get('whitelistHintTag'))}`",
        "",
        "## Control lane",
        f"- [ ] Confirm stable control family stayed `direct-reality` (actual: `{render(control_snapshot.get('runtimeFamily'))}`)",
        f"- [ ] Confirm control lane was testable before candidate run (status: `{render(control_snapshot.get('status'))}`)",
        f"- [ ] Confirm control lane remained testable after candidate run",
        "",
        "## Candidate lane",
        f"- [ ] Confirm candidate family stayed the intended hidden family (actual: `{render(candidate_snapshot.get('runtimeFamily'))}`)",
        f"- [ ] Confirm selected front host matched expectation when applicable (`{render(candidate_snapshot.get('frontHost'))}`)",
        f"- [ ] Confirm selected dial target matched expectation when applicable (`{render(candidate_snapshot.get('frontConnectHost'))}:{render(candidate_snapshot.get('frontConnectPort'))}`)",
        f"- [ ] Confirm selected front path matched expectation when applicable (`{render(candidate_snapshot.get('frontPath'))}`)",
        f"- [ ] Confirm selected front tag or hint tag matched expectation (`{render(candidate_snapshot.get('frontTag'))}` / `{render(candidate_snapshot.get('whitelistHintTag'))}`)",
        f"- [ ] Confirm CDN DNS strategy matched the intended hidden preset (`{render(candidate_snapshot.get('cdnRoutingDnsQueryStrategy'))}` / `{render(candidate_snapshot.get('cdnRoutingDomainStrategy'))}` / `{render(candidate_snapshot.get('cdnRoutingDomainMatcher'))}`)",
        f"- [ ] Confirm CDN direct/block rule counts looked intentional (`{render(candidate_snapshot.get('cdnRoutingDirectRuleCount'))}` / `{render(candidate_snapshot.get('cdnRoutingBlockRuleCount'))}`)",
        f"- [ ] Confirm CDN local resolver and front-block toggles matched expectation (`{render(candidate_snapshot.get('cdnDnsLocalResolverEnabled'))}` / `{render(candidate_snapshot.get('cdnRoutingBlockSelectedFrontHost'))}`)",
        f"- [ ] Confirm selected SNI hint matched expectation (`{render(candidate_snapshot.get('selectedSniHint'))}`)",
        f"- [ ] Confirm selected CIDR hint matched expectation (`{render(candidate_snapshot.get('selectedCidrHint'))}`)",
        f"- [ ] Confirm activation/failure state is understood (`{render(candidate_snapshot.get('activationState'))}` / `{render(candidate_snapshot.get('lastFailureCode'))}`)",
        "",
        "## Network observations",
        f"- [ ] Record whether the front host itself was reachable from the blocked-direct network",
        f"- [ ] Record candidate `lastNetworkEvent`: `{render(candidate_snapshot.get('lastNetworkEvent'))}`",
        f"- [ ] Record candidate `lastRecoveryAction`: `{render(candidate_snapshot.get('lastRecoveryAction'))}`",
        f"- [ ] Compare `reloadCount`: control=`{render(control_snapshot.get('reloadCount'))}`, candidate=`{render(candidate_snapshot.get('reloadCount'))}`",
        f"- [ ] Compare `restoreCount`: control=`{render(control_snapshot.get('restoreCount'))}`, candidate=`{render(candidate_snapshot.get('restoreCount'))}`",
        "",
        "## Artifacts",
        f"- [ ] Save candidate artifacts directory: `{render(candidate.get('artifact_dir'))}`",
        f"- [ ] Review candidate artifacts: `{render(sorted((candidate.get('artifacts') or {}).keys()))}`",
        f"- [ ] Confirm the candidate scaffold artifact matches the hidden preset used for the run",
        "",
        "## Outcome",
        "- [ ] Decide whether the candidate is a pass, soft-pass, or fail for owner-only rollout",
        "- [ ] Record the exact blocked-direct network conditions used",
        "- [ ] Keep stable `direct-reality` as the default lane until this checklist is clean",
        "",
    ]
    return "\n".join(lines)


control = load_capture(sys.argv[1])
candidate = load_capture(sys.argv[2])
output_path = sys.argv[3].strip() if len(sys.argv) > 3 else ""
checklist = build_checklist(control, candidate)

if output_path:
    Path(output_path).write_text(checklist + "\n", encoding="utf-8")
    print(output_path)
else:
    print(checklist)
PY

if [[ -n "$OUTPUT_PATH" ]]; then
  echo "Wrote checklist to $OUTPUT_PATH"
fi
