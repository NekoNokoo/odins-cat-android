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
    collections::{hash_map::DefaultHasher, HashMap},
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Manager, State};
use x25519_dalek::StaticSecret;

const SHARE_CODE_PREFIX: &str = "odin1:";
const DEFAULT_REALITY_FLOW: &str = "xtls-rprx-vision";
const REALITY_FALLBACK_PORT: u16 = 443;
const REALITY_FALLBACK_MIN_PORT: u16 = 52443;
const REALITY_FALLBACK_MAX_PORT: u16 = 52543;
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
const DEFAULT_PROBE_HTTP_URL: &str = "http://example.com";
const DEFAULT_PROBE_HTTPS_URL: &str = "https://example.com";
const DEFAULT_REALITY_SERVER_NAME: &str = "www.cloudflare.com";
const DEFAULT_REALITY_DEST: &str = "www.cloudflare.com:443";
const XRAY_RELEASE_URL: &str =
    "https://github.com/XTLS/Xray-core/releases/download/v25.8.3/Xray-linux-64.zip";
const SING_BOX_LINUX_RELEASE_URL: &str = "https://github.com/SagerNet/sing-box/releases/download/v1.12.22/sing-box-1.12.22-linux-amd64.tar.gz";
const BUNDLED_VK_TURN_PROXY_SERVER_LINUX_AMD64: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/vk-turn-proxy-server-linux-amd64"));

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
    server_host: String,
    #[serde(default)]
    vk_turn_proxy_port: u16,
    #[serde(default)]
    endpoint_port: u16,
    #[serde(default)]
    protocol_pack: Vec<ProtocolPackEntry>,
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
    vk_turn_proxy_port: Option<u16>,
    #[serde(default)]
    reality_port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProvisionPayload {
    #[serde(default)]
    server: ServerDraftPayload,
    #[serde(default)]
    secret: String,
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
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LocalTunnelTestPayload {
    #[serde(default)]
    url: String,
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
            inactivity_timeout: Some(Duration::from_secs(8)),
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
pub async fn mobile_validate_provision(payload: ProvisionPayload) -> Result<Value, String> {
    let protocol_pack = build_protocol_pack(&payload.server);
    let warnings = vec![
        "MVP validation currently uses insecure host key acceptance and should be hardened before production use.".to_string(),
        "Odin One keeps VLESS + REALITY and the VK relay ready on the same server so the client can switch paths locally without redeploy.".to_string(),
    ];

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

    if let Err(error) = validate_deployment_port_hints(&payload.server) {
        return Ok(json!({
            "ok": false,
            "host": payload.server.host,
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

#[tauri::command]
pub fn mobile_build_provision_plan(payload: ProvisionPayload) -> Value {
    json!({
        "serverHost": payload.server.host,
        "transport": "xray",
        "steps": build_plan_steps(),
        "warnings": build_plan_warnings(&payload.server),
        "protocolPack": build_protocol_pack(&payload.server)
    })
}

#[tauri::command]
pub fn mobile_start_deployment(
    app: AppHandle,
    store: State<MobileDeploymentStore>,
    payload: ProvisionPayload,
) -> Value {
    let deployment_id = format!("dep_{}", deployment_timestamp_nanos());
    let mut steps = build_plan_steps();
    if let Some(first) = steps.first_mut() {
        first.status = "current".to_string();
    }

    let initial = DeploymentStateEntry {
        deployment_id: deployment_id.clone(),
        server_host: payload.server.host.trim().to_string(),
        transport: "xray".to_string(),
        engine: Some("sing-box".to_string()),
        protocol: Some("vless-reality".to_string()),
        status: "running".to_string(),
        steps,
        turn_port: None,
        wire_guard_port: None,
        reality_port: None,
        health_checks: Vec::new(),
        protocol_pack: build_protocol_pack_for_transport(
            "xray",
            None,
            payload.server.reality_port,
            payload.server.vk_turn_proxy_port,
        ),
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
    let profile: OwnerProfileFile =
        serde_json::from_str(&data).map_err(|err| format!("parse owner profile: {err}"))?;

    Ok(json!({
        "exists": true,
        "name": profile.name,
        "transport": profile.transport,
        "activeProtocol": profile.active_protocol,
        "serverHost": profile.server_host,
        "vkTurnProxyPort": profile.vk_turn_proxy_port,
        "endpointPort": profile.endpoint_port,
        "localPath": target_path.to_string_lossy(),
        "rawJson": data,
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
    let mut guest = InviteProfileFile {
        id: guest_id.clone(),
        role: "guest".to_string(),
        name: default_invite_name(&payload.name),
        protocol: "vless-reality".to_string(),
        transport: owner.transport.clone(),
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
            mobile_validate_provision,
            mobile_build_provision_plan,
            mobile_start_deployment,
            mobile_get_deployment,
            mobile_start_local_tunnel,
            mobile_stop_local_tunnel,
            mobile_get_local_tunnel_status,
            mobile_run_local_tunnel_test,
            mobile_get_owner_profile,
            mobile_get_imported_profile,
            mobile_import_profile,
            mobile_generate_guest_profile
        ])
}

fn build_invite_response(
    invite: &InviteProfileFile,
    local_path: Option<&Path>,
    raw_json_override: Option<String>,
) -> Result<Value, String> {
    let raw_json = match raw_json_override {
        Some(raw_json) => raw_json,
        None => serde_json::to_string_pretty(invite)
            .map_err(|err| format!("marshal invite response: {err}"))?,
    };
    let mut response = json!({
        "id": optional_string(&invite.id),
        "role": invite.role,
        "name": invite.name,
        "protocol": normalized_invite_protocol(invite),
        "transport": invite.transport,
        "serverHost": invite.server_host,
        "vkTurnProxyPort": invite.vk_turn_proxy_port,
        "wireGuardPort": nonzero_u16(invite.wire_guard_port),
        "endpointPort": nonzero_u16(invite.endpoint_port),
        "endpoint": invite.endpoint,
        "fingerprint": effective_invite_fingerprint(invite),
        "vlessReality": invite.vless_reality,
        "supportsReality": invite_supports_reality(invite),
        "supportsVKRelay": invite_supports_vk_relay(invite),
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
        "Odin One Guest".to_string()
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
    if invite.server_host.trim().is_empty() {
        invite.server_host = owner.server_host.clone();
    }
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
    set_deployment_protocol_pack(
        &app,
        deployment_id,
        build_protocol_pack_for_transport(
            "xray",
            Some(wire_guard_port),
            Some(reality_port),
            Some(turn_port),
        ),
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
    )?;
    let xray_unit = render_systemd_unit(
        "Odin One Xray",
        &format!(
            "{} run -config {}",
            WHITELIST_XRAY_BINARY_PATH, WHITELIST_XRAY_CONFIG_PATH
        ),
    );
    let proxy_unit = render_systemd_unit(
        "Odin One vk-turn-proxy",
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
                "{label} UDP port {requested_port} conflicts with another Odin One service"
            ));
        }
        if remote_udp_port_is_free(ssh, requested_port).await? {
            return Ok(requested_port);
        }
        return Err(format!(
            "{label} UDP port {requested_port} is already in use on the server"
        ));
    }

    for port in start..=end {
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

    if remote_tcp_port_is_free(ssh, REALITY_FALLBACK_PORT).await? {
        return Ok(REALITY_FALLBACK_PORT);
    }

    find_remote_preferred_tcp_port(
        ssh,
        None,
        REALITY_FALLBACK_MIN_PORT,
        REALITY_FALLBACK_MAX_PORT,
    )
    .await
}

async fn find_remote_preferred_tcp_port(
    ssh: &mut MobileSshSession,
    preferred: Option<u16>,
    start: u16,
    end: u16,
) -> Result<u16, String> {
    if let Some(port) = preferred.filter(|port| *port > 0) {
        if remote_tcp_port_is_free(ssh, port).await? {
            return Ok(port);
        }
    }
    for port in start..=end {
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
    let unit_text = match ssh
        .run(&format!(
            "cat {}",
            quote_shell(WHITELIST_PROXY_SERVICE_PATH)
        ))
        .await
    {
        Ok(unit_text) => unit_text,
        Err(_) => return false,
    };
    parse_vk_relay_unit_ports(&unit_text).0 == Some(port)
}

async fn remote_existing_reality_uses_port(ssh: &mut MobileSshSession, port: u16) -> bool {
    match load_remote_access_state(ssh).await {
        Ok((_, state)) => state.reality.port == port,
        Err(_) => false,
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
) -> Result<String, String> {
    serde_json::to_string_pretty(&json!({
        "host": host,
        "transport": transport,
        "activeProtocol": active_protocol_id(transport),
        "generatedAt": now_rfc3339(),
        "recommendedPath": active_protocol_id(transport),
        "entries": build_protocol_pack_for_transport(
            transport,
            Some(wire_guard_port),
            Some(reality_port),
            Some(vk_relay_port)
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
    let profile = OwnerProfileFile {
        name: "Odin One Owner Node".to_string(),
        transport: "xray".to_string(),
        active_protocol: "vless-reality".to_string(),
        server_host: host.to_string(),
        vk_turn_proxy_port,
        endpoint_port: wire_guard_port,
        protocol_pack: build_protocol_pack_for_transport(
            "xray",
            Some(wire_guard_port),
            staged_fallbacks
                .get("vlessReality")
                .and_then(|value| value.get("port"))
                .and_then(Value::as_u64)
                .and_then(|value| u16::try_from(value).ok()),
            Some(vk_turn_proxy_port),
        ),
        staged_fallbacks,
        wireguard: OwnerWireGuard {
            server_public_key: server_public_key.to_string(),
            client_private_key: client_private_key.to_string(),
            client_public_key: client_public_key.to_string(),
            address: "10.66.66.2/32".to_string(),
            mtu: 1280,
        },
    };
    serde_json::to_string_pretty(&profile).map_err(|err| format!("marshal owner profile: {err}"))
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

fn build_protocol_pack_for_transport(
    transport: &str,
    wire_guard_port: Option<u16>,
    reality_port: Option<u16>,
    vk_turn_proxy_port: Option<u16>,
) -> Vec<ProtocolPackEntry> {
    let mut entries = vec![
        ProtocolPackEntry {
            id: "vless-reality".to_string(),
            label: "VLESS + REALITY".to_string(),
            status: "active".to_string(),
            engine: "sing-box".to_string(),
            scheme: "vless+reality".to_string(),
            network: "tcp".to_string(),
            port: reality_port.unwrap_or(REALITY_FALLBACK_PORT),
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
    ];

    if transport.trim() == "vk-turn-proxy+xray" {
        entries[0].status = "staged".to_string();
        entries[1].status = "active".to_string();
    }

    entries
}

fn resolve_android_runtime_request(
    app: &AppHandle,
    payload: &LocalTunnelStartPayload,
) -> Result<Value, String> {
    let host = payload.server.host.trim();
    if host.is_empty() {
        return Err("host is required".to_string());
    }

    let transport = requested_transport(&payload.server);
    let protocol = requested_protocol(&payload.server);
    let engine = requested_engine(transport, protocol);
    let use_reality_start_endpoint = transport == "xray" && protocol == "vless-reality";

    if payload.secret.trim().is_empty() {
        if let Ok((invite, local_path)) =
            find_imported_invite_for_runtime(app, host, Some((transport, protocol)))
        {
            if !invite_supports_requested_runtime(&invite, transport, protocol) {
                return Err(imported_runtime_support_error(
                    &invite, host, transport, protocol,
                ));
            }
            let raw_json = fs::read_to_string(&local_path)
                .map_err(|err| format!("read imported profile: {err}"))?;
            return Ok(json!({
                "serverHost": host,
                "transport": transport,
                "engine": engine,
                "protocol": protocol,
                "vkLink": payload.vk_link.trim(),
                "profileJson": raw_json,
                "profileSource": "imported",
                "useRealityStartEndpoint": use_reality_start_endpoint
            }));
        }
    }

    let owner_path = owner_profile_path(app, host)?;
    if !owner_path.exists() {
        if payload.secret.trim().is_empty() {
            return Err(format!(
                "no local imported access key found for host {host:?}"
            ));
        }
        return Err(format!(
            "no local owner profile found for host {host:?}; deploy or refresh the owner profile first"
        ));
    }

    let raw_json =
        fs::read_to_string(&owner_path).map_err(|err| format!("read owner profile: {err}"))?;
    let owner: OwnerProfileFile =
        serde_json::from_str(&raw_json).map_err(|err| format!("parse owner profile: {err}"))?;
    if !owner_supports_requested_runtime(&owner, transport, protocol) {
        return Err(format!(
            "the owner profile for {host} does not support {protocol}"
        ));
    }

    Ok(json!({
        "serverHost": host,
        "transport": transport,
        "engine": engine,
        "protocol": protocol,
        "vkLink": payload.vk_link.trim(),
        "profileJson": raw_json,
        "profileSource": "owner",
        "useRealityStartEndpoint": use_reality_start_endpoint
    }))
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

fn build_plan_steps() -> Vec<PlanEntry> {
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
                "Create isolated Odin One directories and verify network prerequisites."
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
                "Generate keys, write xray and Odin One configs, and install the required systemd units."
                    .to_string(),
        },
        PlanEntry {
            id: "service-start".to_string(),
            label: "Service startup".to_string(),
            status: "queued".to_string(),
            description: "Start the selected Odin One services and verify their health."
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

fn build_plan_warnings(server: &ServerDraftPayload) -> Vec<String> {
    let mut warnings = vec![
        "Odin One uses its own ports and paths so the existing Amnezia stack can remain untouched."
            .to_string(),
        "Odin One now keeps VLESS + REALITY and the VK relay live on the same server, so the client can switch paths locally without redeploying the node.".to_string(),
    ];

    if server.vk_turn_proxy_port.unwrap_or_default() > 0
        || server.reality_port.unwrap_or_default() > 0
    {
        warnings.push(format!(
            "Manual public ports are requested: VK relay {} and REALITY {}. Deploy will fail if either port is already busy on the server.",
            describe_manual_port(server.vk_turn_proxy_port, "auto/udp"),
            describe_manual_port(server.reality_port, "auto/tcp")
        ));
    } else {
        warnings.push("Public VK relay and REALITY ports are auto-selected from currently free server ports unless you pin them manually.".to_string());
    }

    warnings.push("Protocol pack staging is enabled: Odin One keeps the current active data path, while preparing Russia-friendly fallback protocols for later rollout without Apple Network Extension entitlements.".to_string());
    warnings
}

fn build_protocol_pack(server: &ServerDraftPayload) -> Vec<ProtocolPackEntry> {
    build_protocol_pack_for_transport(
        &server.transport,
        None,
        server.reality_port,
        server.vk_turn_proxy_port,
    )
}

fn validate_deployment_port_hints(server: &ServerDraftPayload) -> Result<(), String> {
    validate_requested_port(server.vk_turn_proxy_port, "vk-turn-proxy relay")?;
    validate_requested_port(server.reality_port, "VLESS + REALITY")?;

    if let (Some(vk_port), Some(reality_port)) = (server.vk_turn_proxy_port, server.reality_port) {
        if vk_port > 0 && reality_port > 0 && vk_port == reality_port {
            return Err(
                "vk-turn-proxy relay UDP port and VLESS + REALITY TCP port must be different"
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

fn describe_manual_port(port: Option<u16>, fallback: &str) -> String {
    match port {
        Some(value) if value > 0 => value.to_string(),
        _ => fallback.to_string(),
    }
}
