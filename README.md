# Odin's Cat

`Odin's Cat` is a self-hosted VPN client for macOS and Android that deploys and runs dual-mode access on your own server:

- direct `VLESS + REALITY`
- `VK relay` via `vk-turn-proxy + xray`

The current release line is `0.6.0`.

## Current status

- macOS desktop app is shipped as a `Tauri + Next.js` build
- Android app is built from the same product shell and Android VPN runtime
- one server can expose both `REALITY` and `VK relay` at the same time
- users can switch between `VLESS + REALITY` and `VK relay` without redeploy
- one invite/import key can grant access to both modes

## What already works

- SSH-based deploy to a fresh Linux VPS
- remote install and configuration of:
  - `xray`
  - `sing-box`
  - `vk-turn-proxy`
  - `systemd` units
- dual-stack server deploy:
  - `REALITY` on its own TCP port
  - `VK relay` on its own UDP port
- owner profile, guest share, import, revoke flow
- local runtime start/stop
- quick connectivity test through the local tunnel
- Android VPN runtime with:
  - `VLESS + REALITY`
  - `VK relay`
  - local `SOCKS` endpoint
  - APK and AAB builds

## Stack

- `Next.js` for the app UI
- `Tauri 2` for desktop/mobile shell integration
- `Go` for provisioning, SSH orchestration, profiles, sharing, and local runtime helpers
- `Rust` for native Tauri bridge pieces
- `xray`, `sing-box`, and `vk-turn-proxy` for transport/runtime

## Monorepo layout

```text
apps/
  desktop/        Main product app (desktop shell + Android shell/runtime)
packages/
  contracts/      Shared TypeScript contracts
  ui/             Shared UI and i18n
core/
  go/             Provisioning core, profiles, invite flow, local tunnel runtime
docs/
  android-port-plan.md
```

## Key product behavior

### Server

- deploy from app credentials over SSH
- auto or manual public port selection
- dual-mode access on one server
- no redeploy required for every runtime mode switch

### Client

- owner mode
- imported guest mode
- `Generate connection key`
- `Import key`
- runtime mode toggle:
  - `VLESS + REALITY`
  - `VK relay`

### VK path

- server-side relay via `whitelist-vk-turn-proxy.service`
- client-side `vk-turn-proxy` bridge
- Android runtime includes warmup handling and cached TURN credential reuse

## Requirements

Workspace versions used during development:

- Node.js `22.22.2`
- npm `10.9.7`
- Go `1.26.1`
- JDK `21`

Typical server target:

- Linux `x86_64`
- `systemd`
- SSH access with enough privileges to write to `/opt` and `/etc/systemd/system`

## Development

Install dependencies:

```bash
export PATH="$HOME/.local/bin:$PATH"
npm install
```

Run the desktop web UI:

```bash
npm run dev
```

Run the Go backend:

```bash
cd core/go
go run ./cmd/mvpd
```

Run the Tauri desktop shell:

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
npm run desktop:tauri:dev
```

Build the macOS app bundle:

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
npm run desktop:tauri:build
```

Build Android artifacts:

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
npm run android:tauri:build
```

## Notes

- The desktop and Android products now live in one app workspace under `apps/desktop`.
- The old legacy `apps/mobile` scaffold has been removed from active development.
- Android runtime is already functional, but stabilization work is still ongoing around stop/switch lifecycle and `VK relay` parity.
