#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ANDROID_DIR="${SCRIPT_DIR}/../src-tauri/gen/android"
ANDROID_DIR="${ANDROID_DIR:A}"
DESKTOP_ENV_SCRIPT="${SCRIPT_DIR}/desktop-env.sh"

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-gradle-reuse-native.sh <gradle-task> [more tasks / flags]

Examples:
  apps/desktop/scripts/android-gradle-reuse-native.sh :app:assembleUniversalDebug
  apps/desktop/scripts/android-gradle-reuse-native.sh :app:installUniversalDebug
  apps/desktop/scripts/android-gradle-reuse-native.sh :app:testUniversalDebugUnitTest \
    --tests com.odinone.desktop.vk.VpnRuntimeLibboxTest

This helper always:
  - runs Android Gradle through apps/desktop/scripts/desktop-env.sh
  - exports ODIN_ONE_SKIP_RUST_BUILD=true
  - passes -PskipRustBuild=true to Gradle

Use it only when Kotlin / Android debug tooling changed and the existing Android
native outputs should be reused without a fresh Tauri/Rust rebuild.
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -x "$DESKTOP_ENV_SCRIPT" ]]; then
  echo "desktop-env helper not found: ${DESKTOP_ENV_SCRIPT}" >&2
  exit 1
fi

if [[ ! -d "$ANDROID_DIR" ]]; then
  echo "Android Gradle directory not found: ${ANDROID_DIR}" >&2
  exit 1
fi

cd "$ANDROID_DIR"
export ODIN_ONE_SKIP_RUST_BUILD=true
exec "$DESKTOP_ENV_SCRIPT" ./gradlew -PskipRustBuild=true "$@"
