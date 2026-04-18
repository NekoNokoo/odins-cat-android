# Odin One VK

Self-hosted access client for constrained networks.

This repository contains the public project snapshot for Odin One VK: a desktop and Android-oriented client that helps deploy, operate, test, and share self-hosted access profiles with a strong focus on:

- direct self-hosted access
- multi-hop entry routing
- Yandex Edge style first-hop deployments
- VK relay based transport experiments
- diagnostics, logging, and safe repeatable field testing

## Important notice

This repository is published for research, engineering, and interoperability purposes.

It is not a universal “one click bypass” project, and it should not be treated as legal advice, operational advice, or a guarantee that a specific setup will work in a specific network.

## What the project is

Odin One VK grew out of a practical need: a self-hosted client is not very useful in restrictive networks if it only knows how to connect to a single direct foreign endpoint.

The project therefore focuses not just on “connecting”, but on the full lifecycle of a self-hosted access stack:

- validating remote nodes over SSH
- deploying server-side components automatically
- building and caching owner access profiles
- generating shareable guest access
- switching between multiple access modes
- testing real traffic through the active tunnel path
- collecting logs when a route fails

In other words, this is not just a config viewer. It is an operator-facing access client.

## How the current architecture works

At a high level, the project supports two main classes of route:

1. Direct self-hosted access
2. Multi-hop access with a separate first hop

In the multi-hop model, the client first connects to a permitted or more reliable entry surface, and only after that traffic is relayed toward the origin node. In practice this means the first hop can be separated from the final external server and tested independently.

This is what makes the project useful for constrained-network experiments: the first hop, the relay surface, and the final route can be inspected separately rather than treated as one opaque tunnel.

## Access modes

The current client is built around several access modes rather than a single fixed path.

### 1. Direct VLESS + REALITY

This is the simplest self-hosted mode.

Use it when:

- a direct route is sufficient
- you want the cleanest self-hosted setup
- you need a baseline for comparing more complex routes

### 2. Yandex Edge

This is the main multi-hop mode for entry-surface experiments.

Use it when:

- you need a dedicated first hop
- you want the client to connect to a separate entry VM first
- you want to keep the origin node behind that entry layer

This mode is where the project’s “edge-attached” logic becomes important: the first hop and the origin are treated as separate parts of the path.

### 3. VK relay

This mode uses relay-oriented transport experiments based on the VK path.

Use it when:

- you want an alternative route family
- you need a fallback that behaves differently from the direct path
- you want to compare relay-based behavior against direct and edge-based routes

In the client, `VK relay` is not just a toggle. The intended flow is:

1. Select the `VK relay` mode
2. Open the `Servers` screen
3. Paste a fresh VK call link
4. Start the route from there

Without that order, the relay path is not properly initialized.

### 4. Free baseline modes

The project also keeps simple baseline modes for comparison and low-cost operation:

- direct `VLESS + REALITY`
- `WireGuard over xray`

These modes are useful as controls, as lighter self-hosted options, and as a sanity check when a more complex route family fails.

## Split tunneling by default

One of the most important practical details is that the client is designed to avoid sending all traffic through the same path unnecessarily.

Split tunneling is enabled by default in two dimensions:

- site and domain routing
- application-level routing

That means the client is designed from the start to:

- keep traffic that does not need the tunnel outside the tunnel
- reduce unnecessary load on the active route
- avoid forcing all applications through the same path
- preserve a cleaner and more controllable traffic profile

This is not an optional afterthought. It is part of the default operating model.

## What the app already does

The current public snapshot already includes work in these areas:

- Next.js based desktop UI
- Tauri desktop shell
- Android shell sharing the same UI model
- Go provisioning core
- real SSH validation
- real server-side deployment flow
- owner profile generation and caching
- guest/share code generation
- import flow for remote access keys
- runtime diagnostics
- white IP checks
- profile probing and debug logging
- built-in tunnel speed test through the active route path

## Why diagnostics matter here

In ordinary clients the question is often just “did it connect or not?”

Here that is not enough.

Odin One VK is intentionally built to help answer more useful operational questions:

- Did the first hop start?
- Did the second hop come up?
- Is the active route actually passing traffic?
- Which mode worked last time?
- Which profile failed and at what stage?

This is why logging, probing, and route-by-route inspection are first-class parts of the product rather than hidden debug leftovers.

## Repository layout

```text
apps/
  desktop/        main desktop and Android-shared client shell
packages/
  contracts/      shared TypeScript contracts
  ui/             shared UI layer and i18n
core/
  go/             provisioning core and remote orchestration
docs/             notes, rollout docs, and implementation references
```

## Tech stack

- `Next.js` for the main application UI
- `Tauri` for native desktop and Android packaging
- `Go` for provisioning and orchestration logic
- `Rust` for the Tauri host layer and mobile bridge logic
- `xray` as the main route engine

## Local development

Install dependencies:

```bash
npm install
```

Run the desktop UI:

```bash
npm run dev
```

Run the Go core:

```bash
cd core/go
go run ./cmd/mvpd
```

Run the Tauri desktop shell:

```bash
npm run desktop:tauri:dev
```

Build Android artifacts:

```bash
npm run android:tauri:build
```

## Project direction

The project is moving toward a more complete self-hosted operator client with:

- cleaner route selection
- stronger field diagnostics
- better multi-hop deployment safety
- more predictable Android operation
- improved profile handling for owner and guest users

## Thanks

Special thanks to these repositories for ideas, prior art, and useful reference points while exploring relay and constrained-network workflows:

- [cacggghp/vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy)
- [igareck/vpn-configs-for-russia](https://github.com/igareck/vpn-configs-for-russia)
