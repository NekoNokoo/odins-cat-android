# Odin One Android Port Plan

## Current desktop shape

The current product is already close to an Android-friendly split:

- `apps/desktop/app/_components/control-center.tsx` contains the full mobile-style UI and user flows.
- `packages/contracts` holds the request/response contracts that already describe deploy, owner/imported profiles, local runtime state, quick test state, and dual-mode access.
- `core/go/internal/provision` contains the control-plane business logic:
  - SSH validate
  - deploy
  - owner/imported profile cache
  - guest share/import
  - protocol pack / dual-mode metadata
- `apps/desktop/src-tauri` is intentionally thin and mostly shell glue.

This means the Android port should preserve:

- the existing UI layout and interaction model
- the same contracts for profiles, deploy, test, and runtime state
- the same dual-mode logic and invite/import semantics

## Reusable as-is

- Next/Tauri UI from `apps/desktop/app`
- shared UI primitives from `packages/ui`
- TypeScript contracts from `packages/contracts`
- server deploy, validate, share, import, and protocol-pack logic from `core/go/internal/provision`
- owner/imported profile JSON formats

## macOS-specific pieces to replace on Android

These parts are desktop-only and must not be carried over 1:1:

- `apps/desktop/src-tauri/src/lib.rs`
  - spawns bundled `mvpd`
  - manages macOS proxy cleanup on exit
- `core/go/internal/provision/local_tunnel.go`
  - launches local `xray` / `sing-box` / `vk-turn-proxy` processes for localhost SOCKS mode
  - assumes desktop filesystem + process model
- `core/go/internal/provision/system_proxy.go`
  - uses macOS `networksetup`
  - models VPN enablement through SOCKS + system proxy, not Android `VpnService`

## Safe Android target architecture

### Shell and UI

- Keep Tauri 2 and reuse the current Next app for UI parity.
- Keep `ControlCenter` as the product UI source of truth.
- Route all frontend core calls through a single API boundary so Android can swap transport without rewriting UI logic.

### Control plane

- Reuse the existing Go provisioning/share/import logic instead of rewriting it in Kotlin or Rust.
- Expose Android control-plane operations through a native bridge layer, not a separate Android background HTTP daemon.
- Preserve the current JSON contracts for:
  - deploy
  - validation
  - owner/imported profiles
  - guest share/import
  - protocol pack

### Data plane

- Replace macOS SOCKS + system proxy with Android `VpnService` + foreground service.
- Keep the same two runtime modes:
  - `VLESS + REALITY`
  - `VK relay`
- Use the current profile JSON as runtime input, but make Android runtime state native.
- Android runtime status should map back into the existing `LocalTunnelState` shape so UI parity stays high.

## Recommended migration sequence

### Phase 1

- Reuse desktop UI inside Tauri Android.
- Keep desktop build working unchanged.
- Add Android target, build scripts, and mobile-capable Rust/Tauri entrypoint.
- Centralize frontend backend calls behind one module.

### Phase 2

- Add Android native control-plane bridge for:
  - validate
  - deploy
  - fetch owner profile
  - import/share flows
- Keep using the same contract payloads and responses.

### Phase 3

- Add Android `VpnService` runtime manager.
- Implement `start/stop/status/test` for:
  - `VLESS + REALITY`
  - `VK relay`
- Replace desktop-only proxy toggles with Android VPN state transitions.

### Phase 4

- Verify parity against desktop on:
  - deploy
  - imported vs owner profiles
  - share/import
  - dual-mode switching without redeploy
  - quick connectivity test
  - runtime status recovery after app restart

## What is already done in this repo

- Official Tauri Android project generated under `apps/desktop/src-tauri/gen/android`.
- `apps/desktop/src-tauri` is now mobile-capable:
  - desktop keeps bundled backend startup
  - mobile builds no longer depend on desktop-only `mvpd` spawning
- Android build scripts added to workspace `package.json` files.
- Local build env now selects a compatible JDK 21 for Android/Gradle.
- Frontend core calls are centralized in `apps/desktop/app/_core/core-api.ts`.
- Android native bridge is now wired for:
  - mobile health
  - local owner profile lookup
  - imported profile lookup
  - share-code import into app-local storage
  - SSH-backed validation with remote checks and egress probes
  - native static deploy plan generation
  - native deployment start + polling with desktop-compatible `DeploymentState`
  - remote SSH deploy for dual-stack server setup
  - remote guest share issuance
  - Android `VpnService` permission flow, native plugin bridge, and foreground-service lifecycle scaffold for tunnel start/stop/status/test
- Debug Android artifacts have been produced from this repo.

## Current known gap to full functional parity

The built APK currently proves:

- Android shell generation works
- shared UI can be packaged for Android
- Rust/Tauri mobile entrypoint works
- the repo can emit Android APK/AAB artifacts
- Android `VpnService` now boots a real native runtime path instead of a placeholder failure flow
- `libbox` is wired into the app for `VLESS + REALITY`
- `libvkturn.so` is bundled and launched for `VK relay`
- Android runtime state still maps back into the existing `LocalTunnelState` and shared UI contracts
- Android quick test now runs through the local SOCKS listener instead of a stubbed failure

But it is not yet a fully parity-complete VPN client because Android still needs:

- live device verification for both runtime modes on a real handset
- tighter runtime diagnostics for unexpected `libbox` service stops after startup
- a bundled first-bootstrap server binary path for `vk-turn-proxy-server` during initial deploy on completely fresh servers

The current bridge already covers health, local access-profile reads, share-code import, SSH-backed validation, static deploy-plan generation, remote deploy execution/polling, and remote guest share issuance.

Current deploy caveat:

- Android deploy can finish end-to-end when the server already has `vk-turn-proxy` installed at `/opt/whitelist/bin/vk-turn-proxy-server`, or when the remote server has `go` available so Odin One can build `github.com/cacggghp/vk-turn-proxy/server@latest` directly on the host.
- Android still does not have a bundled first-bootstrap path for uploading a known-good `vk-turn-proxy` server binary from the APK itself. That is the main remaining deploy-specific gap.

Current runtime caveat:

- The APK now has native `VpnService.prepare(...)`, foreground-service startup, `libbox`-backed Android data plane for `VLESS + REALITY`, and bundled `libvkturn.so` process wiring for `VK relay`.
- The Android runtime still exposes a localhost SOCKS listener so the shared UI and quick-test flow can stay close to the desktop contracts, while `VpnService` handles device-wide routing.
- Build verification is complete, but runtime parity is still not fully proven until both modes are exercised on a real Android device with live deploy/imported profiles.
