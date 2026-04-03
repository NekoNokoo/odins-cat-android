#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR}/../../.."
REPO_ROOT="${REPO_ROOT:A}"

GO_BINARY="${GO_BINARY:-/Users/vladislav/.local/opt/go/bin/go}"
if [[ ! -x "$GO_BINARY" ]]; then
  GO_BINARY="$(command -v go || true)"
fi

if [[ -z "$GO_BINARY" || ! -x "$GO_BINARY" ]]; then
  echo "Go binary not found. Set GO_BINARY or install go." >&2
  exit 1
fi

VKTURN_VERSION="${VKTURN_VERSION:-v1.3.0}"
GOPROXY_VALUE="${GOPROXY:-https://proxy.golang.org,direct}"
TARGET_PATH="${TARGET_PATH:-${REPO_ROOT}/apps/desktop/src-tauri/gen/android/app/src/main/jniLibs/arm64-v8a/libvkturn.so}"

binary_is_current() {
  local candidate="${1:-}"
  [[ -f "$candidate" ]] || return 1
  strings "$candidate" | rg -q "github.com/cacggghp/vk-turn-proxy|captchaNotRobot.settings|${VKTURN_VERSION}" &&
    strings "$candidate" | rg -q "github.com/cacggghp/vk-turn-proxy" &&
    strings "$candidate" | rg -q "captchaNotRobot.settings" &&
    strings "$candidate" | rg -q "${VKTURN_VERSION}"
}

if binary_is_current "$TARGET_PATH"; then
  echo "Android vk-turn-proxy client already up to date:"
  echo "  version: ${VKTURN_VERSION}"
  echo "  target:  ${TARGET_PATH}"
  exit 0
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/odin-one-vkturn-android.XXXXXX")"
cleanup() {
  chmod -R u+w "$WORK_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "${TARGET_PATH:h}"

GOPATH_DIR="${WORK_DIR}/gopath"
mkdir -p "$GOPATH_DIR"

(
  export GOPATH="$GOPATH_DIR"
  export GOOS="android"
  export GOARCH="arm64"
  export CGO_ENABLED="0"
  export GOPROXY="$GOPROXY_VALUE"

  "$GO_BINARY" install \
    -ldflags=-checklinkname=0 \
    "github.com/cacggghp/vk-turn-proxy/client@${VKTURN_VERSION}"
)

BUILT_BINARY="${GOPATH_DIR}/bin/android_arm64/client"
if [[ ! -f "$BUILT_BINARY" ]]; then
  echo "Built Android vk-turn-proxy client not found at ${BUILT_BINARY}" >&2
  exit 1
fi

install -m 0755 "$BUILT_BINARY" "$TARGET_PATH"

echo "Updated Android vk-turn-proxy client:"
echo "  version: ${VKTURN_VERSION}"
echo "  target:  ${TARGET_PATH}"
file "$TARGET_PATH"
