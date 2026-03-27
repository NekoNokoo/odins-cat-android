# Odin One MVP

Minimal macOS-first MVP scaffold for the Odin One self-hosted VPN client that:

- takes a user's server credentials
- deploys VPN infrastructure remotely
- prepares shareable client access
- keeps architecture ready for future iOS and Android clients

## Stack

- `Next.js` for the desktop UI
- `Tauri` planned as the desktop shell for `.dmg` packaging
- `Go` for provisioning, SSH orchestration, and future shared core logic
- `xray` plus `vk-turn-proxy` planned as the first transport stack

## Monorepo layout

```text
apps/
  desktop/        Next.js macOS-first UI
  mobile/         mobile architecture notes and future shell
packages/
  contracts/      shared TypeScript contracts
  ui/             shared UI components
core/
  go/             Go provisioning core scaffold
```

## MVP scope

The current MVP already includes:

- a minimal black-and-white macOS-first UI
- real SSH validation from the Go core
- real remote deployment of:
  - `xray`
  - `vk-turn-proxy`
  - `systemd` units
  - an owner profile in `/opt/whitelist/profiles/owner-profile.json`
- automatic server-side UDP port selection during deploy
- a local isolated tunnel mode for macOS tests through a localhost-only `SOCKS5` proxy
- one-click tunnel testing through the local proxy without changing system routes
- local guest share/import flow based on the cached owner profile, without SSH or live tunnel startup
- server-side guest issue/list/revoke flow that rebuilds xray peers without touching macOS system routes

## Current MVP flow

1. User enters `host`, `port`, `username`, and password or SSH key.
2. Desktop app asks the Go core to validate SSH access.
3. Go core picks free UDP ports on the server and deploys the Odin One stack.
4. App shows deployment progress and the allocated external UDP port.
5. User pastes a fresh `VK call link`.
6. App starts an isolated local tunnel for testing on the Mac.
7. App runs a single outbound test request through the local SOCKS proxy.

## Run requirements

This workspace is currently using:

- Node.js `22.22.2`
- npm `10.9.7`
- Go `1.26.1`

Then the intended commands will be:

```bash
export PATH="$HOME/.local/bin:$PATH"
npm install
npm run dev
```

For the Go stub:

```bash
export PATH="$HOME/.local/bin:$PATH"
cd core/go
go run ./cmd/mvpd
```

Or use the combined helper:

```bash
zsh scripts/dev.sh
```

For the native macOS shell:

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
npm run desktop:tauri:dev
```

The Tauri dev shell reuses an already running desktop frontend on `http://localhost:3000` and an existing Go core on `:8088` when present.

And for a local desktop bundle build:

```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
npm run desktop:tauri:build
```

## Next implementation steps

1. Persist the fetched owner profile locally after deploy so tunnel startup no longer depends on a fresh SSH handshake.
2. Upgrade guest profile sharing from local export/import to true per-user remote profile issuance.
3. Wrap the desktop UI in `Tauri` and prepare `.dmg` packaging.
4. Add mobile shells reusing the same contracts and API model.
5. Introduce a true system VPN mode only after the isolated proxy mode is fully stable.
