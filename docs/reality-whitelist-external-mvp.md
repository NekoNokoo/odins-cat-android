# Reality Whitelist External MVP

This runbook is the safest first MVP for whitelist-inspired testing:

- do not touch Android runtime or UI yet
- do not replace the stable Odin One path
- generate external-client `vless://` candidates from the existing owner profile
- patch the current server-side REALITY inbound to accept extra `serverNames`

The current MVP scope is intentionally narrow:

- existing server-side REALITY inbound only
- external V2Ray-compatible clients first
- `type=tcp` + `security=reality` only

Why only TCP for the first MVP:

- the current deployed xray REALITY inbound in Odin One is the existing TCP path
- `xhttp`, `grpc`, and `ws` need a separate server-side transport rollout
- this MVP is meant to answer one question first:
  can our server accept whitelist-inspired `serverName` candidates at all

## Inputs

You need:

- a cached owner profile in `~/Library/Caches/odin-one/profiles/<host>-owner-profile.json`
- a whitelist hint dataset from the curator scripts

Example owner profile path:

```bash
~/Library/Caches/odin-one/profiles/95.81.120.226-owner-profile.json
```

Example curated dataset:

```bash
zsh apps/desktop/scripts/android-reality-whitelist-curate-community.sh \
  --output-dir /tmp/odin-one-reality-whitelist-community-mvp \
  --max-per-family 1 \
  --limit 8
```

If the source is an external community subscription rather than our own exported dataset, decode it first:

```bash
zsh apps/desktop/scripts/reality-whitelist-decode-vless.sh \
  --subscription-url https://raw.githubusercontent.com/zieng2/wl/main/vless_lite.txt \
  --mode summary \
  --output-dir /tmp/odin-one-zieng2-vless-lite-decode
```

That additive helper does not touch runtime state. It only splits raw `vless://` entries into structured fields such as host, port, transport, security, SNI, `serviceName`, `pbk`, and `sid`, so repeated whitelist surfaces can be reviewed before any owner-lab rollout decision.

If you also have raw LTE reachability results from:

```bash
zsh apps/desktop/scripts/android-whitelist-front-probe.sh ...
```

then narrow the decoded dataset down to only the `sni` values that already proved reachable on the handset:

```bash
zsh apps/desktop/scripts/reality-whitelist-shortlist-reachable-sni.sh \
  --decoded-json /tmp/odin-one-zieng2-vless-lite-decode/decoded.json \
  --probe-results /tmp/odin-one-android-whitelist-front-probe/<run>/results.json \
  --output-dir /tmp/odin-one-zieng2-reachable-sni-shortlist
```

That produces a reusable shortlist `json + jsonl + subscription.txt` for external-client experiments without widening anything inside the Android runtime.

## Step 1. Export external client candidates

```bash
zsh apps/desktop/scripts/reality-whitelist-export-subscription.sh \
  --host 95.81.120.226 \
  --reality-port 443 \
  --hints-file /tmp/odin-one-reality-whitelist-community-mvp/dataset.json \
  --surface sni \
  --limit 6 \
  --label-prefix "Odin One SNI MVP" \
  --output-dir /tmp/odin-one-reality-whitelist-external-mvp
```

Output files:

- `/tmp/odin-one-reality-whitelist-external-mvp/subscription.txt`
- `/tmp/odin-one-reality-whitelist-external-mvp/candidates.json`
- `/tmp/odin-one-reality-whitelist-external-mvp/server-names.txt`
- `/tmp/odin-one-reality-whitelist-external-mvp/summary.md`

Notes:

- the stable control `serverName` is included by default
- `--reality-port` is useful when the live server port differs from the cached owner profile
- non-stable entries will not connect until the server-side REALITY inbound accepts those names

## Step 2. Patch the xray REALITY inbound locally

Copy the current xray config from the server, patch it locally, then upload it back:

```bash
scp root@95.81.120.226:/opt/whitelist/config/xray-server.json /tmp/xray-server.json
```

```bash
zsh apps/desktop/scripts/reality-whitelist-patch-xray-config.sh \
  --config /tmp/xray-server.json \
  --hints-file /tmp/odin-one-reality-whitelist-community-mvp/dataset.json \
  --surface sni \
  --limit 6 \
  --output /tmp/xray-server-whitelist-mvp.json
```

Upload the patched config and restart xray:

```bash
scp /tmp/xray-server-whitelist-mvp.json root@95.81.120.226:/opt/whitelist/config/xray-server.json
ssh root@95.81.120.226 'systemctl restart whitelist-xray.service && systemctl is-active whitelist-xray.service'
```

This patch is additive:

- it preserves the existing stable `serverName`
- it only extends `realitySettings.serverNames`

## Step 3. Import into an external client

Import `subscription.txt` into a V2Ray-compatible client such as:

- v2rayN
- v2rayNG
- Nekobox
- Karing

Start with:

- stable control entry first
- then the new whitelist-inspired SNI entries one by one

## Step 4. Run a local smoke test without disconnecting the current macOS VPN

This is a user-space test only:

- starts local `xray` SOCKS on `127.0.0.1:<ephemeral-port>`
- sends only the probe request through `curl --proxy`
- does not touch system routes or the current VPN session

```bash
zsh apps/desktop/scripts/reality-whitelist-local-smoke.sh \
  --subscription /tmp/odin-one-reality-whitelist-external-mvp/subscription.txt \
  --engine sing-box \
  --limit 5 \
  --output-dir /tmp/odin-one-reality-whitelist-live-smoke
```

Smoke outputs:

- `/tmp/odin-one-reality-whitelist-live-smoke/results.json`
- `/tmp/odin-one-reality-whitelist-live-smoke/summary.md`
- per-entry `client-config.json` and `client.log`

## MVP limits

This MVP does not provide a true CIDR solution yet.

Why:

- the current Finland server IP is not a white CIDR surface
- CIDR labels can still be useful for operator grouping and later rollout
- but they do not turn the current server into a white-CIDR endpoint by themselves

This MVP is mainly for:

- proving that Odin One can export whitelist-inspired REALITY candidates from its owner profile
- validating whether extra `serverName` values can reach the current server through external clients
- deciding what should move into Android later

## Current finding

The current single-inbound REALITY layout with `target = www.cloudflare.com:443` is good enough for a stable control check, but it is not a general white-list bypass by itself.

Why:

- in the official Project X REALITY docs, `serverNames` are described as generally staying consistent with `target`
- the actual acceptable values depend on what the `target` itself accepts, usually based on the returned certificate SAN
- this means simply appending unrelated names like `max.ru` or `duma.gov.ru` to one existing REALITY inbound is not enough

Reference:

- [Project X REALITY transport docs](https://xtls.github.io/en/config/transport.html)
