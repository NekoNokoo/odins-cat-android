#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

paths=(
  "$ROOT_DIR/apps/desktop/.next"
  "$ROOT_DIR/apps/desktop/out"
  "$ROOT_DIR/apps/desktop/src-tauri/target"
  "$ROOT_DIR/apps/desktop/src-tauri/gen/android/.gradle"
  "$ROOT_DIR/apps/desktop/src-tauri/gen/android/build"
  "$ROOT_DIR/apps/desktop/src-tauri/gen/android/buildSrc/.gradle"
  "$ROOT_DIR/apps/desktop/src-tauri/gen/android/buildSrc/build"
  "$ROOT_DIR/apps/desktop/src-tauri/gen/android/app/build"
)

before_kb=$(du -sk "$ROOT_DIR" 2>/dev/null | awk '{print $1}')

make_writable() {
  local path="$1"
  [[ -e "$path" ]] || return 0

  if [[ -d "$path" ]]; then
    find "$path" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    find "$path" -type f -exec chmod u+rw {} + 2>/dev/null || true
  else
    chmod u+rw "$path" 2>/dev/null || true
  fi
}

printf 'Cleaning local build artifacts in %s\n' "$ROOT_DIR"
for path in "${paths[@]}"; do
  if [[ -e "$path" ]]; then
    printf '  removing %s\n' "${path#"$ROOT_DIR"/}"
    make_writable "$path"
    rm -rf "$path"
  fi
done

after_kb=$(du -sk "$ROOT_DIR" 2>/dev/null | awk '{print $1}')
freed_kb=$((before_kb - after_kb))

printf 'Done. Freed %.2f GB (from %.2f GB to %.2f GB).\n' \
  "$(awk "BEGIN { print $freed_kb / 1024 / 1024 }")" \
  "$(awk "BEGIN { print $before_kb / 1024 / 1024 }")" \
  "$(awk "BEGIN { print $after_kb / 1024 / 1024 }")"
