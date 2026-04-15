# Android REALITY Profile Presets

These presets are meant for isolated handset validation runs.

Safety rules:

- keep the stable path as the control sample
- enable only one knob group at a time in the first pass
- do not combine DNS, reload, and leak presets in the same initial run
- save one handset dump per preset run

Helper:

```bash
apps/desktop/scripts/android-reality-profile-preset.sh list
```

Recommended first-pass sequence:

1. `baseline`
2. `boot-restore`
3. `dot-google`
4. `network-reload`

Available presets:

- `baseline`
  - explicit stable pin for the control sample
- `boot-restore`
  - stable mode plus `autoRestoreOnBoot = true`
- `dot-google`
  - isolated DoT using `8.8.8.8` plus `dns.google` SNI without changing leak/reload posture
- `doh-cloudflare`
  - isolated DoH using Cloudflare without changing leak/reload posture
- `network-reload`
  - isolated reload-on-network-change with `1500ms` debounce while DNS and leak posture stay on stable defaults
- `leak-balanced`
  - stricter route posture plus selective LAN-only direct bypass for `10.0.0.0/8`, `192.168.0.0/16`, and `169.254.0.0/16`
  - intentionally excludes the observed noisy `172.16.0.0/12` private tail from direct bypass
- `leak-tight`
  - isolated stricter route posture with private bypass disabled while DNS and reload stay on stable defaults
- `per-app-captive-bypass`
  - experimental captive portal bypass via `excludePackages`
- `reality-whitelist-scaffold`
  - hidden operator-facing scaffold for the separate `reality-whitelist-assisted` family
  - carries an ordered hidden `hints` pool with `serverName`, `cidrBucket`, `source`, and `tag`
  - keeps stable `direct-reality` as the control sample and forces boot restore out of scope
  - supports env overrides for first owner-only hint curation:
    - `ODIN_ONE_REALITY_BASE_MODE`
    - `ODIN_ONE_REALITY_HINTS_FILE`
    - `ODIN_ONE_REALITY_HINT_SELECTION`
    - `ODIN_ONE_REALITY_HINT_BOOTSTRAP`
    - `ODIN_ONE_REALITY_HINT_SELECT_TAG`
    - `ODIN_ONE_REALITY_HINT_SELECT_INDEX`
    - `ODIN_ONE_REALITY_HINT_SERVER_NAME`
    - `ODIN_ONE_REALITY_HINT_CIDR_BUCKET`
    - `ODIN_ONE_REALITY_HINT_SOURCE`
    - `ODIN_ONE_REALITY_HINT_TAG`
    - `ODIN_ONE_REALITY_BACKUP_HINT_SERVER_NAME`
    - `ODIN_ONE_REALITY_BACKUP_HINT_CIDR_BUCKET`
    - `ODIN_ONE_REALITY_BACKUP_HINT_SOURCE`
    - `ODIN_ONE_REALITY_BACKUP_HINT_TAG`
  - pairs with:
    - `docs/android-reality-whitelist-assisted-scaffolding.md`
    - `apps/desktop/scripts/android-reality-whitelist-curate.sh`
    - `apps/desktop/scripts/android-reality-whitelist-curate-community.sh`
    - `apps/desktop/scripts/android-reality-whitelist-session.sh`
    - `apps/desktop/scripts/android-reality-whitelist-manual-session.sh`
    - `apps/desktop/scripts/android-reality-whitelist-manual-batch.sh`
- `reality-whitelist-lab`
  - hidden owner-only active preset for the same `reality-whitelist-assisted` family
  - reuses the stable REALITY builder and overrides only the selected curated `serverName`
  - intentionally keeps restore / boot restore out of scope for this phase
  - session helper auto-runs a quick connectivity probe by default so `lastTest` lands in the capture
  - uses the same hint env overrides as `reality-whitelist-scaffold`
  - pairs with:
    - `docs/android-reality-whitelist-assisted-scaffolding.md`
    - `apps/desktop/scripts/android-reality-whitelist-session.sh --preset reality-whitelist-lab`
- `cdn-scaffold`
  - hidden third-mode scaffold for the future `cdn-anti-whitelist` family
  - carries an ordered hidden `frontPool` so we can validate whitelist-reachable HTTPS fronts without touching the stable default lane
  - now also accepts a reusable plan file via:
    - `ODIN_ONE_CDN_PLAN_FILE`
    - `ODIN_ONE_CDN_PLAN_SELECT_TAG`
    - `ODIN_ONE_CDN_PLAN_SELECT_INDEX`
  - front entries now also carry future `WS + TLS` blueprint fields such as `port`, `tlsServerName`, and `hostHeader`, plus optional `connectHost` / `connectPort` dial-target overrides and a hidden nested `origin` block
  - now also seeds a hidden `routingPolicy` scaffold inspired by a working whitelist config:
    - `dnsQueryStrategy = use_ip`
    - `domainStrategy = ip_if_non_match`
    - `domainMatcher = hybrid`
    - direct local-service keyword families
    - `blockSelectedFrontHost = true`
  - supports env overrides for policy scaffolding:
    - `ODIN_ONE_CDN_ROUTING_DNS_QUERY_STRATEGY`
    - `ODIN_ONE_CDN_ROUTING_DOMAIN_STRATEGY`
    - `ODIN_ONE_CDN_ROUTING_DOMAIN_MATCHER`
    - `ODIN_ONE_CDN_ROUTING_DIRECT_KEYWORDS`
    - `ODIN_ONE_CDN_ROUTING_DIRECT_DOMAINS`
    - `ODIN_ONE_CDN_ROUTING_BLOCK_KEYWORDS`
    - `ODIN_ONE_CDN_ROUTING_BLOCK_DOMAINS`
    - `ODIN_ONE_CDN_ROUTING_BLOCK_SELECTED_FRONT_HOST`
  - pairs with:
    - `docs/android-cdn-anti-whitelist-validation.md`
  - stays `scaffold_only` and must not replace the stable direct `VLESS + REALITY` control sample
- `cdn-ws-lab`
  - hidden owner-only activation preset for the first runnable `cdn-anti-whitelist` transport path
  - currently enables only `mode = lab` plus `transport = websocket`
  - still must not replace the stable direct `VLESS + REALITY` control sample
  - intentionally keeps restore / boot restore out of scope for this phase
  - can now load reusable owner-lab front/origin plans from:
    - `ODIN_ONE_CDN_PLAN_FILE`
    - `ODIN_ONE_CDN_PLAN_SELECT_TAG`
    - `ODIN_ONE_CDN_PLAN_SELECT_INDEX`
  - supports env overrides for real owner-lab values:
    - `ODIN_ONE_CDN_FRONT_HOST`
    - `ODIN_ONE_CDN_FRONT_PORT`
    - `ODIN_ONE_CDN_CONNECT_HOST`
    - `ODIN_ONE_CDN_CONNECT_PORT`
    - `ODIN_ONE_CDN_FRONT_PATH`
    - `ODIN_ONE_CDN_TLS_SERVER_NAME`
    - `ODIN_ONE_CDN_HOST_HEADER`
    - `ODIN_ONE_CDN_FRONT_TAG`
    - `ODIN_ONE_CDN_ORIGIN_HOST`
    - `ODIN_ONE_CDN_ORIGIN_PORT`
    - `ODIN_ONE_CDN_ORIGIN_SCHEME`
    - `ODIN_ONE_CDN_ORIGIN_PATH`
    - `ODIN_ONE_CDN_FRONT_SELECTION`
    - `ODIN_ONE_CDN_TRANSPORT`
    - `ODIN_ONE_CDN_BOOTSTRAP`
    - all `ODIN_ONE_CDN_ROUTING_*` policy-scaffold env overrides from `cdn-scaffold`
  - pairs well with:
    - `apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-ws-lab --output-dir /tmp/odin-one-android-cdn-origin-lab`
    - `apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-ws-lab --strict`
    - `apps/desktop/scripts/android-cdn-lab-session.sh`
- `cdn-xhttp-lab`
  - hidden owner-only activation preset for the additive `cdn-anti-whitelist` `xhttp` lane
  - enables `mode = lab` plus `transport = xhttp`
  - keeps the same front/origin plan-file flow and `ODIN_ONE_CDN_*` env overrides as `cdn-ws-lab`
  - stays owner-only and must not replace the stable direct `VLESS + REALITY` control sample
  - pairs well with:
    - `apps/desktop/scripts/android-reality-profile-preset.sh cdn-xhttp-lab`
    - `apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-xhttp-lab --output-dir /tmp/odin-one-android-cdn-origin-lab`
    - `apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-xhttp-lab --strict`
    - `apps/desktop/scripts/android-cdn-origin-lab-rollout.sh --preset cdn-xhttp-lab --host 95.81.120.226 --ssh-key ~/.ssh/afina_bot`
    - when replacing an already-running dedicated lab inbound on the same loopback port, add `--lab-tag <existing-tag>`
- `cdn-xhttp-native-lab`
  - hidden owner-only activation preset for the Android native `xray` sidecar lane
  - enables `mode = lab`, `transport = xhttp`, and `engine = xray-native`
  - targets true handset `xhttp` execution instead of the temporary `httpupgrade` substitute
  - stays owner-only and must not replace the stable direct `VLESS + REALITY` control sample
  - pairs well with:
    - `apps/desktop/scripts/android-reality-profile-preset.sh cdn-xhttp-native-lab`
    - `apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-xhttp-native-lab --strict`
- `cdn-xhttp-yandex-camouflage-lab`
  - hidden owner-only activation preset for the `ya.ru`-ish first-hop camouflage path
  - enables `transport = xhttp`, `engine = xray-native`, `xhttpMode = packet-up`
  - also sets `tlsAlpn = h2,http/1.1`, `tlsAllowInsecure = true`, and `camouflageHost = ya.ru`
  - intended for Yandex-edge lab runs where the handset dials the Yandex IP directly but presents `ya.ru` as first-hop TLS SNI / Host
  - stays owner-only and must not replace the stable direct `VLESS + REALITY` control sample
  - pairs well with:
    - `apps/desktop/scripts/android-reality-profile-preset.sh cdn-xhttp-yandex-camouflage-lab`
    - `apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-xhttp-yandex-camouflage-lab --strict`
    - `apps/desktop/scripts/android-cdn-yandex-edge-rollout.sh --preset cdn-xhttp-yandex-camouflage-lab --edge-host 62.84.123.148 --edge-ssh-key ~/.ssh/yandex_edge_test --prepare-only`
- `cdn-httpupgrade-lab`
  - hidden owner-only activation preset for the additive `cdn-anti-whitelist` `httpupgrade` lane
  - enables `mode = lab` plus `transport = httpupgrade`
  - useful when the Android runtime rejects `xhttp`, but a browser-shaped upgrade transport is still acceptable for owner-lab validation
  - pairs well with:
    - `apps/desktop/scripts/android-reality-profile-preset.sh cdn-httpupgrade-lab`
    - `apps/desktop/scripts/android-cdn-origin-lab.sh --preset cdn-httpupgrade-lab --output-dir /tmp/odin-one-android-cdn-origin-lab`
    - `apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-httpupgrade-lab --strict`

Suggested workflow:

```bash
apps/desktop/scripts/android-reality-profile-preset.sh baseline
apps/desktop/scripts/android-reality-capture-run.sh baseline
```

Then repeat with the next preset and fill:

- `docs/android-reality-validation-report-template.md`

Direct handset helper:

```bash
apps/desktop/scripts/android-reality-apply-preset.sh dot-google
```

This patches the persisted Android REALITY request on the connected debug handset,
then force-stops the package so the next launch validates the preset from a clean process.

Curated whitelist-assisted workflow:

```bash
apps/desktop/scripts/android-reality-whitelist-curate.sh \
  --input /tmp/white-sni.txt \
  --cidr-map /tmp/white-cidr-map.tsv

ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh
```

Community bootstrap workflow:

```bash
apps/desktop/scripts/android-reality-whitelist-curate-community.sh \
  --output-dir /tmp/odin-one-reality-whitelist-community \
  --limit 12
```

Single-hint owner-lab run:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh --hint-tag candidate-01-max-ru
```

Single-hint owner-lab active run:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh \
  --preset reality-whitelist-lab \
  --hint-tag candidate-01-max-ru
```

Batch owner-lab run:

```bash
apps/desktop/scripts/android-reality-whitelist-batch-session.sh \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders
```

Manual batch owner-lab run through the in-app launcher:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders
```
