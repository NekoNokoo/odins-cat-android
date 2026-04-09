#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/src-tauri/target/release/bundle/macos/Odin's Cat.app"
DMG_DIR="$ROOT_DIR/src-tauri/target/release/bundle/dmg"
DMG_PATH="$DMG_DIR/Odin's Cat_0.6.0_aarch64.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/odin-one-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"

cp -R "$APP_PATH" "$STAGING_DIR/Odin's Cat.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Odin's Cat" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
