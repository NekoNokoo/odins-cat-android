#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod android_vpn;
mod mobile_bridge;

use tauri::Builder;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use std::{
    net::TcpStream,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use tauri::{AppHandle, Manager, RunEvent};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
const BACKEND_ADDR: &str = "127.0.0.1:18088";

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[derive(Clone, Default)]
struct BackendState {
    child: Arc<Mutex<Option<Child>>>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        let backend_state = BackendState::default();
        let exit_state = backend_state.clone();

        mobile_bridge::register_mobile_commands(Builder::default())
            .plugin(android_vpn::init())
            .manage(backend_state)
            .setup(|app| {
                ensure_backend_running(app.handle())?;
                Ok(())
            })
            .build(tauri::generate_context!())
            .expect("failed to build Odin One desktop shell")
            .run(move |_app_handle, event| {
                if matches!(event, RunEvent::Exit) {
                    disable_managed_system_proxy();
                    shutdown_backend(&exit_state);
                }
            });
    }

    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        mobile_bridge::register_mobile_commands(Builder::default())
            .plugin(android_vpn::init())
            .build(tauri::generate_context!())
            .expect("failed to build Odin One mobile shell")
            .run(|_app_handle, _event| {});
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn ensure_backend_running(app: &AppHandle) -> tauri::Result<()> {
    if backend_is_ready() {
        return Ok(());
    }

    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|err| tauri::Error::Io(std::io::Error::other(err.to_string())))?;
    let binary_path = resolve_mvpd_path(resource_dir);

    let child = Command::new(&binary_path)
        .env("MVPD_ADDR", BACKEND_ADDR)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .map_err(|err| {
            tauri::Error::Io(std::io::Error::other(format!(
                "spawn bundled mvpd {}: {err}",
                binary_path.display()
            )))
        })?;

    let state = app.state::<BackendState>();
    if let Ok(mut slot) = state.child.lock() {
        *slot = Some(child);
    }

    let deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < deadline {
        if backend_is_ready() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(150));
    }

    Err(tauri::Error::Io(std::io::Error::other(
        "bundled mvpd did not become ready in time",
    )))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn resolve_mvpd_path(resource_dir: PathBuf) -> PathBuf {
    let candidates = [
        resource_dir.join("bin").join("mvpd"),
        resource_dir.join("mvpd"),
    ];
    candidates
        .into_iter()
        .find(|path| path.exists())
        .unwrap_or_else(|| resource_dir.join("bin").join("mvpd"))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn backend_is_ready() -> bool {
    TcpStream::connect(BACKEND_ADDR).is_ok()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn shutdown_backend(state: &BackendState) {
    if let Ok(mut slot) = state.child.lock() {
        if let Some(mut child) = slot.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn disable_managed_system_proxy() {
    if cfg!(target_os = "macos") {
        if let Ok(services) = list_network_services() {
            for service in services {
                if let Ok((enabled, host)) = socks_proxy_state(&service) {
                    if enabled && host == "127.0.0.1" {
                        let _ = Command::new("networksetup")
                            .args(["-setsocksfirewallproxystate", &service, "off"])
                            .output();
                    }
                }
            }
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn list_network_services() -> Result<Vec<String>, String> {
    let output = Command::new("networksetup")
        .arg("-listallnetworkservices")
        .output()
        .map_err(|err| err.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let services = text
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty() && !line.starts_with("An asterisk") && !line.starts_with('*')
        })
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    Ok(services)
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn socks_proxy_state(service: &str) -> Result<(bool, String), String> {
    let output = Command::new("networksetup")
        .args(["-getsocksfirewallproxy", service])
        .output()
        .map_err(|err| err.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let mut enabled = false;
    let mut host = String::new();
    for line in text.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("Enabled:") {
            enabled = value.trim().eq_ignore_ascii_case("yes");
        }
        if let Some(value) = line.strip_prefix("Server:") {
            host = value.trim().to_string();
        }
    }
    Ok((enabled, host))
}
