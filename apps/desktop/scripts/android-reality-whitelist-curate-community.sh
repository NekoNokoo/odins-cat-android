#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
CURL_BIN="${CURL_BIN:-$(command -v curl || true)}"

CURATE_SCRIPT="${SCRIPT_DIR}/android-reality-whitelist-curate.sh"

OUTPUT_DIR=""
BASE_MODE="stable"
SELECTION="source-round-robin"
BOOTSTRAP="direct-reality"
DEFAULT_SOURCE="operator-curated:community"
TAG_PREFIX="candidate"
DEFAULT_CIDR_BUCKET=""
MAX_PER_FAMILY=""
LIMIT=""
ONLY_SOURCE=""
EXCLUDE_RESULTS_FILE=""
EXCLUDE_FAILED_FAMILY_FILE=""

SOURCE_HXEHEX="hxehex-whitelist"
SOURCE_IGARECK_SNI="igareck-white-sni"
SOURCE_IGARECK_MOBILE="igareck-mobile-vless"

URL_HXEHEX="https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/master/whitelist.txt"
URL_IGARECK_SNI="https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/WHITE-SNI-RU-all.txt"
URL_IGARECK_MOBILE="https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/Vless-Reality-White-Lists-Rus-Mobile.txt"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-whitelist-curate-community.sh [options]

Options:
  --output-dir <dir>           Output directory. Default:
                               /tmp/odin-one-reality-whitelist-community/<stamp>
  --source <name>              Restrict to one source:
                               hxehex-whitelist
                               igareck-white-sni
                               igareck-mobile-vless
  --limit <count>              Limit hint count after de-duplication.
  --base-mode <mode>           Base stable REALITY mode. Default: stable
  --selection <mode>           Hint selection mode. Default: source-round-robin
  --bootstrap <mode>           Bootstrap family. Default: direct-reality
  --default-source <label>     Default source prefix. Default: operator-curated:community
  --tag-prefix <prefix>        Default generated tag prefix. Default: candidate
  --default-cidr-bucket <id>   Default cidrBucket when none is provided.
  --max-per-family <count>     Optional cap per registrable domain family before limit.
  --exclude-results <file>     Optional prior batch results JSON to exclude already-tested hints.
  --exclude-failed-families <file>
                               Optional prior active-lab results JSON. Domain families
                               with only failed probes will be excluded.
  -h, --help                   Show this help.

This helper wraps public community sources into the existing owner-only
curation flow and writes:
  - dataset.json
  - preset.json
  - summary.md
  - community-summary.md

Recommended next step:
  apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
    --hints-file <output-dir>/dataset.json --skip-placeholders
EOF
}

require_script() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required script is missing or not executable: $path" >&2
    exit 1
  fi
}

require_python() {
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    echo "python3 not found" >&2
    exit 1
  fi
}

require_curl() {
  if [[ -z "$CURL_BIN" || ! -x "$CURL_BIN" ]]; then
    echo "curl not found" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      ONLY_SOURCE="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      LIMIT="$2"
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
    --exclude-results)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EXCLUDE_RESULTS_FILE="$2"
      shift 2
      ;;
    --exclude-failed-families)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      EXCLUDE_FAILED_FAMILY_FILE="$2"
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
require_curl
require_script "$CURATE_SCRIPT"

if [[ -n "$LIMIT" ]]; then
  if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
    echo "--limit must be a positive integer" >&2
    exit 1
  fi
fi
if [[ -n "$MAX_PER_FAMILY" ]]; then
  if ! [[ "$MAX_PER_FAMILY" =~ ^[0-9]+$ ]] || [[ "$MAX_PER_FAMILY" -le 0 ]]; then
    echo "--max-per-family must be a positive integer" >&2
    exit 1
  fi
fi

case "$ONLY_SOURCE" in
  ""|"$SOURCE_HXEHEX"|"$SOURCE_IGARECK_SNI"|"$SOURCE_IGARECK_MOBILE")
    ;;
  *)
    echo "Unknown --source value: $ONLY_SOURCE" >&2
    exit 1
    ;;
esac

if [[ -n "$EXCLUDE_RESULTS_FILE" && ! -f "$EXCLUDE_RESULTS_FILE" ]]; then
  echo "Prior results file not found: $EXCLUDE_RESULTS_FILE" >&2
  exit 1
fi
if [[ -n "$EXCLUDE_FAILED_FAMILY_FILE" && ! -f "$EXCLUDE_FAILED_FAMILY_FILE" ]]; then
  echo "Prior failed-family results file not found: $EXCLUDE_FAILED_FAMILY_FILE" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="/tmp/odin-one-reality-whitelist-community/$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
fi
mkdir -p "$OUTPUT_DIR"

typeset -a SOURCE_NAMES=()
typeset -a SOURCE_URLS=()

append_source() {
  local name="$1"
  local url="$2"
  SOURCE_NAMES+=("$name")
  SOURCE_URLS+=("$url")
}

if [[ -z "$ONLY_SOURCE" || "$ONLY_SOURCE" == "$SOURCE_HXEHEX" ]]; then
  append_source "$SOURCE_HXEHEX" "$URL_HXEHEX"
fi
if [[ -z "$ONLY_SOURCE" || "$ONLY_SOURCE" == "$SOURCE_IGARECK_SNI" ]]; then
  append_source "$SOURCE_IGARECK_SNI" "$URL_IGARECK_SNI"
fi
if [[ -z "$ONLY_SOURCE" || "$ONLY_SOURCE" == "$SOURCE_IGARECK_MOBILE" ]]; then
  append_source "$SOURCE_IGARECK_MOBILE" "$URL_IGARECK_MOBILE"
fi

if [[ "${#SOURCE_URLS[@]}" -eq 0 ]]; then
  echo "No community sources were selected." >&2
  exit 1
fi

cmd=(
  "$CURATE_SCRIPT"
  --output-dir "$OUTPUT_DIR"
  --base-mode "$BASE_MODE"
  --selection "$SELECTION"
  --bootstrap "$BOOTSTRAP"
  --default-source "$DEFAULT_SOURCE"
  --tag-prefix "$TAG_PREFIX"
)
if [[ -n "$DEFAULT_CIDR_BUCKET" ]]; then
  cmd+=(--default-cidr-bucket "$DEFAULT_CIDR_BUCKET")
fi
if [[ -n "$MAX_PER_FAMILY" ]]; then
  cmd+=(--max-per-family "$MAX_PER_FAMILY")
fi
if [[ -n "$LIMIT" ]]; then
  cmd+=(--limit "$LIMIT")
fi
if [[ -n "$EXCLUDE_RESULTS_FILE" ]]; then
  cmd+=(--exclude-results "$EXCLUDE_RESULTS_FILE")
fi
if [[ -n "$EXCLUDE_FAILED_FAMILY_FILE" ]]; then
  cmd+=(--exclude-failed-families "$EXCLUDE_FAILED_FAMILY_FILE")
fi

FETCH_DIR="${OUTPUT_DIR%/}/fetched-sources"
mkdir -p "$FETCH_DIR"

typeset -a FETCHED_FILES=()
for (( idx = 1; idx <= ${#SOURCE_URLS[@]}; idx++ )); do
  source_name="${SOURCE_NAMES[$idx]}"
  source_url="${SOURCE_URLS[$idx]}"
  fetched_file="${FETCH_DIR%/}/${source_name}.txt"
  "$CURL_BIN" -fsSL "$source_url" -o "$fetched_file"
  FETCHED_FILES+=("$fetched_file")
  cmd+=(--input "$fetched_file")
done

"${cmd[@]}"

SOURCE_INDEX_FILE="${OUTPUT_DIR%/}/community-sources.json"
COMMUNITY_SUMMARY_FILE="${OUTPUT_DIR%/}/community-summary.md"
DATASET_FILE="${OUTPUT_DIR%/}/dataset.json"
PRESET_FILE="${OUTPUT_DIR%/}/preset.json"

SOURCE_NAMES_JOINED="$(printf '%s\n' "${SOURCE_NAMES[@]}")"
SOURCE_URLS_JOINED="$(printf '%s\n' "${SOURCE_URLS[@]}")"
FETCHED_FILES_JOINED="$(printf '%s\n' "${FETCHED_FILES[@]}")"
SOURCE_INDEX_FILE="$SOURCE_INDEX_FILE" \
COMMUNITY_SUMMARY_FILE="$COMMUNITY_SUMMARY_FILE" \
DATASET_FILE="$DATASET_FILE" \
PRESET_FILE="$PRESET_FILE" \
OUTPUT_DIR="$OUTPUT_DIR" \
SOURCE_NAMES_JOINED="$SOURCE_NAMES_JOINED" \
SOURCE_URLS_JOINED="$SOURCE_URLS_JOINED" \
FETCHED_FILES_JOINED="$FETCHED_FILES_JOINED" \
ONLY_SOURCE="$ONLY_SOURCE" \
EXCLUDE_RESULTS_FILE="$EXCLUDE_RESULTS_FILE" \
EXCLUDE_FAILED_FAMILY_FILE="$EXCLUDE_FAILED_FAMILY_FILE" \
"$PYTHON_BIN" - <<'PY'
import json
import os
import re
from pathlib import Path

source_names = [line for line in os.environ["SOURCE_NAMES_JOINED"].splitlines() if line]
source_urls = [line for line in os.environ["SOURCE_URLS_JOINED"].splitlines() if line]
fetched_files = [line for line in os.environ["FETCHED_FILES_JOINED"].splitlines() if line]
dataset_path = Path(os.environ["DATASET_FILE"])
dataset = json.loads(dataset_path.read_text(encoding="utf-8"))
hints = dataset.get("hints") or []
preset_path = Path(os.environ["PRESET_FILE"])
preset = json.loads(preset_path.read_text(encoding="utf-8"))

def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug[:48] or "hint"

for index, hint in enumerate(hints, start=1):
    server_name = str(hint.get("serverName") or "")
    old_tag = str(hint.get("tag") or "")
    hint["tag"] = f"candidate-{index:02d}-{slugify(server_name)}"
    if old_tag and old_tag != hint["tag"]:
        hint["sourceTag"] = old_tag

preset_hints = (
    ((preset.get("androidRuntime") or {}).get("realityWhitelistHints") or {}).get("hints") or []
)
for index, hint in enumerate(preset_hints, start=1):
    server_name = str(hint.get("serverName") or "")
    hint["tag"] = f"candidate-{index:02d}-{slugify(server_name)}"

dataset_path.write_text(json.dumps(dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
preset_path.write_text(json.dumps(preset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

source_index = {
    "kind": "odin-one-reality-whitelist-community-sources-v1",
    "selectedSource": os.environ["ONLY_SOURCE"] or None,
    "sources": [
        {"name": name, "url": url, "fetchedFile": fetched}
        for name, url, fetched in zip(source_names, source_urls, fetched_files)
    ],
    "dataset": str(dataset_path),
}
Path(os.environ["SOURCE_INDEX_FILE"]).write_text(
    json.dumps(source_index, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

cidr_count = sum(1 for hint in hints if hint.get("cidrBucket"))
ru_domain_count = sum(1 for hint in hints if str(hint.get("serverName") or "").endswith(".ru"))
family_count = len({str(hint.get("domainFamily") or hint.get("serverName") or "") for hint in hints if hint.get("serverName")})
multi_source_count = sum(1 for hint in hints if len(hint.get("sourcesSeen") or []) > 1)
top_tags = [str(hint.get("tag") or f"hint-{index}") for index, hint in enumerate(hints[:5], start=1)]

lines = [
    "# Android REALITY Whitelist Community Curation",
    "",
    f"- Output directory: `{os.environ['OUTPUT_DIR']}`",
    f"- Source count: `{len(source_names)}`",
    f"- Hint count: `{len(hints)}`",
    f"- Distinct domain families: `{family_count}`",
    f"- Hints with cidrBucket: `{cidr_count}`",
    f"- `.ru` hints: `{ru_domain_count}`",
    f"- Hints seen in multiple sources: `{multi_source_count}`",
    f"- Selection: `{dataset.get('selection') or 'n/a'}`",
    f"- Dataset: `{dataset_path}`",
    f"- Source index: `{os.environ['SOURCE_INDEX_FILE']}`",
]
if os.environ.get("EXCLUDE_RESULTS_FILE"):
    lines.append(f"- Prior results exclusion: `{os.environ['EXCLUDE_RESULTS_FILE']}`")
if os.environ.get("EXCLUDE_FAILED_FAMILY_FILE"):
    lines.append(f"- Failed-family exclusion: `{os.environ['EXCLUDE_FAILED_FAMILY_FILE']}`")
excluded_hint_count = dataset.get("excludedHintCount")
if excluded_hint_count is not None:
    lines.append(f"- Hints excluded by prior results: `{excluded_hint_count}`")
failed_family_count = dataset.get("excludedFailedFamilyCount")
if failed_family_count is not None:
    lines.append(f"- Domain families excluded by failed active-lab results: `{failed_family_count}`")
failed_family_hint_count = dataset.get("excludedFailedFamilyHintCount")
if failed_family_hint_count is not None:
    lines.append(f"- Hints excluded by failed domain families: `{failed_family_hint_count}`")
if dataset.get("maxPerFamily") is not None:
    lines.append(f"- Max per family: `{dataset.get('maxPerFamily')}`")
family_cap_excluded = dataset.get("familyCapExcludedHintCount")
if family_cap_excluded is not None:
    lines.append(f"- Hints excluded by family cap: `{family_cap_excluded}`")
lines.extend(["", "## Sources"])
for name, url in zip(source_names, source_urls):
    lines.append(f"- `{name}` -> `{url}`")

if top_tags:
    lines.extend(["", "## First Hint Tags"])
    lines.extend([f"- `{tag}`" for tag in top_tags])

first_hints = hints[: min(5, len(hints))]
if first_hints:
    lines.extend(["", "## First Hints"])
    for hint in first_hints:
        lines.append(
            f"- `{hint.get('serverName')}` | family=`{hint.get('domainFamily') or 'n/a'}` | source=`{hint.get('source') or 'n/a'}` | tag=`{hint.get('tag') or 'n/a'}`"
        )

lines.extend(
    [
        "",
        "## Next Commands",
        "",
        "Single-hint owner-lab run:",
        "```bash",
        f"ODIN_ONE_REALITY_HINTS_FILE={dataset_path} \\",
        "  apps/desktop/scripts/android-reality-whitelist-session.sh --hint-tag <tag>",
        "```",
        "",
        "Manual in-app batch run:",
        "```bash",
        f"apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \\",
        f"  --hints-file {dataset_path} \\",
        "  --skip-placeholders",
        "```",
    ]
)

Path(os.environ["COMMUNITY_SUMMARY_FILE"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

echo "Community dataset: $DATASET_FILE"
echo "Community summary: $COMMUNITY_SUMMARY_FILE"
