use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

fn main() {
    println!("cargo:rerun-if-changed=../../../core/go/cmd/mvpd");
    println!("cargo:rerun-if-changed=../../../core/go/internal");

    build_mvpd().expect("failed to build bundled mvpd");
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
