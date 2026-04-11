#!/bin/zsh
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-profile-preset.sh list
  apps/desktop/scripts/android-reality-profile-preset.sh <preset>

Environment:
  ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist/dataset.json \
  ODIN_ONE_REALITY_HINT_SELECT_TAG=candidate-01-max-ru \
    apps/desktop/scripts/android-reality-profile-preset.sh reality-whitelist-scaffold

  ODIN_ONE_CDN_PLAN_FILE=/tmp/odin-one-cdn-plan.json \
  ODIN_ONE_CDN_PLAN_SELECT_TAG=front-primary \
    apps/desktop/scripts/android-reality-profile-preset.sh cdn-ws-lab

  ODIN_ONE_CDN_PLAN_FILE=/tmp/odin-one-cdn-plan.json \
  ODIN_ONE_CDN_PLAN_SELECT_TAG=front-primary \
    apps/desktop/scripts/android-reality-profile-preset.sh cdn-xhttp-lab

Presets:
  baseline
  boot-restore
  dot-google
  doh-cloudflare
  network-reload
  leak-balanced
  leak-tight
  per-app-captive-bypass
  reality-whitelist-scaffold
  cdn-scaffold
  cdn-ws-lab
  cdn-xhttp-lab
  cdn-xhttp-native-lab
  cdn-xhttp-yandex-camouflage-lab
  cdn-httpupgrade-lab
EOF
}

emit_json() {
  cat
}

require_python() {
  if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    echo "python3 not found" >&2
    exit 1
  fi
}

emit_cdn_preset() {
  local mode="$1"
  local include_backup="$2"
  local default_transport="$3"
  local default_engine="${4:-sing-box}"
  require_python
  "$PYTHON_BIN" - "$mode" "$include_backup" "$default_transport" "$default_engine" <<'PY'
import json
import os
import sys
from pathlib import Path

mode = sys.argv[1]
include_backup = sys.argv[2].lower() == "true"
default_transport = sys.argv[3].strip().lower() or "websocket"
default_engine = sys.argv[4].strip().lower() or "sing-box"

def getenv(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default

def getenv_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        parsed = int(raw)
    except ValueError as exc:
        raise SystemExit(f"Invalid integer for {name}: {raw}") from exc
    if parsed <= 0:
        raise SystemExit(f"{name} must be > 0")
    return parsed

def getenv_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise SystemExit(f"Invalid boolean for {name}: {raw}")

def getenv_csv(name: str, default):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return list(default)
    return [item.strip() for item in raw.split(",") if item.strip()]


def normalize_list(value):
    if value is None:
        return None
    if isinstance(value, list):
        normalized = []
        for item in value:
            text = str(item).strip()
            if text:
                normalized.append(text)
        return normalized
    if isinstance(value, str):
        return [item.strip() for item in value.split(",") if item.strip()]
    return None


def parse_positive_int(value, *, default: int, field_name: str) -> int:
    if value is None or value == "":
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"Invalid integer for {field_name}: {value}") from exc
    if parsed <= 0:
        raise SystemExit(f"{field_name} must be > 0")
    return parsed


def parse_bool_like(value, *, default: bool, field_name: str) -> bool:
    if value is None or value == "":
        return default
    if isinstance(value, bool):
        return value
    raw = str(value).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise SystemExit(f"Invalid boolean for {field_name}: {value}")


def normalize_path(value: str, default: str) -> str:
    raw = (value or "").strip()
    if not raw:
        raw = default
    return raw if raw.startswith("/") else f"/{raw}"

default_direct_keywords = [
    "vk",
    "ok.ru",
    "mail.ru",
    "gosuslugi",
    "mos.ru",
    "yandex",
    "ya.ru",
    "ozon",
    "wildberries",
    "avito",
    "kinopoisk",
    "dzen",
    "hh",
    "2gis",
    "rutube",
    "magnit",
    "5ka",
    "perekrestok",
    "alfabank",
    "alfaonline",
    "tbank",
    "t-bank",
    "tinkoff",
    "vtb",
    "sber",
    "sberbank",
    "gazprombank",
    "gpb",
    "pochta",
]

def normalize_front_entry(entry, *, default_provider: str, default_port: int, default_path: str, default_tag_prefix: str, index: int):
    if isinstance(entry, str):
        host = entry.strip()
        if not host:
            return None
        port = default_port
        path = default_path
        tls_server_name = host
        host_header = host
        connect_host = host
        connect_port = port
        provider = default_provider
        tag = f"{default_tag_prefix}-{index:02d}"
    elif isinstance(entry, dict):
        host = str(entry.get("host") or entry.get("frontHost") or "").strip()
        if not host:
            return None
        port = parse_positive_int(entry.get("port") or entry.get("frontPort"), default=default_port, field_name=f"cdn front port #{index}")
        path = normalize_path(str(entry.get("path") or entry.get("frontPath") or ""), default_path)
        tls_server_name = str(entry.get("tlsServerName") or entry.get("serverName") or host).strip() or host
        host_header = str(entry.get("hostHeader") or entry.get("httpHostHeader") or host).strip() or host
        connect_host = str(
            entry.get("connectHost")
            or entry.get("dialHost")
            or entry.get("serverHost")
            or entry.get("address")
            or entry.get("server")
            or host
        ).strip() or host
        connect_port = parse_positive_int(
            entry.get("connectPort") or entry.get("dialPort") or entry.get("serverPort") or port,
            default=port,
            field_name=f"cdn connect port #{index}",
        )
        provider = str(entry.get("provider") or default_provider).strip() or default_provider
        raw_tag = str(entry.get("tag") or "").strip()
        tag = raw_tag or f"{default_tag_prefix}-{index:02d}"
    else:
        return None
    return {
        "host": host,
        "port": port,
        "path": path,
        "tlsServerName": tls_server_name,
        "hostHeader": host_header,
        "connectHost": connect_host,
        "connectPort": connect_port,
        "provider": provider,
        "tag": tag,
    }


def normalize_routing_policy(entry, default_policy: dict) -> dict:
    raw = entry if isinstance(entry, dict) else {}
    direct_keywords = normalize_list(raw.get("directDomainKeywords"))
    direct_domains = normalize_list(raw.get("directDomains"))
    blocked_keywords = normalize_list(raw.get("blockedDomainKeywords"))
    blocked_domains = normalize_list(raw.get("blockedDomains"))
    return {
        "dnsQueryStrategy": str(raw.get("dnsQueryStrategy") or default_policy["dnsQueryStrategy"]).strip().lower(),
        "domainStrategy": str(raw.get("domainStrategy") or default_policy["domainStrategy"]).strip().lower(),
        "domainMatcher": str(raw.get("domainMatcher") or default_policy["domainMatcher"]).strip().lower(),
        "directDomainKeywords": direct_keywords if direct_keywords is not None else list(default_policy["directDomainKeywords"]),
        "directDomains": direct_domains if direct_domains is not None else list(default_policy["directDomains"]),
        "blockedDomainKeywords": blocked_keywords if blocked_keywords is not None else list(default_policy["blockedDomainKeywords"]),
        "blockedDomains": blocked_domains if blocked_domains is not None else list(default_policy["blockedDomains"]),
        "blockSelectedFrontHost": parse_bool_like(
            raw.get("blockSelectedFrontHost"),
            default=bool(default_policy["blockSelectedFrontHost"]),
            field_name="cdn routing blockSelectedFrontHost",
        ),
    }


def load_cdn_plan_from_file(path_value: str, *, default_provider: str, default_front_port: int, default_front_path: str, default_routing_policy: dict):
    path = Path(path_value).expanduser()
    if not path.is_file():
        raise SystemExit(f"CDN plan file not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, list):
        runtime = {}
        front_items = payload
    elif isinstance(payload, dict):
        runtime = (
            (((payload.get("androidRuntime") or {}).get("cdnAntiWhitelist")) or {})
            or (payload.get("cdnAntiWhitelist") or {})
            or payload
        )
        front_items = runtime.get("frontPool")
        if front_items is None:
            front_items = runtime.get("fronts")
        if front_items is None:
            front_items = payload.get("frontPool")
        if front_items is None:
            front_items = payload.get("fronts")
    else:
        raise SystemExit("CDN plan file must contain a JSON object or array.")
    if not isinstance(front_items, list) or not front_items:
        raise SystemExit("CDN plan file does not contain any usable front entries.")
    normalized_fronts = []
    plan_provider = str(runtime.get("provider") or payload.get("provider") or default_provider).strip() or default_provider
    for index, item in enumerate(front_items, start=1):
        front = normalize_front_entry(
            item,
            default_provider=plan_provider,
            default_port=default_front_port,
            default_path=default_front_path,
            default_tag_prefix="cdn-plan",
            index=index,
        )
        if front is not None:
            normalized_fronts.append(front)
    if not normalized_fronts:
        raise SystemExit("CDN plan file did not produce any usable front entries.")
    origin = runtime.get("origin") if isinstance(runtime.get("origin"), dict) else {}
    return {
        "provider": plan_provider,
        "frontSelection": str(runtime.get("frontSelection") or payload.get("frontSelection") or "ordered").strip().lower() or "ordered",
        "bootstrap": str(runtime.get("bootstrap") or payload.get("bootstrap") or "direct-reality").strip().lower() or "direct-reality",
        "transport": str(runtime.get("transport") or payload.get("transport") or "websocket").strip().lower() or "websocket",
        "frontPool": normalized_fronts,
        "origin": {
            "host": str(origin.get("host") or payload.get("originHost") or "").strip(),
            "port": parse_positive_int(origin.get("port") or payload.get("originPort"), default=443, field_name="cdn origin port"),
            "scheme": str(origin.get("scheme") or payload.get("originScheme") or "https").strip().lower() or "https",
            "path": normalize_path(str(origin.get("path") or payload.get("originPath") or ""), "/odin-origin"),
        },
        "routingPolicy": normalize_routing_policy(runtime.get("routingPolicy") or payload.get("routingPolicy"), default_routing_policy),
    }


def select_cdn_fronts(dataset: dict):
    select_tag = os.environ.get("ODIN_ONE_CDN_PLAN_SELECT_TAG", "").strip()
    select_index_raw = os.environ.get("ODIN_ONE_CDN_PLAN_SELECT_INDEX", "").strip()
    fronts = list(dataset["frontPool"])
    if select_tag:
        filtered = [front for front in fronts if str(front.get("tag") or "").strip() == select_tag]
        if not filtered:
            raise SystemExit(f"CDN plan file does not contain tag: {select_tag}")
        fronts = filtered
    if select_index_raw:
        try:
            select_index = int(select_index_raw)
        except ValueError as exc:
            raise SystemExit(f"Invalid integer for ODIN_ONE_CDN_PLAN_SELECT_INDEX: {select_index_raw}") from exc
        if select_index <= 0:
            raise SystemExit("ODIN_ONE_CDN_PLAN_SELECT_INDEX must be > 0")
        if select_index > len(fronts):
            raise SystemExit(
                f"ODIN_ONE_CDN_PLAN_SELECT_INDEX={select_index} is out of range for {len(fronts)} front(s)."
            )
        fronts = [fronts[select_index - 1]]
    updated = dict(dataset)
    updated["frontPool"] = fronts
    return updated


default_provider = "generic"
default_front_port = 443
default_front_path = "/odin-edge-a"
default_routing_policy = {
    "dnsQueryStrategy": "use_ip",
    "domainStrategy": "ip_if_non_match",
    "domainMatcher": "hybrid",
    "directDomainKeywords": list(default_direct_keywords),
    "directDomains": [
        "1018213540.rsc.cdn77.org",
        "avtodor-tr.ru",
        "b2c-ticket-sentry.onelya.ru",
        "bitrix.info",
        "bkvet.ru",
        "cdn1.ozonusercontent.com",
        "cms1.dzvr.ru",
        "counter.yadro.ru",
        "dzvr.ru",
        "emex.ru",
        "fairplay-proxy.ott.yandex.ru",
        "fssp.gov.ru",
        "gorzdrav.spb.ru",
        "gosuslugi.ru",
        "esia.gosuslugi.ru",
        "gov.ru",
        "graphql.kinopoisk.ru",
        "gu-st.ru",
        "lk.gosuslugi.ru",
        "lemanapro.ru",
        "leroymerlin.ru",
        "mobileapp.russianpost.ru",
        "pos.gosuslugi.ru",
        "mos.ru",
        "mosenergosbyt.ru",
        "mosreg.ru",
        "nalog.ru",
        "ozon.ru",
        "pgu.mos.ru",
        "pesc.ru",
        "pochta.ru",
        "reso.ru",
        "rosreestr.gov.ru",
        "rzd-bonus.ru",
        "rzd.ru",
        "showip.net",
        "sys.refocus.ru",
        "vshark.ttk.ru",
        "widevine-proxy.ott.yandex.ru",
        "xn--90aijkdmaud0d.xn--p1ai",
        "yandex.net",
        "yandex.ru",
        "ya.ru",
    ],
    "blockedDomainKeywords": [],
    "blockedDomains": [],
    "blockSelectedFrontHost": True,
}

plan_dataset = None
plan_file = os.environ.get("ODIN_ONE_CDN_PLAN_FILE", "").strip()
if plan_file:
    plan_dataset = load_cdn_plan_from_file(
        plan_file,
        default_provider=default_provider,
        default_front_port=default_front_port,
        default_front_path=default_front_path,
        default_routing_policy=default_routing_policy,
    )
    plan_dataset = select_cdn_fronts(plan_dataset)

provider = getenv("ODIN_ONE_CDN_PROVIDER", (plan_dataset.get("provider") if plan_dataset else None) or default_provider)
front_selection = getenv("ODIN_ONE_CDN_FRONT_SELECTION", (plan_dataset.get("frontSelection") if plan_dataset else None) or "ordered")
transport = getenv("ODIN_ONE_CDN_TRANSPORT", (plan_dataset.get("transport") if plan_dataset else None) or default_transport).lower()
engine = getenv("ODIN_ONE_CDN_ENGINE", default_engine).lower()
bootstrap = getenv("ODIN_ONE_CDN_BOOTSTRAP", (plan_dataset.get("bootstrap") if plan_dataset else None) or "direct-reality")
xhttp_mode = getenv("ODIN_ONE_CDN_XHTTP_MODE", "")
tls_alpn = getenv_csv("ODIN_ONE_CDN_TLS_ALPN", [])
tls_allow_insecure = getenv_bool("ODIN_ONE_CDN_TLS_ALLOW_INSECURE", False)
camouflage_host = getenv("ODIN_ONE_CDN_CAMOUFLAGE_HOST", "")
xmux_max_concurrency_raw = os.environ.get("ODIN_ONE_CDN_XMUX_MAX_CONCURRENCY", "").strip()
xmux_hmax_request_times_raw = os.environ.get("ODIN_ONE_CDN_XMUX_HMAX_REQUEST_TIMES", "").strip()
xmux_hmax_reusable_secs_raw = os.environ.get("ODIN_ONE_CDN_XMUX_HMAX_REUSABLE_SECS", "").strip()
xmux = {}
if xmux_max_concurrency_raw:
    xmux["maxConcurrency"] = parse_positive_int(xmux_max_concurrency_raw, default=1, field_name="ODIN_ONE_CDN_XMUX_MAX_CONCURRENCY")
if xmux_hmax_request_times_raw:
    xmux["hMaxRequestTimes"] = parse_positive_int(xmux_hmax_request_times_raw, default=1, field_name="ODIN_ONE_CDN_XMUX_HMAX_REQUEST_TIMES")
if xmux_hmax_reusable_secs_raw:
    xmux["hMaxReusableSecs"] = parse_positive_int(xmux_hmax_reusable_secs_raw, default=1, field_name="ODIN_ONE_CDN_XMUX_HMAX_REUSABLE_SECS")

front_host = getenv("ODIN_ONE_CDN_FRONT_HOST", "allowed-front-a.example.com")
front_port = getenv_int("ODIN_ONE_CDN_FRONT_PORT", default_front_port)
front_path = normalize_path(os.environ.get("ODIN_ONE_CDN_FRONT_PATH", ""), default_front_path)
tls_server_name = getenv("ODIN_ONE_CDN_TLS_SERVER_NAME", front_host)
host_header = getenv("ODIN_ONE_CDN_HOST_HEADER", front_host)
connect_host = getenv("ODIN_ONE_CDN_CONNECT_HOST", front_host)
connect_port = getenv_int("ODIN_ONE_CDN_CONNECT_PORT", front_port)
front_tag = getenv("ODIN_ONE_CDN_FRONT_TAG", "primary-whitelist")

origin_defaults = (plan_dataset.get("origin") if plan_dataset else None) or {}
origin_host = getenv("ODIN_ONE_CDN_ORIGIN_HOST", str(origin_defaults.get("host") or "origin.example.com"))
origin_port = getenv_int("ODIN_ONE_CDN_ORIGIN_PORT", int(origin_defaults.get("port") or 443))
origin_scheme = getenv("ODIN_ONE_CDN_ORIGIN_SCHEME", str(origin_defaults.get("scheme") or "https")).lower()
origin_path = normalize_path(os.environ.get("ODIN_ONE_CDN_ORIGIN_PATH", str(origin_defaults.get("path") or "")), "/odin-origin")

routing_policy = normalize_routing_policy(plan_dataset.get("routingPolicy") if plan_dataset else None, default_routing_policy)
routing_policy = {
    "dnsQueryStrategy": getenv("ODIN_ONE_CDN_ROUTING_DNS_QUERY_STRATEGY", routing_policy["dnsQueryStrategy"]),
    "domainStrategy": getenv("ODIN_ONE_CDN_ROUTING_DOMAIN_STRATEGY", routing_policy["domainStrategy"]),
    "domainMatcher": getenv("ODIN_ONE_CDN_ROUTING_DOMAIN_MATCHER", routing_policy["domainMatcher"]),
    "directDomainKeywords": getenv_csv("ODIN_ONE_CDN_ROUTING_DIRECT_KEYWORDS", routing_policy["directDomainKeywords"]),
    "directDomains": getenv_csv("ODIN_ONE_CDN_ROUTING_DIRECT_DOMAINS", routing_policy["directDomains"]),
    "blockedDomainKeywords": getenv_csv("ODIN_ONE_CDN_ROUTING_BLOCK_KEYWORDS", routing_policy["blockedDomainKeywords"]),
    "blockedDomains": getenv_csv("ODIN_ONE_CDN_ROUTING_BLOCK_DOMAINS", routing_policy["blockedDomains"]),
    "blockSelectedFrontHost": getenv_bool("ODIN_ONE_CDN_ROUTING_BLOCK_SELECTED_FRONT_HOST", routing_policy["blockSelectedFrontHost"]),
}

if plan_dataset is not None:
    front_pool = []
    for entry in plan_dataset["frontPool"]:
        item = dict(entry)
        if not item.get("provider"):
            item["provider"] = provider
        front_pool.append(item)
else:
    front_pool = [
        {
            "host": front_host,
            "port": front_port,
            "path": front_path,
            "tlsServerName": camouflage_host or tls_server_name,
            "hostHeader": camouflage_host or host_header,
            "connectHost": connect_host,
            "connectPort": connect_port,
            "tlsAllowInsecure": tls_allow_insecure,
            "provider": provider,
            "tag": front_tag,
        }
    ]

    if include_backup:
        backup_host = getenv("ODIN_ONE_CDN_BACKUP_FRONT_HOST", "allowed-front-b.example.com")
        backup_port = getenv_int("ODIN_ONE_CDN_BACKUP_FRONT_PORT", 443)
        backup_path = normalize_path(os.environ.get("ODIN_ONE_CDN_BACKUP_FRONT_PATH", ""), "/odin-edge-b")
        backup_tls = getenv("ODIN_ONE_CDN_BACKUP_TLS_SERVER_NAME", backup_host)
        backup_host_header = getenv("ODIN_ONE_CDN_BACKUP_HOST_HEADER", backup_host)
        backup_connect_host = getenv("ODIN_ONE_CDN_BACKUP_CONNECT_HOST", backup_host)
        backup_connect_port = getenv_int("ODIN_ONE_CDN_BACKUP_CONNECT_PORT", backup_port)
        backup_tag = getenv("ODIN_ONE_CDN_BACKUP_FRONT_TAG", "backup-whitelist")
        front_pool.append(
            {
                "host": backup_host,
                "port": backup_port,
                "path": backup_path,
                "tlsServerName": camouflage_host or backup_tls,
                "hostHeader": camouflage_host or backup_host_header,
                "connectHost": backup_connect_host,
                "connectPort": backup_connect_port,
                "tlsAllowInsecure": tls_allow_insecure,
                "provider": provider,
                "tag": backup_tag,
            }
        )

payload = {
    "androidRuntime": {
        "cdnAntiWhitelist": {
            "enabled": True,
            "mode": mode,
            "provider": provider,
            "engine": engine,
            "transport": transport,
            "xhttpMode": xhttp_mode,
            "tlsAlpn": tls_alpn,
            "tlsAllowInsecure": tls_allow_insecure,
            "camouflageHost": camouflage_host,
            "xmux": xmux,
            "xmuxMaxConcurrency": xmux.get("maxConcurrency"),
            "xmuxHMaxRequestTimes": xmux.get("hMaxRequestTimes"),
            "xmuxHMaxReusableSecs": xmux.get("hMaxReusableSecs"),
            "frontSelection": front_selection,
            "frontPool": front_pool,
            "origin": {
                "host": origin_host,
                "port": origin_port,
                "scheme": origin_scheme,
                "path": origin_path,
            },
            "bootstrap": bootstrap,
            "routingPolicy": routing_policy,
        }
    }
}

print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

emit_reality_whitelist_preset() {
  local include_backup="$1"
  local runtime_mode="${2:-scaffold}"
  require_python
  "$PYTHON_BIN" - "$include_backup" "$runtime_mode" <<'PY'
import json
import os
import sys
from pathlib import Path

include_backup = sys.argv[1].lower() == "true"
runtime_mode = sys.argv[2].strip() or "scaffold"

def getenv(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value if value else default

def normalize_hint_entry(entry, *, default_source: str, default_tag_prefix: str, index: int):
    if isinstance(entry, str):
        server_name = entry.strip()
        if not server_name:
            return None
        cidr_bucket = None
        source = default_source
        tag = f"{default_tag_prefix}-{index:02d}"
    elif isinstance(entry, dict):
        server_name = str(entry.get("serverName") or entry.get("sni") or entry.get("host") or "").strip()
        if not server_name:
            return None
        raw_cidr = str(entry.get("cidrBucket") or entry.get("cidr") or "").strip()
        cidr_bucket = raw_cidr or None
        raw_source = str(entry.get("source") or "").strip()
        source = raw_source or default_source
        raw_tag = str(entry.get("tag") or "").strip()
        tag = raw_tag or f"{default_tag_prefix}-{index:02d}"
    else:
        return None
    return {
        "serverName": server_name,
        "cidrBucket": cidr_bucket,
        "source": source,
        "tag": tag,
    }

def load_hints_from_file(path_value: str):
    path = Path(path_value).expanduser()
    if not path.is_file():
        raise SystemExit(f"Reality whitelist hints file not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, list):
        hint_items = payload
        selection = None
        bootstrap = None
        base_mode = None
    elif isinstance(payload, dict):
        runtime = (((payload.get("androidRuntime") or {}).get("realityWhitelistHints")) or {})
        hint_items = runtime.get("hints")
        if hint_items is None:
            hint_items = payload.get("hints")
        selection = str(runtime.get("selection") or payload.get("selection") or "").strip() or None
        bootstrap = str(runtime.get("bootstrap") or payload.get("bootstrap") or "").strip() or None
        base_runtime = (((payload.get("androidRuntime") or {}).get("reality")) or {})
        base_mode = str(base_runtime.get("mode") or payload.get("baseMode") or payload.get("mode") or "").strip() or None
    else:
        raise SystemExit("Reality whitelist hints file must contain a JSON object or array.")
    if not isinstance(hint_items, list) or not hint_items:
        raise SystemExit("Reality whitelist hints file does not contain any hints.")
    normalized = []
    for index, item in enumerate(hint_items, start=1):
        hint = normalize_hint_entry(
            item,
            default_source="operator-curated",
            default_tag_prefix="curated",
            index=index,
        )
        if hint is not None:
            normalized.append(hint)
    if not normalized:
        raise SystemExit("Reality whitelist hints file did not produce any usable hint entries.")
    return {
        "hints": normalized,
        "selection": selection,
        "bootstrap": bootstrap,
        "baseMode": base_mode,
    }


def select_hints(dataset: dict):
    select_tag = os.environ.get("ODIN_ONE_REALITY_HINT_SELECT_TAG", "").strip()
    select_index_raw = os.environ.get("ODIN_ONE_REALITY_HINT_SELECT_INDEX", "").strip()
    hints = list(dataset["hints"])
    if select_tag:
        filtered = [hint for hint in hints if str(hint.get("tag") or "").strip() == select_tag]
        if not filtered:
            raise SystemExit(f"Reality whitelist hints file does not contain tag: {select_tag}")
        hints = filtered
    if select_index_raw:
        try:
            select_index = int(select_index_raw)
        except ValueError as exc:
            raise SystemExit(f"Invalid integer for ODIN_ONE_REALITY_HINT_SELECT_INDEX: {select_index_raw}") from exc
        if select_index <= 0:
            raise SystemExit("ODIN_ONE_REALITY_HINT_SELECT_INDEX must be > 0")
        if select_index > len(hints):
            raise SystemExit(
                f"ODIN_ONE_REALITY_HINT_SELECT_INDEX={select_index} is out of range for {len(hints)} hint(s)."
            )
        hints = [hints[select_index - 1]]
    updated = dict(dataset)
    updated["hints"] = hints
    return updated

dataset = None
hints_file = os.environ.get("ODIN_ONE_REALITY_HINTS_FILE", "").strip()
if hints_file:
    dataset = load_hints_from_file(hints_file)
    dataset = select_hints(dataset)

base_mode = getenv("ODIN_ONE_REALITY_BASE_MODE", (dataset.get("baseMode") if dataset else None) or "stable")
selection = getenv("ODIN_ONE_REALITY_HINT_SELECTION", (dataset.get("selection") if dataset else None) or "ordered")
bootstrap = getenv("ODIN_ONE_REALITY_HINT_BOOTSTRAP", (dataset.get("bootstrap") if dataset else None) or "direct-reality")
primary_server_name = getenv("ODIN_ONE_REALITY_HINT_SERVER_NAME", "allowed-sni-a.example.com")
primary_cidr_bucket = getenv("ODIN_ONE_REALITY_HINT_CIDR_BUCKET", "white-cidr-a")
primary_source = getenv("ODIN_ONE_REALITY_HINT_SOURCE", "operator-curated")
primary_tag = getenv("ODIN_ONE_REALITY_HINT_TAG", "primary-whitelist")

if dataset is not None:
    hints = dataset["hints"]
else:
    hints = [
        {
            "serverName": primary_server_name,
            "cidrBucket": primary_cidr_bucket,
            "source": primary_source,
            "tag": primary_tag,
        }
    ]

if dataset is None and include_backup:
    hints.append(
        {
            "serverName": getenv("ODIN_ONE_REALITY_BACKUP_HINT_SERVER_NAME", "allowed-sni-b.example.com"),
            "cidrBucket": getenv("ODIN_ONE_REALITY_BACKUP_HINT_CIDR_BUCKET", "white-cidr-b"),
            "source": getenv("ODIN_ONE_REALITY_BACKUP_HINT_SOURCE", primary_source),
            "tag": getenv("ODIN_ONE_REALITY_BACKUP_HINT_TAG", "backup-whitelist"),
        }
    )

payload = {
    "androidRuntime": {
        "reality": {
            "mode": base_mode,
        },
        "realityWhitelistHints": {
            "enabled": True,
            "mode": runtime_mode,
            "selection": selection,
            "hints": hints,
            "bootstrap": bootstrap,
        },
    }
}

print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

preset="${1:-}"

case "$preset" in
  ""|"-h"|"--help")
    usage
    ;;
  "list")
    cat <<'EOF'
baseline
boot-restore
dot-google
doh-cloudflare
network-reload
leak-balanced
leak-tight
per-app-captive-bypass
reality-whitelist-scaffold
reality-whitelist-lab
cdn-scaffold
cdn-ws-lab
cdn-xhttp-lab
cdn-xhttp-native-lab
cdn-xhttp-yandex-camouflage-lab
cdn-httpupgrade-lab
EOF
    ;;
  "baseline")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable"
    }
  }
}
EOF
    ;;
  "boot-restore")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "autoRestoreOnBoot": true
    }
  }
}
EOF
    ;;
  "dot-google")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "dot",
      "dnsServer": "8.8.8.8",
      "dnsServerName": "dns.google",
      "dnsStrategy": "prefer_ipv4"
    }
  }
}
EOF
    ;;
  "doh-cloudflare")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "doh",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsDohPath": "/dns-query",
      "dnsStrategy": "prefer_ipv4"
    }
  }
}
EOF
    ;;
  "network-reload")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": false,
      "allowPrivateNetworkBypass": true,
      "networkReloadOnChange": true,
      "networkReloadDebounceMs": 1500,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "leak-balanced")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": true,
      "allowPrivateNetworkBypass": false,
      "privateBypassCidrs": [
        "10.0.0.0/8",
        "192.168.0.0/16",
        "169.254.0.0/16"
      ],
      "networkReloadOnChange": false,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "leak-tight")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": true,
      "allowPrivateNetworkBypass": false,
      "networkReloadOnChange": false,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "per-app-captive-bypass")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "excludePackages": [
        "com.android.captiveportallogin"
      ]
    }
  }
}
EOF
    ;;
  "reality-whitelist-scaffold")
    emit_reality_whitelist_preset "true" "scaffold"
    ;;
  "reality-whitelist-lab")
    emit_reality_whitelist_preset "false" "lab"
    ;;
  "cdn-scaffold")
    emit_cdn_preset "scaffold" "true" "websocket"
    ;;
  "cdn-ws-lab")
    emit_cdn_preset "lab" "false" "websocket"
    ;;
  "cdn-xhttp-lab")
    emit_cdn_preset "lab" "false" "xhttp"
    ;;
  "cdn-xhttp-native-lab")
    emit_cdn_preset "lab" "false" "xhttp" "xray-native"
    ;;
  "cdn-xhttp-yandex-camouflage-lab")
    ODIN_ONE_CDN_TRANSPORT="${ODIN_ONE_CDN_TRANSPORT:-xhttp}" \
    ODIN_ONE_CDN_ENGINE="${ODIN_ONE_CDN_ENGINE:-xray-native}" \
    ODIN_ONE_CDN_XHTTP_MODE="${ODIN_ONE_CDN_XHTTP_MODE:-packet-up}" \
    ODIN_ONE_CDN_TLS_ALPN="${ODIN_ONE_CDN_TLS_ALPN:-h2,http/1.1}" \
    ODIN_ONE_CDN_TLS_ALLOW_INSECURE="${ODIN_ONE_CDN_TLS_ALLOW_INSECURE:-true}" \
    ODIN_ONE_CDN_CAMOUFLAGE_HOST="${ODIN_ONE_CDN_CAMOUFLAGE_HOST:-ya.ru}" \
    ODIN_ONE_CDN_XMUX_MAX_CONCURRENCY="${ODIN_ONE_CDN_XMUX_MAX_CONCURRENCY:-20}" \
    ODIN_ONE_CDN_XMUX_HMAX_REQUEST_TIMES="${ODIN_ONE_CDN_XMUX_HMAX_REQUEST_TIMES:-900}" \
    ODIN_ONE_CDN_XMUX_HMAX_REUSABLE_SECS="${ODIN_ONE_CDN_XMUX_HMAX_REUSABLE_SECS:-1800}" \
      emit_cdn_preset "lab" "false" "xhttp" "xray-native"
    ;;
  "cdn-httpupgrade-lab")
    emit_cdn_preset "lab" "false" "httpupgrade"
    ;;
  *)
    echo "Unknown preset: $preset" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
