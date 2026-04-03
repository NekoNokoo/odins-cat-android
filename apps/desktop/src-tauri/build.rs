use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
    time::SystemTime,
};

const VK_TURN_PROXY_VERSION: &str = "v1.3.0";

fn main() {
    println!("cargo:rerun-if-changed=../../../core/go/cmd/mvpd");
    println!("cargo:rerun-if-changed=../../../core/go/internal");
    println!("cargo:rerun-if-changed=gen/android/app/src/main/jniLibs/arm64-v8a/libvkturn.so");
    println!("cargo:rerun-if-env-changed=GO_BINARY");
    println!("cargo:rerun-if-env-changed=ODIN_ONE_VK_TURN_PROXY_ANDROID_CLIENT_BINARY");
    println!("cargo:rerun-if-env-changed=ODIN_ONE_VK_TURN_PROXY_SERVER_BINARY");

    let target_os = env::var("CARGO_CFG_TARGET_OS").ok();
    if !matches!(target_os.as_deref(), Some("android") | Some("ios")) {
        build_mvpd().expect("failed to build bundled mvpd");
    }
    if matches!(target_os.as_deref(), Some("android")) {
        build_vk_turn_proxy_android_client_bundle()
            .expect("failed to build bundled vk-turn-proxy Android client");
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
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").map_err(|err| err.to_string())?);
    let out_dir = PathBuf::from(env::var("OUT_DIR").map_err(|err| err.to_string())?);
    let output_path = out_dir.join("vk-turn-proxy-server-linux-amd64");
    if output_path.exists() {
        return Ok(());
    }
    if try_reuse_prebuilt_vk_turn_proxy_server_bundle(&manifest_dir, &output_path)? {
        return Ok(());
    }

    let go_binary = resolve_go_binary();
    let gopath_dir = out_dir.join("gopath-vk-turn-proxy-server");
    fs::create_dir_all(&gopath_dir).map_err(|err| err.to_string())?;

    let mut last_error = None;
    for goproxy in ["https://proxy.golang.org,direct", "direct"] {
        let output = Command::new(&go_binary)
            .arg("install")
            .arg(format!(
                "github.com/cacggghp/vk-turn-proxy/server@{VK_TURN_PROXY_VERSION}"
            ))
            .env("GOPATH", &gopath_dir)
            .env("GOOS", "linux")
            .env("GOARCH", "amd64")
            .env("CGO_ENABLED", "0")
            .env("GOPROXY", goproxy)
            .output()
            .map_err(|err| format!("spawn go install vk-turn-proxy server: {err}"))?;

        if output.status.success() {
            let installed_path = gopath_dir.join("bin").join("linux_amd64").join("server");
            let data = fs::read(&installed_path)
                .map_err(|err| format!("read built vk-turn-proxy server: {err}"))?;
            fs::write(&output_path, data)
                .map_err(|err| format!("cache bundled vk-turn-proxy server: {err}"))?;
            return Ok(());
        }

        last_error = Some(format!(
            "GOPROXY={goproxy}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    Err(format!(
        "go install vk-turn-proxy server failed: {}",
        last_error.unwrap_or_else(|| "unknown error".to_string())
    ))
}

fn build_vk_turn_proxy_android_client_bundle() -> Result<(), String> {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").map_err(|err| err.to_string())?);
    let out_dir = PathBuf::from(env::var("OUT_DIR").map_err(|err| err.to_string())?);
    let output_path = manifest_dir.join("gen/android/app/src/main/jniLibs/arm64-v8a/libvkturn.so");

    fs::create_dir_all(
        output_path
            .parent()
            .ok_or_else(|| "Android vk-turn-proxy output path has no parent".to_string())?,
    )
    .map_err(|err| format!("create Android vk-turn-proxy output dir: {err}"))?;

    if try_reuse_prebuilt_vk_turn_proxy_android_client_bundle(&output_path)? {
        ensure_executable(&output_path)?;
        return Ok(());
    }
    if android_vk_turn_proxy_client_is_current(&output_path)? {
        ensure_executable(&output_path)?;
        return Ok(());
    }

    let go_binary = resolve_go_binary();
    let gopath_dir = out_dir.join("gopath-vk-turn-proxy-android-client");
    fs::create_dir_all(&gopath_dir).map_err(|err| err.to_string())?;

    let mut last_error = None;
    for goproxy in ["https://proxy.golang.org,direct", "direct"] {
        let output = Command::new(&go_binary)
            .arg("install")
            .arg("-ldflags=-checklinkname=0")
            .arg(format!(
                "github.com/cacggghp/vk-turn-proxy/client@{VK_TURN_PROXY_VERSION}"
            ))
            .env("GOPATH", &gopath_dir)
            .env("GOOS", "android")
            .env("GOARCH", "arm64")
            .env("CGO_ENABLED", "0")
            .env("GOPROXY", goproxy)
            .output()
            .map_err(|err| format!("spawn go install vk-turn-proxy Android client: {err}"))?;

        if output.status.success() {
            let installed_path = gopath_dir.join("bin").join("android_arm64").join("client");
            let data = fs::read(&installed_path)
                .map_err(|err| format!("read built vk-turn-proxy Android client: {err}"))?;
            fs::write(&output_path, data)
                .map_err(|err| format!("cache bundled vk-turn-proxy Android client: {err}"))?;
            ensure_executable(&output_path)?;
            return Ok(());
        }

        last_error = Some(format!(
            "GOPROXY={goproxy}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    Err(format!(
        "go install vk-turn-proxy Android client failed: {}",
        last_error.unwrap_or_else(|| "unknown error".to_string())
    ))
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

fn android_vk_turn_proxy_client_is_current(output_path: &Path) -> Result<bool, String> {
    if !output_path.exists() {
        return Ok(false);
    }
    let data = fs::read(output_path)
        .map_err(|err| format!("read bundled vk-turn-proxy Android client: {err}"))?;
    Ok([
        VK_TURN_PROXY_VERSION.as_bytes(),
        b"github.com/cacggghp/vk-turn-proxy".as_slice(),
        b"captchaNotRobot.settings".as_slice(),
    ]
    .iter()
    .all(|needle| binary_contains(&data, needle)))
}

fn binary_contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && haystack.windows(needle.len()).any(|window| window == needle)
}

fn resolve_go_binary() -> String {
    let preferred = Path::new("/Users/vladislav/.local/opt/go/bin/go");
    if preferred.exists() {
        return preferred.display().to_string();
    }
    env::var("GO_BINARY").unwrap_or_else(|_| "go".to_string())
}

fn try_reuse_prebuilt_vk_turn_proxy_android_client_bundle(output_path: &Path) -> Result<bool, String> {
    if let Ok(explicit_path) = env::var("ODIN_ONE_VK_TURN_PROXY_ANDROID_CLIENT_BINARY") {
        let explicit_path = PathBuf::from(explicit_path);
        if explicit_path.exists() {
            fs::copy(&explicit_path, output_path)
                .map_err(|err| format!("copy explicit vk-turn-proxy Android client: {err}"))?;
            return Ok(true);
        }
    }

    Ok(false)
}

fn try_reuse_prebuilt_vk_turn_proxy_server_bundle(
    manifest_dir: &Path,
    output_path: &Path,
) -> Result<bool, String> {
    if let Ok(explicit_path) = env::var("ODIN_ONE_VK_TURN_PROXY_SERVER_BINARY") {
        let explicit_path = PathBuf::from(explicit_path);
        if explicit_path.exists() {
            fs::copy(&explicit_path, output_path)
                .map_err(|err| format!("copy explicit vk-turn-proxy bundle: {err}"))?;
            return Ok(true);
        }
    }

    let target_dir = manifest_dir.join("target");
    let mut newest: Option<(SystemTime, PathBuf)> = None;
    for candidate in collect_vk_turn_proxy_bundle_candidates(&target_dir)? {
        let modified = fs::metadata(&candidate)
            .and_then(|metadata| metadata.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        if newest
            .as_ref()
            .map(|(current, _)| modified > *current)
            .unwrap_or(true)
        {
            newest = Some((modified, candidate));
        }
    }

    if let Some((_, candidate)) = newest {
        fs::copy(candidate, output_path)
            .map_err(|err| format!("copy cached vk-turn-proxy bundle: {err}"))?;
        return Ok(true);
    }

    Ok(false)
}

fn collect_vk_turn_proxy_bundle_candidates(target_dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut candidates = Vec::new();
    if !target_dir.exists() {
        return Ok(candidates);
    }

    collect_vk_turn_proxy_bundle_candidates_from_build_root(
        &mut candidates,
        &target_dir.join("debug").join("build"),
    )?;
    collect_vk_turn_proxy_bundle_candidates_from_build_root(
        &mut candidates,
        &target_dir.join("release").join("build"),
    )?;

    for target_entry in fs::read_dir(target_dir).map_err(|err| err.to_string())? {
        let target_entry = target_entry.map_err(|err| err.to_string())?;
        let target_path = target_entry.path();
        if !target_path.is_dir() {
            continue;
        }
        collect_vk_turn_proxy_bundle_candidates_from_build_root(
            &mut candidates,
            &target_path.join("debug").join("build"),
        )?;
        collect_vk_turn_proxy_bundle_candidates_from_build_root(
            &mut candidates,
            &target_path.join("release").join("build"),
        )?;
    }

    Ok(candidates)
}

fn collect_vk_turn_proxy_bundle_candidates_from_build_root(
    candidates: &mut Vec<PathBuf>,
    build_root: &Path,
) -> Result<(), String> {
    if !build_root.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(build_root).map_err(|err| err.to_string())? {
        let entry = entry.map_err(|err| err.to_string())?;
        let candidate = entry.path().join("out").join("vk-turn-proxy-server-linux-amd64");
        if candidate.exists() {
            candidates.push(candidate);
        }
    }
    Ok(())
}
