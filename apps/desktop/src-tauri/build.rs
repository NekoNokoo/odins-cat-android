use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

fn main() {
    println!("cargo:rerun-if-changed=../../../core/go/cmd/mvpd");
    println!("cargo:rerun-if-changed=../../../core/go/internal");
    println!("cargo:rerun-if-env-changed=GO_BINARY");

    if !matches!(
        env::var("CARGO_CFG_TARGET_OS").ok().as_deref(),
        Some("android") | Some("ios")
    ) {
        build_mvpd().expect("failed to build bundled mvpd");
    }
    build_vk_turn_proxy_server_bundle().expect("failed to build bundled vk-turn-proxy server");
    tauri_build::build()
}

fn build_mvpd() -> Result<(), String> {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").map_err(|err| err.to_string())?);
    let go_root = manifest_dir.join("../../../core/go");
    let bin_dir = manifest_dir.join("bin");
    let output_path = bin_dir.join("mvpd");

    fs::create_dir_all(&bin_dir).map_err(|err| err.to_string())?;

    if should_reuse_prebuilt_mvpd(&output_path, &go_root) {
        ensure_executable(&output_path)?;
        return Ok(());
    }

    let go_binary = resolve_go_binary();
    let output = Command::new(&go_binary)
        .arg("build")
        .arg("-o")
        .arg(&output_path)
        .arg("./cmd/mvpd")
        .current_dir(&go_root)
        .output()
        .map_err(|err| format!("spawn go build: {err}"))?;

    if !output.status.success() {
        return Err(format!(
            "go build failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    ensure_executable(&output_path)?;

    Ok(())
}

fn build_vk_turn_proxy_server_bundle() -> Result<(), String> {
    let out_dir = PathBuf::from(env::var("OUT_DIR").map_err(|err| err.to_string())?);
    let output_path = out_dir.join("vk-turn-proxy-server-linux-amd64");
    if output_path.exists() {
        return Ok(());
    }

    let go_binary = resolve_go_binary();
    let gopath_dir = out_dir.join("gopath-vk-turn-proxy-server");
    fs::create_dir_all(&gopath_dir).map_err(|err| err.to_string())?;

    let output = Command::new(&go_binary)
        .arg("install")
        .arg("github.com/cacggghp/vk-turn-proxy/server@latest")
        .env("GOPATH", &gopath_dir)
        .env("GOOS", "linux")
        .env("GOARCH", "amd64")
        .env("CGO_ENABLED", "0")
        .output()
        .map_err(|err| format!("spawn go install vk-turn-proxy server: {err}"))?;

    if !output.status.success() {
        return Err(format!(
            "go install vk-turn-proxy server failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    let installed_path = gopath_dir.join("bin").join("linux_amd64").join("server");
    let data = fs::read(&installed_path)
        .map_err(|err| format!("read built vk-turn-proxy server: {err}"))?;
    fs::write(&output_path, data)
        .map_err(|err| format!("cache bundled vk-turn-proxy server: {err}"))?;

    Ok(())
}

fn should_reuse_prebuilt_mvpd(output_path: &Path, go_root: &Path) -> bool {
    output_path.exists()
        && (env::var("ODIN_ONE_USE_PREBUILT_MVPD").ok().as_deref() == Some("1")
            || !go_root.exists())
}

fn ensure_executable(output_path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&output_path)
            .map_err(|err| err.to_string())?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&output_path, perms).map_err(|err| err.to_string())?;
    }

    Ok(())
}

fn resolve_go_binary() -> String {
    let preferred = Path::new("/Users/vladislav/.local/opt/go/bin/go");
    if preferred.exists() {
        return preferred.display().to_string();
    }
    env::var("GO_BINARY").unwrap_or_else(|_| "go".to_string())
}
