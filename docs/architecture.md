# Architecture notes

## Product direction

Odin One is designed as a self-hosted VPN deployer and client manager.

Core product jobs:

1. Collect server credentials from the owner.
2. Validate SSH access.
3. Provision VPN services on the owner's server.
4. Generate owner and guest access profiles.
5. Let other users connect using shared access data.

## Runtime split

### Desktop UI

- built with `Next.js`
- later wrapped in `Tauri`
- responsible for:
  - onboarding
  - deployment controls
  - logs and status
  - profile export and import

### Go core

- owns provisioning logic
- will expose a local HTTP or IPC API to the desktop shell
- responsible for:
  - SSH and SCP
  - command execution
  - asset templating
  - deployment state machine
  - health checks

## Planned deploy sequence

1. `ValidateSSH`
2. `DetectOS`
3. `PickFreePorts`
4. `PrepareFolders`
5. `UploadAssets`
6. `InstallXray`
7. `InstallVKTurnProxy`
8. `StartServices`
9. `GenerateOwnerProfile`
10. `PersistLocalOwnerProfile`
11. `GenerateShareProfile`

## Planned server layout

```text
/opt/whitelist/
  bin/
  config/
  profiles/
  services/
```

## Planned first endpoints

- `GET /healthz`
- `POST /api/provision/plan`
- `POST /api/provision/validate`
- `POST /api/provision/deploy`
- `GET /api/provision/deploy/:id`
- `POST /api/local-tunnel/start`
- `POST /api/local-tunnel/stop`
- `GET /api/local-tunnel/status`
- `POST /api/local-tunnel/test`
- `POST /api/profile/share`

## Why keep vk-turn-proxy optional

`vk-turn-proxy` should be modeled as a transport mode, not the only deployment strategy.

That lets us:

- keep a standard `xray` path for safer rollout
- compare transport reliability
- fall back when the transport source changes behavior

## Current deploy behavior

- The deployer uses SSH directly and does not require Docker.
- Odin One assets are installed into `/opt/whitelist`.
- The app now searches for free UDP ports on the user's server instead of assuming a fixed port.
- The macOS test mode stays isolated on localhost and does not touch the system default route.
- At the moment, tunnel startup still reads the owner profile from the server over SSH; the next product step is caching that profile locally after deploy.
