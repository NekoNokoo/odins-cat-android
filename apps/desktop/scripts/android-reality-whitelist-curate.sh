#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DATE_BIN="/bin/date"

SESSION_STAMP="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
OUTPUT_DIR=""
BASE_MODE="stable"
SELECTION="ordered"
BOOTSTRAP="direct-reality"
DEFAULT_SOURCE="operator-curated"
TAG_PREFIX="candidate"
DEFAULT_CIDR_BUCKET=""
MAX_PER_FAMILY=""
LIMIT=""
typeset -a EXCLUDE_RESULTS_FILES=()
typeset -a EXCLUDE_FAILED_FAMILY_FILES=()

typeset -a INPUTS=()
typeset -a URLS=()
CIDR_MAP_FILE=""

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-curate.sh [options]

Options:
  --input <path>               Input source file. May be repeated.
  --url <url>                  Remote source URL. May be repeated.
  --cidr-map <path>            Optional TSV/CSV file: serverName,cidrBucket
  --exclude-results <file>     Optional prior batch results JSON. May be repeated.
                               Matching serverName/tag entries will be excluded.
  --exclude-failed-families <file>
                               Optional prior active-lab batch results JSON. May be
                               repeated. Domain families with only failed probe
                               results will be excluded.
  --default-source <label>     Default source label. Default: operator-curated
  --tag-prefix <prefix>        Default generated tag prefix. Default: candidate
  --default-cidr-bucket <id>   Default cidrBucket when none is provided.
  --max-per-family <count>     Optional cap per registrable domain family before limit.
  --base-mode <mode>           Base stable REALITY mode. Default: stable
  --selection <mode>           Hint selection mode. Default: ordered
                               ordered
                               source-round-robin
  --bootstrap <mode>           Bootstrap family. Default: direct-reality
  --limit <count>              Limit output hint count after de-duplication.
  --output-dir <dir>           Output directory. Default: /tmp/odin-one-reality-whitelist-curation/<stamp>
  -h, --help                   Show this help.

Supported input shapes:
  - plain newline SNI/domain lists
  - VLESS subscription files with vless:// URIs
  - JSON datasets with `hints` or `androidRuntime.realityWhitelistHints.hints`

Outputs:
  - dataset.json               Curated owner-only hint dataset
  - preset.json                Ready-to-apply hidden preset patch
  - summary.md                 Short operator summary and next command

For single-hint owner-lab runs, pair the dataset with:
  --hint-tag <tag>
  --hint-index <n>
EOF
}

require_python() {
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    echo "python3 not found" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      INPUTS+=("$2")
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      URLS+=("$2")
      shift 2
      ;;
    --cidr-map)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      CIDR_MAP_FILE="$2"
      shift 2
      ;;
    --exclude-results)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EXCLUDE_RESULTS_FILES+=("$2")
      shift 2
      ;;
    --exclude-failed-families)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EXCLUDE_FAILED_FAMILY_FILES+=("$2")
      shift 2
      ;;
    --default-source)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DEFAULT_SOURCE="$2"
      shift 2
      ;;
    --tag-prefix)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      TAG_PREFIX="$2"
      shift 2
      ;;
    --default-cidr-bucket)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      DEFAULT_CIDR_BUCKET="$2"
      shift 2
      ;;
    --max-per-family)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      MAX_PER_FAMILY="$2"
      shift 2
      ;;
    --base-mode)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      BASE_MODE="$2"
      shift 2
      ;;
    --selection)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SELECTION="$2"
      shift 2
      ;;
    --bootstrap)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      BOOTSTRAP="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
      shift 2
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

require_python

if [[ ${#INPUTS[@]} -eq 0 && ${#URLS[@]} -eq 0 ]]; then
  echo "Provide at least one --input or --url source." >&2
  exit 1
fi
if [[ -n "$CIDR_MAP_FILE" && ! -f "$CIDR_MAP_FILE" ]]; then
  echo "CIDR map file not found: $CIDR_MAP_FILE" >&2
  exit 1
fi
for results_file in "${EXCLUDE_RESULTS_FILES[@]}"; do
  if [[ ! -f "$results_file" ]]; then
    echo "Prior results file not found: $results_file" >&2
    exit 1
  fi
done
for results_file in "${EXCLUDE_FAILED_FAMILY_FILES[@]}"; do
  if [[ ! -f "$results_file" ]]; then
    echo "Prior failed-family results file not found: $results_file" >&2
    exit 1
  fi
done
if [[ -n "$LIMIT" && ! "$LIMIT" =~ '^[0-9]+$' ]]; then
  echo "--limit must be a positive integer" >&2
  exit 1
fi
if [[ -n "$MAX_PER_FAMILY" ]] && { [[ ! "$MAX_PER_FAMILY" =~ '^[0-9]+$' ]] || [[ "$MAX_PER_FAMILY" -le 0 ]]; }; then
  echo "--max-per-family must be a positive integer" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-reality-whitelist-curation/${SESSION_STAMP}"
fi
mkdir -p "$OUTPUT_DIR"

DATASET_FILE="${OUTPUT_DIR%/}/dataset.json"
PRESET_FILE="${OUTPUT_DIR%/}/preset.json"
SUMMARY_FILE="${OUTPUT_DIR%/}/summary.md"
EXCLUDE_RESULTS_JOINED="$(printf '%s\n' "${EXCLUDE_RESULTS_FILES[@]}")"
EXCLUDE_FAILED_FAMILY_JOINED="$(printf '%s\n' "${EXCLUDE_FAILED_FAMILY_FILES[@]}")"

EXCLUDE_RESULTS_JOINED="$EXCLUDE_RESULTS_JOINED" \
EXCLUDE_FAILED_FAMILY_JOINED="$EXCLUDE_FAILED_FAMILY_JOINED" \
"$PYTHON_BIN" - "$DATASET_FILE" "$PRESET_FILE" "$SUMMARY_FILE" "$BASE_MODE" "$SELECTION" "$BOOTSTRAP" "$DEFAULT_SOURCE" "$TAG_PREFIX" "$DEFAULT_CIDR_BUCKET" "$LIMIT" "$CIDR_MAP_FILE" "$MAX_PER_FAMILY" "${INPUTS[@]}" --urls "${URLS[@]}" <<'PY'
import csv
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

dataset_path = Path(sys.argv[1])
preset_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
base_mode = sys.argv[4].strip() or "stable"
selection = sys.argv[5].strip() or "ordered"
bootstrap = sys.argv[6].strip() or "direct-reality"
default_source = sys.argv[7].strip() or "operator-curated"
tag_prefix = sys.argv[8].strip() or "candidate"
default_cidr_bucket = sys.argv[9].strip() or None
limit_raw = sys.argv[10].strip()
cidr_map_file = sys.argv[11].strip()
max_per_family_raw = sys.argv[12].strip()
remaining = sys.argv[13:]
limit = int(limit_raw) if limit_raw else None
max_per_family = int(max_per_family_raw) if max_per_family_raw else None
selection_aliases = {
    "ordered": "ordered",
    "source-round-robin": "source-round-robin",
    "source_round_robin": "source-round-robin",
    "round-robin-source": "source-round-robin",
}
selection = selection_aliases.get(selection, selection)
if selection not in {"ordered", "source-round-robin"}:
    raise SystemExit(f"Unsupported --selection value: {selection}")
exclude_results_files = [
    line.strip()
    for line in os.environ.get("EXCLUDE_RESULTS_JOINED", "").splitlines()
    if line.strip()
]
exclude_failed_family_files = [
    line.strip()
    for line in os.environ.get("EXCLUDE_FAILED_FAMILY_JOINED", "").splitlines()
    if line.strip()
]

if "--urls" in remaining:
    split_index = remaining.index("--urls")
    input_paths = remaining[:split_index]
    input_urls = remaining[split_index + 1 :]
else:
    input_paths = remaining
    input_urls = []

HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")
MULTI_LABEL_PUBLIC_SUFFIXES = {
    "ac.ru",
    "com.ru",
    "edu.ru",
    "gov.ru",
    "mil.ru",
    "net.ru",
    "org.ru",
    "ac.uk",
    "co.uk",
    "gov.uk",
    "org.uk",
}

def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug[:48] or "hint"

def normalize_hostname(value: str):
    return str(value or "").strip().lower().rstrip(".")

def registrable_domain(hostname: str):
    normalized = normalize_hostname(hostname)
    labels = [label for label in normalized.split(".") if label]
    if len(labels) < 2:
        return normalized
    suffix = ".".join(labels[-2:])
    if suffix in MULTI_LABEL_PUBLIC_SUFFIXES and len(labels) >= 3:
        return ".".join(labels[-3:])
    return suffix

def normalize_hint_entry(entry, *, source_label: str, entry_index: int):
    if isinstance(entry, str):
        server_name = normalize_hostname(entry)
        cidr_bucket = None
        hint_source = source_label
        tag = f"{tag_prefix}-{entry_index:02d}-{slugify(server_name)}"
    elif isinstance(entry, dict):
        server_name = normalize_hostname(entry.get("serverName") or entry.get("sni") or entry.get("host") or "")
        raw_cidr = str(entry.get("cidrBucket") or entry.get("cidr") or "").strip()
        cidr_bucket = raw_cidr or None
        raw_source = str(entry.get("source") or "").strip()
        hint_source = raw_source or source_label
        raw_tag = str(entry.get("tag") or "").strip()
        tag = raw_tag or f"{tag_prefix}-{entry_index:02d}-{slugify(server_name)}"
    else:
        return None
    if not server_name or not HOST_RE.match(server_name):
        return None
    if cidr_bucket is None and default_cidr_bucket:
        cidr_bucket = default_cidr_bucket
    return {
        "serverName": server_name,
        "domainFamily": registrable_domain(server_name),
        "cidrBucket": cidr_bucket,
        "source": hint_source,
        "tag": tag,
    }

def parse_json_payload(payload, *, source_label: str):
    if isinstance(payload, list):
        hint_items = payload
    elif isinstance(payload, dict):
        runtime = (((payload.get("androidRuntime") or {}).get("realityWhitelistHints")) or {})
        hint_items = runtime.get("hints")
        if hint_items is None:
            hint_items = payload.get("hints")
    else:
        return []
    if not isinstance(hint_items, list):
        return []
    return [
        normalize_hint_entry(item, source_label=source_label, entry_index=index)
        for index, item in enumerate(hint_items, start=1)
    ]

def parse_vless_uri(uri: str, *, source_label: str, entry_index: int):
    try:
        parsed = urllib.parse.urlsplit(uri)
    except ValueError:
        return None
    if parsed.scheme.lower() != "vless":
        return None
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=False)
    server_name = (
        query.get("sni", [None])[0]
        or query.get("serverName", [None])[0]
        or query.get("servername", [None])[0]
        or ""
    )
    if not server_name:
        return None
    hint = normalize_hint_entry(
        {
            "serverName": server_name,
            "source": source_label,
        },
        source_label=source_label,
        entry_index=entry_index,
    )
    return hint

def parse_line_payload(text: str, *, source_label: str):
    hints = []
    for index, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//") or line.startswith(";"):
            continue
        if "://" in line:
            hint = parse_vless_uri(line, source_label=source_label, entry_index=index)
            if hint is not None:
                hints.append(hint)
            continue
        hint = normalize_hint_entry(line, source_label=source_label, entry_index=index)
        if hint is not None:
            hints.append(hint)
    return hints

def merge_hint(existing, incoming):
    if not existing.get("domainFamily") and incoming.get("domainFamily"):
        existing["domainFamily"] = incoming["domainFamily"]
    if not existing.get("cidrBucket") and incoming.get("cidrBucket"):
        existing["cidrBucket"] = incoming["cidrBucket"]
    incoming_source = str(incoming.get("source") or "").strip()
    sources_seen = list(existing.get("sourcesSeen") or [])
    if incoming_source and incoming_source not in sources_seen:
        sources_seen.append(incoming_source)
    if sources_seen:
        existing["sourcesSeen"] = sources_seen
    if existing.get("source") == default_source and incoming_source:
        existing["source"] = incoming_source
    if existing.get("tag", "").startswith(f"{tag_prefix}-") and incoming.get("tag"):
        existing["tag"] = incoming["tag"]
    return existing

def build_selected_hints(source_entries):
    seen = OrderedDict()
    ordered = []
    if selection == "ordered":
        for entry in source_entries:
            for hint in entry["hints"]:
                key = hint["serverName"]
                existing = seen.get(key)
                if existing is None:
                    clone = dict(hint)
                    clone["sourcesSeen"] = [clone["source"]] if clone.get("source") else []
                    seen[key] = clone
                    ordered.append(clone)
                else:
                    merge_hint(existing, hint)
        return ordered

    max_len = max((len(entry["hints"]) for entry in source_entries), default=0)
    for offset in range(max_len):
        for entry in source_entries:
            if offset >= len(entry["hints"]):
                continue
            hint = entry["hints"][offset]
            key = hint["serverName"]
            existing = seen.get(key)
            if existing is None:
                clone = dict(hint)
                clone["sourcesSeen"] = [clone["source"]] if clone.get("source") else []
                seen[key] = clone
                ordered.append(clone)
            else:
                merge_hint(existing, hint)
    return ordered

def load_exclusion_sets(paths):
    excluded_server_names = set()
    excluded_tags = set()
    details = []
    for raw_path in paths:
        path = Path(raw_path).expanduser()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            details.append({"path": str(path), "error": str(exc), "excludedCount": 0})
            continue
        runs = payload.get("runs") if isinstance(payload, dict) else None
        run_count = 0
        if isinstance(runs, list):
            for run in runs:
                if not isinstance(run, dict):
                    continue
                run_count += 1
                for server_key in ("serverName", "observedSniHint", "candidateRequestHintServer"):
                    value = str(run.get(server_key) or "").strip().lower().rstrip(".")
                    if value:
                        excluded_server_names.add(value)
                for tag_key in ("tag", "observedHintTag", "candidateRequestHintTag"):
                    value = str(run.get(tag_key) or "").strip()
                    if value:
                        excluded_tags.add(value)
        details.append({"path": str(path), "error": None, "excludedCount": run_count})
    return excluded_server_names, excluded_tags, details

def parse_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "passed", "on"}
    return False

def parse_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0

def run_has_probe_evidence(run):
    if parse_int(run.get("candidateProbeCount")) > 0:
        return True
    for key in (
        "candidateProbeMode",
        "candidateTestStatus",
        "candidateHintTestStatus",
        "candidateHealthClass",
    ):
        if str(run.get(key) or "").strip():
            return True
    matrix = run.get("candidateProbeMatrix")
    return isinstance(matrix, list) and len(matrix) > 0

def run_probe_passed(run):
    if parse_bool(run.get("anyProbePassed")):
        return True
    if parse_bool(run.get("genericProbePassed")) or parse_bool(run.get("hintProbePassed")):
        return True
    if parse_int(run.get("candidateProbePassCount")) > 0:
        return True
    if str(run.get("candidateTestStatus") or "").strip() == "passed":
        return True
    if str(run.get("candidateHintTestStatus") or "").strip() == "passed":
        return True
    matrix = run.get("candidateProbeMatrix")
    if isinstance(matrix, list):
        for entry in matrix:
            if isinstance(entry, dict) and str(entry.get("status") or "").strip() == "passed":
                return True
    return False

def load_failed_family_sets(paths):
    excluded_families = set()
    details = []
    for raw_path in paths:
        path = Path(raw_path).expanduser()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            details.append(
                {
                    "path": str(path),
                    "error": str(exc),
                    "consideredRuns": 0,
                    "excludedFamilyCount": 0,
                    "families": [],
                }
            )
            continue
        runs = payload.get("runs") if isinstance(payload, dict) else None
        family_stats = {}
        considered_runs = 0
        if isinstance(runs, list):
            for run in runs:
                if not isinstance(run, dict):
                    continue
                if str(run.get("observedRuntimeFamily") or "").strip() != "reality-whitelist-assisted":
                    continue
                if str(run.get("observedActivationState") or "").strip() != "active":
                    continue
                if not run_has_probe_evidence(run):
                    continue
                server_name = normalize_hostname(
                    run.get("observedSniHint") or run.get("serverName") or run.get("candidateRequestHintServer") or ""
                )
                family = registrable_domain(server_name)
                if not family:
                    continue
                considered_runs += 1
                stats = family_stats.setdefault(family, {"tested": 0, "passed": False})
                stats["tested"] += 1
                if run_probe_passed(run):
                    stats["passed"] = True
        failed_families = sorted(
            family for family, stats in family_stats.items()
            if stats["tested"] > 0 and not stats["passed"]
        )
        excluded_families.update(failed_families)
        details.append(
            {
                "path": str(path),
                "error": None,
                "consideredRuns": considered_runs,
                "excludedFamilyCount": len(failed_families),
                "families": failed_families[:10],
            }
        )
    return excluded_families, details

def load_source_text(path_or_url: str, *, is_url: bool):
    if is_url:
        with urllib.request.urlopen(path_or_url, timeout=20) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(charset, errors="replace")
    return Path(path_or_url).expanduser().read_text(encoding="utf-8", errors="replace")

def source_label_for(path_or_url: str, *, is_url: bool):
    parsed = urllib.parse.urlparse(path_or_url)
    if is_url:
        label = Path(parsed.path).name or parsed.netloc or "remote-source"
    else:
        label = Path(path_or_url).name
    return f"{default_source}:{label}" if default_source else label

cidr_map = {}
if cidr_map_file:
    raw_map = Path(cidr_map_file).expanduser().read_text(encoding="utf-8", errors="replace")
    for raw_line in raw_map.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "\t" in line:
            parts = [part.strip() for part in line.split("\t", 1)]
        else:
            parts = [part.strip() for part in line.split(",", 1)]
        if len(parts) != 2:
            continue
        cidr_map[parts[0].lower().rstrip(".")] = parts[1]

excluded_server_names, excluded_tags, exclusion_details = load_exclusion_sets(exclude_results_files)
excluded_failed_families, failed_family_details = load_failed_family_sets(exclude_failed_family_files)
excluded_matches = []
excluded_failed_family_matches = []
family_cap_matches = []
source_descriptions = []
source_entries = []

for source_path in input_paths:
    source = Path(source_path).expanduser()
    if not source.is_file():
        raise SystemExit(f"Input file not found: {source}")
    source_text = load_source_text(str(source), is_url=False)
    label = source_label_for(str(source), is_url=False)
    try:
        payload = json.loads(source_text)
    except json.JSONDecodeError:
        hints = parse_line_payload(source_text, source_label=label)
        detected_format = "line"
    else:
        hints = [hint for hint in parse_json_payload(payload, source_label=label) if hint is not None]
        detected_format = "json"
    source_descriptions.append({"kind": "file", "path": str(source), "format": detected_format})
    source_entries.append({"label": label, "hints": hints})

for source_url in input_urls:
    source_text = load_source_text(source_url, is_url=True)
    label = source_label_for(source_url, is_url=True)
    try:
        payload = json.loads(source_text)
    except json.JSONDecodeError:
        hints = parse_line_payload(source_text, source_label=label)
        detected_format = "line"
    else:
        hints = [hint for hint in parse_json_payload(payload, source_label=label) if hint is not None]
        detected_format = "json"
    source_descriptions.append({"kind": "url", "url": source_url, "format": detected_format})
    source_entries.append({"label": label, "hints": hints})

hints = build_selected_hints(source_entries)
filtered_hints = []
for hint in hints:
    if not hint.get("cidrBucket"):
        mapped = cidr_map.get(hint["serverName"])
        if mapped:
            hint["cidrBucket"] = mapped
    if hint["serverName"] in excluded_server_names or hint.get("tag") in excluded_tags:
        excluded_matches.append(
            {
                "serverName": hint["serverName"],
                "tag": hint.get("tag"),
                "source": hint.get("source"),
            }
        )
        continue
    if hint.get("domainFamily") in excluded_failed_families:
        excluded_failed_family_matches.append(
            {
                "serverName": hint["serverName"],
                "domainFamily": hint.get("domainFamily"),
                "tag": hint.get("tag"),
                "source": hint.get("source"),
            }
        )
        continue
    filtered_hints.append(hint)

hints = filtered_hints

if max_per_family is not None:
    family_counts = {}
    capped_hints = []
    for hint in hints:
        family = hint.get("domainFamily") or hint["serverName"]
        seen_count = family_counts.get(family, 0)
        if seen_count >= max_per_family:
            family_cap_matches.append(
                {
                    "serverName": hint["serverName"],
                    "domainFamily": family,
                    "tag": hint.get("tag"),
                    "source": hint.get("source"),
                }
            )
            continue
        family_counts[family] = seen_count + 1
        capped_hints.append(hint)
    hints = capped_hints

if limit is not None:
    hints = hints[:limit]

if not hints:
    raise SystemExit("No whitelist hints were produced from the provided sources.")

dataset = {
    "kind": "odin-one-reality-whitelist-hints-v1",
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "baseMode": base_mode,
    "selection": selection,
    "bootstrap": bootstrap,
    "sources": source_descriptions,
    "excludedResultsFiles": exclusion_details,
    "excludedHintCount": len(excluded_matches),
    "excludedFailedFamilyFiles": failed_family_details,
    "excludedFailedFamilyCount": len(excluded_failed_families),
    "excludedFailedFamilyHintCount": len(excluded_failed_family_matches),
    "maxPerFamily": max_per_family,
    "familyCapExcludedHintCount": len(family_cap_matches),
    "hints": hints,
}

preset_hints = [
    {key: value for key, value in hint.items() if key not in {"sourcesSeen", "domainFamily"}}
    for hint in hints
]

preset = {
    "androidRuntime": {
        "reality": {
            "mode": base_mode,
        },
        "realityWhitelistHints": {
            "enabled": True,
            "mode": "scaffold",
            "selection": selection,
            "bootstrap": bootstrap,
            "hints": preset_hints,
        },
    }
}

placeholder_count = sum(1 for hint in hints if hint["serverName"].endswith(".example.com"))
cidr_count = sum(1 for hint in hints if hint.get("cidrBucket"))
multi_source_count = sum(1 for hint in hints if len(hint.get("sourcesSeen") or []) > 1)
family_count = len({hint.get("domainFamily") or hint["serverName"] for hint in hints})

dataset_path.write_text(json.dumps(dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
preset_path.write_text(json.dumps(preset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    "# Android REALITY Whitelist Hint Curation",
    "",
    f"- Output directory: `{dataset_path.parent}`",
    f"- Hint count: `{len(hints)}`",
    f"- Distinct domain families: `{family_count}`",
    f"- Hints with cidrBucket: `{cidr_count}`",
    f"- Placeholder hints: `{placeholder_count}`",
    f"- Hints seen in multiple sources: `{multi_source_count}`",
    f"- Base mode: `{base_mode}`",
    f"- Selection: `{selection}`",
    f"- Bootstrap: `{bootstrap}`",
]
if exclusion_details:
    summary_lines.append(f"- Prior result files: `{len(exclusion_details)}`")
    summary_lines.append(f"- Hints excluded by prior results: `{len(excluded_matches)}`")
if failed_family_details:
    summary_lines.append(f"- Prior failed-family files: `{len(failed_family_details)}`")
    summary_lines.append(f"- Domain families excluded by failed active-lab results: `{len(excluded_failed_families)}`")
    summary_lines.append(f"- Hints excluded by failed domain families: `{len(excluded_failed_family_matches)}`")
if max_per_family is not None:
    summary_lines.append(f"- Max per family: `{max_per_family}`")
    summary_lines.append(f"- Hints excluded by family cap: `{len(family_cap_matches)}`")
summary_lines.extend(["", "## Sources"])
for source in source_descriptions:
    if source["kind"] == "file":
        summary_lines.append(f"- file: `{source['path']}` (`{source['format']}`)")
    else:
        summary_lines.append(f"- url: `{source['url']}` (`{source['format']}`)")
summary_lines.extend(
    [
        "",
        "## First Hints",
    ]
)
for hint in hints[: min(5, len(hints))]:
    cidr_label = hint.get("cidrBucket") or "n/a"
    sources_seen = ", ".join(hint.get("sourcesSeen") or [hint["source"]])
    summary_lines.append(
        f"- `{hint['serverName']}` | family=`{hint.get('domainFamily') or 'n/a'}` | cidr=`{cidr_label}` | source=`{hint['source']}` | seen=`{sources_seen}` | tag=`{hint['tag']}`"
    )
if exclusion_details:
    summary_lines.extend(["", "## Prior Result Exclusions"])
    for detail in exclusion_details:
        status = detail["error"] or f"runs={detail['excludedCount']}"
        summary_lines.append(f"- `{detail['path']}` | `{status}`")
    for hint in excluded_matches[: min(5, len(excluded_matches))]:
        summary_lines.append(
            f"- excluded `{hint['serverName']}` | source=`{hint['source']}` | tag=`{hint['tag']}`"
        )
if failed_family_details:
    summary_lines.extend(["", "## Failed Family Exclusions"])
    for detail in failed_family_details:
        if detail["error"]:
            status = detail["error"]
        else:
            families = ", ".join(detail.get("families") or []) or "n/a"
            status = f"considered={detail['consideredRuns']} families={detail['excludedFamilyCount']} ({families})"
        summary_lines.append(f"- `{detail['path']}` | `{status}`")
    for hint in excluded_failed_family_matches[: min(5, len(excluded_failed_family_matches))]:
        summary_lines.append(
            f"- excluded `{hint['serverName']}` | family=`{hint['domainFamily']}` | source=`{hint['source']}` | tag=`{hint['tag']}`"
        )
if family_cap_matches:
    summary_lines.extend(["", "## Family Cap Exclusions"])
    for hint in family_cap_matches[: min(5, len(family_cap_matches))]:
        summary_lines.append(
            f"- capped `{hint['serverName']}` | family=`{hint['domainFamily']}` | source=`{hint['source']}` | tag=`{hint['tag']}`"
        )
summary_lines.extend(
    [
        "",
        "## Next Command",
        "```bash",
        f"ODIN_ONE_REALITY_HINTS_FILE={dataset_path} \\",
        "  apps/desktop/scripts/android-reality-whitelist-session.sh",
        "```",
    ]
)
first_hint = hints[0]
first_tag = first_hint["tag"]
summary_lines.extend(
    [
        "",
        "## Single-Hint Command",
        "```bash",
        f"ODIN_ONE_REALITY_HINTS_FILE={dataset_path} \\",
        f"  apps/desktop/scripts/android-reality-whitelist-session.sh --hint-tag {first_tag}",
        "```",
    ]
)
summary_lines.extend(
    [
        "",
        "## Batch Command",
        "```bash",
        f"apps/desktop/scripts/android-reality-whitelist-batch-session.sh --hints-file {dataset_path}",
        "```",
    ]
)
if placeholder_count:
    summary_lines.extend(
        [
            "",
            "## Warnings",
            f"- `{placeholder_count}` hint(s) still use `.example.com` placeholders and are not ready for blocked-direct owner-lab tests.",
        ]
    )

summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
print(f"Wrote curated whitelist hint dataset to {dataset_path}")
print(f"Wrote ready-to-apply preset patch to {preset_path}")
print(f"Wrote summary to {summary_path}")
PY

echo "Output dir: $OUTPUT_DIR"
