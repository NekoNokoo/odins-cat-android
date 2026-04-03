# Android CDN / Anti-Whitelist Third Mode Scaffolding

## Goal

Start the Android third mode as an additive, opt-in track without destabilizing the working `VLESS + REALITY` default path.

For Russian clients this should be read as a hidden `whitelist-front` mode:

- not "CDN for its own sake"
- but `VLESS` over a whitelist-reachable HTTPS front
- with stable direct `REALITY` preserved as the default lane

This document is intentionally about scaffolding, not production activation.

One useful clue from a working external whitelist config is that the transport can still be `VLESS + REALITY`, while the effective bypass depends on a policy layer:

- DNS query strategy biased toward IP resolution
- direct handling for local-service domain families
- explicit anti-loop blocking for the chosen visible surface

This pass models that layer inside the hidden CDN schema, but does not activate it yet.

The next additive step on this branch now projects part of that policy into the hidden active `cdn-ws-lab` config:

- direct keyword/domain rules
- anti-loop block keyword/domain rules
- explicit block for the selected front host
- direct-surface DNS routing to a separate `local` resolver for supported local-service families

Phone-side runtime captures now surface CDN policy diagnostics directly in the snapshot:

- `cdnRoutingDnsQueryStrategy`
- `cdnRoutingDomainStrategy`
- `cdnRoutingDomainMatcher`
- `cdnRoutingDirectRuleCount`
- `cdnRoutingBlockRuleCount`
- `cdnRoutingBlockSelectedFrontHost`
- `cdnDnsLocalResolverEnabled`
- `frontConnectHost`
- `frontConnectPort`

The owner-only handset helper [android-cdn-lab-session.sh](/Users/vladislav/Downloads/odin-one-vk-git/apps/desktop/scripts/android-cdn-lab-session.sh) now wakes `MainActivity` before control/candidate/restore starts, waits for the expected snapshot family, and retries the hidden candidate start once before capture if Xiaomi/Android 15 surfaces a stale stable lane. That makes both candidate capture and restore back to `direct-reality` much more reliable on this handset class.

The preset apply helper [android-reality-apply-preset.sh](/Users/vladislav/Downloads/odin-one-vk-git/apps/desktop/scripts/android-reality-apply-preset.sh) now force-stops the package before patching shared prefs. On Xiaomi/Android 15 this prevents a live stable runtime from flushing stale `last_request` state over a freshly written hidden CDN preset during shutdown, which was the main cause of false `direct-reality` candidate captures.

The preset helper [android-reality-profile-preset.sh](/Users/vladislav/Downloads/odin-one-vk-git/apps/desktop/scripts/android-reality-profile-preset.sh) now also supports reusable owner-only CDN plan files via:

- `ODIN_ONE_CDN_PLAN_FILE`
- `ODIN_ONE_CDN_PLAN_SELECT_TAG`
- `ODIN_ONE_CDN_PLAN_SELECT_INDEX`

That lets us keep a small JSON shortlist of real `front/origin` pairs and select one candidate at a time without hand-editing env vars for every handset run.

Plan entries can now also separate the visible front from the actual dial target via optional `connectHost` / `connectPort` fields. This keeps the hidden family closer to the working Happ posture where TLS/HTTP metadata can present one surface while the client dials another.

The full DNS part of the Happ-style posture is still not a 1:1 mapping, because `sing-box` does not expose a direct `UseIP` toggle with the same semantics. The current hidden CDN family now uses a safer supported subset: direct-surface DNS rules routed to a `local` resolver, while the rest stays on the default resolver.

## Current Android extension points

The current Android runtime already has a clean additive seam:

1. `apps/desktop/src-tauri/src/mobile_bridge.rs`
   - resolves the Android start request from owner/imported profile JSON
   - keeps invite/import flow and deploy flow outside the runtime itself
2. `apps/desktop/src-tauri/gen/android/app/src/main/java/com/odinone/desktop/vk/VpnRuntimePlugin.kt`
   - normalizes request args before `VpnService` launch
   - reuses or restarts the runtime based on normalized request identity
3. `apps/desktop/src-tauri/gen/android/app/src/main/java/com/odinone/desktop/vk/VpnRuntimeLibbox.kt`
   - converts profile-local runtime blocks into normalized args
   - computes the `profileHash`
   - chooses the builder/runtime branch
4. `apps/desktop/src-tauri/gen/android/app/src/main/java/com/odinone/desktop/vk/VpnRuntimeService.kt`
   - drives lifecycle, startup telemetry, failure classification, and restore persistence
5. `apps/desktop/app/_components/control-center.tsx`
   - surfaces runtime diagnostics from `LocalTunnelState`

That means the safest third-mode insertion point is not the deploy layer and not the invite/import schema first.
It is the existing Android runtime normalization and diagnostics path.

## Safest implementation path

The safest path is:

- keep stable `direct-reality` as the default runtime family
- add a separate hidden family: `cdn-anti-whitelist`
- keep it `scaffold_only` by default
- allow only one narrow hidden activation slice first: `mode = lab` plus `transport = websocket`
- give it its own normalized args, `profileHash`, diagnostics fields, preset, and builder branch
- fail closed for every other transport/mode combination before any provider-backed traffic path becomes active

This branch now does exactly that:

- `runtimeFamily`
  - `direct-reality`
  - `vk-relay`
  - `cdn-anti-whitelist`
- `activationState`
  - `active`
  - `scaffold_only`
- hidden profile block:

```json
{
  "androidRuntime": {
    "cdnAntiWhitelist": {
      "enabled": true,
      "provider": "generic",
      "transport": "websocket",
      "frontSelection": "ordered",
      "frontPool": [
        {
          "host": "allowed-front-a.example.com",
          "port": 443,
          "connectHost": "owner-edge-a.example.net",
          "connectPort": 9443,
          "path": "/odin-edge-a",
          "tlsServerName": "allowed-front-a.example.com",
          "hostHeader": "allowed-front-a.example.com",
          "provider": "generic",
          "tag": "primary-whitelist"
        },
        {
          "host": "allowed-front-b.example.com",
          "port": 443,
          "path": "/odin-edge-b",
          "tlsServerName": "allowed-front-b.example.com",
          "hostHeader": "allowed-front-b.example.com",
          "provider": "generic",
          "tag": "backup-whitelist"
        }
      ],
      "origin": {
        "host": "origin.example.com",
        "port": 443,
        "scheme": "https",
        "path": "/odin-origin"
      },
      "bootstrap": "direct-reality",
      "routingPolicy": {
        "dnsQueryStrategy": "use_ip",
        "domainStrategy": "ip_if_non_match",
        "domainMatcher": "hybrid",
        "directDomainKeywords": [
          "vk",
          "mail.ru",
          "gosuslugi",
          "ozon",
          "wildberries"
        ],
        "blockedDomainKeywords": [],
        "blockedDomains": [],
        "blockSelectedFrontHost": true
      }
    }
  }
}
```

- separate third-mode branch inside `VpnRuntimeLibbox.prepareRuntime(...)`
- selected front metadata in normalized args, snapshot diagnostics, and scaffold output:
  - `frontHost`
  - `frontConnectHost`
  - `frontConnectPort`
  - `frontPath`
  - `frontProvider`
  - `frontTag`
- hidden transport blueprint fields for future activation:
  - per-front `port`
  - per-front `tlsServerName`
  - per-front `hostHeader`
  - nested `origin.host`
  - nested `origin.port`
  - nested `origin.scheme`
  - nested `origin.path`
- hidden client policy blueprint fields for future activation:
  - `routingPolicy.dnsQueryStrategy`
  - `routingPolicy.domainStrategy`
  - `routingPolicy.domainMatcher`
  - `routingPolicy.directDomainKeywords[]`
  - `routingPolicy.directDomains[]`
  - `routingPolicy.blockedDomainKeywords[]`
  - `routingPolicy.blockedDomains[]`
  - `routingPolicy.blockSelectedFrontHost`
- scaffold plan file output at:
  - `files/vpn-runtime/cdn-anti-whitelist-scaffold.json`
- scaffold plan now also carries future activation templates:
  - `clientBuilderSpec`
  - `serverBuilderSpec`
  - `routingPolicyPlan`
  - `dnsPlanTemplate`
  - `outboundSetTemplate`
  - `routePlanTemplate`
- explicit startup refusal with a `scaffold_only` diagnostic failure code for non-activated combinations
- hidden websocket lab activation now writes:
  - `files/vpn-runtime/active-cdn-anti-whitelist.json`
  - while still emitting `cdn-anti-whitelist-scaffold.json` beside it
- hidden websocket lab activation intentionally keeps:
  - stable `direct-reality` as default
  - boot restore off
  - system restore resume ineligible until a later phase

## Realistic initial CDN-backed path

The current realistic first activation target is:

- `VLESS` over `WebSocket` or `XHTTP`
- over standard HTTPS semantics
- through a whitelist-reachable HTTPS front hostname
- as a separate family from direct `REALITY`

What is not realistic as the first step:

- pretending generic CDN proxying can transparently carry current direct `REALITY`
- replacing the stable direct path
- routing raw TCP through a provider-specific client requirement

Reason:

- Project X Browser Dialer documents that browser-mediated anti-blocking currently supports only `WebSocket` and `XHTTP`
- Cloudflare documents proxied application routing around HTTPS and WebSocket semantics, while non-HTTP published services in Cloudflare Tunnel require client-side `cloudflared`

So the first real CDN family should be HTTP-shaped, not REALITY-shaped.

In practice the initial Android design should look like:

- client: `VLESS + WS + TLS`
- front layer: a hidden ordered pool of whitelist-reachable hostnames with explicit `port`, `tlsServerName`, and `hostHeader`
- origin: a dedicated inbound for this family with explicit hidden `origin` host/port/scheme/path
- fallback/bootstrap: stable direct `REALITY`

## What to do now

Safe to implement now:

- third-mode contract fields and runtime snapshot fields
- hidden profile block and hidden preset
- hidden front-pool selection with diagnostics-only exposure
- hidden DNS/split-routing/anti-loop policy scaffold with diagnostics-only exposure
- hidden builder templates for future DNS and route plans derived from that policy scaffold
- separate normalization and builder/runtime branch
- hidden websocket lab builder path for owner-only `WS + TLS` activation
- owner-lab origin package helper for reverse-proxy and loopback-core prep
- separate `profileHash`
- diagnostics and failure classification placeholders
- rollout documentation

## What to design next

Still design work, not safe default code yet:

- server-side origin config for `WebSocket` or `XHTTP`
- CDN/provider-specific constraints per provider
- DNS-side equivalent for the Happ-style `UseIP` posture inside the hidden CDN family
- share/import schema for CDN-capable invites if this mode graduates past hidden owner-only use
- device validation matrix for:
  - startup
  - quick test
  - Wi-Fi <-> LTE
  - Always-on
  - Lockdown
  - boot restore policy for this family
  - anti-whitelist behavior under blocked-direct scenarios

Validation runbook:

- `docs/android-cdn-anti-whitelist-validation.md`
- `apps/desktop/scripts/android-cdn-origin-lab.sh`

## Risk split

Low risk:

- new `runtimeFamily` and `activationState` fields
- hidden preset tooling
- docs
- diagnostics-only UI exposure
- separate `profileHash` path

Medium risk:

- persisting hidden third-mode overrides across app-driven starts
- future owner/imported profile propagation for this family
- allowing any restore behavior for a non-default family

High risk:

- switching default away from stable `direct-reality`
- trying to reuse direct `REALITY` semantics as if they were CDN-native
- assuming a provider works unless its specific front host is actually reachable from Russian whitelist networks
- broad transport rewrite in the current stable branch
- touching `vk-turn-proxy`
- widening invite/import semantics before the transport is validated on-device

## Rollout guardrails

- stable `direct-reality` stays default
- third mode stays hidden
- third mode stays opt-in
- third mode stays additive
- third mode stays `scaffold_only` unless the hidden profile explicitly requests `mode = lab` with `transport = websocket`
- even in `lab`, the family must stay owner-only and must not participate in restore/Always-on rollout yet
