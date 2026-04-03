# Reality Whitelist Edge / Origin Scaffolding

This is the next additive step after the raw VPS lab verdict:

- keep the current VPS as the hidden REALITY origin
- stop treating the raw VPS IP as the handset-facing entry surface
- introduce a separate controlled edge that does TCP pass-through by TLS SNI

Why this path:

- the handset already proved that LTE can reach some whitelist-visible surfaces
- the handset also proved it cannot reach raw `95.81.120.226:30443/40443`
- copying more `vless://` shapes onto the same raw VPS IP will not fix that reachability boundary

So the next thing to validate is not a new client shape, but a new entry surface.

## Model

The intended split is:

- client visible surface
  - `serverName`
  - REALITY metadata such as `pbk`, `sid`, `fp`, `flow`
- controlled edge dial target
  - `connectHost`
  - `connectPort`
- hidden origin
  - `originHost`
  - `originPort`

The edge must stay L4-only:

- no TLS termination
- no REALITY termination
- only TCP pass-through routing by ClientHello SNI

That keeps the current VPS `xray` in charge of REALITY, while the edge only changes the reachable surface.

## Bundle helper

Use:

```bash
zsh apps/desktop/scripts/reality-whitelist-edge-origin-bundle.sh \
  --dataset /tmp/odin-one-reality-vps-lab-promote-after-id-eh/dataset.json \
  --tag reality-lab-id-x5-ru-tcp \
  --tag reality-lab-eh-vk-com-tcp \
  --edge-host edge-owner.example.net \
  --edge-port 443 \
  --output-dir /tmp/odin-one-reality-edge-origin-bundle
```

This writes:

- `bundle.json`
- `routes.json`
- `android-dataset.json`
- `subscription.txt`
- `haproxy.cfg`
- `nginx.stream.conf`
- `summary.md`
- `rollout-checklist.md`

## What the bundle means

- `subscription.txt`
  - external-client smoke pack with rewritten dial host/port pointing at the future edge
- `android-dataset.json`
  - future handoff layer for hidden Android `reality-vps-lab`
  - keeps the original origin port in `port`
  - adds `connectHost` / `connectPort` so the Android runtime can dial the edge instead
- `haproxy.cfg` / `nginx.stream.conf`
  - SNI-routing pass-through examples for a controlled edge

## Android handoff

The hidden Android `reality-vps-lab` flow now also accepts optional:

- `connectHost`
- `connectPort`

That keeps the family additive while making edge/origin testing possible without widening stable `direct-reality`.

The intended order is:

1. prove the new edge with the rewritten external-client `subscription.txt`
2. only then use `android-dataset.json` for owner-only handset passes
3. keep stable `direct-reality` as the control and restore target

## Guardrails

- do not replace the stable REALITY default
- do not widen invite/import
- do not change `vk-proxy`
- do not terminate REALITY on the edge
- do not treat same-host edge/origin scaffolding as field truth for LTE reachability
