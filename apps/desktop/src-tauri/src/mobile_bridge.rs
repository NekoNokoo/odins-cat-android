use crate::android_vpn;
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine as _,
};
use getrandom::getrandom;
use russh::{
    client,
    keys::{decode_secret_key, PrivateKeyWithHashAlg},
    ChannelMsg, Disconnect,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{hash_map::DefaultHasher, HashMap, HashSet},
    fs,
    hash::{Hash, Hasher},
    net::Ipv4Addr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Manager, State};
use x25519_dalek::StaticSecret;

const SHARE_CODE_PREFIX: &str = "odin1:";
const DEFAULT_REALITY_FLOW: &str = "xtls-rprx-vision";
const REALITY_DEPLOY_DEFAULT_PORT: u16 = 52443;
const REALITY_FALLBACK_MIN_PORT: u16 = 52443;
const REALITY_FALLBACK_MAX_PORT: u16 = 52543;
const REALITY_RELAY_DIRECT_PORT: u16 = 443;
const NAIVE_FALLBACK_PORT: u16 = 8443;
const HYSTERIA2_FALLBACK_PORT: u16 = 9443;
const WHITELIST_TURN_PORT_START: u16 = 56080;
const WHITELIST_TURN_PORT_END: u16 = 56180;
const WHITELIST_WIREGUARD_PORT_START: u16 = 51820;
const WHITELIST_WIREGUARD_PORT_END: u16 = 51920;
const WHITELIST_ROOT: &str = "/opt/whitelist";
const WHITELIST_BIN_DIR: &str = "/opt/whitelist/bin";
const WHITELIST_CONFIG_DIR: &str = "/opt/whitelist/config";
const WHITELIST_PROFILES_DIR: &str = "/opt/whitelist/profiles";
const WHITELIST_GUEST_PROFILES_DIR: &str = "/opt/whitelist/profiles/guests";
const LEGACY_WHITELIST_EDGE_ROOT: &str = "/opt/whitelist-edge";
const LEGACY_WHITELIST_YANDEX_EDGE_SERVICE_NAME: &str = "whitelist-yandex-edge.service";
const WHITELIST_XRAY_CONFIG_PATH: &str = "/opt/whitelist/config/xray-server.json";
const WHITELIST_REALITY_CONFIG_PATH: &str = "/opt/whitelist/config/xray-reality-server.json";
const WHITELIST_FALLBACKS_PATH: &str = "/opt/whitelist/config/fallbacks-staged.json";
const WHITELIST_PROTOCOL_PACK_PATH: &str = "/opt/whitelist/config/protocol-pack.json";
const WHITELIST_INVITE_PATH: &str = "/opt/whitelist/profiles/owner-profile.json";
const WHITELIST_XRAY_BINARY_PATH: &str = "/opt/whitelist/bin/xray";
const WHITELIST_SING_BOX_BINARY_PATH: &str = "/opt/whitelist/bin/sing-box";
const WHITELIST_PROXY_BINARY_PATH: &str = "/opt/whitelist/bin/vk-turn-proxy-server";
const WHITELIST_XRAY_SERVICE_PATH: &str = "/etc/systemd/system/whitelist-xray.service";
const WHITELIST_PROXY_SERVICE_PATH: &str = "/etc/systemd/system/whitelist-vk-turn-proxy.service";
const WHITELIST_YANDEX_ORIGIN_XHTTP_CONFIG_PATH: &str =
    "/opt/whitelist/config/xray-yandex-origin-xhttp.json";
const WHITELIST_YANDEX_ORIGIN_XHTTP_CERT_PATH: &str =
    "/opt/whitelist/config/xray-yandex-origin-xhttp.crt";
const WHITELIST_YANDEX_ORIGIN_XHTTP_KEY_PATH: &str =
    "/opt/whitelist/config/xray-yandex-origin-xhttp.key";
const WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_NAME: &str = "whitelist-yandex-origin-xhttp.service";
const WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_PATH: &str =
    "/etc/systemd/system/whitelist-yandex-origin-xhttp.service";
const VK_TURN_STREAM_COUNT_DEFAULT: u16 = 10;
const VK_TURN_STREAM_COUNT_MIN: u16 = 1;
const VK_TURN_STREAM_COUNT_MAX: u16 = 16;
const DEFAULT_PROBE_HTTP_URL: &str = "http://example.com";
const DEFAULT_PROBE_HTTPS_URL: &str = "https://example.com";
const DEFAULT_REALITY_SERVER_NAME: &str = "www.cloudflare.com";
const DEFAULT_REALITY_DEST: &str = "www.cloudflare.com:443";
const MOBILE_SSH_INACTIVITY_TIMEOUT_SECS: u64 = 120;
const MOBILE_SSH_KEEPALIVE_INTERVAL_SECS: u64 = 10;
const MOBILE_SSH_KEEPALIVE_MAX: usize = 12;
const PROVISION_FLOW_ORIGIN: &str = "origin";
const PROVISION_FLOW_EDGE_ATTACH: &str = "edge-attach";
const EDGE_PROVIDER_YANDEX: &str = "yandex-edge";
const EDGE_ROUTING_MODE_TCP_FORWARD: &str = "tcp-forward";
const EDGE_ROUTING_MODE_SNI_ROUTER: &str = "sni-router";
const EDGE_ROUTING_MODE_XRAY_PROXY: &str = "xray-proxy";
const EDGE_ROUTING_MODE_DEFAULT: &str = EDGE_ROUTING_MODE_XRAY_PROXY;
const OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD: &str = "reality-whitelist-scaffold";
const OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB: &str = "reality-whitelist-lab";
const OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD: &str = "reality-vps-scaffold";
const OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB: &str = "reality-vps-lab";
const OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB: &str = "reality-vps-relay-lab";
const OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE: &str = "reality-yandex-edge";
const OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY: &str = "reality-yandex-edge-proxy";
const OWNER_RUNTIME_LAB_VPS_TRANSPORT_TCP: &str = "tcp";
const OWNER_RUNTIME_LAB_VPS_TRANSPORT_GRPC: &str = "grpc";
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL: &str =
    "https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt";
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL: &str = "igareck-mobile-hourly";
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS: u64 = 1;
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_THRESHOLD_MS: u64 = 300;
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_TIMEOUT_MS: u64 = 1200;
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_CANDIDATE_LIMIT: u64 = 8;
const OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_MAX_PER_SNI: u64 = 2;
const YANDEX_EDGE_CONNECT_HOST: &str = "62.84.123.148";
const YANDEX_EDGE_CONNECT_PORT: u16 = 443;
const YANDEX_EDGE_FRONT_PATH: &str = "/odin-ws";
const YANDEX_EDGE_ORIGIN_PATH: &str = "/odin-origin";
const YANDEX_EDGE_CDN_ENGINE: &str = "xray-native";
const YANDEX_EDGE_CDN_MODE: &str = "lab";
const YANDEX_EDGE_CDN_PROVIDER: &str = "generic";
const YANDEX_EDGE_CDN_TRANSPORT: &str = "xhttp";
const YANDEX_EDGE_CDN_BOOTSTRAP: &str = "direct-reality";
const YANDEX_EDGE_CDN_FRONT_SELECTION: &str = "ordered";
const YANDEX_EDGE_CDN_CAMOUFLAGE_HOST: &str = "ya.ru";
const YANDEX_EDGE_CDN_CAMOUFLAGE_HOST_POOL: &[&str] = &[
    "ya.ru",
    "tunnel.vk-apps.com",
    "5post-gate.x5.ru",
    "ads.x5.ru",
];
const YANDEX_EDGE_CDN_DIRECT_DOMAIN_KEYWORDS: &[&str] = &[
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
];
const YANDEX_EDGE_CDN_DIRECT_DOMAINS: &[&str] = &[
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
    "gov.ru",
    "graphql.kinopoisk.ru",
    "gu-st.ru",
    "lemanapro.ru",
    "leroymerlin.ru",
    "mobileapp.russianpost.ru",
    "esia.gosuslugi.ru",
    "lk.gosuslugi.ru",
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
];
const YANDEX_EDGE_CDN_XHTTP_MODE: &str = "packet-up";
const YANDEX_EDGE_CDN_XMUX_MAX_CONCURRENCY: u64 = 20;
const YANDEX_EDGE_CDN_XMUX_HMAX_REQUEST_TIMES: u64 = 900;
const YANDEX_EDGE_CDN_XMUX_HMAX_REUSABLE_SECS: u64 = 1800;
const YANDEX_EDGE_ORIGIN_HOST: &str = "95.81.120.226";
const YANDEX_EDGE_ORIGIN_PORT: u16 = 52444;
const YANDEX_EDGE_ORIGIN_MIN_PORT: u16 = 52444;
const YANDEX_EDGE_ORIGIN_MAX_PORT: u16 = 52544;
const YANDEX_EDGE_SERVER_NAME: &str = "yandex.ru";
const YANDEX_EDGE_ACCEPTED_SERVER_NAMES: &[&str] = &[
    YANDEX_EDGE_SERVER_NAME,
    "ya.ru",
    "max.ru",
    "vkvideo.ru",
    "ads.x5.ru",
    "yandex.net",
];
const YANDEX_EDGE_ORIGIN_XHTTP_SERVER_NAME: &str = "www.microsoft.com";
const YANDEX_EDGE_FLOW: &str = "xtls-rprx-vision";
const YANDEX_EDGE_FINGERPRINT: &str = "chrome";
const YANDEX_EDGE_UUID: &str = "242fde4a-8b68-4e37-ada7-f37fb4f3d1d4";
const YANDEX_EDGE_PUBLIC_KEY: &str = "akv5dcxO4Gt9Spl_Tx612SnWC9958B4ihXhLRcavwAc";
const YANDEX_EDGE_SHORT_ID: &str = "5e26013865785390";
const YANDEX_EDGE_SOURCE: &str = "operator-curated:yandex-edge";
const YANDEX_EDGE_TAG: &str = "yandex-edge-62-84-123-148";
const WHITELIST_SOURCE_REPO_URL: &str = "embedded-static-whitelist";
const WHITELIST_IP_LIST_URL: &str = "embedded-static-whitelist:ipwhitelist.txt";
const WHITELIST_CIDR_LIST_URL: &str = "embedded-static-whitelist:cidrwhitelist.txt";
const BUNDLED_WHITELIST_IP_LIST: &str = include_str!("../resources/whitelist/ipwhitelist.txt");
const BUNDLED_WHITELIST_CIDR_LIST: &str = include_str!("../resources/whitelist/cidrwhitelist.txt");
const INVITE_EXPORT_EXTENSION: &str = ".odinone-access.json";
const XRAY_RELEASE_URL: &str =
    "https://github.com/XTLS/Xray-core/releases/download/v25.8.3/Xray-linux-64.zip";
const SING_BOX_LINUX_RELEASE_URL: &str = "https://github.com/SagerNet/sing-box/releases/download/v1.12.22/sing-box-1.12.22-linux-amd64.tar.gz";
const BUNDLED_VK_TURN_PROXY_SERVER_LINUX_AMD64: &[u8] = include_bytes!(concat!(
    env!("OUT_DIR"),
    "/vk-turn-proxy-server-linux-amd64"
));

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct InviteWireGuard {
    #[serde(default)]
    server_public_key: String,
    #[serde(default)]
    client_private_key: String,
    #[serde(default)]
    client_public_key: String,
    #[serde(default)]
    address: String,
    #[serde(default)]
    mtu: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct InviteReality {
    #[serde(default)]
    port: u16,
    #[serde(default)]
    server_name: String,
    #[serde(default)]
    public_key: String,
    #[serde(default)]
    short_id: String,
    #[serde(default)]
    uuid: String,
    #[serde(default)]
    flow: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct InviteProfileFile {
    #[serde(default)]
    id: String,
    #[serde(default)]
    role: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    protocol: String,
    #[serde(default)]
    transport: String,
    #[serde(default)]
    vk_turn_stream_count: u16,
    #[serde(default)]
    server_host: String,
    #[serde(default)]
    vk_turn_proxy_port: u16,
    #[serde(default)]
    wire_guard_port: u16,
    #[serde(default)]
    endpoint_port: u16,
    #[serde(default)]
    endpoint: String,
    #[serde(default)]
    fingerprint: String,
    #[serde(default)]
    created_at: String,
    #[serde(default)]
    revoked_at: String,
    #[serde(default)]
    status: String,
    #[serde(default, alias = "wireguard")]
    wire_guard: InviteWireGuard,
    #[serde(default)]
    vless_reality: InviteReality,
    #[serde(default)]
    android_runtime: Value,
    #[serde(default)]
    staged_fallbacks: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ProtocolPackEntry {
    #[serde(default)]
    id: String,
    #[serde(default)]
    label: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    engine: String,
    #[serde(default)]
    scheme: String,
    #[serde(default)]
    network: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct OwnerWireGuard {
    #[serde(default)]
    server_public_key: String,
    #[serde(default)]
    client_private_key: String,
    #[serde(default)]
    client_public_key: String,
    #[serde(default)]
    address: String,
    #[serde(default)]
    mtu: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct OwnerProfileFile {
    #[serde(default)]
    name: String,
    #[serde(default)]
    transport: String,
    #[serde(default)]
    active_protocol: String,
    #[serde(default)]
    vk_turn_stream_count: u16,
    #[serde(default)]
    server_host: String,
    #[serde(default)]
    vk_turn_proxy_port: u16,
    #[serde(default)]
    endpoint_port: u16,
    #[serde(default)]
    protocol_pack: Vec<ProtocolPackEntry>,
    #[serde(default)]
    android_runtime: Value,
    #[serde(default)]
    staged_fallbacks: Value,
    #[serde(default)]
    wireguard: OwnerWireGuard,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ServerDraftPayload {
    #[serde(default)]
    host: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    username: String,
    #[serde(default)]
    auth_method: String,
    #[serde(default)]
    transport: String,
    #[serde(default)]
    engine: Option<String>,
    #[serde(default)]
    protocol: Option<String>,
    #[serde(default)]
    vk_turn_stream_count: Option<u16>,
    #[serde(default)]
    vk_turn_proxy_port: Option<u16>,
    #[serde(default)]
    reality_port: Option<u16>,
    #[serde(default)]
    yandex_edge_origin_port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct EdgeServerPayload {
    #[serde(default)]
    host: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    username: String,
    #[serde(default)]
    auth_method: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct EdgeAttachPayload {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    provider: String,
    #[serde(default)]
    server: EdgeServerPayload,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    public_port: Option<u16>,
    #[serde(default)]
    routing_mode: Option<String>,
}

#[derive(Debug, Clone)]
struct YandexEdgeRuntimeLayout {
    root_dir: String,
    config_dir: String,
    manifest_path: String,
    haproxy_path: String,
    xray_path: String,
    xray_config: String,
    service_name: String,
    service_path: String,
    backend_service_name: String,
    backend_service_path: String,
}

#[derive(Debug, Clone)]
struct YandexEdgeRealityRoute {
    server_name: String,
    local_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProvisionPayload {
    #[serde(default)]
    server: ServerDraftPayload,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    flow: String,
    #[serde(default)]
    edge: Option<EdgeAttachPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GuestProfilePayload {
    #[serde(default)]
    server: ServerDraftPayload,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    host: String,
    #[serde(default)]
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalTunnelStartPayload {
    #[serde(default)]
    server: ServerDraftPayload,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    vk_link: String,
    #[serde(default)]
    exclude_packages: Vec<String>,
    #[serde(default)]
    owner_runtime_lab: Option<OwnerRuntimeLabPayload>,
    #[serde(default)]
    runtime_family: String,
    #[serde(default)]
    activation_state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SplitTunnelSelectionPayload {
    #[serde(default)]
    exclude_packages: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OwnerRuntimeLabRelayAutoselectPayload {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    subscription_url: String,
    #[serde(default)]
    source_label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OwnerRuntimeLabPayload {
    #[serde(default)]
    mode: String,
    #[serde(default)]
    hint_server_name: String,
    #[serde(default)]
    hint_cidr_bucket: String,
    #[serde(default)]
    hint_source: String,
    #[serde(default)]
    hint_tag: String,
    #[serde(default)]
    edge_server_name: String,
    #[serde(default)]
    vps_server_name: String,
    #[serde(default)]
    vps_port: u16,
    #[serde(default)]
    vps_connect_host: String,
    #[serde(default)]
    vps_connect_port: u16,
    #[serde(default)]
    vps_transport: String,
    #[serde(default)]
    vps_flow: String,
    #[serde(default)]
    vps_fingerprint: String,
    #[serde(default)]
    vps_grpc_service_name: String,
    #[serde(default)]
    vps_grpc_authority: String,
    #[serde(default)]
    vps_source: String,
    #[serde(default)]
    vps_tag: String,
    #[serde(default)]
    vps_owner_reality_egress: bool,
    #[serde(default)]
    vps_relay_autoselect: Option<OwnerRuntimeLabRelayAutoselectPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalTunnelTestPayload {
    #[serde(default)]
    url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MobileNetworkLensPayload {
    #[serde(default)]
    origin_host: String,
    #[serde(default)]
    tunnel_host: String,
    #[serde(default = "default_true")]
    cellular_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CheckEntry {
    key: String,
    label: String,
    ok: bool,
    detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanEntry {
    id: String,
    label: String,
    status: String,
    description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeploymentStateEntry {
    deployment_id: String,
    server_host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    deploy_flow: Option<String>,
    transport: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    protocol: Option<String>,
    status: String,
    steps: Vec<PlanEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    turn_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    wire_guard_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reality_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edge_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edge_host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edge_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edge_routing_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    health_checks: Vec<CheckEntry>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    protocol_pack: Vec<ProtocolPackEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct RemoteRealityState {
    port: u16,
    private_key: String,
    server_name: String,
    short_id: String,
    dest: String,
}

#[derive(Debug, Clone, Default)]
struct RemoteXrayState {
    wire_guard_port: u16,
    secret_key: String,
    reality: RemoteRealityState,
}

#[derive(Debug, Clone)]
struct RealityFallback {
    port: u16,
    server_name: String,
    public_key: String,
    short_id: String,
    uuid: String,
    flow: String,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct MobileDeploymentStore {
    items: Arc<Mutex<HashMap<String, DeploymentStateEntry>>>,
}

#[derive(Debug, Clone)]
struct ParsedIpv4Cidr {
    raw: String,
    network: u32,
    prefix: u8,
}

#[derive(Debug, Clone)]
struct ParsedWhitelistFiles {
    exact_ips: HashSet<Ipv4Addr>,
    cidrs: Vec<ParsedIpv4Cidr>,
    fetched_at: String,
}

struct MobileSshClient;

struct MobileSshSession {
    address: String,
    handle: client::Handle<MobileSshClient>,
}

impl client::Handler for MobileSshClient {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

impl MobileSshSession {
    async fn connect(server: &ServerDraftPayload, secret: &str) -> Result<Self, String> {
        let address = format!("{}:{}", server.host.trim(), normalized_port(server.port));
        let config = Arc::new(client::Config {
            // Android deploy runs long remote commands (binary downloads, systemd restarts,
            // egress probes). A tiny inactivity timeout can sever the SSH transport mid-rollout
            // and the next channel_open_session then surfaces as "new session: Disconnected".
            inactivity_timeout: Some(Duration::from_secs(MOBILE_SSH_INACTIVITY_TIMEOUT_SECS)),
            keepalive_interval: Some(Duration::from_secs(MOBILE_SSH_KEEPALIVE_INTERVAL_SECS)),
            keepalive_max: MOBILE_SSH_KEEPALIVE_MAX,
            ..<_>::default()
        });
        let mut handle = client::connect(config, address.clone(), MobileSshClient)
            .await
            .map_err(|err| format!("ssh dial failed: {err}"))?;
        let user = server.username.trim().to_string();

        let auth_result = match server.auth_method.trim() {
            "password" => handle
                .authenticate_password(user, secret.to_string())
                .await
                .map_err(|err| format!("ssh password authentication failed: {err}"))?,
            "private-key" => {
                let private_key = decode_secret_key(secret, None)
                    .map_err(|err| format!("parse private key: {err}"))?;
                let rsa_hash = handle
                    .best_supported_rsa_hash()
                    .await
                    .map_err(|err| format!("resolve best RSA hash: {err}"))?
                    .flatten();
                handle
                    .authenticate_publickey(
                        user,
                        PrivateKeyWithHashAlg::new(Arc::new(private_key), rsa_hash),
                    )
                    .await
                    .map_err(|err| format!("ssh public-key authentication failed: {err}"))?
            }
            auth_method => {
                return Err(format!("unsupported auth method: {auth_method}"));
            }
        };

        if !auth_result.success() {
            return Err("ssh authentication failed".to_string());
        }

        Ok(Self { address, handle })
    }

    async fn run(&mut self, cmd: &str) -> Result<String, String> {
        self.run_with_input(cmd, None).await
    }

    async fn run_with_input(&mut self, cmd: &str, input: Option<&[u8]>) -> Result<String, String> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .map_err(|err| format!("new session: {err}"))?;
        channel
            .exec(true, cmd)
            .await
            .map_err(|err| format!("command {cmd:?} failed: {err}"))?;

        if let Some(input_bytes) = input {
            let cursor = std::io::Cursor::new(input_bytes.to_vec());
            channel
                .data(cursor)
                .await
                .map_err(|err| format!("command {cmd:?} stdin failed: {err}"))?;
        }
        channel
            .eof()
            .await
            .map_err(|err| format!("command {cmd:?} eof failed: {err}"))?;

        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut exit_status: Option<u32> = None;

        while let Some(message) = channel.wait().await {
            match message {
                ChannelMsg::Data { data } => stdout.extend_from_slice(data.as_ref()),
                ChannelMsg::ExtendedData { data, .. } => stderr.extend_from_slice(data.as_ref()),
                ChannelMsg::ExitStatus {
                    exit_status: status,
                } => exit_status = Some(status),
                _ => {}
            }
        }

        let stdout_text = String::from_utf8_lossy(&stdout).trim().to_string();
        let stderr_text = String::from_utf8_lossy(&stderr).trim().to_string();
        if exit_status.unwrap_or_default() != 0 {
            let detail = if !stderr_text.is_empty() {
                stderr_text
            } else if !stdout_text.is_empty() {
                stdout_text
            } else {
                format!("exit status {}", exit_status.unwrap_or_default())
            };
            return Err(format!("command {cmd:?} failed: {detail}"));
        }

        if !stdout_text.is_empty() {
            Ok(stdout_text)
        } else {
            Ok(stderr_text)
        }
    }

    async fn upload(&mut self, remote_path: &str, data: &[u8], mode: &str) -> Result<(), String> {
        let temporary_path = format!("{remote_path}.tmp-upload");
        let command = format!(
            "mkdir -p {dir} && cat > {tmp} && chmod {mode} {tmp} && mv -f {tmp} {target}",
            dir = quote_shell(dir_of(remote_path)),
            tmp = quote_shell(&temporary_path),
            target = quote_shell(remote_path),
        );
        self.run_with_input(&command, Some(data)).await.map(|_| ())
    }

    async fn close(self) -> Result<(), String> {
        self.handle
            .disconnect(Disconnect::ByApplication, "", "English")
            .await
            .map_err(|err| format!("disconnect SSH session: {err}"))
    }
}

fn remote_root_shell(cmd: &str) -> String {
    let quoted = quote_shell(cmd);
    format!("if [ \"$(id -u)\" = \"0\" ]; then sh -lc {quoted}; else sudo sh -lc {quoted}; fi")
}

fn render_edge_service_ready_command(service_name: &str, public_port: u16) -> String {
    remote_root_shell(&format!(
        "for _ in $(seq 1 20); do state=\"$(systemctl is-active {} 2>/dev/null || true)\"; if [ \"$state\" = \"active\" ] && ss -H -ltn | awk '{{print $4}}' | grep -Eq '(^|\\\\]|:){}$'; then exit 0; fi; sleep 1; done; systemctl is-active {}",
        quote_shell(service_name),
        public_port,
        quote_shell(service_name),
    ))
}

fn render_remote_tcp_probe_command(
    host: &str,
    port: u16,
    attempts: u8,
    sleep_seconds: u8,
) -> String {
    remote_root_shell(&format!(
        "for _ in $(seq 1 {attempts}); do if timeout 8 bash -lc 'cat </dev/null >/dev/tcp/{host}/{port}' >/dev/null 2>&1; then exit 0; fi; sleep {sleep_seconds}; done; timeout 8 bash -lc 'cat </dev/null >/dev/tcp/{host}/{port}'",
        host = host,
        port = port,
        attempts = attempts,
        sleep_seconds = sleep_seconds,
    ))
}

async fn upload_with_sudo(
    ssh: &mut MobileSshSession,
    remote_path: &str,
    data: &[u8],
    mode: &str,
) -> Result<(), String> {
    let encoded = STANDARD.encode(data);
    let command = remote_root_shell(&format!(
        "mkdir -p {dir} && printf %s {data} | base64 -d > {target} && chmod {mode} {target}",
        dir = quote_shell(dir_of(remote_path)),
        data = quote_shell(&encoded),
        target = quote_shell(remote_path),
        mode = mode,
    ));
    ssh.run(&command).await.map(|_| ())
}

async fn ensure_remote_socat_installed(ssh: &mut MobileSshSession) -> Result<(), String> {
    let command = remote_root_shell(
        "if command -v socat >/dev/null 2>&1; then exit 0; fi; if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y socat; else echo 'socat is required and apt-get was not found' >&2; exit 1; fi",
    );
    ssh.run(&command).await.map(|_| ())
}

async fn ensure_remote_haproxy_installed(ssh: &mut MobileSshSession) -> Result<(), String> {
    let command = remote_root_shell(
        "if command -v haproxy >/dev/null 2>&1; then exit 0; fi; if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy; else echo 'haproxy is required and apt-get was not found' >&2; exit 1; fi",
    );
    ssh.run(&command).await.map(|_| ())
}

async fn ensure_remote_edge_xray_installed(
    ssh: &mut MobileSshSession,
    target_path: &str,
) -> Result<(), String> {
    let command = remote_root_shell(&format!(
        "mkdir -p {} && if [ -x {} ]; then exit 0; fi; {}",
        quote_shell(dir_of(target_path)),
        quote_shell(target_path),
        render_remote_xray_install_command(XRAY_RELEASE_URL, target_path),
    ));
    ssh.run(&command).await.map(|_| ())
}

impl MobileDeploymentStore {
    fn insert(&self, deployment: DeploymentStateEntry) {
        if let Ok(mut items) = self.items.lock() {
            items.insert(deployment.deployment_id.clone(), deployment);
        }
    }

    fn get(&self, deployment_id: &str) -> Option<DeploymentStateEntry> {
        self.items
            .lock()
            .ok()
            .and_then(|items| items.get(deployment_id).cloned())
    }

    fn update<F>(&self, deployment_id: &str, apply: F)
    where
        F: FnOnce(&mut DeploymentStateEntry),
    {
        if let Ok(mut items) = self.items.lock() {
            if let Some(deployment) = items.get_mut(deployment_id) {
                apply(deployment);
            }
        }
    }
}

#[tauri::command]
pub fn mobile_core_health() -> Value {
    json!({
        "service": "odin-one-mobile-bridge",
        "status": "ok"
    })
}

#[tauri::command]
pub async fn mobile_check_whitelist_ip(app: AppHandle, ip: String) -> Result<Value, String> {
    let checked_at = now_rfc3339();
    let trimmed_ip = ip.trim();
    let response_meta = json!({
        "sourceRepo": WHITELIST_SOURCE_REPO_URL,
        "ipListUrl": WHITELIST_IP_LIST_URL,
        "cidrListUrl": WHITELIST_CIDR_LIST_URL,
    });

    let parsed_ip = match trimmed_ip.parse::<Ipv4Addr>() {
        Ok(address) => address,
        Err(_) => {
            let mut response = json!({
                "ip": trimmed_ip,
                "valid": false,
                "matchedIp": false,
                "matchedCidr": false,
                "matchedCidrs": Vec::<String>::new(),
                "checkedAt": checked_at,
                "cached": false,
                "error": "enter a valid IPv4 address"
            });
            merge_json_object(&mut response, &response_meta);
            return Ok(response);
        }
    };

    let (source, cached, note) = load_whitelist_lookup_source(&app).await?;
    let matched_ip = source.exact_ips.contains(&parsed_ip);
    let mut matched_cidrs = source
        .cidrs
        .iter()
        .filter(|cidr| ipv4_in_cidr(parsed_ip, cidr))
        .map(|cidr| (cidr.prefix, cidr.raw.clone()))
        .collect::<Vec<_>>();
    matched_cidrs.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| left.1.cmp(&right.1)));
    let matched_cidrs = matched_cidrs
        .into_iter()
        .map(|(_, cidr)| cidr)
        .collect::<Vec<_>>();

    let mut response = json!({
        "ip": trimmed_ip,
        "valid": true,
        "matchedIp": matched_ip,
        "matchedCidr": !matched_cidrs.is_empty(),
        "matchedCidrs": matched_cidrs,
        "checkedAt": checked_at,
        "listsFetchedAt": source.fetched_at,
        "cached": cached
    });
    if let Some(message) = note {
        response["note"] = json!(message);
    }
    merge_json_object(&mut response, &response_meta);
    Ok(response)
}

#[tauri::command]
pub async fn mobile_validate_provision(payload: ProvisionPayload) -> Result<Value, String> {
    let flow = normalized_provision_flow(&payload.flow);
    eprintln!(
        "[mobile-provision] validate flow={} host={} user={} edge_enabled={}",
        flow,
        payload.server.host.trim(),
        payload.server.username.trim(),
        payload.edge.as_ref().is_some_and(|edge| edge.enabled)
    );
    let protocol_pack = build_protocol_pack(&payload);
    let mut warnings = build_plan_warnings(&payload.server, flow);
    warnings.insert(
        0,
        "MVP validation currently uses insecure host key acceptance and should be hardened before production use.".to_string(),
    );

    if payload.server.host.trim().is_empty()
        || payload.server.username.trim().is_empty()
        || payload.secret.trim().is_empty()
    {
        return Ok(json!({
            "ok": false,
            "host": payload.server.host,
            "user": payload.server.username,
            "authMethod": payload.server.auth_method,
            "checks": [],
            "warnings": warnings,
            "protocolPack": protocol_pack,
            "error": "host, username, and secret are required"
        }));
    }

    if flow == PROVISION_FLOW_EDGE_ATTACH {
        if let Err(error) = validate_edge_attach_payload(&payload) {
            return Ok(json!({
                "ok": false,
                "host": payload.server.host,
                "deployFlow": flow,
                "user": payload.server.username,
                "authMethod": payload.server.auth_method,
                "edgeEnabled": payload.edge.as_ref().is_some_and(|edge| edge.enabled),
                "edgeHost": payload.edge.as_ref().map(|edge| edge.server.host.trim()).unwrap_or_default(),
                "edgePort": payload.edge.as_ref().map(|edge| normalized_edge_public_port(Some(edge))).unwrap_or_default(),
                "checks": [],
                "warnings": warnings,
                "protocolPack": protocol_pack,
                "error": error
            }));
        }
        return mobile_validate_edge_attach(payload, warnings, protocol_pack).await;
    }

    if let Err(error) = validate_deployment_port_hints(&payload.server) {
        return Ok(json!({
            "ok": false,
            "host": payload.server.host,
            "deployFlow": flow,
            "user": payload.server.username,
            "authMethod": payload.server.auth_method,
            "checks": [],
            "warnings": warnings,
            "protocolPack": protocol_pack,
            "error": error
        }));
    }

    let mut ssh = match MobileSshSession::connect(&payload.server, &payload.secret).await {
        Ok(ssh) => ssh,
        Err(error) => {
            return Ok(json!({
                "ok": false,
                "host": payload.server.host,
                "deployFlow": flow,
                "user": payload.server.username,
                "authMethod": payload.server.auth_method,
                "checks": [],
                "warnings": warnings,
                "protocolPack": protocol_pack,
                "error": error
            }));
        }
    };
    let address = ssh.address.clone();
    let port = normalized_port(payload.server.port);
    let mut checks = vec![
        CheckEntry {
            key: "ssh-port".to_string(),
            label: "SSH port reachable".to_string(),
            ok: true,
            detail: format!("{port}/tcp accepted the connection"),
        },
        CheckEntry {
            key: "tcp-connect".to_string(),
            label: "TCP connectivity".to_string(),
            ok: true,
            detail: format!("Connected to {address}"),
        },
    ];

    let result_specs = [
        ("remote-user", "Remote user", "whoami"),
        ("os-release", "Operating system", "uname -a"),
        (
            "sudo-presence",
            "Sudo availability",
            "command -v sudo || true",
        ),
        (
            "docker-presence",
            "Docker presence",
            "command -v docker || true",
        ),
    ];
    let mut all_ok = true;
    for (key, label, command) in result_specs {
        let outcome = ssh.run(command).await;
        let ok = outcome.is_ok();
        let mut detail = match outcome {
            Ok(output) => output,
            Err(error) => error,
        };
        if detail.trim().is_empty() {
            detail = "No output".to_string();
        }
        checks.push(CheckEntry {
            key: key.to_string(),
            label: label.to_string(),
            ok,
            detail,
        });
        all_ok &= ok;
    }
    let (egress_checks, egress_ok) = run_remote_egress_checks(&mut ssh).await;
    checks.extend(egress_checks);
    let _ = ssh.close().await;

    let mut response = json!({
        "ok": all_ok && egress_ok,
        "host": payload.server.host,
        "deployFlow": flow,
        "user": payload.server.username,
        "authMethod": payload.server.auth_method,
        "checks": checks,
        "warnings": warnings,
        "protocolPack": protocol_pack
    });
    if !all_ok {
        response["error"] = json!("one or more validation checks failed");
    } else if !egress_ok {
        response["error"] = json!("remote egress checks failed");
    }

    Ok(response)
}

async fn mobile_validate_edge_attach(
    payload: ProvisionPayload,
    warnings: Vec<String>,
    protocol_pack: Vec<ProtocolPackEntry>,
) -> Result<Value, String> {
    let flow = normalized_provision_flow(&payload.flow);
    let edge = payload
        .edge
        .as_ref()
        .ok_or_else(|| "edge configuration is required".to_string())?;
    let edge_server = edge_server_payload(edge);

    let mut checks = Vec::new();
    let mut all_ok = true;

    let mut origin = match MobileSshSession::connect(&payload.server, &payload.secret).await {
        Ok(ssh) => ssh,
        Err(error) => {
            return Ok(json!({
                "ok": false,
                "host": payload.server.host,
                "deployFlow": flow,
                "user": payload.server.username,
                "authMethod": payload.server.auth_method,
                "edgeEnabled": true,
                "edgeHost": edge.server.host,
                "edgePort": normalized_edge_public_port(Some(edge)),
                "edgeRoutingMode": normalized_edge_routing_mode(Some(edge)),
                "checks": checks,
                "warnings": warnings,
                "protocolPack": protocol_pack,
                "error": error
            }));
        }
    };
    checks.push(CheckEntry {
        key: "origin-tcp-connect".to_string(),
        label: "Origin TCP connectivity".to_string(),
        ok: true,
        detail: format!(
            "Connected to {}:{}",
            payload.server.host.trim(),
            normalized_port(payload.server.port)
        ),
    });
    let reality = match load_remote_access_state(&mut origin).await {
        Ok((owner, _)) => match read_invite_reality_fallback(&owner) {
            Ok(reality) => {
                checks.push(CheckEntry {
                    key: "origin-owner-profile".to_string(),
                    label: "Origin owner profile".to_string(),
                    ok: true,
                    detail: format!(
                        "Loaded the live owner profile with REALITY fallback {}:{}.",
                        payload.server.host.trim(),
                        reality.port
                    ),
                });
                Some(reality)
            }
            Err(error) => {
                checks.push(CheckEntry {
                    key: "origin-owner-profile".to_string(),
                    label: "Origin owner profile".to_string(),
                    ok: false,
                    detail: error.clone(),
                });
                all_ok = false;
                None
            }
        },
        Err(error) => {
            checks.push(CheckEntry {
                key: "origin-owner-profile".to_string(),
                label: "Origin owner profile".to_string(),
                ok: false,
                detail: error.clone(),
            });
            all_ok = false;
            None
        }
    };
    let _ = origin.close().await;

    let mut edge_ssh = match MobileSshSession::connect(&edge_server, &edge.secret).await {
        Ok(ssh) => ssh,
        Err(error) => {
            return Ok(json!({
                "ok": false,
                "host": payload.server.host,
                "deployFlow": flow,
                "user": payload.server.username,
                "authMethod": payload.server.auth_method,
                "edgeEnabled": true,
                "edgeHost": edge.server.host,
                "edgePort": normalized_edge_public_port(Some(edge)),
                "edgeRoutingMode": normalized_edge_routing_mode(Some(edge)),
                "checks": checks,
                "warnings": warnings,
                "protocolPack": protocol_pack,
                "error": error
            }));
        }
    };
    checks.push(CheckEntry {
        key: "edge-tcp-connect".to_string(),
        label: "Edge TCP connectivity".to_string(),
        ok: true,
        detail: format!(
            "Connected to {}:{}",
            edge.server.host.trim(),
            normalized_port(edge.server.port)
        ),
    });

    for (key, label, command) in [
        ("edge-remote-user", "Edge remote user", "whoami"),
        ("edge-os-release", "Edge operating system", "uname -a"),
        (
            "edge-sudo-ready",
            "Edge sudo readiness",
            "if [ \"$(id -u)\" = \"0\" ]; then echo root; else sudo -n true && echo sudo-ready; fi",
        ),
    ] {
        let outcome = edge_ssh.run(command).await;
        let ok = outcome.is_ok();
        let detail = outcome.unwrap_or_else(|error| error);
        checks.push(CheckEntry {
            key: key.to_string(),
            label: label.to_string(),
            ok,
            detail: if detail.trim().is_empty() {
                "No output".to_string()
            } else {
                detail
            },
        });
        all_ok &= ok;
    }

    let port = normalized_edge_public_port(Some(edge));
    let port_check_command = format!(
        "sh -lc {}",
        quote_shell(&format!(
            "if command -v ss >/dev/null 2>&1 && ss -ltnH | awk '{{print $4}}' | grep -Eq '(^|:){port}$'; then echo 'port {port} already listens'; exit 1; else echo 'port {port} is free'; fi"
        ))
    );
    let port_check = edge_ssh.run(&port_check_command).await;
    let port_check_ok = port_check.is_ok();
    checks.push(CheckEntry {
        key: "edge-public-port".to_string(),
        label: "Edge public port".to_string(),
        ok: port_check_ok,
        detail: port_check.unwrap_or_else(|error| error),
    });
    all_ok &= port_check_ok;

    if let Some(reality) = reality.as_ref() {
        let origin_reachability = edge_ssh
            .run(&remote_root_shell(&format!(
                "timeout 8 bash -lc 'cat </dev/null >/dev/tcp/{}/{}'",
                payload.server.host.trim(),
                reality.port,
            )))
            .await;
        let origin_reachability_ok = origin_reachability.is_ok();
        checks.push(CheckEntry {
            key: "edge-origin-reachability".to_string(),
            label: "Edge to origin reachability".to_string(),
            ok: origin_reachability_ok,
            detail: origin_reachability.unwrap_or_else(|error| error),
        });
        all_ok &= origin_reachability_ok;
    }

    if normalized_edge_routing_mode(Some(edge)) == EDGE_ROUTING_MODE_XRAY_PROXY {
        let prereq = edge_ssh
            .run(
                "command -v curl >/dev/null && command -v timeout >/dev/null && command -v systemctl >/dev/null",
            )
            .await;
        let prereq_ok = prereq.is_ok();
        checks.push(CheckEntry {
            key: "edge-xray-proxy-prerequisites".to_string(),
            label: "Edge xray-proxy prerequisites".to_string(),
            ok: prereq_ok,
            detail: prereq.unwrap_or_else(|error| error),
        });
        all_ok &= prereq_ok;
    }
    let _ = edge_ssh.close().await;

    let mut response = json!({
        "ok": all_ok,
        "host": payload.server.host,
        "deployFlow": flow,
        "user": payload.server.username,
        "authMethod": payload.server.auth_method,
        "edgeEnabled": true,
        "edgeHost": edge.server.host,
        "edgePort": port,
        "edgeRoutingMode": normalized_edge_routing_mode(Some(edge)),
        "checks": checks,
        "warnings": warnings,
        "protocolPack": protocol_pack,
    });
    if !all_ok {
        response["error"] = json!("one or more validation checks failed");
    }
    Ok(response)
}

#[tauri::command]
pub fn mobile_build_provision_plan(payload: ProvisionPayload) -> Value {
    let flow = normalized_provision_flow(&payload.flow);
    json!({
        "serverHost": payload.server.host,
        "deployFlow": flow,
        "transport": "xray",
        "steps": build_plan_steps(flow),
        "warnings": build_plan_warnings(&payload.server, flow),
        "protocolPack": build_protocol_pack(&payload)
    })
}

#[tauri::command]
pub fn mobile_start_deployment(
    app: AppHandle,
    store: State<MobileDeploymentStore>,
    payload: ProvisionPayload,
) -> Value {
    let deployment_id = format!("dep_{}", deployment_timestamp_nanos());
    let flow = normalized_provision_flow(&payload.flow);
    let edge_enabled = payload.edge.as_ref().is_some_and(|edge| edge.enabled);
    let edge_host = payload
        .edge
        .as_ref()
        .map(|edge| edge.server.host.trim().to_string())
        .filter(|host| !host.is_empty());
    let edge_port = payload
        .edge
        .as_ref()
        .filter(|edge| edge.enabled)
        .map(|edge| normalized_edge_public_port(Some(edge)));
    let edge_routing_mode = payload
        .edge
        .as_ref()
        .filter(|edge| edge.enabled)
        .map(|edge| normalized_edge_routing_mode(Some(edge)).to_string());
    let mut steps = build_plan_steps(flow);
    eprintln!(
        "[mobile-provision] start deployment_id={} flow={} host={} user={} edge_enabled={} edge_host={} edge_port={}",
        deployment_id,
        flow,
        payload.server.host.trim(),
        payload.server.username.trim(),
        edge_enabled,
        edge_host.as_deref().unwrap_or_default(),
        edge_port.unwrap_or_default()
    );
    if let Some(first) = steps.first_mut() {
        first.status = "current".to_string();
    }

    let initial = DeploymentStateEntry {
        deployment_id: deployment_id.clone(),
        server_host: payload.server.host.trim().to_string(),
        deploy_flow: Some(flow.to_string()),
        transport: "xray".to_string(),
        engine: Some("sing-box".to_string()),
        protocol: Some("vless-reality".to_string()),
        status: "running".to_string(),
        steps,
        turn_port: None,
        wire_guard_port: None,
        reality_port: None,
        edge_enabled: edge_enabled.then_some(true),
        edge_host,
        edge_port,
        edge_routing_mode,
        health_checks: Vec::new(),
        protocol_pack: build_protocol_pack(&payload),
        error: None,
    };
    store.insert(initial.clone());

    let app_handle = app.clone();
    let deployment_id_for_task = deployment_id.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) =
            mobile_run_deployment(app_handle.clone(), &deployment_id_for_task, payload).await
        {
            let deployment_store = app_handle.state::<MobileDeploymentStore>();
            fail_deployment(&deployment_store, &deployment_id_for_task, &error);
            return;
        }

        let deployment_store = app_handle.state::<MobileDeploymentStore>();
        deployment_store.update(&deployment_id_for_task, |deployment| {
            deployment.status = "done".to_string();
        });
    });

    json!(initial)
}

#[tauri::command]
pub fn mobile_get_deployment(
    store: State<MobileDeploymentStore>,
    deployment_id: String,
) -> Result<Value, String> {
    let deployment = store
        .get(deployment_id.trim())
        .ok_or_else(|| format!("deployment {:?} not found", deployment_id.trim()))?;
    Ok(json!(deployment))
}

#[tauri::command]
pub async fn mobile_start_local_tunnel(
    app: AppHandle,
    payload: LocalTunnelStartPayload,
) -> Result<Value, String> {
    eprintln!(
        "[mobile-tunnel] start host={} transport={} protocol={} payload_runtime_family={} payload_activation_state={} owner_runtime_lab_mode={}",
        payload.server.host.trim(),
        requested_transport(&payload.server),
        requested_protocol(&payload.server),
        payload.runtime_family.trim(),
        payload.activation_state.trim(),
        payload
            .owner_runtime_lab
            .as_ref()
            .map(|value| value.mode.trim())
            .unwrap_or("")
    );
    let runtime_request = match resolve_android_runtime_request(&app, &payload) {
        Ok(request) => request,
        Err(error) => {
            return Ok(android_tunnel_state(
                &payload.server,
                "failed",
                Some(&error),
                vec![error.clone()],
                None,
            ));
        }
    };
    eprintln!(
        "[mobile-tunnel] resolved host={} request_runtime_family={} request_activation_state={} profile_source={} front_tag={} cdn_front_tag={}",
        payload.server.host.trim(),
        runtime_request
            .get("runtimeFamily")
            .and_then(Value::as_str)
            .unwrap_or(""),
        runtime_request
            .get("activationState")
            .and_then(Value::as_str)
            .unwrap_or(""),
        runtime_request
            .get("profileSource")
            .and_then(Value::as_str)
            .unwrap_or(""),
        runtime_request
            .get("frontTag")
            .and_then(Value::as_str)
            .unwrap_or(""),
        runtime_request
            .get("cdnFrontTag")
            .and_then(Value::as_str)
            .unwrap_or("")
    );

    match android_vpn::start_tunnel(&app, runtime_request).await {
        Ok(state) => Ok(state),
        Err(error) => Ok(android_tunnel_state(
            &payload.server,
            "failed",
            Some(&error),
            vec![error.clone()],
            None,
        )),
    }
}

#[tauri::command]
pub async fn mobile_stop_local_tunnel(app: AppHandle) -> Result<Value, String> {
    android_vpn::stop_tunnel(&app).await
}

#[tauri::command]
pub async fn mobile_get_local_tunnel_status(app: AppHandle) -> Result<Value, String> {
    android_vpn::get_status(&app).await
}

#[tauri::command]
pub async fn mobile_run_local_tunnel_test(
    app: AppHandle,
    payload: LocalTunnelTestPayload,
) -> Result<Value, String> {
    android_vpn::run_connectivity_test(
        &app,
        json!({
            "url": if payload.url.trim().is_empty() {
                DEFAULT_PROBE_HTTPS_URL
            } else {
                payload.url.trim()
            }
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_inspect_network_lens(
    app: AppHandle,
    payload: MobileNetworkLensPayload,
) -> Result<Value, String> {
    android_vpn::inspect_network_lens(
        &app,
        json!({
            "originHost": payload.origin_host.trim(),
            "tunnelHost": optional_string(&payload.tunnel_host),
            "cellularOnly": payload.cellular_only,
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_list_installed_apps(app: AppHandle) -> Result<Value, String> {
    android_vpn::list_installed_apps(&app).await
}

#[tauri::command]
pub async fn mobile_get_split_tunnel_selection(app: AppHandle) -> Result<Value, String> {
    android_vpn::get_split_tunnel_selection(&app).await
}

#[tauri::command]
pub async fn mobile_set_split_tunnel_selection(
    app: AppHandle,
    payload: SplitTunnelSelectionPayload,
) -> Result<Value, String> {
    android_vpn::set_split_tunnel_selection(
        &app,
        json!({
            "excludePackages": normalize_package_list(&payload.exclude_packages),
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_get_next_vpn_session_log_state(app: AppHandle) -> Result<Value, String> {
    android_vpn::get_next_vpn_session_log_state(&app).await
}

#[tauri::command]
pub async fn mobile_set_next_vpn_session_log_state(
    app: AppHandle,
    enabled: bool,
) -> Result<Value, String> {
    android_vpn::set_next_vpn_session_log_state(
        &app,
        json!({
            "enabled": enabled,
        }),
    )
    .await
}

#[tauri::command]
pub fn mobile_get_owner_profile(app: AppHandle, host: String) -> Result<Value, String> {
    if host.trim().is_empty() {
        return Ok(json!({
            "exists": false,
            "error": "host is required"
        }));
    }

    let target_path = owner_profile_path(&app, &host)?;
    if !target_path.exists() {
        return Ok(json!({
            "exists": false,
            "localPath": target_path.to_string_lossy()
        }));
    }

    let data =
        fs::read_to_string(&target_path).map_err(|err| format!("read owner profile: {err}"))?;
    let mut profile: OwnerProfileFile =
        serde_json::from_str(&data).map_err(|err| format!("parse owner profile: {err}"))?;
    profile.vk_turn_stream_count = effective_vk_turn_stream_count(profile.vk_turn_stream_count);
    ensure_reality_relay_direct_fallback(&mut profile.staged_fallbacks);
    ensure_reality_relay_owner_egress_fallback(&mut profile.staged_fallbacks);
    profile.protocol_pack = build_protocol_pack_for_transport_with_fallbacks(
        &profile.transport,
        nonzero_u16(profile.endpoint_port),
        profile
            .staged_fallbacks
            .get("vlessReality")
            .and_then(|value| value.get("port"))
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok()),
        nonzero_u16(profile.vk_turn_proxy_port),
        Some(&profile.staged_fallbacks),
    );
    let normalized_raw_json = serde_json::to_string_pretty(&profile)
        .map_err(|err| format!("marshal owner profile response: {err}"))?;

    Ok(json!({
        "exists": true,
        "name": profile.name,
        "transport": profile.transport,
        "activeProtocol": profile.active_protocol,
        "serverHost": profile.server_host,
        "vkTurnStreamCount": profile.vk_turn_stream_count,
        "vkTurnProxyPort": profile.vk_turn_proxy_port,
        "endpointPort": profile.endpoint_port,
        "localPath": target_path.to_string_lossy(),
        "rawJson": normalized_raw_json,
        "protocolPack": profile.protocol_pack,
        "stagedFallbacks": profile.staged_fallbacks,
        "wireguard": profile.wireguard
    }))
}

#[tauri::command]
pub fn mobile_get_imported_profile(app: AppHandle, host: String) -> Result<Value, String> {
    if host.trim().is_empty() {
        return Ok(json!({
            "error": "host is required"
        }));
    }

    let (invite, local_path) = find_imported_invite(&app, &host)?;
    build_invite_response(&invite, Some(&local_path), None)
}

#[tauri::command]
pub fn mobile_import_profile(app: AppHandle, share_code: String) -> Result<Value, String> {
    let invite = decode_invite(&share_code)?;
    let local_path = imported_profile_path(
        &app,
        &invite.server_host,
        &invite.name,
        &effective_invite_fingerprint(&invite),
    )?;
    let raw_json = serde_json::to_string_pretty(&invite)
        .map_err(|err| format!("normalize invite profile: {err}"))?;

    if let Some(parent) = local_path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("prepare imports directory: {err}"))?;
    }
    fs::write(&local_path, raw_json.as_bytes())
        .map_err(|err| format!("save imported profile: {err}"))?;

    build_invite_response(&invite, Some(&local_path), Some(raw_json))
}

#[tauri::command]
pub fn mobile_export_invite_file(app: AppHandle, contents: String) -> Result<Value, String> {
    let invite = decode_invite(&contents)?;
    let raw_json = serde_json::to_string_pretty(&invite)
        .map_err(|err| format!("normalize invite file payload: {err}"))?;
    let file_name = invite_export_file_name(&invite);
    let export_dir = invite_export_dir(&app)?;
    let export_path = export_dir.join(&file_name);
    fs::write(&export_path, raw_json.as_bytes())
        .map_err(|err| format!("write invite export file: {err}"))?;

    Ok(json!({
        "fileName": file_name,
        "exportPath": export_path.to_string_lossy().to_string(),
        "rawJson": raw_json,
        "shareCode": format!("{SHARE_CODE_PREFIX}{}", URL_SAFE_NO_PAD.encode(raw_json.as_bytes())),
    }))
}

#[tauri::command]
pub async fn mobile_share_invite_file(
    app: AppHandle,
    file_name: String,
    contents: String,
) -> Result<Value, String> {
    if contents.trim().is_empty() {
        return Err("invite file contents are required".to_string());
    }

    android_vpn::share_invite_file(
        &app,
        json!({
            "fileName": if file_name.trim().is_empty() {
                "odin-one-access.odinone-access.json"
            } else {
                file_name.trim()
            },
            "contents": contents,
            "mimeType": "application/json"
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_export_debug_log(
    app: AppHandle,
    file_name: String,
    contents: String,
) -> Result<Value, String> {
    if contents.trim().is_empty() {
        return Err("debug log contents are required".to_string());
    }

    android_vpn::export_debug_log(
        &app,
        json!({
            "fileName": if file_name.trim().is_empty() {
                "whitelist-probe.log.txt"
            } else {
                file_name.trim()
            },
            "contents": contents,
            "mimeType": "text/plain"
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_open_external_url(app: AppHandle, url: String) -> Result<Value, String> {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return Err("external url is required".to_string());
    }

    android_vpn::open_external_url(
        &app,
        json!({
            "url": trimmed,
        }),
    )
    .await
}

#[tauri::command]
pub async fn mobile_generate_guest_profile(payload: GuestProfilePayload) -> Result<Value, String> {
    let mut ssh = MobileSshSession::connect(&payload.server, &payload.secret).await?;
    let (owner, xray_state) = load_remote_access_state(&mut ssh).await?;
    let mut guest_profiles = read_remote_guest_profiles(&mut ssh).await?;

    if owner.transport.trim() != "xray" {
        return Err(
            "VLESS + REALITY guest access keys require the direct xray transport".to_string(),
        );
    }
    if xray_state.reality.port == 0
        || xray_state.reality.private_key.trim().is_empty()
        || owner.vless_reality.public_key.trim().is_empty()
    {
        return Err(
            "remote VLESS + REALITY inbound is not available for guest access keys".to_string(),
        );
    }
    if xray_state.wire_guard_port == 0
        || owner.vk_turn_proxy_port == 0
        || owner.wire_guard.server_public_key.trim().is_empty()
    {
        return Err("remote VK relay path is not available for guest access keys".to_string());
    }

    let guest_id = next_guest_id(&guest_profiles);
    let guest_keys = generate_wireguard_key_pair()?;
    let guest_address = next_guest_address(&owner, &guest_profiles)?;
    let guest_uuid = generate_protocol_uuid()?;
    let requested_stream_count = requested_vk_turn_stream_count(&payload.server);
    let mut guest = InviteProfileFile {
        id: guest_id.clone(),
        role: "guest".to_string(),
        name: default_invite_name(&payload.name),
        protocol: "vless-reality".to_string(),
        transport: owner.transport.clone(),
        vk_turn_stream_count: requested_stream_count
            .unwrap_or_else(|| effective_vk_turn_stream_count(owner.vk_turn_stream_count)),
        server_host: owner.server_host.clone(),
        vk_turn_proxy_port: owner.vk_turn_proxy_port,
        wire_guard_port: xray_state.wire_guard_port,
        endpoint_port: xray_state.reality.port,
        endpoint: format!("{}:{}", owner.server_host, xray_state.reality.port),
        created_at: now_rfc3339(),
        status: "active".to_string(),
        ..Default::default()
    };
    guest.wire_guard.client_private_key = guest_keys.client_private_key;
    guest.wire_guard.client_public_key = guest_keys.client_public_key;
    guest.wire_guard.address = guest_address;
    guest.vless_reality.uuid = guest_uuid;
    guest.vless_reality.flow = DEFAULT_REALITY_FLOW.to_string();
    enrich_invite_profile(&mut guest, &owner, &xray_state);

    let raw_json = serde_json::to_string_pretty(&guest)
        .map_err(|err| format!("marshal guest profile: {err}"))?;
    ssh.upload(
        &remote_guest_profile_path(&guest.id),
        raw_json.as_bytes(),
        "0600",
    )
    .await?;

    guest_profiles.push(guest.clone());
    sync_remote_xray_config(&mut ssh, &owner, &xray_state, &guest_profiles).await?;
    let _ = ssh.close().await;

    build_invite_response(&guest, None, Some(raw_json))
}

pub fn register_mobile_commands(builder: tauri::Builder<tauri::Wry>) -> tauri::Builder<tauri::Wry> {
    builder
        .manage(MobileDeploymentStore::default())
        .invoke_handler(tauri::generate_handler![
            mobile_core_health,
            mobile_check_whitelist_ip,
            mobile_validate_provision,
            mobile_build_provision_plan,
            mobile_start_deployment,
            mobile_get_deployment,
            mobile_start_local_tunnel,
            mobile_stop_local_tunnel,
            mobile_get_local_tunnel_status,
            mobile_run_local_tunnel_test,
            mobile_inspect_network_lens,
            mobile_list_installed_apps,
            mobile_get_split_tunnel_selection,
            mobile_set_split_tunnel_selection,
            mobile_get_next_vpn_session_log_state,
            mobile_set_next_vpn_session_log_state,
            mobile_get_owner_profile,
            mobile_get_imported_profile,
            mobile_import_profile,
            mobile_export_invite_file,
            mobile_share_invite_file,
            mobile_export_debug_log,
            mobile_open_external_url,
            mobile_generate_guest_profile
        ])
}

fn merge_json_object(target: &mut Value, extra: &Value) {
    let Some(target_object) = target.as_object_mut() else {
        return;
    };
    let Some(extra_object) = extra.as_object() else {
        return;
    };
    for (key, value) in extra_object {
        target_object.insert(key.clone(), value.clone());
    }
}

fn merge_json_object_deep(target: &mut Value, extra: &Value) {
    let Some(target_object) = target.as_object_mut() else {
        return;
    };
    let Some(extra_object) = extra.as_object() else {
        return;
    };
    for (key, value) in extra_object {
        if let Some(target_value) = target_object.get_mut(key) {
            if target_value.is_object() && value.is_object() {
                merge_json_object_deep(target_value, value);
                continue;
            }
        }
        target_object.insert(key.clone(), value.clone());
    }
}

async fn load_whitelist_lookup_source(
    app: &AppHandle,
) -> Result<(ParsedWhitelistFiles, bool, Option<String>), String> {
    let _ = app;
    Ok((
        bundled_whitelist_source()?,
        true,
        Some("Using the bundled static whitelist dataset.".to_string()),
    ))
}

fn bundled_whitelist_source() -> Result<ParsedWhitelistFiles, String> {
    parse_whitelist_files(
        BUNDLED_WHITELIST_IP_LIST,
        BUNDLED_WHITELIST_CIDR_LIST,
        "embedded-static-whitelist",
    )
}

fn parse_whitelist_files(
    ip_text: &str,
    cidr_text: &str,
    fetched_at: &str,
) -> Result<ParsedWhitelistFiles, String> {
    let exact_ips = ip_text
        .lines()
        .filter_map(normalized_whitelist_entry)
        .filter_map(|entry| entry.parse::<Ipv4Addr>().ok())
        .collect::<HashSet<_>>();
    let cidrs = cidr_text
        .lines()
        .filter_map(normalized_whitelist_entry)
        .filter_map(parse_ipv4_cidr)
        .collect::<Vec<_>>();

    if cidrs.is_empty() {
        return Err("cidrwhitelist.txt did not yield any IPv4 CIDR entries".to_string());
    }

    Ok(ParsedWhitelistFiles {
        exact_ips,
        cidrs,
        fetched_at: fetched_at.to_string(),
    })
}

fn normalized_whitelist_entry(line: &str) -> Option<&str> {
    let raw = line.split('#').next().unwrap_or_default().trim();
    (!raw.is_empty()).then_some(raw)
}

fn parse_ipv4_cidr(entry: &str) -> Option<ParsedIpv4Cidr> {
    let (ip_text, prefix_text) = entry.split_once('/')?;
    let ip = ip_text.trim().parse::<Ipv4Addr>().ok()?;
    let prefix = prefix_text.trim().parse::<u8>().ok()?;
    if prefix > 32 {
        return None;
    }
    let mask = ipv4_mask(prefix);
    Some(ParsedIpv4Cidr {
        raw: entry.trim().to_string(),
        network: ipv4_to_u32(ip) & mask,
        prefix,
    })
}

fn ipv4_in_cidr(ip: Ipv4Addr, cidr: &ParsedIpv4Cidr) -> bool {
    ipv4_to_u32(ip) & ipv4_mask(cidr.prefix) == cidr.network
}

fn ipv4_to_u32(ip: Ipv4Addr) -> u32 {
    u32::from_be_bytes(ip.octets())
}

fn ipv4_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - u32::from(prefix))
    }
}

fn build_invite_response(
    invite: &InviteProfileFile,
    local_path: Option<&Path>,
    raw_json_override: Option<String>,
) -> Result<Value, String> {
    let normalized_stream_count = effective_vk_turn_stream_count(invite.vk_turn_stream_count);
    let mut normalized_invite = invite.clone();
    normalized_invite.vk_turn_stream_count = normalized_stream_count;
    let normalized_staged_fallbacks = invite_effective_staged_fallbacks(invite);
    let normalized_android_runtime = invite_effective_android_runtime(invite);
    normalized_invite.staged_fallbacks = normalized_staged_fallbacks.clone();
    normalized_invite.android_runtime = normalized_android_runtime.clone();
    let raw_json = match raw_json_override {
        Some(raw_json) => apply_invite_runtime_overrides(
            &raw_json,
            normalized_stream_count,
            &normalized_staged_fallbacks,
            &normalized_android_runtime,
        )?,
        None => serde_json::to_string_pretty(&normalized_invite)
            .map_err(|err| format!("marshal invite response: {err}"))?,
    };
    let mut response = json!({
        "id": optional_string(&invite.id),
        "role": invite.role,
        "name": invite.name,
        "protocol": normalized_invite_protocol(invite),
        "transport": invite.transport,
        "serverHost": invite.server_host,
        "vkTurnStreamCount": normalized_stream_count,
        "vkTurnProxyPort": invite.vk_turn_proxy_port,
        "wireGuardPort": nonzero_u16(invite.wire_guard_port),
        "endpointPort": nonzero_u16(invite.endpoint_port),
        "endpoint": invite.endpoint,
        "fingerprint": effective_invite_fingerprint(invite),
        "vlessReality": invite.vless_reality,
        "protocolPack": invite_protocol_pack(invite),
        "androidRuntime": normalized_android_runtime,
        "stagedFallbacks": normalized_staged_fallbacks,
        "supportsReality": invite_supports_reality(invite),
        "supportsVKRelay": invite_supports_vk_relay(invite),
        "supportsRealityRelay": invite_supports_reality_relay(invite),
        "shareCode": format!("{SHARE_CODE_PREFIX}{}", URL_SAFE_NO_PAD.encode(raw_json.as_bytes())),
        "rawJson": raw_json,
        "createdAt": optional_string(&invite.created_at),
        "revokedAt": optional_string(&invite.revoked_at),
        "status": optional_string(&invite.status)
    });
    if let Some(path) = local_path {
        response["localPath"] = json!(path.to_string_lossy().to_string());
    }
    Ok(response)
}

fn apply_invite_runtime_overrides(
    raw_json: &str,
    normalized_stream_count: u16,
    staged_fallbacks: &Value,
    android_runtime: &Value,
) -> Result<String, String> {
    let patched = apply_vk_turn_stream_count_override(raw_json, Some(normalized_stream_count))?;
    let mut payload: Value = serde_json::from_str(&patched)
        .map_err(|err| format!("parse invite response json: {err}"))?;
    let Some(object) = payload.as_object_mut() else {
        return Err("invite response json must be an object".to_string());
    };
    object.insert("stagedFallbacks".to_string(), staged_fallbacks.clone());
    object.insert("androidRuntime".to_string(), android_runtime.clone());
    serde_json::to_string_pretty(&payload)
        .map_err(|err| format!("marshal invite response json: {err}"))
}

fn invite_effective_staged_fallbacks(invite: &InviteProfileFile) -> Value {
    let mut staged = invite.staged_fallbacks.clone();
    ensure_reality_relay_direct_fallback(&mut staged);
    ensure_reality_relay_owner_egress_fallback(&mut staged);
    let mut normalized = invite.clone();
    normalized.staged_fallbacks = staged;
    sync_invite_reality_staged_fallbacks(&mut normalized);
    normalized.staged_fallbacks
}

fn invite_effective_android_runtime(invite: &InviteProfileFile) -> Value {
    let mut runtime = invite.android_runtime.clone();
    if !runtime.is_object() {
        runtime = json!({});
    }
    let Some(runtime_object) = runtime.as_object_mut() else {
        return invite.android_runtime.clone();
    };
    if let Some(cdn_runtime) = build_invite_cdn_anti_whitelist_runtime(invite) {
        if let Some(existing_cdn) = runtime_object
            .get("cdnAntiWhitelist")
            .and_then(Value::as_object)
            .filter(|cdn| !cdn.is_empty())
        {
            let mut merged = cdn_runtime;
            merge_json_object_deep(&mut merged, &Value::Object(existing_cdn.clone()));
            runtime_object.insert("cdnAntiWhitelist".to_string(), merged);
            return runtime;
        }
        runtime_object.insert("cdnAntiWhitelist".to_string(), cdn_runtime);
    }
    runtime
}

fn sync_invite_android_runtime(invite: &mut InviteProfileFile) {
    invite.android_runtime = invite_effective_android_runtime(invite);
}

fn owner_effective_android_runtime(profile: &OwnerProfileFile) -> Value {
    let invite = InviteProfileFile {
        server_host: profile.server_host.clone(),
        android_runtime: profile.android_runtime.clone(),
        staged_fallbacks: profile.staged_fallbacks.clone(),
        ..Default::default()
    };
    invite_effective_android_runtime(&invite)
}

fn sync_owner_android_runtime(profile: &mut OwnerProfileFile) {
    profile.android_runtime = owner_effective_android_runtime(profile);
}

fn sync_owner_android_runtime_in_value(profile: &mut Value) -> Result<(), String> {
    let mut owner: OwnerProfileFile = serde_json::from_value(profile.clone())
        .map_err(|err| format!("parse owner profile json: {err}"))?;
    sync_owner_android_runtime(&mut owner);
    let profile_object = ensure_object_value(profile, "owner profile")?;
    profile_object.insert("androidRuntime".to_string(), owner.android_runtime);
    Ok(())
}

fn yandex_edge_cover_domain_pool() -> Vec<&'static str> {
    YANDEX_EDGE_CDN_CAMOUFLAGE_HOST_POOL.to_vec()
}

fn build_invite_cdn_anti_whitelist_runtime(invite: &InviteProfileFile) -> Option<Value> {
    let connect_host = invite_yandex_connect_host(invite)?;
    let front_host = sslip_host_for_invite(&connect_host);
    let origin_host = sslip_host_for_invite(&invite.server_host);
    let front_tag = format!("yandex-edge-xhttp-{YANDEX_EDGE_CONNECT_PORT}");
    let tls_server_name = YANDEX_EDGE_CDN_CAMOUFLAGE_HOST;
    let http_host_header = YANDEX_EDGE_CDN_CAMOUFLAGE_HOST;
    let camouflage_host_pool = yandex_edge_cover_domain_pool();
    let front_pool: Vec<Value> = camouflage_host_pool
        .iter()
        .enumerate()
        .map(|(index, host)| {
            let tag = if index == 0 {
                front_tag.clone()
            } else {
                format!("{front_tag}-{}", host.replace('.', "-"))
            };
            json!({
                "host": front_host,
                "port": YANDEX_EDGE_CONNECT_PORT,
                "connectHost": connect_host,
                "connectPort": YANDEX_EDGE_CONNECT_PORT,
                "path": YANDEX_EDGE_FRONT_PATH,
                "tlsServerName": host,
                "hostHeader": host,
                "tlsAllowInsecure": true,
                "camouflageHostPool": yandex_edge_cover_domain_pool(),
                "provider": YANDEX_EDGE_CDN_PROVIDER,
                "tag": tag
            })
        })
        .collect();
    Some(json!({
        "enabled": true,
        "mode": YANDEX_EDGE_CDN_MODE,
        "engine": YANDEX_EDGE_CDN_ENGINE,
        "provider": YANDEX_EDGE_CDN_PROVIDER,
        "transport": YANDEX_EDGE_CDN_TRANSPORT,
        "frontHost": front_host,
        "frontPort": YANDEX_EDGE_CONNECT_PORT,
        "connectHost": connect_host,
        "connectPort": YANDEX_EDGE_CONNECT_PORT,
        "frontPath": YANDEX_EDGE_FRONT_PATH,
        "tlsServerName": tls_server_name,
        "hostHeader": http_host_header,
        "tlsAllowInsecure": true,
        "camouflageHost": YANDEX_EDGE_CDN_CAMOUFLAGE_HOST,
        "camouflageHostPool": camouflage_host_pool,
        "xhttpMode": YANDEX_EDGE_CDN_XHTTP_MODE,
        "tlsAlpn": ["h2", "http/1.1"],
        "xmuxMaxConcurrency": YANDEX_EDGE_CDN_XMUX_MAX_CONCURRENCY,
        "xmuxHMaxRequestTimes": YANDEX_EDGE_CDN_XMUX_HMAX_REQUEST_TIMES,
        "xmuxHMaxReusableSecs": YANDEX_EDGE_CDN_XMUX_HMAX_REUSABLE_SECS,
        "frontTag": front_tag,
        "frontSelection": YANDEX_EDGE_CDN_FRONT_SELECTION,
        "bootstrap": YANDEX_EDGE_CDN_BOOTSTRAP,
        "routingPolicy": {
            "dnsQueryStrategy": "use_ip",
            "domainStrategy": "ip_if_non_match",
            "domainMatcher": "hybrid",
            "directDomainKeywords": YANDEX_EDGE_CDN_DIRECT_DOMAIN_KEYWORDS,
            "directDomains": YANDEX_EDGE_CDN_DIRECT_DOMAINS,
            "blockedDomainKeywords": [],
            "blockedDomains": [],
            "blockSelectedFrontHost": true
        },
        "origin": {
            "host": origin_host,
            "port": 443,
            "scheme": "https",
            "path": YANDEX_EDGE_ORIGIN_PATH
        },
        "frontPool": front_pool
    }))
}

fn invite_yandex_connect_host(invite: &InviteProfileFile) -> Option<String> {
    for key in ["realityYandexEdgeProxy", "realityYandexEdge"] {
        let host = invite
            .staged_fallbacks
            .get(key)
            .and_then(Value::as_object)
            .and_then(|fallback| fallback.get("connectHost"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if let Some(host) = host {
            return Some(host.to_string());
        }
    }
    None
}

fn sslip_host_for_invite(host: &str) -> String {
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed.parse::<std::net::IpAddr>().is_ok() {
        format!("{}.sslip.io", trimmed.replace('.', "-"))
    } else {
        trimmed.to_string()
    }
}

fn sync_invite_reality_staged_fallbacks(invite: &mut InviteProfileFile) {
    let port = invite.vless_reality.port;
    let server_name = invite.vless_reality.server_name.trim();
    let public_key = invite.vless_reality.public_key.trim();
    let short_id = invite.vless_reality.short_id.trim();
    let uuid = invite.vless_reality.uuid.trim();
    let flow = if invite.vless_reality.flow.trim().is_empty() {
        DEFAULT_REALITY_FLOW
    } else {
        invite.vless_reality.flow.trim()
    };
    if port == 0
        || server_name.is_empty()
        || public_key.is_empty()
        || short_id.is_empty()
        || uuid.is_empty()
    {
        return;
    }

    let Some(staged) = invite.staged_fallbacks.as_object_mut() else {
        return;
    };

    let vless = staged
        .entry("vlessReality".to_string())
        .or_insert_with(|| json!({}));
    if let Some(vless) = vless.as_object_mut() {
        vless.insert("port".to_string(), json!(port));
        vless.insert("serverName".to_string(), json!(server_name));
        vless.insert("publicKey".to_string(), json!(public_key));
        vless.insert("shortId".to_string(), json!(short_id));
        vless.insert("uuid".to_string(), json!(uuid));
        vless.insert("flow".to_string(), json!(flow));
    }

    if let Some(owner_egress) = staged
        .get_mut("realityRelayOwnerEgress")
        .and_then(Value::as_object_mut)
    {
        owner_egress.insert("ownerEgressPort".to_string(), json!(port));
    }

    if let Some(edge) = staged
        .get_mut("realityYandexEdge")
        .and_then(Value::as_object_mut)
    {
        edge.insert("originPort".to_string(), json!(port));
        if !yandex_edge_keeps_existing_client_identity(edge) {
            edge.insert("serverName".to_string(), json!(server_name));
            edge.insert("publicKey".to_string(), json!(public_key));
            edge.insert("shortId".to_string(), json!(short_id));
            edge.insert("uuid".to_string(), json!(uuid));
            edge.insert("flow".to_string(), json!(flow));
        }
        if !invite.server_host.trim().is_empty() {
            edge.insert("originHost".to_string(), json!(invite.server_host.trim()));
        }
    }

    if let Some(edge_proxy) = staged
        .get_mut("realityYandexEdgeProxy")
        .and_then(Value::as_object_mut)
    {
        edge_proxy.insert("originPort".to_string(), json!(port));
        if !yandex_edge_keeps_existing_client_identity(edge_proxy) {
            edge_proxy.insert("serverName".to_string(), json!(server_name));
            edge_proxy.insert("publicKey".to_string(), json!(public_key));
            edge_proxy.insert("shortId".to_string(), json!(short_id));
            edge_proxy.insert("uuid".to_string(), json!(uuid));
            edge_proxy.insert("flow".to_string(), json!(flow));
        }
        edge_proxy.insert("ownerRealityEgress".to_string(), Value::Bool(false));
        if yandex_edge_keeps_existing_client_identity(edge_proxy) {
            edge_proxy.insert("transport".to_string(), json!(YANDEX_EDGE_CDN_TRANSPORT));
        } else {
            edge_proxy.insert("transport".to_string(), json!("tcp"));
        }
        if !invite.server_host.trim().is_empty() {
            edge_proxy.insert("originHost".to_string(), json!(invite.server_host.trim()));
        }
    }
}

fn yandex_edge_keeps_existing_client_identity(fallback: &serde_json::Map<String, Value>) -> bool {
    fallback
        .get("routingMode")
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|value| value == EDGE_ROUTING_MODE_XRAY_PROXY)
        && fallback
            .get("uuid")
            .and_then(Value::as_str)
            .map(str::trim)
            .is_some_and(|value| !value.is_empty())
}

fn invite_effective_reality_port(invite: &InviteProfileFile) -> Option<u16> {
    read_invite_reality_fallback(invite)
        .map(|reality| reality.port)
        .ok()
        .or_else(|| nonzero_u16(invite.vless_reality.port))
}

fn invite_protocol_pack(invite: &InviteProfileFile) -> Vec<ProtocolPackEntry> {
    build_protocol_pack_for_transport_with_fallbacks(
        &invite.transport,
        nonzero_u16(invite.wire_guard_port),
        invite_effective_reality_port(invite),
        nonzero_u16(invite.vk_turn_proxy_port),
        Some(&invite_effective_staged_fallbacks(invite)),
    )
}

fn decode_invite(share_code: &str) -> Result<InviteProfileFile, String> {
    let mut raw_text = share_code.trim().to_string();
    if raw_text.is_empty() {
        return Err("share code is required".to_string());
    }

    if let Some(encoded) = raw_text.strip_prefix(SHARE_CODE_PREFIX) {
        let decoded = URL_SAFE_NO_PAD
            .decode(encoded)
            .map_err(|err| format!("decode share code: {err}"))?;
        raw_text = String::from_utf8(decoded)
            .map_err(|err| format!("decode share code as UTF-8: {err}"))?;
    }

    let mut invite: InviteProfileFile =
        serde_json::from_str(&raw_text).map_err(|err| format!("parse invite profile: {err}"))?;

    invite.protocol = normalized_invite_protocol(&invite).to_string();
    if invite.protocol == "vless-reality" && invite.vless_reality.flow.trim().is_empty() {
        invite.vless_reality.flow = DEFAULT_REALITY_FLOW.to_string();
    }
    if invite.fingerprint.trim().is_empty() {
        invite.fingerprint = fallback_fingerprint(&invite);
    }
    invite.vk_turn_stream_count = effective_vk_turn_stream_count(invite.vk_turn_stream_count);
    ensure_reality_relay_direct_fallback(&mut invite.staged_fallbacks);
    ensure_reality_relay_owner_egress_fallback(&mut invite.staged_fallbacks);
    sync_invite_reality_staged_fallbacks(&mut invite);
    sync_invite_android_runtime(&mut invite);

    validate_invite(&invite)?;
    Ok(invite)
}

fn validate_invite(invite: &InviteProfileFile) -> Result<(), String> {
    if invite.name.trim().is_empty() {
        return Err("invite profile name is required".to_string());
    }
    if invite.server_host.trim().is_empty() {
        return Err("invite profile serverHost is required".to_string());
    }
    if effective_invite_endpoint_port(invite) == 0 {
        return Err("invite profile endpointPort is required".to_string());
    }
    if invite.transport.trim().is_empty() {
        return Err("invite profile transport is required".to_string());
    }

    match normalized_invite_protocol(invite) {
        "wireguard" => {
            if invite.wire_guard.server_public_key.trim().is_empty()
                || invite.wire_guard.client_private_key.trim().is_empty()
            {
                return Err("invite profile wireguard keys are required".to_string());
            }
        }
        "vless-reality" => {
            if !invite_supports_reality(invite) {
                return Err("invite profile VLESS + REALITY settings are required".to_string());
            }
        }
        protocol => {
            return Err(format!(
                "invite profile protocol {protocol:?} is not supported"
            ));
        }
    }

    Ok(())
}

fn invite_supports_reality(invite: &InviteProfileFile) -> bool {
    invite_has_reality(invite)
        || invite
            .staged_fallbacks
            .get("vlessReality")
            .and_then(Value::as_object)
            .is_some_and(|fallback| {
                fallback
                    .get("port")
                    .and_then(Value::as_u64)
                    .unwrap_or_default()
                    > 0
                    && string_field(fallback.get("serverName")) != ""
                    && string_field(fallback.get("publicKey")) != ""
                    && string_field(fallback.get("shortId")) != ""
                    && string_field(fallback.get("uuid")) != ""
            })
}

fn invite_supports_vk_relay(invite: &InviteProfileFile) -> bool {
    invite.vk_turn_proxy_port > 0
        && !invite.wire_guard.server_public_key.trim().is_empty()
        && !invite.wire_guard.client_private_key.trim().is_empty()
        && !invite.wire_guard.address.trim().is_empty()
}

fn invite_supports_reality_relay(invite: &InviteProfileFile) -> bool {
    invite
        .staged_fallbacks
        .get("realityRelayOwnerEgress")
        .and_then(Value::as_object)
        .is_some_and(|fallback| {
            !string_field(fallback.get("subscriptionUrl")).is_empty()
                && !string_field(fallback.get("sourceLabel")).is_empty()
        })
}

fn invite_has_wireguard(invite: &InviteProfileFile) -> bool {
    !invite.wire_guard.server_public_key.trim().is_empty()
        && !invite.wire_guard.client_private_key.trim().is_empty()
        && !invite.wire_guard.client_public_key.trim().is_empty()
}

fn invite_has_reality(invite: &InviteProfileFile) -> bool {
    invite.vless_reality.port > 0
        && !invite.vless_reality.server_name.trim().is_empty()
        && !invite.vless_reality.public_key.trim().is_empty()
        && !invite.vless_reality.short_id.trim().is_empty()
        && !invite.vless_reality.uuid.trim().is_empty()
}

fn normalized_invite_protocol(invite: &InviteProfileFile) -> &str {
    match invite.protocol.trim() {
        "vless-reality" | "wireguard" => invite.protocol.trim(),
        "direct-wireguard" => "wireguard",
        _ if invite_has_reality(invite) => "vless-reality",
        _ => "wireguard",
    }
}

fn find_imported_invite(
    app: &AppHandle,
    host: &str,
) -> Result<(InviteProfileFile, PathBuf), String> {
    find_imported_invite_for_runtime(app, host, None)
}

fn find_imported_invite_for_runtime(
    app: &AppHandle,
    host: &str,
    requested_runtime: Option<(&str, &str)>,
) -> Result<(InviteProfileFile, PathBuf), String> {
    let imports_dir = imports_dir(app)?;
    let mut newest_match: Option<(InviteProfileFile, PathBuf, std::time::SystemTime)> = None;
    let mut newest_runtime_match: Option<(InviteProfileFile, PathBuf, std::time::SystemTime)> =
        None;

    for entry in
        fs::read_dir(&imports_dir).map_err(|err| format!("read imports directory: {err}"))?
    {
        let entry = entry.map_err(|err| format!("read imports entry: {err}"))?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }

        let body = match fs::read_to_string(&path) {
            Ok(body) => body,
            Err(_) => continue,
        };
        let invite: InviteProfileFile = match serde_json::from_str(&body) {
            Ok(invite) => invite,
            Err(_) => continue,
        };
        if validate_invite(&invite).is_err() {
            continue;
        }
        if invite.server_host != host.trim() {
            continue;
        }

        let modified_at = fs::metadata(&path)
            .and_then(|metadata| metadata.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);

        match &newest_match {
            Some((_, _, current_modified_at)) if *current_modified_at >= modified_at => {}
            _ => newest_match = Some((invite.clone(), path.clone(), modified_at)),
        }

        if requested_runtime.is_some_and(|(transport, protocol)| {
            invite_supports_requested_runtime(&invite, transport, protocol)
        }) {
            match &newest_runtime_match {
                Some((_, _, current_modified_at)) if *current_modified_at >= modified_at => {}
                _ => newest_runtime_match = Some((invite, path, modified_at)),
            }
        }
    }

    newest_runtime_match
        .or(newest_match)
        .map(|(invite, path, _)| (invite, path))
        .ok_or_else(|| format!("no imported profile found for host {host:?}"))
}

fn owner_profile_path(app: &AppHandle, host: &str) -> Result<PathBuf, String> {
    Ok(profiles_dir(app)?.join(format!("{}-owner-profile.json", sanitize_host(host))))
}

fn imported_profile_path(
    app: &AppHandle,
    host: &str,
    name: &str,
    fingerprint: &str,
) -> Result<PathBuf, String> {
    Ok(imports_dir(app)?.join(format!(
        "{}-{}-{}.json",
        sanitize_host(host),
        sanitize_host(name),
        sanitize_host(fingerprint)
    )))
}

fn invite_export_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = match app.path().download_dir() {
        Ok(downloads) => downloads.join("Odin's Cat"),
        Err(_) => app_root_dir(app)?.join("exports"),
    };
    fs::create_dir_all(&dir).map_err(|err| format!("create invite export directory: {err}"))?;
    Ok(dir)
}

fn invite_export_file_name(invite: &InviteProfileFile) -> String {
    format!(
        "{}-{}{}",
        sanitize_host(&invite.server_host),
        sanitize_host(&invite.name),
        INVITE_EXPORT_EXTENSION
    )
}

fn profiles_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app_root_dir(app)?.join("profiles");
    fs::create_dir_all(&dir).map_err(|err| format!("create profiles directory: {err}"))?;
    Ok(dir)
}

fn imports_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app_root_dir(app)?.join("imports");
    fs::create_dir_all(&dir).map_err(|err| format!("create imports directory: {err}"))?;
    Ok(dir)
}

fn app_root_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_local_data_dir()
        .map_err(|err| format!("resolve app local data dir: {err}"))?
        .join("odin-one");
    fs::create_dir_all(&dir).map_err(|err| format!("create app data dir: {err}"))?;
    Ok(dir)
}

fn sanitize_host(value: &str) -> String {
    let sanitized = value
        .trim()
        .chars()
        .map(|character| match character {
            '/' | ':' | ' ' => '_',
            _ => character,
        })
        .collect::<String>();

    if sanitized.is_empty() {
        "unknown".to_string()
    } else {
        sanitized
    }
}

fn fallback_fingerprint(invite: &InviteProfileFile) -> String {
    let mut hasher = DefaultHasher::new();
    invite.server_host.hash(&mut hasher);
    invite.endpoint_port.hash(&mut hasher);
    if !invite.vless_reality.uuid.trim().is_empty() {
        invite.vless_reality.uuid.hash(&mut hasher);
    } else {
        invite.wire_guard.client_public_key.hash(&mut hasher);
    }
    format!("{:016x}", hasher.finish())
}

fn effective_invite_fingerprint(invite: &InviteProfileFile) -> String {
    if invite.fingerprint.trim().is_empty() {
        fallback_fingerprint(invite)
    } else {
        invite.fingerprint.clone()
    }
}

fn effective_invite_endpoint_port(invite: &InviteProfileFile) -> u16 {
    if invite.endpoint_port > 0 {
        return invite.endpoint_port;
    }
    if normalized_invite_protocol(invite) == "vless-reality" && invite.vless_reality.port > 0 {
        return invite.vless_reality.port;
    }
    invite.vk_turn_proxy_port
}

fn effective_vk_turn_stream_count(value: u16) -> u16 {
    if (VK_TURN_STREAM_COUNT_MIN..=VK_TURN_STREAM_COUNT_MAX).contains(&value) {
        value
    } else {
        VK_TURN_STREAM_COUNT_DEFAULT
    }
}

fn requested_vk_turn_stream_count(server: &ServerDraftPayload) -> Option<u16> {
    server
        .vk_turn_stream_count
        .filter(|value| (VK_TURN_STREAM_COUNT_MIN..=VK_TURN_STREAM_COUNT_MAX).contains(value))
}

fn optional_string(value: &str) -> Option<&str> {
    if value.trim().is_empty() {
        None
    } else {
        Some(value)
    }
}

fn nonzero_u16(value: u16) -> Option<u16> {
    if value == 0 {
        None
    } else {
        Some(value)
    }
}

fn default_true() -> bool {
    true
}

fn string_field(value: Option<&Value>) -> &str {
    value.and_then(Value::as_str).unwrap_or("").trim()
}

async fn run_remote_egress_checks(ssh: &mut MobileSshSession) -> (Vec<CheckEntry>, bool) {
    let specs = vec![
        (
            "curl-presence".to_string(),
            "Curl availability".to_string(),
            "command -v curl".to_string(),
        ),
        (
            "dns-resolution".to_string(),
            "DNS resolution".to_string(),
            "getent ahostsv4 example.com | head -n 1 || getent hosts example.com | head -n 1"
                .to_string(),
        ),
        (
            "remote-http-egress".to_string(),
            "Remote HTTP egress".to_string(),
            format!(
                "curl -4 -fsSI --connect-timeout 5 --max-time 12 {} | head -n 1",
                quote_shell(DEFAULT_PROBE_HTTP_URL)
            ),
        ),
        (
            "remote-https-egress".to_string(),
            "Remote HTTPS egress".to_string(),
            format!(
                "curl -4 -fsSI --connect-timeout 5 --max-time 12 {} | head -n 1",
                quote_shell(DEFAULT_PROBE_HTTPS_URL)
            ),
        ),
    ];
    let mut checks = Vec::with_capacity(specs.len());
    let mut all_ok = true;

    for (key, label, command) in specs {
        let result = ssh.run(&command).await;
        let ok = result.is_ok();
        let mut detail = match result {
            Ok(output) => output,
            Err(error) => error,
        };
        if detail.trim().is_empty() {
            detail = "No output".to_string();
        }
        checks.push(CheckEntry {
            key,
            label,
            ok,
            detail,
        });
        all_ok &= ok;
    }

    (checks, all_ok)
}

fn default_invite_name(name: &str) -> String {
    if name.trim().is_empty() {
        "Odin's Cat Guest".to_string()
    } else {
        name.trim().to_string()
    }
}

fn remote_guest_profile_path(guest_id: &str) -> String {
    format!(
        "{WHITELIST_GUEST_PROFILES_DIR}/{}.json",
        sanitize_host(guest_id)
    )
}

fn now_rfc3339() -> String {
    chrono_like_now_rfc3339()
}

fn chrono_like_now_rfc3339() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = now.as_secs() as i64;
    let nanos = now.subsec_nanos();
    format_rfc3339_utc(seconds, nanos)
}

fn format_rfc3339_utc(seconds: i64, nanos: u32) -> String {
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    if nanos == 0 {
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
    } else {
        format!(
            "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z",
            millis = nanos / 1_000_000
        )
    }
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m, d)
}

fn generate_wireguard_key_pair() -> Result<InviteWireGuard, String> {
    let mut private_key = [0_u8; 32];
    getrandom(&mut private_key).map_err(|err| format!("generate private key: {err}"))?;
    let private = StaticSecret::from(private_key);
    let public = x25519_dalek::PublicKey::from(&private);

    Ok(InviteWireGuard {
        client_private_key: STANDARD.encode(private.to_bytes()),
        client_public_key: STANDARD.encode(public.as_bytes()),
        ..Default::default()
    })
}

fn generate_protocol_uuid() -> Result<String, String> {
    let mut raw = [0_u8; 16];
    getrandom(&mut raw).map_err(|err| format!("generate uuid bytes: {err}"))?;
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    let hex = hex_lower(&raw);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
}

fn invite_fingerprint(host: &str, port: u16, identity: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(host.as_bytes());
    hasher.update(b"|");
    hasher.update(port.to_string().as_bytes());
    hasher.update(b"|");
    hasher.update(identity.as_bytes());
    let digest = hasher.finalize();
    hex_lower(&digest[..8])
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut text, "{byte:02x}");
    }
    text
}

fn quote_shell(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn dir_of(path: &str) -> &str {
    path.rsplit_once('/').map(|(dir, _)| dir).unwrap_or(".")
}

fn reality_server_name() -> String {
    std::env::var("ODIN_ONE_REALITY_SERVER_NAME")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_REALITY_SERVER_NAME.to_string())
}

fn reality_destination() -> String {
    if let Ok(value) = std::env::var("ODIN_ONE_REALITY_DEST") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    if let Ok(value) = std::env::var("ODIN_ONE_REALITY_DEST_HOST") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return format!("{trimmed}:443");
        }
    }
    DEFAULT_REALITY_DEST.to_string()
}

fn normalized_yandex_edge_server_name_override(value: &str) -> Option<String> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return None;
    }
    YANDEX_EDGE_ACCEPTED_SERVER_NAMES
        .iter()
        .copied()
        .find(|candidate| *candidate == normalized)
        .map(str::to_string)
}

fn yandex_edge_accepted_server_names(primary: &str) -> Vec<String> {
    let mut names = Vec::new();
    let push_unique = |names: &mut Vec<String>, value: &str| {
        let normalized = value.trim().to_ascii_lowercase();
        if normalized.is_empty() || names.iter().any(|existing| existing == &normalized) {
            return;
        }
        names.push(normalized);
    };
    push_unique(&mut names, primary);
    for candidate in YANDEX_EDGE_ACCEPTED_SERVER_NAMES {
        push_unique(&mut names, candidate);
    }
    names
}

fn read_invite_reality_fallback(invite: &InviteProfileFile) -> Result<RealityFallback, String> {
    if invite_has_reality(invite) {
        return Ok(RealityFallback {
            port: invite.vless_reality.port,
            server_name: invite.vless_reality.server_name.clone(),
            public_key: invite.vless_reality.public_key.clone(),
            short_id: invite.vless_reality.short_id.clone(),
            uuid: invite.vless_reality.uuid.clone(),
            flow: if invite.vless_reality.flow.trim().is_empty() {
                DEFAULT_REALITY_FLOW.to_string()
            } else {
                invite.vless_reality.flow.clone()
            },
        });
    }

    let Some(raw) = invite.staged_fallbacks.get("vlessReality") else {
        return Err("invite profile has no VLESS + REALITY settings".to_string());
    };
    let parsed = raw
        .as_object()
        .ok_or_else(|| "parse invite reality config: expected object".to_string())?;
    let port = parsed
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .unwrap_or_default();
    let server_name = string_field(parsed.get("serverName")).to_string();
    let public_key = string_field(parsed.get("publicKey")).to_string();
    let short_id = string_field(parsed.get("shortId")).to_string();
    let uuid = string_field(parsed.get("uuid")).to_string();
    let flow = {
        let value = string_field(parsed.get("flow"));
        if value.is_empty() {
            DEFAULT_REALITY_FLOW.to_string()
        } else {
            value.to_string()
        }
    };
    if port == 0
        || server_name.is_empty()
        || public_key.is_empty()
        || short_id.is_empty()
        || uuid.is_empty()
    {
        return Err("invite profile has incomplete VLESS + REALITY settings".to_string());
    }

    Ok(RealityFallback {
        port,
        server_name,
        public_key,
        short_id,
        uuid,
        flow,
    })
}

async fn read_remote_guest_profiles(
    ssh: &mut MobileSshSession,
) -> Result<Vec<InviteProfileFile>, String> {
    let output = match ssh
        .run(&format!(
            "find {} -maxdepth 1 -type f -name '*.json' | sort",
            quote_shell(WHITELIST_GUEST_PROFILES_DIR)
        ))
        .await
    {
        Ok(output) => output,
        Err(error) if error.contains("No such file") => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    if output.trim().is_empty() {
        return Ok(Vec::new());
    }

    let mut guests = Vec::new();
    for path in output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let body = ssh.run(&format!("cat {}", quote_shell(path))).await?;
        let guest: InviteProfileFile = serde_json::from_str(&body)
            .map_err(|err| format!("parse guest profile {path}: {err}"))?;
        guests.push(guest);
    }
    Ok(guests)
}

async fn load_remote_access_state(
    ssh: &mut MobileSshSession,
) -> Result<(InviteProfileFile, RemoteXrayState), String> {
    let owner_text = ssh
        .run(&format!("cat {}", quote_shell(WHITELIST_INVITE_PATH)))
        .await?;
    let mut owner: InviteProfileFile = serde_json::from_str(&owner_text)
        .map_err(|err| format!("parse remote owner profile: {err}"))?;
    if let Ok(reality) = read_invite_reality_fallback(&owner) {
        owner.vless_reality.port = reality.port;
        owner.vless_reality.server_name = reality.server_name;
        owner.vless_reality.public_key = reality.public_key;
        owner.vless_reality.short_id = reality.short_id;
        owner.vless_reality.uuid = reality.uuid;
        owner.vless_reality.flow = reality.flow;
        owner.protocol = "vless-reality".to_string();
    } else {
        owner.protocol = normalized_invite_protocol(&owner).to_string();
    }
    ensure_reality_relay_direct_fallback(&mut owner.staged_fallbacks);
    ensure_reality_relay_owner_egress_fallback(&mut owner.staged_fallbacks);

    let xray_text = ssh
        .run(&format!("cat {}", quote_shell(WHITELIST_XRAY_CONFIG_PATH)))
        .await?;
    let parsed: Value = serde_json::from_str(&xray_text)
        .map_err(|err| format!("parse remote xray config: {err}"))?;
    let inbounds = parsed
        .get("inbounds")
        .and_then(Value::as_array)
        .ok_or_else(|| "remote xray config has no inbounds".to_string())?;
    let mut xray_state = RemoteXrayState::default();

    for inbound in inbounds {
        let protocol = string_field(inbound.get("protocol"));
        let port = inbound
            .get("port")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .unwrap_or_default();
        match protocol {
            "wireguard" => {
                xray_state.wire_guard_port = port;
                xray_state.secret_key = string_field(
                    inbound
                        .get("settings")
                        .and_then(Value::as_object)
                        .and_then(|settings| settings.get("secretKey")),
                )
                .to_string();
            }
            "vless" => {
                xray_state.reality.port = port;
                let reality_settings = inbound
                    .get("streamSettings")
                    .and_then(Value::as_object)
                    .and_then(|stream| stream.get("realitySettings"))
                    .and_then(Value::as_object);
                xray_state.reality.private_key =
                    string_field(reality_settings.and_then(|settings| settings.get("privateKey")))
                        .to_string();
                xray_state.reality.dest =
                    string_field(reality_settings.and_then(|settings| settings.get("dest")))
                        .to_string();
                xray_state.reality.server_name = reality_settings
                    .and_then(|settings| settings.get("serverNames"))
                    .and_then(Value::as_array)
                    .and_then(|names| names.first())
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                xray_state.reality.short_id = reality_settings
                    .and_then(|settings| settings.get("shortIds"))
                    .and_then(Value::as_array)
                    .and_then(|ids| ids.first())
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
            }
            _ => {}
        }
    }

    if xray_state.wire_guard_port == 0 {
        return Err("remote xray config has no wireguard inbound".to_string());
    }
    if owner.wire_guard_port == 0 {
        owner.wire_guard_port = xray_state.wire_guard_port;
    }
    if owner.endpoint_port == 0 {
        owner.endpoint_port = if owner.transport == "xray" {
            xray_state.wire_guard_port
        } else {
            owner.vk_turn_proxy_port
        };
    }
    Ok((owner, xray_state))
}

async fn sync_remote_xray_config(
    ssh: &mut MobileSshSession,
    owner: &InviteProfileFile,
    xray_state: &RemoteXrayState,
    guests: &[InviteProfileFile],
) -> Result<(), String> {
    let mut peers = vec![json!({
        "publicKey": owner.wire_guard.client_public_key,
        "allowedIPs": [owner.wire_guard.address]
    })];
    let mut reality_clients = Vec::new();
    if let Ok(reality) = read_invite_reality_fallback(owner) {
        reality_clients.push(json!({
            "id": reality.uuid,
            "flow": reality.flow
        }));
    }

    for guest in guests {
        if guest.status == "revoked" || !guest.revoked_at.trim().is_empty() {
            continue;
        }
        if invite_has_wireguard(guest) {
            peers.push(json!({
                "publicKey": guest.wire_guard.client_public_key,
                "allowedIPs": [guest.wire_guard.address]
            }));
        }
        if let Ok(reality) = read_invite_reality_fallback(guest) {
            reality_clients.push(json!({
                "id": reality.uuid,
                "flow": reality.flow
            }));
        }
    }

    let listen_host = if owner.transport == "xray" {
        "0.0.0.0"
    } else {
        "127.0.0.1"
    };
    let mut inbounds = vec![json!({
        "tag": "wg-in",
        "protocol": "wireguard",
        "listen": listen_host,
        "port": xray_state.wire_guard_port,
        "settings": {
            "secretKey": xray_state.secret_key,
            "mtu": 1280,
            "peers": peers
        }
    })];
    if xray_state.reality.port > 0
        && !xray_state.reality.private_key.trim().is_empty()
        && !reality_clients.is_empty()
    {
        inbounds.push(json!({
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": xray_state.reality.port,
            "protocol": "vless",
            "settings": {
                "clients": reality_clients,
                "decryption": "none"
            },
            "sniffing": {
                "destOverride": ["http", "tls", "quic"],
                "enabled": true
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": if xray_state.reality.dest.trim().is_empty() {
                        reality_destination()
                    } else {
                        xray_state.reality.dest.clone()
                    },
                    "privateKey": xray_state.reality.private_key,
                    "serverNames": [if xray_state.reality.server_name.trim().is_empty() {
                        reality_server_name()
                    } else {
                        xray_state.reality.server_name.clone()
                    }],
                    "shortIds": [xray_state.reality.short_id],
                    "show": false,
                    "xver": 0
                }
            }
        }));
    }
    let config = serde_json::to_string_pretty(&json!({
        "log": { "loglevel": "warning" },
        "inbounds": inbounds,
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }]
    }))
    .map_err(|err| format!("marshal xray config: {err}"))?;

    ssh.upload(WHITELIST_XRAY_CONFIG_PATH, config.as_bytes(), "0644")
        .await?;
    ssh.run(&format!(
        "systemctl restart whitelist-xray.service && systemctl is-active whitelist-xray.service && test -f {}",
        quote_shell(WHITELIST_XRAY_SERVICE_PATH)
    ))
    .await?;
    Ok(())
}

fn next_guest_address(
    owner: &InviteProfileFile,
    guests: &[InviteProfileFile],
) -> Result<String, String> {
    let mut used = std::collections::BTreeSet::new();
    if let Ok(octet) = address_last_octet(&owner.wire_guard.address) {
        used.insert(octet);
    }
    for guest in guests {
        if let Ok(octet) = address_last_octet(&guest.wire_guard.address) {
            used.insert(octet);
        }
    }
    for octet in 3..=254 {
        if !used.contains(&octet) {
            return Ok(format!("10.66.66.{octet}/32"));
        }
    }
    Err("no free guest addresses left in 10.66.66.0/24".to_string())
}

fn address_last_octet(address: &str) -> Result<u16, String> {
    let base = address.trim().trim_end_matches("/32");
    let Some(last) = base.rsplit('.').next() else {
        return Err(format!("invalid address {address:?}"));
    };
    last.parse::<u16>()
        .map_err(|err| format!("parse address octet: {err}"))
}

fn next_guest_id(guests: &[InviteProfileFile]) -> String {
    let max_id = guests
        .iter()
        .filter_map(|guest| guest.id.strip_prefix("guest-"))
        .filter_map(|value| value.parse::<u16>().ok())
        .max()
        .unwrap_or_default();
    format!("guest-{:03}", max_id + 1)
}

fn effective_reality_port(owner: &InviteProfileFile, xray_state: &RemoteXrayState) -> u16 {
    if xray_state.reality.port > 0 {
        return xray_state.reality.port;
    }
    if owner.vless_reality.port > 0 {
        return owner.vless_reality.port;
    }
    read_invite_reality_fallback(owner)
        .map(|reality| reality.port)
        .unwrap_or_default()
}

fn invite_identity_value(invite: &InviteProfileFile) -> &str {
    if !invite.vless_reality.uuid.trim().is_empty() {
        &invite.vless_reality.uuid
    } else {
        &invite.wire_guard.client_public_key
    }
}

fn enrich_invite_profile(
    invite: &mut InviteProfileFile,
    owner: &InviteProfileFile,
    xray_state: &RemoteXrayState,
) {
    invite.protocol = normalized_invite_protocol(invite).to_string();
    if invite.status.trim().is_empty() {
        invite.status = "active".to_string();
    }
    if invite.transport.trim().is_empty() {
        invite.transport = owner.transport.clone();
    }
    invite.vk_turn_stream_count = if invite.vk_turn_stream_count > 0 {
        effective_vk_turn_stream_count(invite.vk_turn_stream_count)
    } else {
        effective_vk_turn_stream_count(owner.vk_turn_stream_count)
    };
    if invite.server_host.trim().is_empty() {
        invite.server_host = owner.server_host.clone();
    }
    if invite.staged_fallbacks.is_null()
        || invite
            .staged_fallbacks
            .as_object()
            .is_some_and(|value| value.is_empty())
    {
        invite.staged_fallbacks = owner.staged_fallbacks.clone();
    }
    ensure_reality_relay_direct_fallback(&mut invite.staged_fallbacks);
    ensure_reality_relay_owner_egress_fallback(&mut invite.staged_fallbacks);
    if invite.vk_turn_proxy_port == 0 {
        invite.vk_turn_proxy_port = owner.vk_turn_proxy_port;
    }
    if invite.wire_guard_port == 0 {
        invite.wire_guard_port = if owner.wire_guard_port > 0 {
            owner.wire_guard_port
        } else {
            xray_state.wire_guard_port
        };
    }
    if invite.protocol == "vless-reality" {
        if let Ok(reality) = read_invite_reality_fallback(owner) {
            if invite.vless_reality.port == 0 {
                invite.vless_reality.port = effective_reality_port(owner, xray_state);
            }
            if invite.vless_reality.server_name.trim().is_empty() {
                invite.vless_reality.server_name =
                    if xray_state.reality.server_name.trim().is_empty() {
                        reality.server_name
                    } else {
                        xray_state.reality.server_name.clone()
                    };
            }
            if invite.vless_reality.public_key.trim().is_empty() {
                invite.vless_reality.public_key = reality.public_key;
            }
            if invite.vless_reality.short_id.trim().is_empty() {
                invite.vless_reality.short_id = if xray_state.reality.short_id.trim().is_empty() {
                    reality.short_id
                } else {
                    xray_state.reality.short_id.clone()
                };
            }
            if invite.vless_reality.uuid.trim().is_empty() {
                invite.vless_reality.uuid = reality.uuid;
            }
            if invite.vless_reality.flow.trim().is_empty() {
                invite.vless_reality.flow = reality.flow;
            }
        }
    }
    sync_invite_reality_staged_fallbacks(invite);
    sync_invite_android_runtime(invite);
    if invite.endpoint_port == 0 {
        invite.endpoint_port = if invite.protocol == "vless-reality" {
            effective_reality_port(owner, xray_state)
        } else {
            effective_invite_endpoint_port(owner)
        };
    }
    if invite.endpoint.trim().is_empty() {
        invite.endpoint = format!(
            "{}:{}",
            invite.server_host,
            effective_invite_endpoint_port(invite)
        );
    }
    if invite.fingerprint.trim().is_empty() {
        invite.fingerprint = invite_fingerprint(
            &invite.server_host,
            effective_invite_endpoint_port(invite),
            invite_identity_value(invite),
        );
    }
    if invite.wire_guard.server_public_key.trim().is_empty() {
        invite.wire_guard.server_public_key = owner.wire_guard.server_public_key.clone();
    }
    if invite.wire_guard.mtu == 0 {
        invite.wire_guard.mtu = owner.wire_guard.mtu;
    }
}

async fn mobile_run_deployment(
    app: AppHandle,
    deployment_id: &str,
    payload: ProvisionPayload,
) -> Result<(), String> {
    let flow = normalized_provision_flow(&payload.flow);
    eprintln!(
        "[mobile-provision] run deployment_id={} flow={} host={} user={}",
        deployment_id,
        flow,
        payload.server.host.trim(),
        payload.server.username.trim()
    );
    if flow == PROVISION_FLOW_EDGE_ATTACH {
        return mobile_run_edge_attach(app, deployment_id, payload).await;
    }

    let mut ssh = MobileSshSession::connect(&payload.server, &payload.secret).await?;

    ssh.run("whoami && uname -a").await?;
    complete_step(&app, deployment_id, 0);

    ssh.run(&format!(
        "mkdir -p {} {} {} {}",
        quote_shell(WHITELIST_BIN_DIR),
        quote_shell(WHITELIST_CONFIG_DIR),
        quote_shell(WHITELIST_PROFILES_DIR),
        quote_shell(WHITELIST_GUEST_PROFILES_DIR)
    ))
    .await?;
    complete_step(&app, deployment_id, 1);

    validate_deployment_port_hints(&payload.server)?;

    let turn_port = resolve_remote_relay_port(&mut ssh, payload.server.vk_turn_proxy_port).await?;
    let wire_guard_port = resolve_remote_udp_port(
        &mut ssh,
        None,
        WHITELIST_WIREGUARD_PORT_START,
        WHITELIST_WIREGUARD_PORT_END,
        &[turn_port],
        "xray wireguard",
    )
    .await?;
    let reality_port =
        resolve_deployment_reality_port(&mut ssh, payload.server.reality_port).await?;
    set_deployment_ports(
        &app,
        deployment_id,
        turn_port,
        wire_guard_port,
        reality_port,
    );

    ensure_remote_vk_turn_proxy_binary(&mut ssh).await?;
    install_remote_xray_binary(&mut ssh).await?;
    install_remote_sing_box_binary(&mut ssh).await?;
    complete_step(&app, deployment_id, 2);

    let server_keys = generate_wireguard_key_pair()?;
    let client_keys = generate_wireguard_key_pair()?;
    let reality_keys = generate_reality_key_pair()?;
    let reality_uuid = generate_protocol_uuid()?;
    let reality_short_id = generate_reality_short_id()?;

    let xray_config = render_xray_config_with_listen(
        &server_keys.client_private_key,
        &[json!({
            "publicKey": client_keys.client_public_key,
            "allowedIPs": ["10.66.66.2/32"]
        })],
        "0.0.0.0",
        wire_guard_port,
        Some(&json!({
            "port": reality_port,
            "clients": [{
                "id": reality_uuid,
                "flow": DEFAULT_REALITY_FLOW
            }],
            "privateKey": reality_keys.private_key,
            "shortId": reality_short_id,
            "serverName": reality_server_name(),
            "dest": reality_destination()
        })),
    )?;
    let reality_config = render_reality_server_config(
        reality_port,
        &reality_uuid,
        &reality_keys.private_key,
        &reality_short_id,
    )?;
    let staged_fallbacks = build_staged_fallbacks(
        reality_port,
        &reality_keys.public_key,
        &reality_short_id,
        &reality_uuid,
        true,
    );
    set_deployment_protocol_pack(
        &app,
        deployment_id,
        build_protocol_pack_for_transport_with_fallbacks(
            "xray",
            Some(wire_guard_port),
            Some(reality_port),
            Some(turn_port),
            Some(&staged_fallbacks),
        ),
    );
    let fallback_manifest = render_staged_fallback_manifest(&payload.server.host, reality_port)?;
    let owner_profile = render_owner_profile(
        &payload.server.host,
        wire_guard_port,
        turn_port,
        &server_keys.client_public_key,
        &client_keys.client_private_key,
        &client_keys.client_public_key,
        staged_fallbacks.clone(),
    )?;
    let protocol_pack_manifest = render_protocol_pack_manifest(
        &payload.server.host,
        "xray",
        wire_guard_port,
        reality_port,
        turn_port,
        Some(&staged_fallbacks),
    )?;
    let xray_unit = render_systemd_unit(
        "Odin's Cat Xray",
        &format!(
            "{} run -config {}",
            WHITELIST_XRAY_BINARY_PATH, WHITELIST_XRAY_CONFIG_PATH
        ),
    );
    let proxy_unit = render_systemd_unit(
        "Odin's Cat vk-turn-proxy",
        &format!(
            "{} -listen 0.0.0.0:{} -connect 127.0.0.1:{}",
            WHITELIST_PROXY_BINARY_PATH, turn_port, wire_guard_port
        ),
    );

    ssh.upload(WHITELIST_XRAY_CONFIG_PATH, xray_config.as_bytes(), "0644")
        .await?;
    ssh.upload(
        WHITELIST_REALITY_CONFIG_PATH,
        reality_config.as_bytes(),
        "0644",
    )
    .await?;
    ssh.upload(
        WHITELIST_FALLBACKS_PATH,
        fallback_manifest.as_bytes(),
        "0644",
    )
    .await?;
    ssh.upload(WHITELIST_INVITE_PATH, owner_profile.as_bytes(), "0600")
        .await?;
    save_local_owner_profile(&app, &payload.server.host, owner_profile.as_bytes())?;
    ssh.upload(
        WHITELIST_PROTOCOL_PACK_PATH,
        protocol_pack_manifest.as_bytes(),
        "0644",
    )
    .await?;
    ssh.upload(WHITELIST_XRAY_SERVICE_PATH, xray_unit.as_bytes(), "0644")
        .await?;
    ssh.upload(WHITELIST_PROXY_SERVICE_PATH, proxy_unit.as_bytes(), "0644")
        .await?;
    complete_step(&app, deployment_id, 3);

    ssh.run("systemctl daemon-reload && systemctl enable whitelist-xray.service whitelist-vk-turn-proxy.service && systemctl restart whitelist-xray.service whitelist-vk-turn-proxy.service && sleep 2")
        .await?;
    ssh.run(&format!(
        "systemctl is-active whitelist-xray.service && systemctl is-active whitelist-vk-turn-proxy.service && ss -H -lun | grep -Fq ':{}' && ss -H -lun | grep -Fq ':{}' && ss -H -ltn | grep -Fq ':{}'",
        wire_guard_port, turn_port, reality_port
    ))
    .await?;
    complete_step(&app, deployment_id, 4);

    let (health_checks, health_ok) = run_remote_egress_checks(&mut ssh).await;
    set_deployment_health_checks(&app, deployment_id, health_checks);
    if !health_ok {
        return Err("remote egress health checks failed".to_string());
    }
    complete_step(&app, deployment_id, 5);

    let _ = ssh.close().await;
    Ok(())
}

fn render_yandex_edge_tcp_forward_systemd_unit(
    origin_host: &str,
    origin_port: u16,
    public_port: u16,
) -> String {
    format!(
        "[Unit]\nDescription=Odin's Cat Yandex edge passthrough\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart=/usr/bin/socat TCP-LISTEN:{public_port},fork,reuseaddr TCP:{origin_host}:{origin_port}\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn render_yandex_edge_haproxy_config(
    bind_host: &str,
    public_port: u16,
    server_name: &str,
    origin_host: &str,
    origin_port: u16,
) -> String {
    format!(
        "global\n  log /dev/log local0\n\ndefaults\n  log global\n  mode tcp\n  timeout connect 10s\n  timeout client 60s\n  timeout server 60s\n\nfrontend reality_edge_in\n  bind {bind_host}:{public_port}\n  mode tcp\n  tcp-request inspect-delay 5s\n  tcp-request content accept if {{ req.ssl_hello_type 1 }}\n  acl sni_route req.ssl_sni -i {server_name}\n  use_backend be_route if sni_route\n  default_backend reality_drop\n\nbackend be_route\n  mode tcp\n  server route {origin_host}:{origin_port} check\n\nbackend reality_drop\n  mode tcp\n  server drop 127.0.0.1:9\n"
    )
}

fn render_yandex_edge_multi_sni_haproxy_config(
    bind_host: &str,
    public_port: u16,
    routes: &[YandexEdgeRealityRoute],
) -> String {
    let mut acl_lines = String::new();
    let mut use_backend_lines = String::new();
    let mut backend_sections = String::new();
    for (index, route) in routes.iter().enumerate() {
        let acl_name = format!("sni_route_{}", index + 1);
        let backend_name = format!("be_route_{}", index + 1);
        acl_lines.push_str(&format!(
            "  acl {acl_name} req.ssl_sni -i {}\n",
            route.server_name
        ));
        use_backend_lines.push_str(&format!("  use_backend {backend_name} if {acl_name}\n"));
        backend_sections.push_str(&format!(
            "\nbackend {backend_name}\n  mode tcp\n  server route 127.0.0.1:{} check\n",
            route.local_port
        ));
    }
    format!(
        "global\n  log /dev/log local0\n\ndefaults\n  log global\n  mode tcp\n  timeout connect 10s\n  timeout client 60s\n  timeout server 60s\n\nfrontend reality_edge_in\n  bind {bind_host}:{public_port}\n  mode tcp\n  tcp-request inspect-delay 5s\n  tcp-request content accept if {{ req.ssl_hello_type 1 }}\n{acl_lines}{use_backend_lines}  default_backend reality_drop\n{backend_sections}\nbackend reality_drop\n  mode tcp\n  server drop 127.0.0.1:9\n"
    )
}

fn render_yandex_edge_sni_router_systemd_unit(config_path: &str) -> String {
    format!(
        "[Unit]\nDescription=Odin's Cat Yandex edge SNI router\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart=/usr/sbin/haproxy -W -db -f {config_path}\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn render_yandex_edge_xray_proxy_config(
    edge_private_key: &str,
    edge_short_id: &str,
    edge_uuid: &str,
    edge_routes: &[YandexEdgeRealityRoute],
    origin_host: &str,
    origin_port: u16,
    origin_tls_server_name: &str,
    origin_uuid: &str,
) -> Result<String, String> {
    let inbounds: Vec<Value> = edge_routes
        .iter()
        .enumerate()
        .map(|(index, route)| {
            json!({
                "tag": format!("edge-reality-in-{}", index + 1),
                "listen": "127.0.0.1",
                "port": route.local_port,
                "protocol": "vless",
                "settings": {
                    "clients": [{
                        "id": edge_uuid,
                        "flow": YANDEX_EDGE_FLOW
                    }],
                    "decryption": "none"
                },
                "sniffing": {
                    "destOverride": ["http", "tls", "quic"],
                    "enabled": true
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": false,
                        "dest": format!("{}:443", route.server_name),
                        "xver": 0,
                        "serverNames": [route.server_name],
                        "privateKey": edge_private_key,
                        "shortIds": [edge_short_id]
                    }
                }
            })
        })
        .collect();
    let routing_inbounds: Vec<String> = edge_routes
        .iter()
        .enumerate()
        .map(|(index, _)| format!("edge-reality-in-{}", index + 1))
        .collect();
    serde_json::to_string_pretty(&json!({
        "log": { "loglevel": "warning" },
        "inbounds": inbounds,
        "outbounds": [{
            "tag": "origin-xhttp-out",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": origin_host,
                    "port": origin_port,
                    "users": [{
                        "id": origin_uuid,
                        "encryption": "none"
                    }]
                }]
            },
            "streamSettings": {
                "network": YANDEX_EDGE_CDN_TRANSPORT,
                "security": "tls",
                "tlsSettings": {
                    "serverName": origin_tls_server_name,
                    "allowInsecure": true,
                    "alpn": ["h2", "http/1.1"]
                },
                "xhttpSettings": {
                    "path": YANDEX_EDGE_ORIGIN_PATH,
                    "host": origin_tls_server_name,
                    "mode": YANDEX_EDGE_CDN_XHTTP_MODE
                }
            }
        }, {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }],
        "routing": {
            "rules": [{
                "type": "field",
                "inboundTag": routing_inbounds,
                "outboundTag": "origin-xhttp-out"
            }]
        }
    }))
    .map_err(|err| format!("marshal yandex edge xray proxy config: {err}"))
}

fn render_yandex_origin_xhttp_config(
    port: u16,
    cert_path: &str,
    key_path: &str,
    client_uuid: &str,
) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "log": { "loglevel": "warning" },
        "inbounds": [{
            "tag": "edge-origin-xhttp-in",
            "listen": "0.0.0.0",
            "port": port,
            "protocol": "vless",
            "settings": {
                "clients": [{
                    "id": client_uuid
                }],
                "decryption": "none"
            },
            "sniffing": {
                "destOverride": ["http", "tls", "quic"],
                "enabled": true
            },
            "streamSettings": {
                "network": YANDEX_EDGE_CDN_TRANSPORT,
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h2", "http/1.1"],
                    "certificates": [{
                        "certificateFile": cert_path,
                        "keyFile": key_path
                    }]
                },
                "xhttpSettings": {
                    "path": YANDEX_EDGE_ORIGIN_PATH
                }
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }]
    }))
    .map_err(|err| format!("marshal yandex origin xhttp config: {err}"))
}

fn render_yandex_edge_xray_proxy_systemd_unit(binary_path: &str, config_path: &str) -> String {
    format!(
        "[Unit]\nDescription=Odin's Cat Yandex edge xray proxy\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart={binary_path} run -config {config_path}\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn render_yandex_edge_router_systemd_unit(config_path: &str) -> String {
    format!(
        "[Unit]\nDescription=Odin's Cat Yandex edge router\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart=/usr/sbin/haproxy -W -db -f {config_path}\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn render_yandex_origin_xhttp_systemd_unit(binary_path: &str, config_path: &str) -> String {
    format!(
        "[Unit]\nDescription=Odin's Cat Yandex origin xhttp inbound\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart={binary_path} run -config {config_path}\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn build_yandex_edge_runtime_layout(
    public_port: u16,
    routing_mode: &str,
) -> YandexEdgeRuntimeLayout {
    let effective_port = if public_port == 0 {
        YANDEX_EDGE_CONNECT_PORT
    } else {
        public_port
    };
    let effective_mode = if routing_mode.trim().is_empty() {
        EDGE_ROUTING_MODE_DEFAULT
    } else {
        routing_mode.trim()
    };
    if effective_port == YANDEX_EDGE_CONNECT_PORT && effective_mode == EDGE_ROUTING_MODE_TCP_FORWARD
    {
        return YandexEdgeRuntimeLayout {
            root_dir: LEGACY_WHITELIST_EDGE_ROOT.to_string(),
            config_dir: format!("{LEGACY_WHITELIST_EDGE_ROOT}/config"),
            manifest_path: format!("{LEGACY_WHITELIST_EDGE_ROOT}/config/edge-forward.json"),
            haproxy_path: format!("{LEGACY_WHITELIST_EDGE_ROOT}/config/haproxy.cfg"),
            xray_path: format!("{LEGACY_WHITELIST_EDGE_ROOT}/bin/xray"),
            xray_config: format!("{LEGACY_WHITELIST_EDGE_ROOT}/config/xray-edge-proxy.json"),
            service_name: LEGACY_WHITELIST_YANDEX_EDGE_SERVICE_NAME.to_string(),
            service_path: format!(
                "/etc/systemd/system/{LEGACY_WHITELIST_YANDEX_EDGE_SERVICE_NAME}"
            ),
            backend_service_name: String::new(),
            backend_service_path: String::new(),
        };
    }
    let root_dir = format!("/opt/whitelist-edge-{effective_mode}-{effective_port}");
    let service_name = format!("whitelist-yandex-edge-{effective_mode}-{effective_port}.service");
    let backend_service_name =
        if effective_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
            format!("whitelist-yandex-edge-{effective_mode}-backend-{effective_port}.service")
        } else {
            String::new()
        };
    YandexEdgeRuntimeLayout {
        config_dir: format!("{root_dir}/config"),
        manifest_path: format!("{root_dir}/config/edge-forward.json"),
        haproxy_path: format!("{root_dir}/config/haproxy.cfg"),
        xray_path: format!("{root_dir}/bin/xray"),
        xray_config: format!("{root_dir}/config/xray-edge-proxy.json"),
        service_path: format!("/etc/systemd/system/{service_name}"),
        service_name,
        backend_service_path: if backend_service_name.is_empty() {
            String::new()
        } else {
            format!("/etc/systemd/system/{backend_service_name}")
        },
        backend_service_name,
        root_dir,
    }
}

fn build_yandex_edge_fallback_source(public_port: u16, routing_mode: &str) -> String {
    if public_port == YANDEX_EDGE_CONNECT_PORT && routing_mode == EDGE_ROUTING_MODE_TCP_FORWARD {
        "owner-attached:yandex-edge".to_string()
    } else {
        format!("owner-attached:yandex-edge:{routing_mode}:{public_port}")
    }
}

fn build_yandex_edge_fallback_tag(edge_host: &str, public_port: u16, routing_mode: &str) -> String {
    let mut tag = format!("yandex-edge-{}", edge_host.trim().replace('.', "-"));
    if public_port != YANDEX_EDGE_CONNECT_PORT {
        tag.push_str(&format!("-{public_port}"));
    }
    if routing_mode != EDGE_ROUTING_MODE_TCP_FORWARD {
        tag.push_str(&format!("-{routing_mode}"));
    }
    tag
}

fn render_yandex_edge_manifest(
    edge_host: &str,
    public_port: u16,
    origin_host: &str,
    origin_port: u16,
    edge_reality: &RealityFallback,
    accepted_server_names: &[String],
    origin_reality_port: u16,
    routing_mode: &str,
    layout: &YandexEdgeRuntimeLayout,
) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "provider": EDGE_PROVIDER_YANDEX,
        "routingMode": routing_mode,
        "bridgeMode": if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY { "edge-reality-in -> origin-xhttp-out" } else { "passthrough" },
        "chain": [
            "client",
            format!("yandex-edge:{}:{}", edge_host, public_port),
            if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
                format!("edge-reality:{}:{}", edge_host, public_port)
            } else {
                format!("origin:{}:{}", origin_host, origin_reality_port)
            },
            if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
                format!("origin-xhttp:{}:{}{}", origin_host, origin_port, YANDEX_EDGE_ORIGIN_PATH)
            } else {
                "internet".to_string()
            },
            "internet".to_string(),
        ],
        "edgeHost": edge_host,
        "publicPort": public_port,
        "serviceName": layout.service_name,
        "servicePath": layout.service_path,
        "installRoot": layout.root_dir,
        "configDir": layout.config_dir,
        "configPath": layout.manifest_path,
        "xrayPath": layout.xray_path,
        "xrayConfig": layout.xray_config,
        "originHost": origin_host,
        "originPort": origin_port,
        "serverName": edge_reality.server_name,
        "acceptedServerNames": accepted_server_names,
        "publicKey": edge_reality.public_key,
        "shortId": edge_reality.short_id,
        "uuid": edge_reality.uuid,
        "flow": edge_reality.flow,
        "routes": [{
            "serverName": edge_reality.server_name,
            "acceptedServerNames": accepted_server_names,
            "originHost": origin_host,
            "originPort": origin_port,
            "routingMode": routing_mode,
            "secondHopServerName": YANDEX_EDGE_ORIGIN_XHTTP_SERVER_NAME,
        }],
        "generatedAt": now_rfc3339(),
    }))
    .map_err(|err| format!("marshal yandex edge manifest: {err}"))
}

fn yandex_edge_entry_description(routing_mode: &str) -> String {
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        "Visible Yandex edge mode for Android. The client enters through a dedicated edge REALITY inbound on the Yandex VM and the edge relays traffic into a separate xHTTP hop to the stable origin.".to_string()
    } else {
        "Visible Yandex edge mode for Android. The client reaches the current REALITY origin through a dedicated Yandex edge surface.".to_string()
    }
}

fn yandex_edge_proxy_description(routing_mode: &str) -> String {
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        "Yandex edge bridge mode for Android. The client terminates on the dedicated edge REALITY inbound and the Yandex VM opens a separate xHTTP outbound to the stable origin.".to_string()
    } else {
        "Yandex edge proxy mode for Android. The client enters through the dedicated Yandex edge surface and reaches the stable REALITY origin through it.".to_string()
    }
}

fn yandex_edge_protocol_note(routing_mode: &str, proxy_mode: bool) -> String {
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        if proxy_mode {
            "Two-hop Yandex edge bridge path for restrictive networks. The client enters through a REALITY hop to the Yandex VM and the edge opens a fresh xHTTP hop to the stable origin.".to_string()
        } else {
            "Visible whitelist-facing Yandex edge entry. In bridge mode the Yandex host terminates the client REALITY hop and re-encapsulates traffic into a fresh xHTTP hop to the stable origin.".to_string()
        }
    } else if proxy_mode {
        "Two-hop Yandex edge proxy path for restrictive networks. The client enters through the Yandex edge and keeps egress on the stable REALITY origin.".to_string()
    } else {
        "Visible whitelist-facing edge entry that forwards the live REALITY origin through a dedicated Yandex host.".to_string()
    }
}

fn patch_owner_profile_with_yandex_edge(
    raw_json: &str,
    edge_host: &str,
    public_port: u16,
    origin_host: &str,
    origin_port: u16,
    reality: &RealityFallback,
    routing_mode: &str,
    edge_client_reality: Option<&RealityFallback>,
) -> Result<(String, Value, Vec<ProtocolPackEntry>), String> {
    let mut profile: OwnerProfileFile =
        serde_json::from_str(raw_json).map_err(|err| format!("parse owner profile: {err}"))?;
    ensure_reality_relay_direct_fallback(&mut profile.staged_fallbacks);
    ensure_reality_relay_owner_egress_fallback(&mut profile.staged_fallbacks);
    let client_reality = edge_client_reality.unwrap_or(reality);
    upsert_yandex_edge_fallback(
        &mut profile.staged_fallbacks,
        yandex_edge_fallback_value_for(
            edge_host,
            public_port,
            origin_host,
            if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
                origin_port
            } else {
                reality.port
            },
            &client_reality.server_name,
            &client_reality.public_key,
            &client_reality.short_id,
            &client_reality.uuid,
            &client_reality.flow,
            YANDEX_EDGE_FINGERPRINT,
            &build_yandex_edge_fallback_source(public_port, routing_mode),
            &build_yandex_edge_fallback_tag(edge_host, public_port, routing_mode),
            routing_mode,
        ),
    );
    if let Some(fallback) = profile
        .staged_fallbacks
        .get_mut("realityYandexEdgeProxy")
        .and_then(Value::as_object_mut)
    {
        fallback.insert(
            "routingMode".to_string(),
            Value::String(routing_mode.to_string()),
        );
        fallback.insert(
            "source".to_string(),
            Value::String(format!(
                "{}:proxy",
                build_yandex_edge_fallback_source(public_port, routing_mode)
            )),
        );
        fallback.insert(
            "tag".to_string(),
            Value::String(format!(
                "{}-proxy",
                build_yandex_edge_fallback_tag(edge_host, public_port, routing_mode)
            )),
        );
        fallback.insert("ownerRealityEgress".to_string(), Value::Bool(false));
        if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
            fallback.insert(
                "connectPort".to_string(),
                Value::Number(serde_json::Number::from(public_port)),
            );
            fallback.insert(
                "originPort".to_string(),
                Value::Number(serde_json::Number::from(origin_port)),
            );
            fallback.insert(
                "serverName".to_string(),
                Value::String(client_reality.server_name.clone()),
            );
            fallback.insert(
                "publicKey".to_string(),
                Value::String(client_reality.public_key.clone()),
            );
            fallback.insert(
                "shortId".to_string(),
                Value::String(client_reality.short_id.clone()),
            );
            fallback.insert(
                "uuid".to_string(),
                Value::String(client_reality.uuid.clone()),
            );
            fallback.insert(
                "flow".to_string(),
                Value::String(client_reality.flow.clone()),
            );
            fallback.insert(
                "transport".to_string(),
                Value::String(OWNER_RUNTIME_LAB_VPS_TRANSPORT_TCP.to_string()),
            );
            fallback.insert(
                "description".to_string(),
                Value::String(format!(
                    "Edge-terminated Yandex edge bridge mode. The client first connects to the dedicated edge REALITY inbound on {}:{}, then the Yandex VM forwards traffic to the xHTTP origin {}:{}.",
                    edge_host.trim(),
                    public_port,
                    origin_host.trim(),
                    origin_port,
                )),
            );
        }
    }
    sync_owner_android_runtime(&mut profile);
    profile.protocol_pack = build_protocol_pack_for_transport_with_fallbacks(
        &profile.transport,
        nonzero_u16(profile.endpoint_port),
        Some(reality.port),
        nonzero_u16(profile.vk_turn_proxy_port),
        Some(&profile.staged_fallbacks),
    );
    let staged_fallbacks = profile.staged_fallbacks.clone();
    let protocol_pack = profile.protocol_pack.clone();
    let normalized = serde_json::to_string_pretty(&profile)
        .map_err(|err| format!("marshal owner profile: {err}"))?;
    Ok((normalized, staged_fallbacks, protocol_pack))
}

async fn mobile_run_edge_attach(
    app: AppHandle,
    deployment_id: &str,
    payload: ProvisionPayload,
) -> Result<(), String> {
    validate_edge_attach_payload(&payload)?;
    let edge = payload
        .edge
        .as_ref()
        .ok_or_else(|| "edge configuration is required".to_string())?;
    let edge_server = edge_server_payload(edge);
    let public_port = normalized_edge_public_port(Some(edge));
    let routing_mode = normalized_edge_routing_mode(Some(edge));
    let layout = build_yandex_edge_runtime_layout(public_port, routing_mode);

    let mut origin = MobileSshSession::connect(&payload.server, &payload.secret).await?;
    origin.run("whoami && uname -a").await?;
    complete_step(&app, deployment_id, 0);
    eprintln!(
        "[mobile-provision] edge-attach deployment_id={} origin_host={} edge_host={} edge_port={} routing_mode={}",
        deployment_id,
        payload.server.host.trim(),
        edge.server.host.trim(),
        public_port,
        routing_mode
    );

    let owner_text = match origin
        .run(&format!("cat {}", quote_shell(WHITELIST_INVITE_PATH)))
        .await
    {
        Ok(text) => text,
        Err(error) => {
            if error.contains("No such file or directory") {
                return Err(format!(
                    "edge attach requires an existing origin deployment: {} is missing on {}. Run the regular origin deploy first, then attach the Yandex edge.",
                    WHITELIST_INVITE_PATH,
                    payload.server.host.trim()
                ));
            }
            return Err(error);
        }
    };
    let (owner, xray_state) = load_remote_access_state(&mut origin).await?;
    let reality = read_invite_reality_fallback(&owner)
        .map_err(|err| format!("read origin reality fallback: {err}"))?;
    let origin_xhttp_port = resolve_yandex_edge_origin_port(
        &mut origin,
        &owner,
        payload.server.yandex_edge_origin_port,
    )
    .await?;
    let edge_accepted_server_names = yandex_edge_accepted_server_names(YANDEX_EDGE_SERVER_NAME);
    let edge_routes: Vec<YandexEdgeRealityRoute> = edge_accepted_server_names
        .iter()
        .enumerate()
        .map(|(index, server_name)| YandexEdgeRealityRoute {
            server_name: server_name.clone(),
            local_port: 24043 + index as u16,
        })
        .collect();
    let edge_reality_keys = generate_reality_key_pair()?;
    let edge_reality_uuid = generate_protocol_uuid()?;
    let edge_reality_short_id = generate_reality_short_id()?;
    let edge_client_reality = RealityFallback {
        port: public_port,
        server_name: YANDEX_EDGE_SERVER_NAME.to_string(),
        public_key: edge_reality_keys.public_key.clone(),
        short_id: edge_reality_short_id.clone(),
        uuid: edge_reality_uuid.clone(),
        flow: if reality.flow.trim().is_empty() {
            DEFAULT_REALITY_FLOW.to_string()
        } else {
            reality.flow.clone()
        },
    };
    let origin_tls_server_name = YANDEX_EDGE_ORIGIN_XHTTP_SERVER_NAME.to_string();

    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        origin
            .run(&render_yandex_origin_xhttp_certificate_command(
                payload.server.host.trim(),
            ))
            .await?;
        let origin_xhttp_config = render_yandex_origin_xhttp_config(
            origin_xhttp_port,
            WHITELIST_YANDEX_ORIGIN_XHTTP_CERT_PATH,
            WHITELIST_YANDEX_ORIGIN_XHTTP_KEY_PATH,
            &reality.uuid,
        )?;
        upload_with_sudo(
            &mut origin,
            WHITELIST_YANDEX_ORIGIN_XHTTP_CONFIG_PATH,
            origin_xhttp_config.as_bytes(),
            "0644",
        )
        .await?;
        upload_with_sudo(
            &mut origin,
            WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_PATH,
            render_yandex_origin_xhttp_systemd_unit(
                WHITELIST_XRAY_BINARY_PATH,
                WHITELIST_YANDEX_ORIGIN_XHTTP_CONFIG_PATH,
            )
            .as_bytes(),
            "0644",
        )
        .await?;
        origin
            .run(&remote_root_shell(&format!(
                "systemctl daemon-reload && systemctl enable {} && systemctl restart {}",
                quote_shell(WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_NAME),
                quote_shell(WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_NAME),
            )))
            .await?;
        origin
            .run(&render_edge_service_ready_command(
                WHITELIST_YANDEX_ORIGIN_XHTTP_SERVICE_NAME,
                origin_xhttp_port,
            ))
            .await?;
    }

    let mut edge_ssh = MobileSshSession::connect(&edge_server, &edge.secret).await?;
    edge_ssh.run("whoami && uname -a").await?;
    complete_step(&app, deployment_id, 1);

    match routing_mode {
        EDGE_ROUTING_MODE_SNI_ROUTER => ensure_remote_haproxy_installed(&mut edge_ssh).await?,
        EDGE_ROUTING_MODE_XRAY_PROXY => {
            ensure_remote_edge_xray_installed(&mut edge_ssh, &layout.xray_path).await?
        }
        _ => ensure_remote_socat_installed(&mut edge_ssh).await?,
    }
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        let edge_config = render_yandex_edge_xray_proxy_config(
            &edge_reality_keys.private_key,
            &edge_reality_short_id,
            &edge_reality_uuid,
            &edge_routes,
            payload.server.host.trim(),
            origin_xhttp_port,
            &origin_tls_server_name,
            &reality.uuid,
        )?;
        upload_with_sudo(
            &mut edge_ssh,
            &layout.xray_config,
            edge_config.as_bytes(),
            "0644",
        )
        .await?;
        let haproxy_config =
            render_yandex_edge_multi_sni_haproxy_config("0.0.0.0", public_port, &edge_routes);
        upload_with_sudo(
            &mut edge_ssh,
            &layout.haproxy_path,
            haproxy_config.as_bytes(),
            "0644",
        )
        .await?;
    }
    let edge_manifest = render_yandex_edge_manifest(
        edge.server.host.trim(),
        public_port,
        payload.server.host.trim(),
        origin_xhttp_port,
        &edge_client_reality,
        &edge_accepted_server_names,
        reality.port,
        routing_mode,
        &layout,
    )?;
    upload_with_sudo(
        &mut edge_ssh,
        &layout.manifest_path,
        edge_manifest.as_bytes(),
        "0644",
    )
    .await?;
    if routing_mode == EDGE_ROUTING_MODE_SNI_ROUTER {
        let haproxy_config = render_yandex_edge_haproxy_config(
            "0.0.0.0",
            public_port,
            &reality.server_name,
            payload.server.host.trim(),
            reality.port,
        );
        upload_with_sudo(
            &mut edge_ssh,
            &layout.haproxy_path,
            haproxy_config.as_bytes(),
            "0644",
        )
        .await?;
    }
    complete_step(&app, deployment_id, 2);

    let edge_unit = if routing_mode == EDGE_ROUTING_MODE_SNI_ROUTER {
        render_yandex_edge_sni_router_systemd_unit(&layout.haproxy_path)
    } else if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        render_yandex_edge_router_systemd_unit(&layout.haproxy_path)
    } else {
        render_yandex_edge_tcp_forward_systemd_unit(
            payload.server.host.trim(),
            reality.port,
            public_port,
        )
    };
    upload_with_sudo(
        &mut edge_ssh,
        &layout.service_path,
        edge_unit.as_bytes(),
        "0644",
    )
    .await?;
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        upload_with_sudo(
            &mut edge_ssh,
            &layout.backend_service_path,
            render_yandex_edge_xray_proxy_systemd_unit(&layout.xray_path, &layout.xray_config)
                .as_bytes(),
            "0644",
        )
        .await?;
    }
    edge_ssh
        .run(&remote_root_shell("systemctl daemon-reload"))
        .await?;
    complete_step(&app, deployment_id, 3);

    if routing_mode == EDGE_ROUTING_MODE_SNI_ROUTER {
        edge_ssh
            .run(&remote_root_shell(&format!(
                "haproxy -c -f {}",
                quote_shell(&layout.haproxy_path)
            )))
            .await?;
    } else if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        edge_ssh
            .run(&remote_root_shell(&format!(
                "{} version >/dev/null && haproxy -c -f {}",
                quote_shell(&layout.xray_path),
                quote_shell(&layout.haproxy_path)
            )))
            .await?;
    }
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        edge_ssh
            .run(&remote_root_shell(&format!(
                "systemctl enable {} {} && systemctl restart {} {} && sleep 2",
                quote_shell(&layout.service_name),
                quote_shell(&layout.backend_service_name),
                quote_shell(&layout.backend_service_name),
                quote_shell(&layout.service_name),
            )))
            .await?;
    } else {
        edge_ssh
            .run(&remote_root_shell(&format!(
                "systemctl enable {} && systemctl restart {} && sleep 2",
                quote_shell(&layout.service_name),
                quote_shell(&layout.service_name),
            )))
            .await?;
    }
    edge_ssh
        .run(&render_edge_service_ready_command(
            &layout.service_name,
            public_port,
        ))
        .await?;
    if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
        edge_ssh
            .run(&remote_root_shell(&format!(
                "systemctl is-active {}",
                quote_shell(&layout.backend_service_name)
            )))
            .await?;
    }
    edge_ssh
        .run(&render_remote_tcp_probe_command(
            payload.server.host.trim(),
            if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
                origin_xhttp_port
            } else {
                reality.port
            },
            12,
            1,
        ))
        .await?;
    complete_step(&app, deployment_id, 4);

    let (patched_owner_profile, staged_fallbacks, protocol_pack) =
        patch_owner_profile_with_yandex_edge(
            &owner_text,
            edge.server.host.trim(),
            public_port,
            payload.server.host.trim(),
            origin_xhttp_port,
            &reality,
            routing_mode,
            Some(&edge_client_reality),
        )?;
    origin
        .upload(
            WHITELIST_INVITE_PATH,
            patched_owner_profile.as_bytes(),
            "0600",
        )
        .await?;
    save_local_owner_profile(&app, &payload.server.host, patched_owner_profile.as_bytes())?;
    let fallback_manifest =
        render_staged_fallback_manifest(payload.server.host.trim(), reality.port)?;
    origin
        .upload(
            WHITELIST_FALLBACKS_PATH,
            fallback_manifest.as_bytes(),
            "0644",
        )
        .await?;
    let protocol_pack_manifest = render_protocol_pack_manifest(
        payload.server.host.trim(),
        &owner.transport,
        xray_state.wire_guard_port,
        reality.port,
        owner.vk_turn_proxy_port,
        Some(&staged_fallbacks),
    )?;
    origin
        .upload(
            WHITELIST_PROTOCOL_PACK_PATH,
            protocol_pack_manifest.as_bytes(),
            "0644",
        )
        .await?;
    set_deployment_protocol_pack(&app, deployment_id, protocol_pack);
    let (health_checks, health_ok) = run_edge_attach_health_checks(
        &mut edge_ssh,
        &layout,
        routing_mode,
        public_port,
        payload.server.host.trim(),
        if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
            origin_xhttp_port
        } else {
            reality.port
        },
    )
    .await;
    set_deployment_health_checks(&app, deployment_id, health_checks);
    if !health_ok {
        return Err("edge attach health checks failed".to_string());
    }
    let store = app.state::<MobileDeploymentStore>();
    store.update(deployment_id, |deployment| {
        deployment.edge_enabled = Some(true);
        deployment.edge_host = Some(edge.server.host.trim().to_string());
        deployment.edge_port = Some(public_port);
        deployment.edge_routing_mode = Some(routing_mode.to_string());
    });
    complete_step(&app, deployment_id, 5);

    let _ = edge_ssh.close().await;
    let _ = origin.close().await;
    Ok(())
}

fn deployment_timestamp_nanos() -> u128 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn complete_step(app: &AppHandle, deployment_id: &str, index: usize) {
    let store = app.state::<MobileDeploymentStore>();
    store.update(deployment_id, |deployment| {
        if let Some(current) = deployment.steps.get_mut(index) {
            current.status = "done".to_string();
        }
        if let Some(next) = deployment.steps.get_mut(index + 1) {
            next.status = "current".to_string();
        }
    });
}

fn set_deployment_ports(
    app: &AppHandle,
    deployment_id: &str,
    turn_port: u16,
    wire_guard_port: u16,
    reality_port: u16,
) {
    let store = app.state::<MobileDeploymentStore>();
    store.update(deployment_id, |deployment| {
        deployment.turn_port = Some(turn_port);
        deployment.wire_guard_port = Some(wire_guard_port);
        deployment.reality_port = Some(reality_port);
    });
}

fn set_deployment_protocol_pack(
    app: &AppHandle,
    deployment_id: &str,
    protocol_pack: Vec<ProtocolPackEntry>,
) {
    let store = app.state::<MobileDeploymentStore>();
    store.update(deployment_id, |deployment| {
        deployment.protocol_pack = protocol_pack;
    });
}

fn set_deployment_health_checks(
    app: &AppHandle,
    deployment_id: &str,
    health_checks: Vec<CheckEntry>,
) {
    let store = app.state::<MobileDeploymentStore>();
    store.update(deployment_id, |deployment| {
        deployment.health_checks = health_checks;
    });
}

async fn run_edge_attach_health_checks(
    ssh: &mut MobileSshSession,
    layout: &YandexEdgeRuntimeLayout,
    routing_mode: &str,
    public_port: u16,
    origin_host: &str,
    origin_port: u16,
) -> (Vec<CheckEntry>, bool) {
    let mut checks = vec![
        (
            "edge-service-active",
            "Edge service active",
            remote_root_shell(&format!(
                "systemctl is-active {}",
                quote_shell(&layout.service_name)
            )),
            format!("{} is active.", layout.service_name),
        ),
        (
            "edge-public-listener",
            "Edge public listener",
            remote_root_shell(&format!(
                "ss -H -ltn | awk '{{print $4}}' | grep -Eq '(^|\\\\]|:){}$'",
                public_port
            )),
            format!("{public_port}/tcp is listening on the edge host."),
        ),
        (
            "edge-origin-reachability",
            "Edge to origin reachability",
            render_remote_tcp_probe_command(origin_host, origin_port, 12, 1),
            format!("Edge can reach the REALITY origin on {origin_host}:{origin_port}."),
        ),
        (
            "edge-manifest",
            "Edge manifest",
            remote_root_shell(&format!("test -s {}", quote_shell(&layout.manifest_path))),
            format!("Edge manifest is present at {}.", layout.manifest_path),
        ),
    ];

    match routing_mode {
        EDGE_ROUTING_MODE_SNI_ROUTER => checks.push((
            "edge-haproxy-config",
            "Edge HAProxy config",
            remote_root_shell(&format!(
                "haproxy -c -f {}",
                quote_shell(&layout.haproxy_path)
            )),
            format!(
                "HAProxy config passes syntax validation at {}.",
                layout.haproxy_path
            ),
        )),
        EDGE_ROUTING_MODE_XRAY_PROXY => {
            if !layout.backend_service_name.is_empty() {
                checks.push((
                    "edge-backend-service-active",
                    "Edge backend service active",
                    remote_root_shell(&format!(
                        "systemctl is-active {}",
                        quote_shell(&layout.backend_service_name)
                    )),
                    format!("{} is active.", layout.backend_service_name),
                ));
            }
            checks.push((
                "edge-xray-config",
                "Edge xray config",
                remote_root_shell(&format!(
                    "{} run -test -config {}",
                    quote_shell(&layout.xray_path),
                    quote_shell(&layout.xray_config)
                )),
                format!(
                    "Xray config passes syntax validation at {}.",
                    layout.xray_config
                ),
            ));
        }
        _ => checks.push((
            "edge-socat-runtime",
            "Edge socat runtime",
            remote_root_shell("command -v socat >/dev/null"),
            "socat is installed for tcp-forward mode.".to_string(),
        )),
    }

    let mut results = Vec::with_capacity(checks.len());
    let mut all_ok = true;
    for (key, label, command, success_detail) in checks {
        let outcome = ssh.run(&command).await;
        let ok = outcome.is_ok();
        let detail = match outcome {
            Ok(output) if output.trim().is_empty() => success_detail,
            Ok(output) => output,
            Err(error) => error,
        };
        results.push(CheckEntry {
            key: key.to_string(),
            label: label.to_string(),
            ok,
            detail,
        });
        all_ok &= ok;
    }
    (results, all_ok)
}

fn fail_deployment(store: &MobileDeploymentStore, deployment_id: &str, error: &str) {
    store.update(deployment_id, |deployment| {
        deployment.status = "failed".to_string();
        deployment.error = Some(error.to_string());
        if let Some(current) = deployment
            .steps
            .iter_mut()
            .find(|step| step.status == "current")
        {
            current.status = "failed".to_string();
        }
    });
}

fn save_local_owner_profile(app: &AppHandle, host: &str, data: &[u8]) -> Result<(), String> {
    let target_path = owner_profile_path(app, host)?;
    if let Some(parent) = target_path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("prepare owner profile dir: {err}"))?;
    }
    fs::write(&target_path, data).map_err(|err| format!("save local owner profile: {err}"))
}

async fn install_remote_xray_binary(ssh: &mut MobileSshSession) -> Result<(), String> {
    ssh.run(&render_remote_xray_install_command(
        XRAY_RELEASE_URL,
        WHITELIST_XRAY_BINARY_PATH,
    ))
    .await?;
    Ok(())
}

async fn install_remote_sing_box_binary(ssh: &mut MobileSshSession) -> Result<(), String> {
    ssh.run(&format!(
        "tmp=$(mktemp -d) && cd \"$tmp\" && curl -fsSLo sing-box.tar.gz {} && tar -xzf sing-box.tar.gz && install -m 0755 sing-box-*/sing-box {} && rm -rf \"$tmp\"",
        quote_shell(SING_BOX_LINUX_RELEASE_URL),
        quote_shell(WHITELIST_SING_BOX_BINARY_PATH),
    ))
    .await?;
    Ok(())
}

async fn ensure_remote_vk_turn_proxy_binary(ssh: &mut MobileSshSession) -> Result<(), String> {
    if ssh
        .run(&format!(
            "test -x {}",
            quote_shell(WHITELIST_PROXY_BINARY_PATH)
        ))
        .await
        .is_ok()
    {
        return Ok(());
    }

    ssh.upload(
        WHITELIST_PROXY_BINARY_PATH,
        BUNDLED_VK_TURN_PROXY_SERVER_LINUX_AMD64,
        "0755",
    )
    .await?;
    ssh.run(&format!(
        "test -x {}",
        quote_shell(WHITELIST_PROXY_BINARY_PATH)
    ))
    .await?;
    Ok(())
}

async fn resolve_remote_udp_port(
    ssh: &mut MobileSshSession,
    requested: Option<u16>,
    start: u16,
    end: u16,
    excluded: &[u16],
    label: &str,
) -> Result<u16, String> {
    if let Some(requested_port) = requested.filter(|port| *port > 0) {
        if excluded.contains(&requested_port) {
            return Err(format!(
                "{label} UDP port {requested_port} conflicts with another Odin's Cat service"
            ));
        }
        if remote_udp_port_is_free(ssh, requested_port).await? {
            return Ok(requested_port);
        }
        return Err(format!(
            "{label} UDP port {requested_port} is already in use on the server"
        ));
    }

    for port in port_candidates(start, end, None)? {
        if excluded.contains(&port) {
            continue;
        }
        if remote_udp_port_is_free(ssh, port).await? {
            return Ok(port);
        }
    }

    Err(format!("no free UDP port found in range {start}-{end}"))
}

async fn resolve_remote_relay_port(
    ssh: &mut MobileSshSession,
    requested: Option<u16>,
) -> Result<u16, String> {
    if let Some(requested_port) = requested.filter(|port| *port > 0) {
        if remote_udp_port_is_free(ssh, requested_port).await?
            || remote_existing_relay_uses_port(ssh, requested_port).await
        {
            return Ok(requested_port);
        }
        return Err(format!(
            "vk-turn-proxy relay UDP port {requested_port} is already in use on the server"
        ));
    }

    resolve_remote_udp_port(
        ssh,
        None,
        WHITELIST_TURN_PORT_START,
        WHITELIST_TURN_PORT_END,
        &[],
        "vk-turn-proxy relay",
    )
    .await
}

async fn resolve_deployment_reality_port(
    ssh: &mut MobileSshSession,
    requested: Option<u16>,
) -> Result<u16, String> {
    if let Some(requested_port) = requested.filter(|port| *port > 0) {
        if remote_tcp_port_is_free(ssh, requested_port).await?
            || remote_existing_reality_uses_port(ssh, requested_port).await
        {
            return Ok(requested_port);
        }
        return Err(format!(
            "VLESS + REALITY TCP port {requested_port} is already in use on the server"
        ));
    }

    find_remote_preferred_tcp_port(ssh, None, REALITY_FALLBACK_MIN_PORT, REALITY_FALLBACK_MAX_PORT)
        .await
}

fn existing_yandex_edge_origin_port(owner: &InviteProfileFile) -> Option<u16> {
    owner
        .staged_fallbacks
        .get("realityYandexEdge")
        .and_then(Value::as_object)
        .and_then(|fallback| fallback.get("originPort"))
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| *value > 0)
        .or_else(|| {
            owner
                .staged_fallbacks
                .get("realityYandexEdgeProxy")
                .and_then(Value::as_object)
                .and_then(|fallback| fallback.get("originPort"))
                .and_then(Value::as_u64)
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| *value > 0)
        })
}

async fn remote_existing_yandex_origin_xhttp_uses_port(
    ssh: &mut MobileSshSession,
    owner: &InviteProfileFile,
    port: u16,
) -> Result<bool, String> {
    Ok(matches!(
        remote_existing_yandex_origin_xhttp_port(ssh, owner).await?,
        Some(existing_port) if existing_port == port
    ))
}

async fn remote_existing_yandex_origin_xhttp_port(
    ssh: &mut MobileSshSession,
    owner: &InviteProfileFile,
) -> Result<Option<u16>, String> {
    if let Some(existing_port) = existing_yandex_edge_origin_port(owner) {
        return Ok(Some(existing_port));
    }

    let config_text = match ssh
        .run(&format!(
            "cat {}",
            quote_shell(WHITELIST_YANDEX_ORIGIN_XHTTP_CONFIG_PATH)
        ))
        .await
    {
        Ok(config_text) => config_text,
        Err(error) if error.contains("No such file or directory") => return Ok(None),
        Err(error) => return Err(error),
    };
    let config_value: Value = serde_json::from_str(&config_text)
        .map_err(|err| format!("parse yandex origin xhttp config: {err}"))?;
    Ok(config_value
        .get("inbounds")
        .and_then(Value::as_array)
        .and_then(|inbounds| inbounds.first())
        .and_then(Value::as_object)
        .and_then(|inbound| inbound.get("port"))
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| *value > 0))
}

async fn resolve_yandex_edge_origin_port(
    ssh: &mut MobileSshSession,
    owner: &InviteProfileFile,
    requested: Option<u16>,
) -> Result<u16, String> {
    if let Some(requested_port) = requested.filter(|port| *port > 0) {
        if remote_tcp_port_is_free(ssh, requested_port).await?
            || remote_existing_yandex_origin_xhttp_uses_port(ssh, owner, requested_port).await?
        {
            return Ok(requested_port);
        }
        return Err(format!(
            "Yandex edge origin xHTTP TCP port {requested_port} is already in use on the server"
        ));
    }

    find_remote_preferred_tcp_port(
        ssh,
        None,
        YANDEX_EDGE_ORIGIN_MIN_PORT,
        YANDEX_EDGE_ORIGIN_MAX_PORT,
    )
    .await
}

fn port_candidates_with_seed(start: u16, end: u16, preferred: Option<u16>, seed: u16) -> Vec<u16> {
    if start > end {
        return Vec::new();
    }

    let start_u32 = u32::from(start);
    let end_u32 = u32::from(end);
    let span = end_u32 - start_u32 + 1;
    let offset = u32::from(seed) % span;
    let preferred = preferred.filter(|port| *port >= start && *port <= end);
    let mut ports = Vec::with_capacity(span as usize + usize::from(preferred.is_some()));

    if let Some(preferred_port) = preferred {
        ports.push(preferred_port);
    }

    for step in 0..span {
        let port = (start_u32 + ((offset + step) % span)) as u16;
        if Some(port) == preferred {
            continue;
        }
        ports.push(port);
    }

    ports
}

fn port_candidates(start: u16, end: u16, preferred: Option<u16>) -> Result<Vec<u16>, String> {
    let mut seed = [0_u8; 2];
    getrandom(&mut seed).map_err(|err| format!("generate port selection seed: {err}"))?;
    Ok(port_candidates_with_seed(
        start,
        end,
        preferred,
        u16::from_le_bytes(seed),
    ))
}

async fn find_remote_preferred_tcp_port(
    ssh: &mut MobileSshSession,
    preferred: Option<u16>,
    start: u16,
    end: u16,
) -> Result<u16, String> {
    for port in port_candidates(start, end, preferred.filter(|port| *port > 0))? {
        if remote_tcp_port_is_free(ssh, port).await? {
            return Ok(port);
        }
    }
    Err(format!("no free TCP port found in range {start}-{end}"))
}

async fn remote_udp_port_is_free(ssh: &mut MobileSshSession, port: u16) -> Result<bool, String> {
    Ok(ssh
        .run(&format!(
            "if ss -H -lun | awk '{{print $5}}' | grep -Eq '(^|\\\\]|:){}$'; then exit 1; fi",
            port
        ))
        .await
        .is_ok())
}

async fn remote_tcp_port_is_free(ssh: &mut MobileSshSession, port: u16) -> Result<bool, String> {
    Ok(ssh
        .run(&format!(
            "if ss -H -ltn | awk '{{print $4}}' | grep -Eq '(^|\\\\]|:){}$'; then exit 1; fi",
            port
        ))
        .await
        .is_ok())
}

async fn remote_existing_relay_uses_port(ssh: &mut MobileSshSession, port: u16) -> bool {
    remote_existing_relay_port(ssh).await == Some(port)
}

async fn remote_existing_relay_port(ssh: &mut MobileSshSession) -> Option<u16> {
    let unit_text = match ssh
        .run(&format!(
            "cat {}",
            quote_shell(WHITELIST_PROXY_SERVICE_PATH)
        ))
        .await
    {
        Ok(unit_text) => unit_text,
        Err(_) => return None,
    };
    parse_vk_relay_unit_ports(&unit_text).0
}

async fn remote_existing_reality_uses_port(ssh: &mut MobileSshSession, port: u16) -> bool {
    matches!(remote_existing_reality_port(ssh).await, Ok(Some(existing_port)) if existing_port == port)
}

async fn remote_existing_reality_port(ssh: &mut MobileSshSession) -> Result<Option<u16>, String> {
    match load_remote_access_state(ssh).await {
        Ok((_, state)) => Ok(nonzero_u16(state.reality.port)),
        Err(err) if err.contains("No such file or directory") => Ok(None),
        Err(err) => Err(err),
    }
}

fn parse_vk_relay_unit_ports(unit_text: &str) -> (Option<u16>, Option<u16>) {
    (
        parse_port_after_flag(unit_text, "-listen"),
        parse_port_after_flag(unit_text, "-connect"),
    )
}

fn parse_port_after_flag(unit_text: &str, flag: &str) -> Option<u16> {
    let mut parts = unit_text.split_whitespace();
    while let Some(part) = parts.next() {
        let raw_value = if part == flag {
            parts.next()
        } else {
            part.strip_prefix(&format!("{flag}="))
        };
        if let Some(value) = raw_value {
            if let Some(port_text) = value.rsplit(':').next() {
                if let Ok(port) = port_text.parse::<u16>() {
                    return Some(port);
                }
            }
        }
    }
    None
}

fn generate_reality_key_pair() -> Result<X25519KeyPair, String> {
    let mut private_key = [0_u8; 32];
    getrandom(&mut private_key).map_err(|err| format!("generate reality key: {err}"))?;
    private_key[0] &= 248;
    private_key[31] = (private_key[31] & 127) | 64;
    let private = StaticSecret::from(private_key);
    let public = x25519_dalek::PublicKey::from(&private);
    Ok(X25519KeyPair {
        private_key: URL_SAFE_NO_PAD.encode(private.to_bytes()),
        public_key: URL_SAFE_NO_PAD.encode(public.as_bytes()),
    })
}

fn generate_reality_short_id() -> Result<String, String> {
    let mut raw = [0_u8; 8];
    getrandom(&mut raw).map_err(|err| format!("generate reality short id: {err}"))?;
    Ok(hex_lower(&raw))
}

#[derive(Debug, Clone)]
struct X25519KeyPair {
    private_key: String,
    public_key: String,
}

fn render_xray_config_with_listen(
    server_private_key: &str,
    peers: &[Value],
    listen_host: &str,
    wire_guard_port: u16,
    reality: Option<&Value>,
) -> Result<String, String> {
    let mut inbounds = vec![json!({
        "tag": "wg-in",
        "protocol": "wireguard",
        "listen": listen_host,
        "port": wire_guard_port,
        "settings": {
            "secretKey": server_private_key,
            "mtu": 1280,
            "peers": peers
        }
    })];

    if let Some(reality_value) = reality {
        inbounds.push(json!({
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": reality_value.get("port").and_then(Value::as_u64).unwrap_or_default(),
            "protocol": "vless",
            "settings": {
                "clients": reality_value.get("clients").cloned().unwrap_or_else(|| json!([])),
                "decryption": "none"
            },
            "sniffing": {
                "destOverride": ["http", "tls", "quic"],
                "enabled": true
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": reality_value.get("dest").and_then(Value::as_str).unwrap_or(DEFAULT_REALITY_DEST),
                    "privateKey": reality_value.get("privateKey").and_then(Value::as_str).unwrap_or(""),
                    "serverNames": [reality_value.get("serverName").and_then(Value::as_str).unwrap_or(DEFAULT_REALITY_SERVER_NAME)],
                    "shortIds": [reality_value.get("shortId").and_then(Value::as_str).unwrap_or("")],
                    "show": false,
                    "xver": 0
                }
            }
        }));
    }

    serde_json::to_string_pretty(&json!({
        "log": { "loglevel": "warning" },
        "inbounds": inbounds,
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }]
    }))
    .map_err(|err| format!("marshal xray config: {err}"))
}

fn render_reality_server_config(
    port: u16,
    uuid: &str,
    private_key: &str,
    short_id: &str,
) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "log": { "loglevel": "warning" },
        "inbounds": [{
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": port,
            "protocol": "vless",
            "settings": {
                "clients": [{
                    "id": uuid,
                    "flow": DEFAULT_REALITY_FLOW
                }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": reality_destination(),
                    "xver": 0,
                    "serverNames": [reality_server_name()],
                    "privateKey": private_key,
                    "shortIds": [short_id]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        }]
    }))
    .map_err(|err| format!("marshal reality server config: {err}"))
}

fn build_staged_fallbacks(
    reality_port: u16,
    reality_public_key: &str,
    reality_short_id: &str,
    reality_uuid: &str,
    promoted: bool,
) -> Value {
    let (reality_status, reality_description) = if promoted {
        (
            "ready",
            "Server-side REALITY inbound is live alongside the current WireGuard path and ready for controlled client-side testing.",
        )
    } else {
        (
            "staged",
            "Server-side config is generated during deploy but not promoted to the active runtime path yet.",
        )
    };

    json!({
        "vlessReality": {
            "status": reality_status,
            "port": reality_port,
            "serverName": reality_server_name(),
            "publicKey": reality_public_key,
            "shortId": reality_short_id,
            "uuid": reality_uuid,
            "flow": DEFAULT_REALITY_FLOW,
            "description": reality_description
        },
        "realityRelayOwnerEgress": {
            "status": if promoted { "ready" } else { "staged" },
            "ownerEgressPort": reality_port,
            "subscriptionUrl": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL,
            "sourceLabel": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL,
            "description": "Experimental relay-assisted REALITY mode. The client picks a curated external REALITY relay first, then moves egress back to your Odin's Cat server."
        },
        "realityRelayDirect": {
            "status": "ready",
            "subscriptionUrl": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL,
            "sourceLabel": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL,
            "description": "Experimental direct relay mode. The client picks a curated external REALITY relay from the hourly igareck feed and sends traffic through it without a second hop to your Odin's Cat server."
        },
        "naive": {
            "status": "staged",
            "port": NAIVE_FALLBACK_PORT,
            "description": "Reserved for future HTTPS camouflage fallback once certificates and credentials are provisioned."
        },
        "hysteria2": {
            "status": "staged",
            "port": HYSTERIA2_FALLBACK_PORT,
            "description": "Reserved for future UDP fallback once client and server configs are promoted from staged mode."
        }
    })
}

fn preview_staged_fallbacks(edge: Option<&EdgeAttachPayload>) -> Value {
    let mut staged = json!({});
    ensure_reality_relay_owner_egress_fallback(&mut staged);
    ensure_reality_relay_direct_fallback(&mut staged);
    if let Some(edge_payload) = edge.filter(|entry| entry.enabled) {
        upsert_yandex_edge_fallback(
            &mut staged,
            yandex_edge_fallback_value_for(
                edge_payload.server.host.trim(),
                normalized_edge_public_port(Some(edge_payload)),
                "",
                0,
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                EDGE_ROUTING_MODE_DEFAULT,
            ),
        );
    }
    staged
}

fn render_staged_fallback_manifest(host: &str, reality_port: u16) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "host": host,
        "generatedAt": now_rfc3339(),
        "entries": [
            {
                "id": "vless-reality",
                "status": "ready",
                "engine": "xray",
                "port": reality_port,
                "network": "tcp",
                "notes": "Controlled direct fallback path exposed alongside the current WireGuard transport for macOS localhost testing."
            },
            {
                "id": "reality-relay-owner-egress",
                "status": "staged",
                "engine": "sing-box",
                "port": REALITY_FALLBACK_MIN_PORT,
                "network": "tcp",
                "notes": "Experimental relay-assisted path that enters through a curated external REALITY relay and then returns egress to the Odin's Cat server."
            },
            {
                "id": "reality-relay-direct",
                "status": "staged",
                "engine": "sing-box",
                "port": REALITY_RELAY_DIRECT_PORT,
                "network": "tcp",
                "notes": "Experimental direct relay path that enters through a curated external REALITY relay from the hourly igareck feed and exits directly through that relay."
            },
            {
                "id": "naive",
                "status": "staged",
                "engine": "sing-box",
                "port": NAIVE_FALLBACK_PORT,
                "network": "tcp",
                "notes": "Reserved for future HTTPS camouflage fallback once certificates and auth material are provisioned."
            },
            {
                "id": "hysteria2",
                "status": "staged",
                "engine": "sing-box",
                "port": HYSTERIA2_FALLBACK_PORT,
                "network": "udp",
                "notes": "Reserved for future UDP fallback once client and server configs are promoted from staged mode."
            }
        ]
    }))
    .map_err(|err| format!("marshal fallback manifest: {err}"))
}

fn render_protocol_pack_manifest(
    host: &str,
    transport: &str,
    wire_guard_port: u16,
    reality_port: u16,
    vk_relay_port: u16,
    staged_fallbacks: Option<&Value>,
) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "host": host,
        "transport": transport,
        "activeProtocol": active_protocol_id(transport),
        "generatedAt": now_rfc3339(),
        "recommendedPath": active_protocol_id(transport),
        "entries": build_protocol_pack_for_transport_with_fallbacks(
            transport,
            Some(wire_guard_port),
            Some(reality_port),
            Some(vk_relay_port),
            staged_fallbacks,
        )
    }))
    .map_err(|err| format!("marshal protocol pack manifest: {err}"))
}

fn render_owner_profile(
    host: &str,
    wire_guard_port: u16,
    vk_turn_proxy_port: u16,
    server_public_key: &str,
    client_private_key: &str,
    client_public_key: &str,
    staged_fallbacks: Value,
) -> Result<String, String> {
    let mut profile = OwnerProfileFile {
        name: "Odin's Cat Owner Node".to_string(),
        transport: "xray".to_string(),
        active_protocol: "vless-reality".to_string(),
        vk_turn_stream_count: VK_TURN_STREAM_COUNT_DEFAULT,
        server_host: host.to_string(),
        vk_turn_proxy_port,
        endpoint_port: wire_guard_port,
        protocol_pack: build_protocol_pack_for_transport_with_fallbacks(
            "xray",
            Some(wire_guard_port),
            staged_fallbacks
                .get("vlessReality")
                .and_then(|value| value.get("port"))
                .and_then(Value::as_u64)
                .and_then(|value| u16::try_from(value).ok()),
            Some(vk_turn_proxy_port),
            Some(&staged_fallbacks),
        ),
        android_runtime: json!({}),
        staged_fallbacks,
        wireguard: OwnerWireGuard {
            server_public_key: server_public_key.to_string(),
            client_private_key: client_private_key.to_string(),
            client_public_key: client_public_key.to_string(),
            address: "10.66.66.2/32".to_string(),
            mtu: 1280,
        },
    };
    sync_owner_android_runtime(&mut profile);
    serde_json::to_string_pretty(&profile).map_err(|err| format!("marshal owner profile: {err}"))
}

fn render_yandex_origin_xhttp_certificate_command(origin_host: &str) -> String {
    let mut san_entries = vec![
        format!("DNS:{}", YANDEX_EDGE_CDN_CAMOUFLAGE_HOST),
        format!("DNS:{}", YANDEX_EDGE_ORIGIN_XHTTP_SERVER_NAME),
    ];
    let origin_host = origin_host.trim();
    let origin_sslip = sslip_host_for_invite(origin_host);
    if !origin_sslip.trim().is_empty() {
        san_entries.push(format!("DNS:{origin_sslip}"));
    }
    if !origin_host.is_empty() {
        if origin_host.parse::<std::net::IpAddr>().is_ok() {
            san_entries.push(format!("IP:{origin_host}"));
        } else {
            san_entries.push(format!("DNS:{origin_host}"));
        }
    }
    remote_root_shell(&format!(
        "mkdir -p {config_dir} && if ! command -v openssl >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssl; else echo 'openssl is required and apt-get was not found' >&2; exit 1; fi; fi && openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -keyout {key_path} -out {cert_path} -subj {subject} -addext {san} >/dev/null 2>&1 && chmod 0600 {key_path} && chmod 0644 {cert_path}",
        config_dir = quote_shell(WHITELIST_CONFIG_DIR),
        key_path = quote_shell(WHITELIST_YANDEX_ORIGIN_XHTTP_KEY_PATH),
        cert_path = quote_shell(WHITELIST_YANDEX_ORIGIN_XHTTP_CERT_PATH),
        subject = quote_shell(&format!("/CN={}", YANDEX_EDGE_ORIGIN_XHTTP_SERVER_NAME)),
        san = quote_shell(&format!("subjectAltName={}", san_entries.join(","))),
    ))
}

fn render_systemd_unit(name: &str, exec_start: &str) -> String {
    format!(
        "[Unit]\nDescription={name}\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart={exec_start}\nRestart=always\nRestartSec=2\nWorkingDirectory={WHITELIST_ROOT}\n\n[Install]\nWantedBy=multi-user.target\n"
    )
}

fn render_remote_xray_install_command(download_url: &str, target_path: &str) -> String {
    format!(
        "tmp=$(mktemp -d) && cd \"$tmp\" && curl -fsSLo xray.zip {} && if command -v unzip >/dev/null 2>&1; then unzip -oq xray.zip xray; else python3 - <<'PY'\nimport zipfile\nwith zipfile.ZipFile('xray.zip') as zf:\n    with zf.open('xray') as src, open('xray', 'wb') as dst:\n        dst.write(src.read())\nPY\nfi && install -m 0755 xray {} && rm -rf \"$tmp\"",
        quote_shell(download_url),
        quote_shell(target_path)
    )
}

fn active_protocol_id(transport: &str) -> &'static str {
    if transport.trim() == "vk-turn-proxy+xray" {
        "vk-turn-wireguard"
    } else {
        "vless-reality"
    }
}

fn build_protocol_pack_for_transport_with_fallbacks(
    transport: &str,
    wire_guard_port: Option<u16>,
    reality_port: Option<u16>,
    vk_turn_proxy_port: Option<u16>,
    staged_fallbacks: Option<&Value>,
) -> Vec<ProtocolPackEntry> {
    let current_yandex_edge_proxy_routing_mode = staged_fallbacks
        .and_then(|value| value.get("realityYandexEdgeProxy"))
        .and_then(Value::as_object)
        .and_then(|value| value.get("routingMode"))
        .and_then(Value::as_str)
        .unwrap_or(EDGE_ROUTING_MODE_DEFAULT);
    let expose_legacy_yandex_edge_entry =
        !staged_fallback_present(staged_fallbacks, "realityYandexEdgeProxy")
            || current_yandex_edge_proxy_routing_mode != EDGE_ROUTING_MODE_XRAY_PROXY;
    let mut entries = vec![
        ProtocolPackEntry {
            id: "vless-reality".to_string(),
            label: "VLESS + REALITY".to_string(),
            status: "active".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality".to_string(),
            network: "tcp".to_string(),
            port: reality_port.unwrap_or(REALITY_DEPLOY_DEFAULT_PORT),
            notes: "Default direct path for localhost SOCKS and system proxy mode on restrictive networks.".to_string(),
        },
        ProtocolPackEntry {
            id: "vk-turn-wireguard".to_string(),
            label: "VK TURN relay + xray".to_string(),
            status: "staged".to_string(),
            engine: "xray".to_string(),
            scheme: "wireguard".to_string(),
            network: "udp".to_string(),
            port: vk_turn_proxy_port.unwrap_or(WHITELIST_TURN_PORT_START),
            notes: "VK relay stays deployed on the same server so the client can switch to it without another server rollout.".to_string(),
        },
    ];

    if staged_fallback_present(staged_fallbacks, "realityRelayOwnerEgress") {
        entries.push(ProtocolPackEntry {
            id: "vless-reality-relay-owner".to_string(),
            label: "white tunel".to_string(),
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality-relay".to_string(),
            network: "tcp".to_string(),
            port: fallback_port_from_value(
                staged_fallbacks.and_then(|value| value.get("realityRelayOwnerEgress")),
                "ownerEgressPort",
                REALITY_FALLBACK_MIN_PORT,
            ),
            notes: "Experimental relay-assisted path that starts through a curated external REALITY relay and returns internet egress to your server.".to_string(),
        });
    }

    if staged_fallback_present(staged_fallbacks, "realityRelayDirect") {
        entries.push(ProtocolPackEntry {
            id: "vless-reality-relay-direct".to_string(),
            label: "white relay".to_string(),
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality-relay-direct".to_string(),
            network: "tcp".to_string(),
            port: REALITY_RELAY_DIRECT_PORT,
            notes: "Experimental direct relay path that picks a curated external REALITY relay from the hourly igareck feed and sends traffic through it without returning egress to your server.".to_string(),
        });
    }

    if expose_legacy_yandex_edge_entry
        && staged_fallback_present(staged_fallbacks, "realityYandexEdge")
    {
        let routing_mode = staged_fallbacks
            .and_then(|value| value.get("realityYandexEdge"))
            .and_then(Value::as_object)
            .and_then(|value| value.get("routingMode"))
            .and_then(Value::as_str)
            .unwrap_or(EDGE_ROUTING_MODE_DEFAULT);
        entries.push(ProtocolPackEntry {
            id: "vless-reality-yandex-edge".to_string(),
            label: "Yandex edge".to_string(),
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality-edge".to_string(),
            network: "tcp".to_string(),
            port: fallback_port_from_value(
                staged_fallbacks.and_then(|value| value.get("realityYandexEdge")),
                "connectPort",
                YANDEX_EDGE_CONNECT_PORT,
            ),
            notes: yandex_edge_protocol_note(routing_mode, false),
        });
    }

    if staged_fallback_present(staged_fallbacks, "realityYandexEdgeProxy") {
        let routing_mode = staged_fallbacks
            .and_then(|value| value.get("realityYandexEdgeProxy"))
            .and_then(Value::as_object)
            .and_then(|value| value.get("routingMode"))
            .and_then(Value::as_str)
            .unwrap_or(EDGE_ROUTING_MODE_DEFAULT);
        entries.push(ProtocolPackEntry {
            id: "vless-reality-yandex-edge-proxy".to_string(),
            label: if routing_mode == EDGE_ROUTING_MODE_XRAY_PROXY {
                "Yandex edge".to_string()
            } else {
                "Yandex edge proxy".to_string()
            },
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality-edge-proxy".to_string(),
            network: "tcp".to_string(),
            port: fallback_port_from_value(
                staged_fallbacks.and_then(|value| value.get("realityYandexEdgeProxy")),
                "connectPort",
                YANDEX_EDGE_CONNECT_PORT,
            ),
            notes: yandex_edge_protocol_note(routing_mode, true),
        });
    }

    entries.extend([
        ProtocolPackEntry {
            id: "direct-wireguard".to_string(),
            label: "Direct WireGuard-over-xray".to_string(),
            status: "staged".to_string(),
            engine: "xray".to_string(),
            scheme: "wireguard".to_string(),
            network: "udp".to_string(),
            port: wire_guard_port.unwrap_or(WHITELIST_WIREGUARD_PORT_START),
            notes: "Legacy direct UDP path kept as a fallback while VLESS + REALITY is the default.".to_string(),
        },
        ProtocolPackEntry {
            id: "naive".to_string(),
            label: "Naive".to_string(),
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "naive".to_string(),
            network: "tcp".to_string(),
            port: NAIVE_FALLBACK_PORT,
            notes: "Planned browser-like HTTPS fallback for restrictive networks once server certificates are provisioned.".to_string(),
        },
        ProtocolPackEntry {
            id: "hysteria2".to_string(),
            label: "Hysteria2".to_string(),
            status: "staged".to_string(),
            engine: "sing-box".to_string(),
            scheme: "hysteria2".to_string(),
            network: "udp".to_string(),
            port: HYSTERIA2_FALLBACK_PORT,
            notes: "Planned high-performance UDP fallback for networks where direct WireGuard is unstable.".to_string(),
        },
    ]);

    if transport.trim() == "vk-turn-proxy+xray" {
        entries[0].status = "staged".to_string();
        entries[1].status = "active".to_string();
    }

    entries
}

fn staged_fallback_present(staged_fallbacks: Option<&Value>, key: &str) -> bool {
    staged_fallbacks
        .and_then(|value| value.get(key))
        .and_then(Value::as_object)
        .is_some()
}

fn fallback_port_from_value(raw: Option<&Value>, key: &str, fallback: u16) -> u16 {
    raw.and_then(|entry| entry.get(key))
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .unwrap_or(fallback)
}

fn normalize_package_list(packages: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = Vec::new();
    for package in packages {
        let value = package.trim();
        if value.is_empty() {
            continue;
        }
        if seen.insert(value.to_string()) {
            normalized.push(value.to_string());
        }
    }
    normalized
}

fn apply_exclude_packages_to_request(request: &mut Value, exclude_packages: &[String]) {
    if let Some(object) = request.as_object_mut() {
        if exclude_packages.is_empty() {
            object.remove("excludePackages");
        } else {
            object.insert("excludePackages".to_string(), json!(exclude_packages));
        }
    }
}

fn resolve_android_runtime_request(
    app: &AppHandle,
    payload: &LocalTunnelStartPayload,
) -> Result<Value, String> {
    let host = payload.server.host.trim();
    if host.is_empty() {
        return Err("host is required".to_string());
    }

    let exclude_packages = normalize_package_list(&payload.exclude_packages);
    let transport = requested_transport(&payload.server);
    let protocol = requested_protocol(&payload.server);
    let engine = requested_engine(transport, protocol);
    let use_reality_start_endpoint = transport == "xray" && protocol == "vless-reality";
    let owner_runtime_lab = requested_owner_runtime_lab(payload);
    let runtime_family = requested_runtime_family(payload);
    let activation_state = requested_activation_state(payload);

    if payload.secret.trim().is_empty() {
        if let Ok((invite, local_path)) =
            find_imported_invite_for_runtime(app, host, Some((transport, protocol)))
        {
            if !invite_supports_requested_runtime(&invite, transport, protocol) {
                return Err(imported_runtime_support_error(
                    &invite, host, transport, protocol,
                ));
            }
            let mut raw_json = fs::read_to_string(&local_path)
                .map_err(|err| format!("read imported profile: {err}"))?;
            if let Some(owner_runtime_lab) = owner_runtime_lab {
                raw_json = apply_owner_runtime_lab_overrides(&raw_json, owner_runtime_lab)?;
            }
            raw_json = apply_vk_turn_stream_count_override(
                &raw_json,
                requested_vk_turn_stream_count(&payload.server),
            )?;
            let mut request = json!({
                "serverHost": host,
                "transport": transport,
                "engine": engine,
                "protocol": protocol,
                "vkLink": payload.vk_link.trim(),
                "vkTurnStreamCount": requested_vk_turn_stream_count(&payload.server),
                "profileJson": raw_json,
                "profileSource": "imported",
                "useRealityStartEndpoint": use_reality_start_endpoint
            });
            if let Some(runtime_family) = runtime_family {
                request["runtimeFamily"] = json!(runtime_family);
            }
            if let Some(activation_state) = activation_state {
                request["activationState"] = json!(activation_state);
            }
            apply_exclude_packages_to_request(&mut request, &exclude_packages);
            return Ok(request);
        }
    }

    let owner_path = owner_profile_path(app, host)?;
    if !owner_path.exists() {
        if owner_runtime_lab.is_none() && payload.secret.trim().is_empty() {
            return Err(format!(
                "no local imported access key found for host {host:?}"
            ));
        }
        return Err(format!(
            "no local owner profile found for host {host:?}; deploy or refresh the owner profile first"
        ));
    }

    let mut raw_json =
        fs::read_to_string(&owner_path).map_err(|err| format!("read owner profile: {err}"))?;
    if let Some(owner_runtime_lab) = owner_runtime_lab {
        raw_json = apply_owner_runtime_lab_overrides(&raw_json, owner_runtime_lab)?;
    }
    raw_json = apply_vk_turn_stream_count_override(
        &raw_json,
        requested_vk_turn_stream_count(&payload.server),
    )?;
    let owner: OwnerProfileFile =
        serde_json::from_str(&raw_json).map_err(|err| format!("parse owner profile: {err}"))?;
    if !owner_supports_requested_runtime(&owner, transport, protocol) {
        return Err(format!(
            "the owner profile for {host} does not support {protocol}"
        ));
    }

    let mut request = json!({
        "serverHost": host,
        "transport": transport,
        "engine": engine,
        "protocol": protocol,
        "vkLink": payload.vk_link.trim(),
        "vkTurnStreamCount": requested_vk_turn_stream_count(&payload.server),
        "profileJson": raw_json,
        "profileSource": "owner",
        "useRealityStartEndpoint": use_reality_start_endpoint
    });
    if let Some(runtime_family) = runtime_family {
        request["runtimeFamily"] = json!(runtime_family);
    }
    if let Some(activation_state) = activation_state {
        request["activationState"] = json!(activation_state);
    }
    apply_exclude_packages_to_request(&mut request, &exclude_packages);
    Ok(request)
}

fn requested_owner_runtime_lab(
    payload: &LocalTunnelStartPayload,
) -> Option<&OwnerRuntimeLabPayload> {
    payload.owner_runtime_lab.as_ref().filter(|runtime_lab| {
        matches!(
            runtime_lab.mode.trim(),
            OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD
                | OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB
                | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD
                | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB
                | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB
                | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
        )
    })
}

fn requested_runtime_family(payload: &LocalTunnelStartPayload) -> Option<&str> {
    let requested = payload.runtime_family.trim();
    if !requested.is_empty() {
        return match requested {
            "direct-reality"
            | "cdn-anti-whitelist"
            | "reality-vps-lab"
            | "reality-whitelist-assisted"
            | "vk-relay" => Some(requested),
            _ => None,
        };
    }

    match payload
        .owner_runtime_lab
        .as_ref()
        .map(|runtime_lab| runtime_lab.mode.trim())
        .unwrap_or_default()
    {
        OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => Some("cdn-anti-whitelist"),
        OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
        | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD
        | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB
        | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB => Some("reality-vps-lab"),
        OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD
        | OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB => Some("reality-whitelist-assisted"),
        _ => None,
    }
}

fn requested_activation_state(payload: &LocalTunnelStartPayload) -> Option<&str> {
    match payload.activation_state.trim() {
        "active" | "scaffold_only" => Some(payload.activation_state.trim()),
        _ => None,
    }
}

fn apply_yandex_edge_reality_preset(
    profile_object: &mut serde_json::Map<String, Value>,
) -> Result<(), String> {
    let fallback = resolve_yandex_edge_fallback(profile_object);
    let proxy_fallback = resolve_yandex_edge_proxy_fallback(profile_object);
    let staged_fallbacks = ensure_object_value(
        profile_object
            .entry("stagedFallbacks")
            .or_insert_with(|| json!({})),
        "stagedFallbacks",
    )?;
    staged_fallbacks.insert("realityYandexEdge".to_string(), fallback);
    staged_fallbacks.insert("realityYandexEdgeProxy".to_string(), proxy_fallback);
    Ok(())
}

fn yandex_edge_string_field(
    fallback: Option<&serde_json::Map<String, Value>>,
    key: &str,
    default: &str,
) -> String {
    fallback
        .and_then(|value| value.get(key))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(default)
        .to_string()
}

fn yandex_edge_u16_field(
    fallback: Option<&serde_json::Map<String, Value>>,
    key: &str,
    default: u16,
) -> u16 {
    fallback
        .and_then(|value| value.get(key))
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn resolve_yandex_edge_fallback(profile_object: &serde_json::Map<String, Value>) -> Value {
    let staged_fallbacks = profile_object
        .get("stagedFallbacks")
        .and_then(Value::as_object);
    let direct_reality = staged_fallbacks
        .and_then(|value| value.get("vlessReality"))
        .and_then(Value::as_object)
        .or_else(|| {
            profile_object
                .get("vlessReality")
                .and_then(Value::as_object)
        });
    let existing_edge = staged_fallbacks
        .and_then(|value| value.get("realityYandexEdge"))
        .and_then(Value::as_object);
    let origin_host = yandex_edge_string_field(
        existing_edge,
        "originHost",
        profile_object
            .get("serverHost")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(YANDEX_EDGE_ORIGIN_HOST),
    );
    let origin_port = existing_edge
        .and_then(|value| value.get("originPort"))
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| *value > 0)
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("port"))
                .and_then(Value::as_u64)
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| *value > 0)
        })
        .unwrap_or(YANDEX_EDGE_ORIGIN_PORT);
    let server_name = existing_edge
        .and_then(|value| value.get("serverName"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("serverName"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or(YANDEX_EDGE_SERVER_NAME);
    let public_key = existing_edge
        .and_then(|value| value.get("publicKey"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("publicKey"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or(YANDEX_EDGE_PUBLIC_KEY);
    let short_id = existing_edge
        .and_then(|value| value.get("shortId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("shortId"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or(YANDEX_EDGE_SHORT_ID);
    let uuid = existing_edge
        .and_then(|value| value.get("uuid"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("uuid"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or(YANDEX_EDGE_UUID);
    let flow = existing_edge
        .and_then(|value| value.get("flow"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            direct_reality
                .and_then(|value| value.get("flow"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or(YANDEX_EDGE_FLOW);
    let fingerprint =
        yandex_edge_string_field(existing_edge, "fingerprint", YANDEX_EDGE_FINGERPRINT);
    let source = yandex_edge_string_field(existing_edge, "source", YANDEX_EDGE_SOURCE);
    let tag = yandex_edge_string_field(existing_edge, "tag", YANDEX_EDGE_TAG);
    let routing_mode =
        yandex_edge_string_field(existing_edge, "routingMode", EDGE_ROUTING_MODE_DEFAULT);
    let connect_host =
        yandex_edge_string_field(existing_edge, "connectHost", YANDEX_EDGE_CONNECT_HOST);
    let connect_port =
        yandex_edge_u16_field(existing_edge, "connectPort", YANDEX_EDGE_CONNECT_PORT);

    yandex_edge_fallback_value_for(
        &connect_host,
        connect_port,
        &origin_host,
        origin_port,
        server_name,
        public_key,
        short_id,
        uuid,
        flow,
        &fingerprint,
        &source,
        &tag,
        &routing_mode,
    )
}

fn resolve_yandex_edge_proxy_fallback(profile_object: &serde_json::Map<String, Value>) -> Value {
    let staged_fallbacks = profile_object
        .get("stagedFallbacks")
        .and_then(Value::as_object);
    if let Some(existing_proxy) = staged_fallbacks
        .and_then(|value| value.get("realityYandexEdgeProxy"))
        .and_then(Value::as_object)
    {
        return Value::Object(existing_proxy.clone());
    }
    let edge = resolve_yandex_edge_fallback(profile_object);
    yandex_edge_proxy_fallback_value_from_edge(&edge)
}

fn apply_owner_runtime_lab_overrides(
    raw_json: &str,
    owner_runtime_lab: &OwnerRuntimeLabPayload,
) -> Result<String, String> {
    let mut profile: Value =
        serde_json::from_str(raw_json).map_err(|err| format!("parse owner profile json: {err}"))?;
    let (bootstrap_server_host, bootstrap_reality) = {
        let profile_object = ensure_object_value(&mut profile, "owner profile")?;
        let bootstrap_server_host = profile_object
            .get("serverHost")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or_default()
            .to_string();
        let bootstrap_reality = profile_object
            .get("stagedFallbacks")
            .and_then(Value::as_object)
            .and_then(|value| value.get("vlessReality"))
            .and_then(Value::as_object)
            .cloned()
            .or_else(|| {
                profile_object
                    .get("vlessReality")
                    .and_then(Value::as_object)
                    .cloned()
            });
        if matches!(
            owner_runtime_lab.mode.trim(),
            OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
        ) {
            apply_yandex_edge_reality_preset(profile_object)?;
        }
        (bootstrap_server_host, bootstrap_reality)
    };
    if matches!(
        owner_runtime_lab.mode.trim(),
        OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
            | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
    ) {
        sync_owner_android_runtime_in_value(&mut profile)?;
    }
    let profile_object = ensure_object_value(&mut profile, "owner profile")?;
    let yandex_edge_reality = profile_object
        .get("stagedFallbacks")
        .and_then(Value::as_object)
        .and_then(|value| value.get("realityYandexEdge"))
        .and_then(Value::as_object)
        .cloned();
    let yandex_edge_proxy_reality = profile_object
        .get("stagedFallbacks")
        .and_then(Value::as_object)
        .and_then(|value| value.get("realityYandexEdgeProxy"))
        .and_then(Value::as_object)
        .cloned();
    let android_runtime = ensure_object_value(
        profile_object
            .entry("androidRuntime")
            .or_insert_with(|| json!({})),
        "androidRuntime",
    )?;
    let reality = ensure_object_value(
        android_runtime
            .entry("reality")
            .or_insert_with(|| json!({})),
        "androidRuntime.reality",
    )?;
    reality.insert("mode".to_string(), Value::String("stable".to_string()));

    match owner_runtime_lab.mode.trim() {
        OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD
        | OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB => {
            let hint_server_name = owner_runtime_lab
                .hint_server_name
                .trim()
                .to_ascii_lowercase();
            if hint_server_name.is_empty() {
                return Err("owner runtime lab requires hintServerName".to_string());
            }

            let hint_source = if owner_runtime_lab.hint_source.trim().is_empty() {
                "operator-curated".to_string()
            } else {
                owner_runtime_lab.hint_source.trim().to_string()
            };
            let hint_tag = if owner_runtime_lab.hint_tag.trim().is_empty() {
                format!("owner-lab-{hint_server_name}")
            } else {
                owner_runtime_lab.hint_tag.trim().to_string()
            };
            let cidr_bucket = owner_runtime_lab.hint_cidr_bucket.trim();
            let runtime_mode = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB => "lab",
                _ => "scaffold",
            };

            let whitelist_hints = ensure_object_value(
                android_runtime
                    .entry("realityWhitelistHints")
                    .or_insert_with(|| json!({})),
                "androidRuntime.realityWhitelistHints",
            )?;
            whitelist_hints.insert("enabled".to_string(), Value::Bool(true));
            whitelist_hints.insert("mode".to_string(), Value::String(runtime_mode.to_string()));
            whitelist_hints.insert(
                "selection".to_string(),
                Value::String("ordered".to_string()),
            );
            whitelist_hints.insert(
                "bootstrap".to_string(),
                Value::String("direct-reality".to_string()),
            );
            whitelist_hints.insert(
                "hints".to_string(),
                Value::Array(vec![Value::Object({
                    let mut hint = serde_json::Map::new();
                    hint.insert("serverName".to_string(), Value::String(hint_server_name));
                    hint.insert("source".to_string(), Value::String(hint_source));
                    hint.insert("tag".to_string(), Value::String(hint_tag));
                    if !cidr_bucket.is_empty() {
                        hint.insert(
                            "cidrBucket".to_string(),
                            Value::String(cidr_bucket.to_string()),
                        );
                    }
                    hint
                })]),
            );
            if let Some(existing) = android_runtime.get_mut("realityVpsLab") {
                if let Some(existing_object) = existing.as_object_mut() {
                    existing_object.insert("enabled".to_string(), Value::Bool(false));
                    if let Some(existing_relay_autoselect) = existing_object
                        .get_mut("relayAutoselect")
                        .and_then(Value::as_object_mut)
                    {
                        existing_relay_autoselect.insert("enabled".to_string(), Value::Bool(false));
                    }
                }
            }
        }
        OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD
        | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB
        | OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB
        | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
        | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => {
            let server_name = owner_runtime_lab
                .vps_server_name
                .trim()
                .to_ascii_lowercase();
            if server_name.is_empty()
                && !matches!(
                    owner_runtime_lab.mode.trim(),
                    OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                        | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                )
            {
                return Err("owner runtime lab requires vpsServerName".to_string());
            }
            if owner_runtime_lab.vps_port == 0
                && !matches!(
                    owner_runtime_lab.mode.trim(),
                    OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                        | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                )
            {
                return Err("owner runtime lab requires a positive vpsPort".to_string());
            }
            let transport = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => {
                    OWNER_RUNTIME_LAB_VPS_TRANSPORT_TCP
                }
                _ => match owner_runtime_lab.vps_transport.trim() {
                    OWNER_RUNTIME_LAB_VPS_TRANSPORT_TCP => OWNER_RUNTIME_LAB_VPS_TRANSPORT_TCP,
                    OWNER_RUNTIME_LAB_VPS_TRANSPORT_GRPC => OWNER_RUNTIME_LAB_VPS_TRANSPORT_GRPC,
                    _ => {
                        return Err(
                            "owner runtime lab requires vpsTransport to be tcp or grpc".to_string()
                        )
                    }
                },
            };
            let runtime_mode = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB => "lab",
                OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB => "lab",
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => "lab",
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => "lab",
                _ => "scaffold",
            };
            let source = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => yandex_edge_string_field(
                    yandex_edge_reality.as_ref(),
                    "source",
                    YANDEX_EDGE_SOURCE,
                ),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => yandex_edge_string_field(
                    yandex_edge_proxy_reality.as_ref(),
                    "source",
                    "owner-attached:yandex-edge-proxy",
                ),
                _ if owner_runtime_lab.vps_source.trim().is_empty() => {
                    "operator-curated:vps-lab".to_string()
                }
                _ => owner_runtime_lab.vps_source.trim().to_string(),
            };
            let tag = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => {
                    yandex_edge_string_field(yandex_edge_reality.as_ref(), "tag", YANDEX_EDGE_TAG)
                }
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => yandex_edge_string_field(
                    yandex_edge_proxy_reality.as_ref(),
                    "tag",
                    "yandex-edge-proxy",
                ),
                _ if owner_runtime_lab.vps_tag.trim().is_empty() => {
                    format!(
                        "owner-vps-lab-{server_name}-{transport}-{}",
                        owner_runtime_lab.vps_port
                    )
                }
                _ => owner_runtime_lab.vps_tag.trim().to_string(),
            };
            let fingerprint = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => yandex_edge_string_field(
                    yandex_edge_reality.as_ref(),
                    "fingerprint",
                    YANDEX_EDGE_FINGERPRINT,
                ),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => yandex_edge_string_field(
                    yandex_edge_proxy_reality.as_ref(),
                    "fingerprint",
                    YANDEX_EDGE_FINGERPRINT,
                ),
                _ if owner_runtime_lab.vps_fingerprint.trim().is_empty() => {
                    if transport == OWNER_RUNTIME_LAB_VPS_TRANSPORT_GRPC {
                        "firefox".to_string()
                    } else {
                        "chrome".to_string()
                    }
                }
                _ => owner_runtime_lab.vps_fingerprint.trim().to_string(),
            };
            let force_relay_owner_mode = matches!(
                owner_runtime_lab.mode.trim(),
                OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB
            );
            let connect_host = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => Some(yandex_edge_string_field(
                    yandex_edge_reality.as_ref(),
                    "connectHost",
                    YANDEX_EDGE_CONNECT_HOST,
                )),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => Some(yandex_edge_string_field(
                    yandex_edge_proxy_reality.as_ref(),
                    "connectHost",
                    YANDEX_EDGE_CONNECT_HOST,
                )),
                _ => {
                    let value = owner_runtime_lab.vps_connect_host.trim();
                    if value.is_empty() {
                        None
                    } else {
                        Some(value.to_string())
                    }
                }
            };
            let connect_port = match owner_runtime_lab.mode.trim() {
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE => Some(yandex_edge_u16_field(
                    yandex_edge_reality.as_ref(),
                    "connectPort",
                    YANDEX_EDGE_CONNECT_PORT,
                )),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY => Some(yandex_edge_u16_field(
                    yandex_edge_proxy_reality.as_ref(),
                    "connectPort",
                    YANDEX_EDGE_CONNECT_PORT,
                )),
                _ if owner_runtime_lab.vps_connect_port > 0 => {
                    Some(owner_runtime_lab.vps_connect_port)
                }
                _ => None,
            };
            let server_name = if matches!(
                owner_runtime_lab.mode.trim(),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                    | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
            ) {
                normalized_yandex_edge_server_name_override(&owner_runtime_lab.edge_server_name)
                    .unwrap_or_else(|| {
                        yandex_edge_string_field(
                    if owner_runtime_lab.mode.trim()
                        == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                    {
                        yandex_edge_proxy_reality.as_ref()
                    } else {
                        yandex_edge_reality.as_ref()
                    },
                    "serverName",
                    YANDEX_EDGE_SERVER_NAME,
                )
                    })
            } else {
                server_name
            };
            let vps_port = if matches!(
                owner_runtime_lab.mode.trim(),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                    | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
            ) {
                yandex_edge_u16_field(
                    if owner_runtime_lab.mode.trim()
                        == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                    {
                        yandex_edge_proxy_reality.as_ref()
                    } else {
                        yandex_edge_reality.as_ref()
                    },
                    "originPort",
                    bootstrap_reality
                        .as_ref()
                        .and_then(|value| value.get("port"))
                        .and_then(Value::as_u64)
                        .and_then(|value| u16::try_from(value).ok())
                        .filter(|value| *value > 0)
                        .unwrap_or(YANDEX_EDGE_ORIGIN_PORT),
                )
            } else {
                owner_runtime_lab.vps_port
            };
            let vps_lab = ensure_object_value(
                android_runtime
                    .entry("realityVpsLab")
                    .or_insert_with(|| json!({})),
                "androidRuntime.realityVpsLab",
            )?;
            let proxy_mode =
                owner_runtime_lab.mode.trim() == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY;
            if proxy_mode {
                vps_lab.insert("enabled".to_string(), Value::Bool(false));
                let relay_autoselect = ensure_object_value(
                    vps_lab
                        .entry("relayAutoselect")
                        .or_insert_with(|| json!({})),
                    "androidRuntime.realityVpsLab.relayAutoselect",
                )?;
                relay_autoselect.insert("enabled".to_string(), Value::Bool(false));
                sync_owner_android_runtime_in_value(&mut profile)?;
                return serde_json::to_string(&profile)
                    .map_err(|err| format!("serialize owner profile json: {err}"));
            }
            vps_lab.insert(
                "ownerRealityEgress".to_string(),
                Value::Bool(force_relay_owner_mode || owner_runtime_lab.vps_owner_reality_egress),
            );
            if matches!(
                owner_runtime_lab.mode.trim(),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                    | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
            ) {
                let bootstrap = ensure_object_value(
                    vps_lab
                        .entry("ownerRealityBootstrap")
                        .or_insert_with(|| json!({})),
                    "androidRuntime.realityVpsLab.ownerRealityBootstrap",
                )?;
                bootstrap.insert(
                    "serverHost".to_string(),
                    Value::String(yandex_edge_string_field(
                        if owner_runtime_lab.mode.trim()
                            == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                        {
                            yandex_edge_proxy_reality.as_ref()
                        } else {
                            yandex_edge_reality.as_ref()
                        },
                        "originHost",
                        if bootstrap_server_host.is_empty() {
                            YANDEX_EDGE_ORIGIN_HOST
                        } else {
                            &bootstrap_server_host
                        },
                    )),
                );
                bootstrap.insert(
                    "port".to_string(),
                    Value::Number(serde_json::Number::from(vps_port)),
                );
                bootstrap.insert(
                    "uuid".to_string(),
                    Value::String(yandex_edge_string_field(
                        if owner_runtime_lab.mode.trim()
                            == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                        {
                            yandex_edge_proxy_reality.as_ref()
                        } else {
                            yandex_edge_reality.as_ref()
                        },
                        "uuid",
                        YANDEX_EDGE_UUID,
                    )),
                );
                bootstrap.insert(
                    "flow".to_string(),
                    Value::String(yandex_edge_string_field(
                        if owner_runtime_lab.mode.trim()
                            == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                        {
                            yandex_edge_proxy_reality.as_ref()
                        } else {
                            yandex_edge_reality.as_ref()
                        },
                        "flow",
                        YANDEX_EDGE_FLOW,
                    )),
                );
                bootstrap.insert("serverName".to_string(), Value::String(server_name.clone()));
                bootstrap.insert(
                    "publicKey".to_string(),
                    Value::String(yandex_edge_string_field(
                        if owner_runtime_lab.mode.trim()
                            == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                        {
                            yandex_edge_proxy_reality.as_ref()
                        } else {
                            yandex_edge_reality.as_ref()
                        },
                        "publicKey",
                        YANDEX_EDGE_PUBLIC_KEY,
                    )),
                );
                bootstrap.insert(
                    "shortId".to_string(),
                    Value::String(yandex_edge_string_field(
                        if owner_runtime_lab.mode.trim()
                            == OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
                        {
                            yandex_edge_proxy_reality.as_ref()
                        } else {
                            yandex_edge_reality.as_ref()
                        },
                        "shortId",
                        YANDEX_EDGE_SHORT_ID,
                    )),
                );
            } else if let Some(bootstrap_reality) = bootstrap_reality.as_ref() {
                let bootstrap = ensure_object_value(
                    vps_lab
                        .entry("ownerRealityBootstrap")
                        .or_insert_with(|| json!({})),
                    "androidRuntime.realityVpsLab.ownerRealityBootstrap",
                )?;
                if !bootstrap_server_host.is_empty() {
                    bootstrap.insert(
                        "serverHost".to_string(),
                        Value::String(bootstrap_server_host),
                    );
                }
                if let Some(port) = bootstrap_reality.get("port").and_then(Value::as_u64) {
                    bootstrap.insert(
                        "port".to_string(),
                        Value::Number(serde_json::Number::from(port)),
                    );
                }
                for key in ["uuid", "flow", "serverName", "publicKey", "shortId"] {
                    if let Some(value) = bootstrap_reality
                        .get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                    {
                        bootstrap.insert(key.to_string(), Value::String(value.to_string()));
                    }
                }
            }
            vps_lab.insert("enabled".to_string(), Value::Bool(true));
            vps_lab.insert("mode".to_string(), Value::String(runtime_mode.to_string()));
            vps_lab.insert("serverName".to_string(), Value::String(server_name));
            vps_lab.insert(
                "port".to_string(),
                Value::Number(serde_json::Number::from(vps_port)),
            );
            if let Some(connect_host) = connect_host.filter(|value| !value.trim().is_empty()) {
                vps_lab.insert("connectHost".to_string(), Value::String(connect_host));
            }
            if let Some(connect_port) = connect_port {
                vps_lab.insert(
                    "connectPort".to_string(),
                    Value::Number(serde_json::Number::from(connect_port)),
                );
            }
            vps_lab.insert(
                "transport".to_string(),
                Value::String(transport.to_string()),
            );
            vps_lab.insert("source".to_string(), Value::String(source));
            vps_lab.insert("tag".to_string(), Value::String(tag));
            vps_lab.insert("fingerprint".to_string(), Value::String(fingerprint));
            if matches!(
                owner_runtime_lab.mode.trim(),
                OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE
                    | OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY
            ) {
                vps_lab.insert(
                    "flow".to_string(),
                    Value::String(YANDEX_EDGE_FLOW.to_string()),
                );
            } else if !owner_runtime_lab.vps_flow.trim().is_empty() {
                vps_lab.insert(
                    "flow".to_string(),
                    Value::String(owner_runtime_lab.vps_flow.trim().to_string()),
                );
            }
            if !owner_runtime_lab.vps_grpc_service_name.trim().is_empty() {
                vps_lab.insert(
                    "grpcServiceName".to_string(),
                    Value::String(owner_runtime_lab.vps_grpc_service_name.trim().to_string()),
                );
            }
            if !owner_runtime_lab.vps_grpc_authority.trim().is_empty() {
                vps_lab.insert(
                    "grpcAuthority".to_string(),
                    Value::String(owner_runtime_lab.vps_grpc_authority.trim().to_string()),
                );
            }
            let relay_autoselect_enabled = if force_relay_owner_mode {
                true
            } else {
                owner_runtime_lab
                    .vps_relay_autoselect
                    .as_ref()
                    .map(|value| value.enabled)
                    .unwrap_or(false)
            };
            let relay_autoselect = ensure_object_value(
                vps_lab
                    .entry("relayAutoselect")
                    .or_insert_with(|| json!({})),
                "androidRuntime.realityVpsLab.relayAutoselect",
            )?;
            if relay_autoselect_enabled {
                let relay_options = owner_runtime_lab.vps_relay_autoselect.as_ref();
                let subscription_url = if relay_options
                    .map(|value| value.subscription_url.trim())
                    .unwrap_or_default()
                    .is_empty()
                {
                    OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL.to_string()
                } else {
                    relay_options
                        .map(|value| value.subscription_url.trim().to_string())
                        .unwrap_or_else(|| {
                            OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL.to_string()
                        })
                };
                let source_label = if relay_options
                    .map(|value| value.source_label.trim())
                    .unwrap_or_default()
                    .is_empty()
                {
                    OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL.to_string()
                } else {
                    relay_options
                        .map(|value| value.source_label.trim().to_string())
                        .unwrap_or_else(|| {
                            OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL.to_string()
                        })
                };
                relay_autoselect.insert("enabled".to_string(), Value::Bool(true));
                relay_autoselect.insert(
                    "subscriptionUrl".to_string(),
                    Value::String(subscription_url),
                );
                relay_autoselect.insert("sourceLabel".to_string(), Value::String(source_label));
                relay_autoselect.insert(
                    "refreshIntervalHours".to_string(),
                    Value::Number(serde_json::Number::from(
                        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS,
                    )),
                );
                relay_autoselect.insert(
                    "russianLatencyThresholdMs".to_string(),
                    Value::Number(serde_json::Number::from(
                        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_THRESHOLD_MS,
                    )),
                );
                relay_autoselect.insert(
                    "latencyTimeoutMs".to_string(),
                    Value::Number(serde_json::Number::from(
                        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_TIMEOUT_MS,
                    )),
                );
                relay_autoselect.insert(
                    "candidateLimit".to_string(),
                    Value::Number(serde_json::Number::from(
                        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_CANDIDATE_LIMIT,
                    )),
                );
                relay_autoselect.insert(
                    "maxPerSni".to_string(),
                    Value::Number(serde_json::Number::from(
                        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_MAX_PER_SNI,
                    )),
                );
            } else {
                relay_autoselect.insert("enabled".to_string(), Value::Bool(false));
            }
            if let Some(existing) = android_runtime.get_mut("realityWhitelistHints") {
                if let Some(existing_object) = existing.as_object_mut() {
                    existing_object.insert("enabled".to_string(), Value::Bool(false));
                }
            }
        }
        _ => {
            return Err("unsupported owner runtime lab mode".to_string());
        }
    }

    serde_json::to_string(&profile)
        .map_err(|err| format!("serialize owner runtime lab profile: {err}"))
}

fn apply_vk_turn_stream_count_override(
    raw_json: &str,
    requested_stream_count: Option<u16>,
) -> Result<String, String> {
    let mut profile: Value = serde_json::from_str(raw_json)
        .map_err(|err| format!("parse access profile json: {err}"))?;
    let profile_object = ensure_object_value(&mut profile, "access profile")?;
    let stream_count = requested_stream_count.unwrap_or_else(|| {
        profile_object
            .get("vkTurnStreamCount")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .map(effective_vk_turn_stream_count)
            .unwrap_or(VK_TURN_STREAM_COUNT_DEFAULT)
    });
    profile_object.insert("vkTurnStreamCount".to_string(), json!(stream_count));
    serde_json::to_string_pretty(&profile).map_err(|err| format!("marshal access profile: {err}"))
}

fn ensure_object_value<'a>(
    value: &'a mut Value,
    label: &str,
) -> Result<&'a mut serde_json::Map<String, Value>, String> {
    if value.is_null() {
        *value = json!({});
    }
    value
        .as_object_mut()
        .ok_or_else(|| format!("{label} must be a JSON object"))
}

fn ensure_reality_relay_owner_egress_fallback(staged_fallbacks: &mut Value) {
    if staged_fallbacks.is_null() {
        *staged_fallbacks = json!({});
    }
    let Some(staged_object) = staged_fallbacks.as_object_mut() else {
        return;
    };
    if staged_object.contains_key("realityRelayOwnerEgress") {
        return;
    }
    staged_object.insert(
        "realityRelayOwnerEgress".to_string(),
        json!({
            "status": "ready",
            "ownerEgressPort": REALITY_FALLBACK_MIN_PORT,
            "subscriptionUrl": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL,
            "sourceLabel": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL,
            "description": "Experimental relay-assisted REALITY mode. The client picks a curated external REALITY relay first, then moves egress back to your Odin's Cat server."
        }),
    );
}

fn ensure_reality_relay_direct_fallback(staged_fallbacks: &mut Value) {
    if staged_fallbacks.is_null() {
        *staged_fallbacks = json!({});
    }
    let Some(staged_object) = staged_fallbacks.as_object_mut() else {
        return;
    };
    if staged_object.contains_key("realityRelayDirect") {
        return;
    }
    staged_object.insert(
        "realityRelayDirect".to_string(),
        json!({
            "status": "ready",
            "subscriptionUrl": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL,
            "sourceLabel": OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL,
            "description": "Experimental direct relay mode. The client picks a curated external REALITY relay from the hourly igareck feed and sends traffic through it without a second hop to your Odin's Cat server."
        }),
    );
}

fn yandex_edge_fallback_value_for(
    connect_host: &str,
    connect_port: u16,
    origin_host: &str,
    origin_port: u16,
    server_name: &str,
    public_key: &str,
    short_id: &str,
    uuid: &str,
    flow: &str,
    fingerprint: &str,
    source: &str,
    tag: &str,
    routing_mode: &str,
) -> Value {
    json!({
        "status": "ready",
        "connectHost": connect_host,
        "connectPort": connect_port,
        "originHost": origin_host,
        "originPort": origin_port,
        "serverName": server_name,
        "publicKey": public_key,
        "shortId": short_id,
        "uuid": uuid,
        "flow": flow,
        "fingerprint": fingerprint,
        "source": source,
        "tag": tag,
        "routingMode": routing_mode,
        "description": yandex_edge_entry_description(routing_mode)
    })
}

fn yandex_edge_proxy_fallback_value_from_edge(edge: &Value) -> Value {
    let edge_object = edge.as_object();
    let source = yandex_edge_string_field(edge_object, "source", YANDEX_EDGE_SOURCE);
    let source = if source.ends_with(":proxy") {
        source
    } else {
        format!("{source}:proxy")
    };
    let tag = yandex_edge_string_field(edge_object, "tag", YANDEX_EDGE_TAG);
    let tag = if tag.ends_with("-proxy") {
        tag
    } else {
        format!("{tag}-proxy")
    };
    json!({
        "status": "ready",
        "connectHost": yandex_edge_string_field(edge_object, "connectHost", YANDEX_EDGE_CONNECT_HOST),
        "connectPort": yandex_edge_u16_field(edge_object, "connectPort", YANDEX_EDGE_CONNECT_PORT),
        "originHost": yandex_edge_string_field(edge_object, "originHost", YANDEX_EDGE_ORIGIN_HOST),
        "originPort": yandex_edge_u16_field(edge_object, "originPort", YANDEX_EDGE_ORIGIN_PORT),
        "serverName": yandex_edge_string_field(edge_object, "serverName", YANDEX_EDGE_SERVER_NAME),
        "publicKey": yandex_edge_string_field(edge_object, "publicKey", YANDEX_EDGE_PUBLIC_KEY),
        "shortId": yandex_edge_string_field(edge_object, "shortId", YANDEX_EDGE_SHORT_ID),
        "uuid": yandex_edge_string_field(edge_object, "uuid", YANDEX_EDGE_UUID),
        "flow": yandex_edge_string_field(edge_object, "flow", YANDEX_EDGE_FLOW),
        "fingerprint": yandex_edge_string_field(edge_object, "fingerprint", YANDEX_EDGE_FINGERPRINT),
        "source": source,
        "tag": tag,
        "routingMode": yandex_edge_string_field(edge_object, "routingMode", EDGE_ROUTING_MODE_DEFAULT),
        "transport": if yandex_edge_string_field(edge_object, "routingMode", EDGE_ROUTING_MODE_DEFAULT) == EDGE_ROUTING_MODE_XRAY_PROXY {
            YANDEX_EDGE_CDN_TRANSPORT
        } else {
            "tcp"
        },
        "ownerRealityEgress": false,
        "description": yandex_edge_proxy_description(&yandex_edge_string_field(edge_object, "routingMode", EDGE_ROUTING_MODE_DEFAULT))
    })
}

#[cfg(test)]
fn curated_yandex_edge_fallback_value() -> Value {
    yandex_edge_fallback_value_for(
        YANDEX_EDGE_CONNECT_HOST,
        YANDEX_EDGE_CONNECT_PORT,
        YANDEX_EDGE_ORIGIN_HOST,
        YANDEX_EDGE_ORIGIN_PORT,
        YANDEX_EDGE_SERVER_NAME,
        YANDEX_EDGE_PUBLIC_KEY,
        YANDEX_EDGE_SHORT_ID,
        YANDEX_EDGE_UUID,
        YANDEX_EDGE_FLOW,
        YANDEX_EDGE_FINGERPRINT,
        YANDEX_EDGE_SOURCE,
        YANDEX_EDGE_TAG,
        EDGE_ROUTING_MODE_DEFAULT,
    )
}

fn upsert_yandex_edge_fallback(staged_fallbacks: &mut Value, fallback: Value) {
    if staged_fallbacks.is_null() {
        *staged_fallbacks = json!({});
    }
    let Some(staged_object) = staged_fallbacks.as_object_mut() else {
        return;
    };
    let proxy_fallback = yandex_edge_proxy_fallback_value_from_edge(&fallback);
    staged_object.insert("realityYandexEdge".to_string(), fallback);
    staged_object.insert("realityYandexEdgeProxy".to_string(), proxy_fallback);
}

fn requested_transport(server: &ServerDraftPayload) -> &str {
    if server.transport.trim() == "vk-turn-proxy+xray" {
        "vk-turn-proxy+xray"
    } else {
        "xray"
    }
}

fn requested_protocol(server: &ServerDraftPayload) -> &str {
    if requested_transport(server) == "vk-turn-proxy+xray" {
        "direct-wireguard"
    } else if server.protocol.as_deref().unwrap_or_default().trim() == "direct-wireguard" {
        "direct-wireguard"
    } else {
        "vless-reality"
    }
}

fn requested_engine<'a>(transport: &'a str, protocol: &'a str) -> &'a str {
    if transport == "xray" && protocol == "vless-reality" {
        "sing-box"
    } else {
        "xray"
    }
}

fn owner_supports_requested_runtime(
    owner: &OwnerProfileFile,
    transport: &str,
    protocol: &str,
) -> bool {
    match (transport, protocol) {
        ("xray", "vless-reality") => owner
            .staged_fallbacks
            .get("vlessReality")
            .and_then(Value::as_object)
            .is_some(),
        ("vk-turn-proxy+xray", _) => {
            owner.vk_turn_proxy_port > 0
                && !owner.wireguard.server_public_key.trim().is_empty()
                && !owner.wireguard.client_private_key.trim().is_empty()
                && !owner.wireguard.address.trim().is_empty()
        }
        _ => false,
    }
}

fn invite_supports_requested_runtime(
    invite: &InviteProfileFile,
    transport: &str,
    protocol: &str,
) -> bool {
    match (transport, protocol) {
        ("xray", "vless-reality") => invite_supports_reality(invite),
        ("vk-turn-proxy+xray", _) => invite_supports_vk_relay(invite),
        _ => false,
    }
}

fn imported_runtime_support_error(
    invite: &InviteProfileFile,
    host: &str,
    transport: &str,
    protocol: &str,
) -> String {
    match (transport, protocol) {
        ("vk-turn-proxy+xray", _) => {
            let mut missing = Vec::new();
            if invite.vk_turn_proxy_port == 0 {
                missing.push("vkTurnProxyPort");
            }
            if invite.wire_guard.server_public_key.trim().is_empty() {
                missing.push("wireguard.serverPublicKey");
            }
            if invite.wire_guard.client_private_key.trim().is_empty() {
                missing.push("wireguard.clientPrivateKey");
            }
            if invite.wire_guard.address.trim().is_empty() {
                missing.push("wireguard.address");
            }
            if missing.is_empty() {
                format!(
                    "the imported access key for {host} does not support {protocol}; re-import a fresh dual-mode invite key"
                )
            } else {
                format!(
                    "the imported access key for {host} does not support {protocol}; missing {}",
                    missing.join(", ")
                )
            }
        }
        _ => format!("the imported access key for {host} does not support {protocol}"),
    }
}

fn android_tunnel_state(
    server: &ServerDraftPayload,
    status: &str,
    error: Option<&str>,
    log_tail: Vec<String>,
    last_test: Option<Value>,
) -> Value {
    let mut state = json!({
        "status": status,
        "serverHost": server.host.trim(),
        "transport": requested_transport(server),
        "engine": requested_engine(requested_transport(server), requested_protocol(server)),
        "protocol": requested_protocol(server),
        "logTail": log_tail
    });
    if let Some(error_text) = error.filter(|value| !value.trim().is_empty()) {
        state["error"] = json!(error_text);
    }
    if let Some(last_test_value) = last_test {
        state["lastTest"] = last_test_value;
    }
    state
}

fn build_plan_steps(flow: &str) -> Vec<PlanEntry> {
    if flow == PROVISION_FLOW_EDGE_ATTACH {
        return vec![
            PlanEntry {
                id: "origin-ssh-check".to_string(),
                label: "Origin validation".to_string(),
                status: "queued".to_string(),
                description:
                    "Load the live Odin's Cat origin profile and confirm the current REALITY port and keys."
                        .to_string(),
            },
            PlanEntry {
                id: "edge-ssh-check".to_string(),
                label: "Edge validation".to_string(),
                status: "queued".to_string(),
                description:
                    "Validate the Yandex edge host and confirm that privileged setup can run there."
                        .to_string(),
            },
            PlanEntry {
                id: "edge-runtime-prep".to_string(),
                label: "Edge preparation".to_string(),
                status: "queued".to_string(),
                description: "Prepare the selected edge runtime and write the manifest for the new Yandex edge surface."
                    .to_string(),
            },
            PlanEntry {
                id: "edge-configure".to_string(),
                label: "Edge wiring".to_string(),
                status: "queued".to_string(),
                description:
                    "Install the edge systemd service that exposes the current REALITY origin through the Yandex edge."
                        .to_string(),
            },
            PlanEntry {
                id: "edge-service-start".to_string(),
                label: "Edge startup".to_string(),
                status: "queued".to_string(),
                description:
                    "Start the selected edge service and verify that it can reach the current origin REALITY port."
                        .to_string(),
            },
            PlanEntry {
                id: "profile-refresh".to_string(),
                label: "Profile refresh".to_string(),
                status: "queued".to_string(),
                description:
                    "Patch the owner profile and protocol pack so the extra Yandex edge mode can be exported in a single invite key."
                        .to_string(),
            },
        ];
    }

    vec![
        PlanEntry {
            id: "ssh-check".to_string(),
            label: "SSH validation".to_string(),
            status: "queued".to_string(),
            description: "Validate credentials, remote OS, and the current server state."
                .to_string(),
        },
        PlanEntry {
            id: "runtime-prep".to_string(),
            label: "Runtime preparation".to_string(),
            status: "queued".to_string(),
            description:
                "Create isolated Odin's Cat directories and verify network prerequisites."
                    .to_string(),
        },
        PlanEntry {
            id: "install-binaries".to_string(),
            label: "Install binaries".to_string(),
            status: "queued".to_string(),
            description:
                "Install xray and upload the transport binaries required for this mode."
                    .to_string(),
        },
        PlanEntry {
            id: "configure-services".to_string(),
            label: "Configure services".to_string(),
            status: "queued".to_string(),
            description:
                "Generate keys, write xray and Odin's Cat configs, and install the required systemd units."
                    .to_string(),
        },
        PlanEntry {
            id: "service-start".to_string(),
            label: "Service startup".to_string(),
            status: "queued".to_string(),
            description: "Start the selected Odin's Cat services and verify their health."
                .to_string(),
        },
        PlanEntry {
            id: "egress-check".to_string(),
            label: "Egress health".to_string(),
            status: "queued".to_string(),
            description:
                "Verify that the server can resolve DNS and complete outbound HTTP and HTTPS probes."
                    .to_string(),
        },
    ]
}

fn build_plan_warnings(server: &ServerDraftPayload, flow: &str) -> Vec<String> {
    let mut warnings = vec![
        "Odin's Cat uses its own ports and paths so the existing Amnezia stack can remain untouched."
            .to_string(),
        "Odin's Cat keeps the stable direct REALITY path separate from additive access surfaces so stable mode can stay untouched while extra modes are attached later.".to_string(),
    ];

    if flow == PROVISION_FLOW_EDGE_ATTACH {
        warnings.push("The Yandex edge step is additive: it keeps the stable REALITY origin untouched while attaching a second whitelist-facing bridge host in front of it.".to_string());
        warnings.push("You should re-issue invite keys after the edge is attached so imported profiles receive the extra visible mode.".to_string());
        if server.yandex_edge_origin_port.unwrap_or_default() > 0 {
            warnings.push(format!(
                "Manual Yandex edge origin xHTTP port {} is requested. Edge attach will fail if that TCP port is already busy on the VPS.",
                describe_manual_port(server.yandex_edge_origin_port, "auto/tcp")
            ));
        } else {
            warnings.push("The Yandex edge origin xHTTP port is auto-selected from currently free TCP ports on the VPS unless you pin it manually.".to_string());
        }
        return warnings;
    }

    if server.vk_turn_proxy_port.unwrap_or_default() > 0
        || server.reality_port.unwrap_or_default() > 0
        || server.yandex_edge_origin_port.unwrap_or_default() > 0
    {
        warnings.push(format!(
            "Manual public ports are requested: VK relay {}, REALITY {}, and Yandex edge origin xHTTP {}. Deploy will fail if any requested port is already busy on the server.",
            describe_manual_port(server.vk_turn_proxy_port, "auto/udp"),
            describe_manual_port(server.reality_port, "auto/tcp"),
            describe_manual_port(server.yandex_edge_origin_port, "auto/tcp")
        ));
    } else {
        warnings.push("Public VK relay, REALITY, and Yandex edge origin xHTTP ports are auto-selected from currently free server ports unless you pin them manually.".to_string());
    }

    warnings.push("Protocol pack staging is enabled: Odin's Cat keeps the current active data path, while preparing Russia-friendly fallback protocols for later rollout without Apple Network Extension entitlements.".to_string());
    warnings
}

fn build_protocol_pack(payload: &ProvisionPayload) -> Vec<ProtocolPackEntry> {
    let preview_fallbacks = preview_staged_fallbacks(payload.edge.as_ref());
    build_protocol_pack_for_transport_with_fallbacks(
        &payload.server.transport,
        None,
        payload.server.reality_port,
        payload.server.vk_turn_proxy_port,
        Some(&preview_fallbacks),
    )
}

fn validate_deployment_port_hints(server: &ServerDraftPayload) -> Result<(), String> {
    validate_requested_port(server.vk_turn_proxy_port, "vk-turn-proxy relay")?;
    validate_requested_port(server.reality_port, "VLESS + REALITY")?;
    validate_requested_port(server.yandex_edge_origin_port, "Yandex edge origin xHTTP")?;

    if let (Some(vk_port), Some(reality_port)) = (server.vk_turn_proxy_port, server.reality_port) {
        if vk_port > 0 && reality_port > 0 && vk_port == reality_port {
            return Err(
                "vk-turn-proxy relay UDP port and VLESS + REALITY TCP port must be different"
                    .to_string(),
            );
        }
    }

    if let (Some(vk_port), Some(yandex_edge_origin_port)) =
        (server.vk_turn_proxy_port, server.yandex_edge_origin_port)
    {
        if vk_port > 0 && yandex_edge_origin_port > 0 && vk_port == yandex_edge_origin_port {
            return Err(
                "vk-turn-proxy relay UDP port and Yandex edge origin xHTTP TCP port must be different"
                    .to_string(),
            );
        }
    }

    if let (Some(reality_port), Some(yandex_edge_origin_port)) =
        (server.reality_port, server.yandex_edge_origin_port)
    {
        if reality_port > 0
            && yandex_edge_origin_port > 0
            && reality_port == yandex_edge_origin_port
        {
            return Err(
                "VLESS + REALITY TCP port and Yandex edge origin xHTTP TCP port must be different"
                    .to_string(),
            );
        }
    }

    Ok(())
}

fn validate_requested_port(port: Option<u16>, _name: &str) -> Result<(), String> {
    match port {
        None | Some(0) | Some(_) => Ok(()),
    }
}

fn normalized_port(port: u16) -> u16 {
    if port == 0 {
        22
    } else {
        port
    }
}

fn normalized_provision_flow(flow: &str) -> &str {
    if flow.trim() == PROVISION_FLOW_EDGE_ATTACH {
        PROVISION_FLOW_EDGE_ATTACH
    } else {
        PROVISION_FLOW_ORIGIN
    }
}

fn normalized_edge_public_port(edge: Option<&EdgeAttachPayload>) -> u16 {
    edge.and_then(|entry| entry.public_port)
        .filter(|port| *port > 0)
        .unwrap_or(YANDEX_EDGE_CONNECT_PORT)
}

fn normalized_edge_routing_mode(edge: Option<&EdgeAttachPayload>) -> &str {
    let mode = edge
        .and_then(|entry| entry.routing_mode.as_deref())
        .unwrap_or(EDGE_ROUTING_MODE_DEFAULT)
        .trim();
    if mode.is_empty() || mode == EDGE_ROUTING_MODE_TCP_FORWARD {
        EDGE_ROUTING_MODE_DEFAULT
    } else {
        mode
    }
}

fn edge_server_payload(edge: &EdgeAttachPayload) -> ServerDraftPayload {
    ServerDraftPayload {
        host: edge.server.host.trim().to_string(),
        port: normalized_port(edge.server.port),
        username: edge.server.username.trim().to_string(),
        auth_method: edge.server.auth_method.trim().to_string(),
        transport: "xray".to_string(),
        engine: Some("sing-box".to_string()),
        protocol: Some("vless-reality".to_string()),
        vk_turn_stream_count: None,
        vk_turn_proxy_port: None,
        reality_port: None,
        yandex_edge_origin_port: None,
    }
}

fn validate_edge_attach_payload(payload: &ProvisionPayload) -> Result<(), String> {
    let Some(edge) = payload.edge.as_ref().filter(|edge| edge.enabled) else {
        return Err("edge attach requires an enabled edge configuration".to_string());
    };
    if !edge.provider.trim().is_empty() && edge.provider.trim() != EDGE_PROVIDER_YANDEX {
        return Err(format!(
            "unsupported edge provider: {}",
            edge.provider.trim()
        ));
    }
    if payload.server.host.trim().is_empty()
        || payload.server.username.trim().is_empty()
        || payload.secret.trim().is_empty()
    {
        return Err("origin host, username, and secret are required".to_string());
    }
    if edge.server.host.trim().is_empty()
        || edge.server.username.trim().is_empty()
        || edge.secret.trim().is_empty()
    {
        return Err("edge host, username, and secret are required".to_string());
    }
    if normalized_port(edge.server.port) == 0 {
        return Err("edge ssh port must be positive".to_string());
    }
    if normalized_edge_public_port(Some(edge)) == 0 {
        return Err("edge public port must be positive".to_string());
    }
    match normalized_edge_routing_mode(Some(edge)) {
        EDGE_ROUTING_MODE_TCP_FORWARD
        | EDGE_ROUTING_MODE_SNI_ROUTER
        | EDGE_ROUTING_MODE_XRAY_PROXY => {}
        _ => return Err("unsupported edge routing mode".to_string()),
    }
    Ok(())
}

fn describe_manual_port(port: Option<u16>, fallback: &str) -> String {
    match port {
        Some(value) if value > 0 => value.to_string(),
        _ => fallback.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        apply_owner_runtime_lab_overrides, build_protocol_pack_for_transport_with_fallbacks,
        curated_yandex_edge_fallback_value, ensure_reality_relay_direct_fallback, ipv4_in_cidr,
        parse_ipv4_cidr, parse_whitelist_files, port_candidates_with_seed,
        upsert_yandex_edge_fallback, OwnerRuntimeLabPayload, OwnerRuntimeLabRelayAutoselectPayload,
        EDGE_ROUTING_MODE_DEFAULT, EDGE_ROUTING_MODE_TCP_FORWARD,
        OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB, OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB,
        OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD, OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB,
        OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD,
        OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE,
        OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY,
        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS,
        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL,
        OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL, REALITY_DEPLOY_DEFAULT_PORT,
        YANDEX_EDGE_CONNECT_HOST, YANDEX_EDGE_CONNECT_PORT, YANDEX_EDGE_ORIGIN_PORT,
        YANDEX_EDGE_SOURCE, YANDEX_EDGE_TAG,
    };
    use serde_json::Value;
    use std::net::Ipv4Addr;

    #[test]
    fn owner_runtime_lab_patch_adds_hidden_reality_whitelist_block() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","stagedFallbacks":{"vlessReality":{"port":443}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD.to_string(),
                hint_server_name: "max.ru".to_string(),
                hint_cidr_bucket: "cidr-max".to_string(),
                hint_source: "operator-curated".to_string(),
                hint_tag: "candidate-max-ru".to_string(),
                edge_server_name: String::new(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should succeed");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["reality"]["mode"].as_str(),
            Some("stable")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["enabled"].as_bool(),
            Some(true)
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["mode"].as_str(),
            Some("scaffold")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["selection"].as_str(),
            Some("ordered")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["bootstrap"].as_str(),
            Some("direct-reality")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["hints"][0]["serverName"].as_str(),
            Some("max.ru")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["hints"][0]["cidrBucket"].as_str(),
            Some("cidr-max")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["hints"][0]["source"].as_str(),
            Some("operator-curated")
        );
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["hints"][0]["tag"].as_str(),
            Some("candidate-max-ru")
        );
    }

    #[test]
    fn port_candidates_put_preferred_port_first_without_duplicates() {
        let ports = port_candidates_with_seed(1000, 1004, Some(1002), 1);
        assert_eq!(ports[0], 1002);
        assert_eq!(ports.len(), 5);
        assert_eq!(
            ports
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>(),
            [1000_u16, 1001, 1002, 1003, 1004].into_iter().collect()
        );
    }

    #[test]
    fn protocol_pack_defaults_direct_reality_to_high_port_range() {
        let entries =
            build_protocol_pack_for_transport_with_fallbacks("xray", Some(51820), None, None, None);
        let direct = entries
            .iter()
            .find(|entry| entry.id == "vless-reality")
            .expect("direct reality entry should exist");
        assert_eq!(direct.port, REALITY_DEPLOY_DEFAULT_PORT);
    }

    #[test]
    fn owner_runtime_lab_patch_rejects_empty_server_name() {
        let result = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner"}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_SCAFFOLD.to_string(),
                hint_server_name: "   ".to_string(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        );

        assert!(result.is_err());
    }

    #[test]
    fn owner_runtime_lab_patch_supports_whitelist_lab_mode() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner"}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_WHITELIST_LAB.to_string(),
                hint_server_name: "duma.gov.ru".to_string(),
                hint_cidr_bucket: String::new(),
                hint_source: "operator-curated".to_string(),
                hint_tag: "candidate-02-duma-gov-ru".to_string(),
                edge_server_name: String::new(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support lab mode");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityWhitelistHints"]["mode"].as_str(),
            Some("lab")
        );
    }

    #[test]
    fn owner_runtime_lab_patch_adds_hidden_reality_vps_lab_block() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","stagedFallbacks":{"vlessReality":{"port":443}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "ads.x5.ru".to_string(),
                vps_port: 20443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "grpc".to_string(),
                vps_flow: String::new(),
                vps_fingerprint: "firefox".to_string(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: "operator-curated:vps-lab".to_string(),
                vps_tag: "reality-lab-ads-x5-ru-grpc".to_string(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support vps lab mode");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["enabled"].as_bool(),
            Some(true)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["mode"].as_str(),
            Some("lab")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["serverName"].as_str(),
            Some("ads.x5.ru")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["port"].as_u64(),
            Some(20443)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["transport"].as_str(),
            Some("grpc")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["fingerprint"].as_str(),
            Some("firefox")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["tag"].as_str(),
            Some("reality-lab-ads-x5-ru-grpc")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityEgress"].as_bool(),
            Some(false)
        );
    }

    #[test]
    fn owner_runtime_lab_patch_adds_hidden_relay_autoselect_block() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","androidRuntime":{"realityVpsLab":{"relayAutoselect":{"enabled":true,"sourceLabel":"stale"}}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "id.x5.ru".to_string(),
                vps_port: 443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "tcp".to_string(),
                vps_flow: "xtls-rprx-vision".to_string(),
                vps_fingerprint: "chrome".to_string(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: Some(OwnerRuntimeLabRelayAutoselectPayload {
                    enabled: true,
                    subscription_url: String::new(),
                    source_label: String::new(),
                }),
            },
        )
        .expect("owner runtime lab patch should support relay autoselect");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["enabled"].as_bool(),
            Some(true)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["subscriptionUrl"]
                .as_str(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["sourceLabel"].as_str(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["refreshIntervalHours"]
                .as_u64(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_INTERVAL_HOURS)
        );
    }

    #[test]
    fn owner_runtime_lab_patch_can_enable_owner_reality_egress() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","serverHost":"95.81.120.226","stagedFallbacks":{"vlessReality":{"port":52443,"uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4"}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "id.x5.ru".to_string(),
                vps_port: 443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "tcp".to_string(),
                vps_flow: "xtls-rprx-vision".to_string(),
                vps_fingerprint: "chrome".to_string(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support owner reality egress");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityEgress"].as_bool(),
            Some(false)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["serverHost"]
                .as_str(),
            Some("95.81.120.226")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["port"].as_u64(),
            Some(52443)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["serverName"]
                .as_str(),
            Some("www.cloudflare.com")
        );
    }

    #[test]
    fn owner_runtime_lab_patch_forces_relay_owner_mode() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","serverHost":"95.81.120.226","stagedFallbacks":{"vlessReality":{"port":52443,"uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4"}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_RELAY_LAB.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "id.x5.ru".to_string(),
                vps_port: 443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "tcp".to_string(),
                vps_flow: "xtls-rprx-vision".to_string(),
                vps_fingerprint: "chrome".to_string(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should force relay -> owner mode");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["mode"].as_str(),
            Some("lab")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityEgress"].as_bool(),
            Some(true)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["enabled"].as_bool(),
            Some(true)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["subscriptionUrl"]
                .as_str(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL)
        );
    }

    #[test]
    fn owner_runtime_lab_patch_disables_stale_relay_autoselect_for_manual_vps_lab() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","androidRuntime":{"realityVpsLab":{"relayAutoselect":{"enabled":true,"sourceLabel":"stale"}}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_LAB.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "ads.x5.ru".to_string(),
                vps_port: 20443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "grpc".to_string(),
                vps_flow: String::new(),
                vps_fingerprint: "firefox".to_string(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should disable stale relay autoselect");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["enabled"].as_bool(),
            Some(false)
        );
    }

    #[test]
    fn owner_runtime_lab_patch_supports_reality_vps_scaffold_defaults() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner"}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_VPS_SCAFFOLD.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: "pimg.mycdn.me".to_string(),
                vps_port: 10443,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: "tcp".to_string(),
                vps_flow: "xtls-rprx-vision".to_string(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support vps scaffold mode");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["mode"].as_str(),
            Some("scaffold")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["fingerprint"].as_str(),
            Some("chrome")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["flow"].as_str(),
            Some("xtls-rprx-vision")
        );
    }

    #[test]
    fn owner_runtime_lab_patch_supports_yandex_edge_preset() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","serverHost":"95.81.120.226","stagedFallbacks":{"vlessReality":{"port":52443,"uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4"}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support the Yandex edge preset");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["connectHost"].as_str(),
            Some(YANDEX_EDGE_CONNECT_HOST)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["connectPort"].as_u64(),
            Some(YANDEX_EDGE_CONNECT_PORT as u64)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["source"].as_str(),
            Some(YANDEX_EDGE_SOURCE)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["tag"].as_str(),
            Some(YANDEX_EDGE_TAG)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["serverHost"]
                .as_str(),
            Some("95.81.120.226")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["port"].as_u64(),
            Some(52443)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["serverName"].as_str(),
            Some("www.cloudflare.com")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["port"].as_u64(),
            Some(52443)
        );
        assert_eq!(
            payload["stagedFallbacks"]["realityYandexEdge"]["originPort"].as_u64(),
            Some(52443)
        );
        assert_eq!(
            payload["stagedFallbacks"]["realityYandexEdge"]["publicKey"].as_str(),
            Some("EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4")
        );
        assert_eq!(
            payload["stagedFallbacks"]["realityYandexEdge"]["routingMode"].as_str(),
            Some(EDGE_ROUTING_MODE_DEFAULT)
        );
        assert_eq!(
            payload["stagedFallbacks"]["vlessReality"]["publicKey"].as_str(),
            Some("EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4")
        );
    }

    #[test]
    fn owner_runtime_lab_patch_accepts_supported_yandex_edge_server_name_override() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","serverHost":"95.81.120.226","stagedFallbacks":{"vlessReality":{"port":52443,"uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4"}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: "ya.ru".to_string(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: false,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support overriding yandex edge server name");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["serverName"].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["ownerRealityBootstrap"]["serverName"]
                .as_str(),
            Some("ya.ru")
        );
    }

    #[test]
    fn owner_runtime_lab_patch_supports_yandex_edge_proxy_without_relay_autoselect() {
        let patched = apply_owner_runtime_lab_overrides(
            r#"{"name":"Owner","serverHost":"95.81.120.226","androidRuntime":{"realityVpsLab":{"relayAutoselect":{"enabled":true,"sourceLabel":"stale"}}},"stagedFallbacks":{"vlessReality":{"port":55555,"uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4"},"realityYandexEdgeProxy":{"connectHost":"62.84.123.148","connectPort":10443,"originHost":"95.81.120.226","originPort":55555,"serverName":"www.cloudflare.com","publicKey":"EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4","shortId":"2d2812af9d8e4cf4","uuid":"fe05feb2-c88c-46bc-b809-ba9eefc5e6ee","flow":"xtls-rprx-vision","source":"owner-attached:yandex-edge:xray-proxy:10443:proxy","tag":"yandex-edge-62-84-123-148-10443-xray-proxy-proxy","routingMode":"xray-proxy","ownerRealityEgress":false}}}"#,
            &OwnerRuntimeLabPayload {
                mode: OWNER_RUNTIME_LAB_MODE_REALITY_YANDEX_EDGE_PROXY.to_string(),
                hint_server_name: String::new(),
                hint_cidr_bucket: String::new(),
                hint_source: String::new(),
                hint_tag: String::new(),
                edge_server_name: String::new(),
                vps_server_name: String::new(),
                vps_port: 0,
                vps_connect_host: String::new(),
                vps_connect_port: 0,
                vps_transport: String::new(),
                vps_flow: String::new(),
                vps_fingerprint: String::new(),
                vps_grpc_service_name: String::new(),
                vps_grpc_authority: String::new(),
                vps_source: String::new(),
                vps_tag: String::new(),
                vps_owner_reality_egress: true,
                vps_relay_autoselect: None,
            },
        )
        .expect("owner runtime lab patch should support the Yandex edge proxy preset");

        let payload: Value =
            serde_json::from_str(&patched).expect("patched profile should stay valid json");
        assert_eq!(
            payload["androidRuntime"]["cdnAntiWhitelist"]["connectHost"].as_str(),
            Some("62.84.123.148")
        );
        assert_eq!(
            payload["androidRuntime"]["cdnAntiWhitelist"]["connectPort"].as_u64(),
            Some(443)
        );
        assert_eq!(
            payload["androidRuntime"]["cdnAntiWhitelist"]["transport"].as_str(),
            Some("xhttp")
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["relayAutoselect"]["enabled"].as_bool(),
            Some(false)
        );
        assert_eq!(
            payload["androidRuntime"]["realityVpsLab"]["enabled"].as_bool(),
            Some(false)
        );
        assert_eq!(
            payload["androidRuntime"]["cdnAntiWhitelist"]["tlsServerName"].as_str(),
            Some("ya.ru")
        );
    }

    #[test]
    fn yandex_edge_runtime_layout_keeps_legacy_default_path() {
        let layout = super::build_yandex_edge_runtime_layout(
            YANDEX_EDGE_CONNECT_PORT,
            EDGE_ROUTING_MODE_TCP_FORWARD,
        );
        assert_eq!(layout.root_dir, super::LEGACY_WHITELIST_EDGE_ROOT);
        assert_eq!(
            layout.service_name,
            super::LEGACY_WHITELIST_YANDEX_EDGE_SERVICE_NAME
        );
    }

    #[test]
    fn yandex_edge_runtime_layout_scopes_non_default_path() {
        let layout =
            super::build_yandex_edge_runtime_layout(10443, super::EDGE_ROUTING_MODE_SNI_ROUTER);
        assert_eq!(layout.root_dir, "/opt/whitelist-edge-sni-router-10443");
        assert_eq!(
            layout.service_name,
            "whitelist-yandex-edge-sni-router-10443.service"
        );
        assert_eq!(
            super::build_yandex_edge_fallback_source(10443, super::EDGE_ROUTING_MODE_SNI_ROUTER,),
            "owner-attached:yandex-edge:sni-router:10443"
        );
        assert_eq!(
            super::build_yandex_edge_fallback_tag(
                "62.84.123.148",
                10443,
                super::EDGE_ROUTING_MODE_SNI_ROUTER,
            ),
            "yandex-edge-62-84-123-148-10443-sni-router"
        );
    }

    #[test]
    fn protocol_pack_prefers_current_yandex_edge_proxy_entry() {
        let mut staged = serde_json::json!({});
        upsert_yandex_edge_fallback(&mut staged, curated_yandex_edge_fallback_value());
        staged["realityYandexEdgeProxy"]["routingMode"] =
            Value::String(super::EDGE_ROUTING_MODE_XRAY_PROXY.to_string());
        let entries = build_protocol_pack_for_transport_with_fallbacks(
            "xray",
            Some(51820),
            Some(443),
            Some(56080),
            Some(&staged),
        );
        assert!(
            entries.iter().any(|entry| {
                entry.id == "vless-reality-yandex-edge-proxy"
                    && entry.label == "Yandex edge"
                    && entry.port == YANDEX_EDGE_CONNECT_PORT
            }),
            "protocol pack should expose the bridge-first Yandex edge mode for invite flows",
        );
        assert!(
            !entries
                .iter()
                .any(|entry| entry.id == "vless-reality-yandex-edge"),
            "protocol pack should hide the legacy passthrough entry when the bridge entry is available",
        );
    }

    #[test]
    fn render_yandex_edge_xray_proxy_config_avoids_inbound_sniffing() {
        let routes = super::yandex_edge_accepted_server_names("www.cloudflare.com")
            .into_iter()
            .enumerate()
            .map(|(index, server_name)| super::YandexEdgeRealityRoute {
                server_name,
                local_port: 24043 + index as u16,
            })
            .collect::<Vec<_>>();
        let raw = super::render_yandex_edge_xray_proxy_config(
            "PRIVATE_KEY",
            "deadbeef",
            "11111111-1111-1111-1111-111111111111",
            &routes,
            "2.26.62.246",
            52444,
            "2-26-62-246.sslip.io",
            "22222222-2222-2222-2222-222222222222",
        )
        .expect("config should render");
        let parsed: Value = serde_json::from_str(&raw).expect("config should parse");
        let inbound = parsed["inbounds"][0]
            .as_object()
            .expect("inbound should be object");
        assert_eq!(inbound["tag"].as_str(), Some("edge-reality-in-1"));
        assert_eq!(inbound["streamSettings"]["network"].as_str(), Some("tcp"));
        assert_eq!(
            inbound["streamSettings"]["security"].as_str(),
            Some("reality")
        );
        let server_names = inbound["streamSettings"]["realitySettings"]["serverNames"]
            .as_array()
            .expect("serverNames should be array");
        assert_eq!(server_names.len(), 1);
        assert_eq!(server_names[0].as_str(), Some("www.cloudflare.com"));
        let inbound_count = parsed["inbounds"].as_array().map(|items| items.len()).unwrap_or(0);
        assert!(inbound_count >= 3);
        assert_eq!(
            parsed["routing"]["rules"][0]["outboundTag"].as_str(),
            Some("origin-xhttp-out")
        );
        assert_eq!(
            parsed["outbounds"][0]["streamSettings"]["network"].as_str(),
            Some(super::YANDEX_EDGE_CDN_TRANSPORT)
        );
    }

    #[test]
    fn protocol_pack_includes_white_relay_entry() {
        let mut staged = serde_json::json!({});
        super::ensure_reality_relay_owner_egress_fallback(&mut staged);
        ensure_reality_relay_direct_fallback(&mut staged);
        let entries = build_protocol_pack_for_transport_with_fallbacks(
            "xray",
            Some(51820),
            Some(443),
            Some(56080),
            Some(&staged),
        );
        assert!(
            entries.iter().any(|entry| {
                entry.id == "vless-reality-relay-direct"
                    && entry.label == "white relay"
                    && entry.port == 443
            }),
            "protocol pack should expose the direct relay mode for deploy/invite flows",
        );
    }

    #[test]
    fn ensure_reality_relay_direct_fallback_adds_hourly_source() {
        let mut staged = serde_json::json!({});
        ensure_reality_relay_direct_fallback(&mut staged);
        assert_eq!(
            staged["realityRelayDirect"]["subscriptionUrl"].as_str(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_URL)
        );
        assert_eq!(
            staged["realityRelayDirect"]["sourceLabel"].as_str(),
            Some(OWNER_RUNTIME_LAB_RELAY_AUTOSELECT_DEFAULT_SOURCE_LABEL)
        );
    }

    #[test]
    fn ensure_yandex_edge_fallback_adds_visible_edge_entry() {
        let mut staged = serde_json::json!({});
        upsert_yandex_edge_fallback(&mut staged, curated_yandex_edge_fallback_value());
        assert_eq!(
            staged["realityYandexEdge"]["connectHost"].as_str(),
            Some(YANDEX_EDGE_CONNECT_HOST)
        );
        assert_eq!(
            staged["realityYandexEdge"]["connectPort"].as_u64(),
            Some(YANDEX_EDGE_CONNECT_PORT as u64)
        );
        assert_eq!(
            staged["realityYandexEdge"]["originPort"].as_u64(),
            Some(YANDEX_EDGE_ORIGIN_PORT as u64)
        );
    }

    #[test]
    fn decode_invite_syncs_guest_reality_into_staged_yandex_edge_and_owner_egress() {
        let raw = serde_json::json!({
            "id": "guest-009",
            "role": "guest",
            "name": "Odin's Cat Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "fingerprint": "482471d931882079",
            "status": "active",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                "shortId": "ba81780391343b01",
                "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
                "flow": "xtls-rprx-vision"
            },
            "stagedFallbacks": {
                "vlessReality": {
                    "port": 55555,
                    "serverName": "www.cloudflare.com",
                    "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                    "shortId": "ba81780391343b01",
                    "uuid": "7e56811d-4815-474a-a2a2-9cb869aeae5b",
                    "flow": "xtls-rprx-vision"
                },
                "realityRelayOwnerEgress": {
                    "ownerEgressPort": 52443
                },
                "realityYandexEdge": {
                    "connectHost": "62.84.123.148",
                    "connectPort": 443,
                    "originHost": "95.81.120.226",
                    "originPort": 55555,
                    "serverName": "www.cloudflare.com",
                    "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                    "shortId": "ba81780391343b01",
                    "uuid": "7e56811d-4815-474a-a2a2-9cb869aeae5b",
                    "flow": "xtls-rprx-vision"
                }
            }
        })
        .to_string();

        let invite = super::decode_invite(&raw).expect("invite should decode");
        assert_eq!(
            invite.staged_fallbacks["vlessReality"]["uuid"].as_str(),
            Some("b707d399-3f96-4df9-8daa-8b7b2ea23650")
        );
        assert_eq!(
            invite.staged_fallbacks["realityYandexEdge"]["uuid"].as_str(),
            Some("b707d399-3f96-4df9-8daa-8b7b2ea23650")
        );
        assert_eq!(
            invite.staged_fallbacks["realityRelayOwnerEgress"]["ownerEgressPort"].as_u64(),
            Some(55555)
        );
    }

    #[test]
    fn decode_invite_preserves_xray_proxy_edge_uuid_for_cdn_runtime() {
        let raw = serde_json::json!({
            "id": "guest-010",
            "role": "guest",
            "name": "Odin's Cat Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "fingerprint": "482471d931882080",
            "status": "active",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "guest-public-key",
                "shortId": "guest-short-id",
                "uuid": "guest-uuid-1111-2222-3333-444444444444",
                "flow": "xtls-rprx-vision"
            },
            "stagedFallbacks": {
                "vlessReality": {
                    "port": 55555,
                    "serverName": "www.cloudflare.com",
                    "publicKey": "guest-public-key",
                    "shortId": "guest-short-id",
                    "uuid": "stale-guest-uuid",
                    "flow": "xtls-rprx-vision"
                },
                "realityYandexEdgeProxy": {
                    "connectHost": "62.84.123.148",
                    "connectPort": 443,
                    "originHost": "95.81.120.226",
                    "originPort": 55555,
                    "serverName": "www.cloudflare.com",
                    "publicKey": "owner-edge-public-key",
                    "shortId": "owner-edge-short-id",
                    "uuid": "owner-edge-uuid-aaaa-bbbb-cccc-dddddddddddd",
                    "flow": "xtls-rprx-vision",
                    "routingMode": "xray-proxy"
                }
            }
        })
        .to_string();

        let invite = super::decode_invite(&raw).expect("invite should decode");
        assert_eq!(
            invite.vless_reality.uuid.as_str(),
            "guest-uuid-1111-2222-3333-444444444444"
        );
        assert_eq!(
            invite.staged_fallbacks["realityYandexEdgeProxy"]["uuid"].as_str(),
            Some("owner-edge-uuid-aaaa-bbbb-cccc-dddddddddddd")
        );
        assert_eq!(
            invite.staged_fallbacks["realityYandexEdgeProxy"]["transport"].as_str(),
            Some("xhttp")
        );
    }

    #[test]
    fn parse_ipv4_cidr_matches_expected_ip() {
        let cidr = parse_ipv4_cidr("62.84.120.0/22").expect("cidr should parse");
        assert!(ipv4_in_cidr(
            "62.84.123.148".parse::<Ipv4Addr>().expect("valid ip"),
            &cidr
        ));
        assert!(!ipv4_in_cidr(
            "62.85.123.148".parse::<Ipv4Addr>().expect("valid ip"),
            &cidr
        ));
    }

    #[test]
    fn parse_whitelist_files_skips_comments_and_blank_lines() {
        let parsed = parse_whitelist_files(
            "\n# note\n62.84.123.148\n\n213.165.213.122\n",
            "\n# note\n62.84.120.0/22\n213.165.192.0/19\n",
            "2026-04-06T00:00:00Z",
        )
        .expect("whitelist lists should parse");

        assert!(parsed
            .exact_ips
            .contains(&"62.84.123.148".parse::<Ipv4Addr>().expect("valid ip")));
        assert_eq!(parsed.cidrs.len(), 2);
    }

    #[test]
    fn vk_turn_stream_count_defaults_when_missing_or_invalid() {
        assert_eq!(
            super::effective_vk_turn_stream_count(0),
            super::VK_TURN_STREAM_COUNT_DEFAULT
        );
        assert_eq!(
            super::effective_vk_turn_stream_count(99),
            super::VK_TURN_STREAM_COUNT_DEFAULT
        );
        assert_eq!(super::effective_vk_turn_stream_count(6), 6);
    }

    #[test]
    fn decode_invite_normalizes_vk_turn_stream_count() {
        let raw = serde_json::json!({
            "role": "guest",
            "name": "Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "vkTurnProxyPort": 56080,
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                "shortId": "ba81780391343b01",
                "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
                "flow": "xtls-rprx-vision"
            },
            "wireguard": {
                "serverPublicKey": "server-public",
                "clientPrivateKey": "client-private",
                "clientPublicKey": "client-public",
                "address": "10.66.66.3/32",
                "mtu": 1280
            }
        })
        .to_string();

        let invite = super::decode_invite(&raw).expect("invite should decode");
        assert_eq!(
            invite.vk_turn_stream_count,
            super::VK_TURN_STREAM_COUNT_DEFAULT
        );

        let raw_override = serde_json::json!({
            "role": "guest",
            "name": "Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "vkTurnStreamCount": 8,
            "vkTurnProxyPort": 56080,
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                "shortId": "ba81780391343b01",
                "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
                "flow": "xtls-rprx-vision"
            },
            "wireguard": {
                "serverPublicKey": "server-public",
                "clientPrivateKey": "client-private",
                "clientPublicKey": "client-public",
                "address": "10.66.66.3/32",
                "mtu": 1280
            }
        })
        .to_string();

        let invite_override =
            super::decode_invite(&raw_override).expect("invite with override should decode");
        assert_eq!(invite_override.vk_turn_stream_count, 8);
    }

    #[test]
    fn decode_invite_adds_cdn_anti_whitelist_runtime_for_yandex_edge() {
        let raw = serde_json::json!({
            "role": "guest",
            "name": "Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                "shortId": "ba81780391343b01",
                "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
                "flow": "xtls-rprx-vision"
            },
            "stagedFallbacks": {
                "realityYandexEdgeProxy": {
                    "connectHost": "62.84.123.148",
                    "connectPort": 12443
                }
            }
        })
        .to_string();

        let invite = super::decode_invite(&raw).expect("invite should decode");
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["transport"].as_str(),
            Some("xhttp")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["engine"].as_str(),
            Some("xray-native")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["frontHost"].as_str(),
            Some("62-84-123-148.sslip.io")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["tlsServerName"].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["hostHeader"].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["tlsAllowInsecure"].as_bool(),
            Some(true)
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["xhttpMode"].as_str(),
            Some("packet-up")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["camouflageHost"].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["camouflageHostPool"][0].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["camouflageHostPool"][1].as_str(),
            Some("tunnel.vk-apps.com")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["frontPool"]
                .as_array()
                .map(Vec::len),
            Some(4)
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["frontPool"][0]["tlsServerName"].as_str(),
            Some("ya.ru")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["frontPool"][1]["tlsServerName"].as_str(),
            Some("tunnel.vk-apps.com")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["connectPort"].as_u64(),
            Some(443)
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["xmuxMaxConcurrency"].as_u64(),
            Some(20)
        );
    }

    #[test]
    fn decode_invite_preserves_explicit_cdn_anti_whitelist_runtime() {
        let raw = serde_json::json!({
            "role": "guest",
            "name": "Owner Node",
            "protocol": "vless-reality",
            "transport": "xray",
            "serverHost": "95.81.120.226",
            "endpointPort": 55555,
            "endpoint": "95.81.120.226:55555",
            "vlessReality": {
                "port": 55555,
                "serverName": "www.cloudflare.com",
                "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
                "shortId": "ba81780391343b01",
                "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
                "flow": "xtls-rprx-vision"
            },
            "androidRuntime": {
                "cdnAntiWhitelist": {
                    "enabled": true,
                    "transport": "xhttp",
                    "frontHost": "62-84-123-148.sslip.io",
                    "tlsServerName": "62-84-123-148.sslip.io",
                    "tlsAllowInsecure": false,
                    "hostHeader": "62-84-123-148.sslip.io"
                }
            },
            "stagedFallbacks": {
                "realityYandexEdgeProxy": {
                    "connectHost": "62.84.123.148",
                    "connectPort": 12443
                }
            }
        })
        .to_string();

        let invite = super::decode_invite(&raw).expect("invite should decode");
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["tlsServerName"].as_str(),
            Some("62-84-123-148.sslip.io")
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["tlsAllowInsecure"].as_bool(),
            Some(false)
        );
        assert_eq!(
            invite.android_runtime["cdnAntiWhitelist"]["frontSelection"].as_str(),
            Some("ordered")
        );
        let direct_domains = invite.android_runtime["cdnAntiWhitelist"]["routingPolicy"]
            ["directDomains"]
            .as_array()
            .expect("directDomains should be present");
        assert!(direct_domains
            .iter()
            .filter_map(Value::as_str)
            .any(|domain| domain == "yandex.ru"));
        assert!(direct_domains
            .iter()
            .filter_map(Value::as_str)
            .any(|domain| domain == "ya.ru"));
    }
}
