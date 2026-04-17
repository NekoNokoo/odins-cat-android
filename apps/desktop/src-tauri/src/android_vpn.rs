use serde::Serialize;
use serde_json::Value;
use tauri::{plugin::TauriPlugin, AppHandle};

#[cfg(target_os = "android")]
use tauri::{Manager, Runtime};

#[cfg(target_os = "android")]
pub(crate) struct VpnRuntimeHandle<R: Runtime>(pub(crate) tauri::plugin::PluginHandle<R>);

#[cfg(target_os = "android")]
impl<R: Runtime> Clone for VpnRuntimeHandle<R> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

pub(crate) fn init() -> TauriPlugin<tauri::Wry> {
    tauri::plugin::Builder::new("vpn_runtime")
        .setup(|_app, _api| {
            #[cfg(target_os = "android")]
            {
                let handle =
                    _api.register_android_plugin("com.odinone.desktop.vk", "VpnRuntimePlugin")?;
                _app.manage(VpnRuntimeHandle(handle));
            }

            Ok(())
        })
        .build()
}

#[cfg(target_os = "android")]
async fn run_mobile_command<T: Serialize>(
    app: &AppHandle,
    command: &str,
    payload: T,
) -> Result<Value, String> {
    let Some(handle) = app.try_state::<VpnRuntimeHandle<tauri::Wry>>() else {
        return Err("Android VPN runtime plugin is not registered".to_string());
    };

    handle
        .0
        .run_mobile_plugin_async(command, payload)
        .await
        .map_err(|err| format!("android vpn runtime {command}: {err}"))
}

#[cfg(not(target_os = "android"))]
async fn run_mobile_command<T: Serialize>(
    _app: &AppHandle,
    _command: &str,
    _payload: T,
) -> Result<Value, String> {
    Err("Android VPN runtime is only available on Android".to_string())
}

pub(crate) async fn start_tunnel<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "startTunnel", payload).await
}

pub(crate) async fn stop_tunnel(app: &AppHandle) -> Result<Value, String> {
    run_mobile_command(app, "stopTunnel", ()).await
}

pub(crate) async fn get_status(app: &AppHandle) -> Result<Value, String> {
    run_mobile_command(app, "getStatus", ()).await
}

pub(crate) async fn run_connectivity_test<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "runConnectivityTest", payload).await
}

pub(crate) async fn inspect_network_lens<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "inspectNetworkLens", payload).await
}

pub(crate) async fn list_installed_apps(app: &AppHandle) -> Result<Value, String> {
    run_mobile_command(app, "listInstalledApps", ()).await
}

pub(crate) async fn get_split_tunnel_selection(app: &AppHandle) -> Result<Value, String> {
    run_mobile_command(app, "getSplitTunnelSelection", ()).await
}

pub(crate) async fn set_split_tunnel_selection<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "setSplitTunnelSelection", payload).await
}

pub(crate) async fn get_next_vpn_session_log_state(app: &AppHandle) -> Result<Value, String> {
    run_mobile_command(app, "getNextVpnSessionLogState", ()).await
}

pub(crate) async fn set_next_vpn_session_log_state<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "setNextVpnSessionLogState", payload).await
}

pub(crate) async fn share_invite_file<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "shareInviteFile", payload).await
}

pub(crate) async fn export_debug_log<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "exportDebugLog", payload).await
}

pub(crate) async fn open_external_url<T: Serialize>(
    app: &AppHandle,
    payload: T,
) -> Result<Value, String> {
    run_mobile_command(app, "openExternalUrl", payload).await
}
