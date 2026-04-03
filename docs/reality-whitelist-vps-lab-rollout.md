# Reality Whitelist VPS Lab Rollout

This runbook is the next step after the external `igareck` benchmark:

- keep the stable REALITY lane on `443` untouched
- copy one successful public candidate shape onto our own VPS
- expose it as a separate additive lab inbound on a new port
- verify it locally through a loopback SOCKS smoke test before touching Android

The current rollout scope is intentionally narrow:

- `vless`
- `security=reality`
- `type=tcp` or `type=grpc`
- one candidate at a time

## Why this path

The external benchmark showed that the successful public configs behave like full endpoint shapes:

- `host:port`
- `transport`
- `security`
- `serverName`

They do **not** behave like "any random whitelist SNI on one existing REALITY inbound".

So the safest copy-on-our-VPS path is:

1. pick one successful public candidate
2. add one separate lab inbound for it on our VPS
3. export one external client URI for that lab inbound
4. verify it locally in isolation

## Script

Use:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-rollout.sh \
  --host 95.81.120.226 \
  --ssh-key ~/.ssh/afina_bot \
  --candidate-uri "$(sed -n '1p' /tmp/odin-one-igareck-shortlist-live/subscription.txt)"
```

What it does:

- fetches live `/opt/whitelist/config/xray-server.json`
- fetches live `/opt/whitelist/profiles/owner-profile.json`
- adds or updates one separate lab inbound like `reality-lab-pimg-mycdn-me-tcp`
- backs up the live config on the server
- validates the new config with `/opt/whitelist/bin/xray run -test`
- restarts `whitelist-xray.service`
- exports a single `subscription.txt` for the new inbound
- runs an isolated local smoke test through loopback SOCKS

## Current safe defaults

- reuses the live owner REALITY identity from the owner profile:
  - `uuid`
  - `publicKey`
  - `shortId`
- reuses the live server private key from the stable REALITY inbound
- keeps the stable lane on `443`
- defaults the lab port to the candidate port if it is additive (`>1024`)
- defaults `dest` to `<serverName>:443`

## Output

The rollout writes a timestamped directory under:

- `/tmp/odin-one-reality-vps-lab/<stamp>-<slug>`

Key files:

- `remote-xray-server.json`
- `remote-owner-profile.json`
- `xray-server.lab.json`
- `lab-metadata.json`
- `subscription.txt`
- `summary.md`
- `rollback.sh`
- `smoke/summary.md`

## First candidates

The newest shortlist wave should start with the entries that now pass both isolated smoke and our own VPS lab copy:

- `id.x5.ru` as `tcp + reality` on `30443`
- `eh.vk.com` as `tcp + reality` on `40443`
- keep `ads.x5.ru` as the `grpc + reality` control on `20443`

The older `pimg.mycdn.me` and `sun6-22.userapi.com` lanes stay useful as control samples, but the current strongest signal from the fresh mobile dataset is the `id.x5.ru` / `eh.vk.com` pair.

## Current live findings

On our own VPS `95.81.120.226`, the first additive lab wave already produced these results:

- `pimg.mycdn.me` on `10443` as `tcp + reality`
  - separate lab inbound is live
  - local isolated smoke passed with `204`
- `sun6-22.userapi.com` on `7443` as `tcp + reality`
  - separate lab inbound is live
  - local isolated smoke passed with `204`
- `ads.x5.ru` on `20443` as `grpc + reality`
  - separate lab inbound is live
  - local isolated smoke currently fails with `curl_exit_97`

That means the VPS lab rollout mechanism is already confirmed for at least two `tcp + reality` candidates on our own server, without touching the stable lane on `443`.

The latest additive wave extends that result:

- `id.x5.ru` on `30443` as `tcp + reality`
  - separate lab inbound is live
  - isolated local smoke passed with `204`
  - isolated `redirector.googlevideo.com/generate_204` smoke passed
- `eh.vk.com` on `40443` as `tcp + reality`
  - separate lab inbound is live
  - isolated local smoke passed with `204`
  - isolated `redirector.googlevideo.com/generate_204` smoke passed

Fresh artifacts for that wave:

- rollout: `/tmp/odin-one-reality-vps-lab-id-x5-ru-30443`
- rollout: `/tmp/odin-one-reality-vps-lab-eh-vk-com-40443`
- live verify: `/tmp/odin-one-reality-vps-lab-verify-after-id-eh`
- promoted dataset: `/tmp/odin-one-reality-vps-lab-promote-after-id-eh`

The rollout helper now also waits for the new lab port after restart and writes `rollback.sh` before the optional smoke phase, so a slow listener no longer hides an otherwise successful additive rollout.

## Bundle for phone testing

To combine a few successful VPS lab rollouts into one external-client subscription:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-bundle.sh \
  --lab-dir /tmp/odin-one-reality-vps-lab-pimg-live \
  --lab-dir /tmp/odin-one-reality-vps-lab-userapi-live \
  --lab-dir /tmp/odin-one-reality-vps-lab-x5-grpc-live-clean \
  --only-passed-smoke
```

This writes:

- `subscription.txt`
- `bundle.json`
- `summary.md`

The fastest next phone test is to import that bundled `subscription.txt` into `NekoBox` or `Karing` and try the passed `tcp + reality` entries first.

## Edge / origin bundle

Once the main blocker becomes raw VPS reachability on LTE rather than config shape, move one step up and build a controlled edge handoff:

```bash
zsh apps/desktop/scripts/reality-whitelist-edge-origin-bundle.sh \
  --dataset /tmp/odin-one-reality-vps-lab-promote-after-id-eh/dataset.json \
  --tag reality-lab-id-x5-ru-tcp \
  --tag reality-lab-eh-vk-com-tcp \
  --edge-host edge-owner.example.net \
  --edge-port 443 \
  --output-dir /tmp/odin-one-reality-edge-origin-bundle
```

This keeps the current VPS as the hidden REALITY origin, but rewrites the dial target to a future controlled edge and generates:

- rewritten `subscription.txt`
- `android-dataset.json` with `connectHost/connectPort`
- `haproxy.cfg`
- `nginx.stream.conf`

That is the safer next pass once raw `95.81.120.226:*` is proven unreachable from the handset LTE path.

## Live status

To inventory the VPS after a few lab rollouts:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-status.sh \
  --host 95.81.120.226 \
  --ssh-key ~/.ssh/afina_bot \
  --include-stable
```

This writes:

- `inventory.json`
- `summary.md`
- `subscription.txt`

That `subscription.txt` is generated from the live server config itself, so it is a better source of truth than manually collecting old local rollout folders.

## Safe remove

To remove one lab inbound without touching the stable lane:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-remove.sh \
  --host 95.81.120.226 \
  --ssh-key ~/.ssh/afina_bot \
  --tag reality-lab-ads-x5-ru-grpc \
  --port 20443
```

This:

- validates the new config with `xray run -test`
- backs up the live config on the VPS
- restarts `whitelist-xray.service`
- confirms the removed port is no longer listening

## Verify wave

To verify all currently live VPS lab inbounds and build fresh phone packs from live state:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-verify.sh \
  --host 95.81.120.226 \
  --ssh-key ~/.ssh/afina_bot
```

This runs:

1. `reality-whitelist-vps-lab-status.sh`
2. `reality-whitelist-local-smoke.sh` on the live subscription
3. a join step that writes:
   - `verify.json`
   - `summary.md`
   - `phone-subscription.txt`
   - `phone-subscription-with-stable.txt`

That makes the next phone test much safer, because the phone pack is generated from the **current live server config + current smoke results**, not from older local rollout folders.

## Promote verified endpoints

When a live verify run looks good, promote it into a reusable operator dataset:

```bash
zsh apps/desktop/scripts/reality-whitelist-vps-lab-promote.sh \
  --verify /tmp/odin-one-reality-vps-lab-verify-live-after-grpc-fix/verify.json
```

This writes:

- `dataset.json`
- `summary.md`
- `subscription.txt`

The promoted dataset is meant to be the next handoff layer before deeper Odin integration. It keeps:

- stable control
- smoke-passed VPS lab entries
- transport metadata like `grpcServiceName`, `flow`, and `dest`

but still avoids widening invite/autodeploy too early.
