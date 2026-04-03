# Android Reality VPS Lab Scaffolding

This track is the Android handoff layer for the live VPS-based REALITY lab endpoints.

It is intentionally additive:

- keep `direct-reality` as the stable default
- keep the older `reality-whitelist-assisted` SNI/CIDR scaffolding intact
- add a separate hidden family for full endpoint-shape validation from our own VPS

## Runtime family

- `runtimeFamily = reality-vps-lab`

This family is owner-only and hidden behind the Android owner lab launcher.

## Hidden launcher modes

- `reality-vps-scaffold`
- `reality-vps-lab`

The scaffold mode surfaces the exact endpoint metadata on-device without committing to a live data plane.
The lab mode brings up a real runtime using the same endpoint shape that already passed isolated smoke tests on our VPS.

## Endpoint shape

The Android owner-lab bridge now carries:

- `serverName`
- `port`
- `connectHost`
- `connectPort`
- `transport`
- `flow`
- `fingerprint`
- `grpcServiceName`
- `grpcAuthority`
- `source`
- `tag`

This mirrors the proven VPS lab candidates more closely than the older `realityWhitelistHints` SNI-only block.

For raw VPS lab entries, `connectHost/connectPort` default to the current VPS origin.
For the next hidden edge/origin pass, they can point at a controlled edge while `port` stays the origin lab port.

## Current intended first wave

The current Android wave should start from the promoted VPS dataset that now includes:

- `id.x5.ru:30443` as `tcp + reality`
- `eh.vk.com:40443` as `tcp + reality`
- `ads.x5.ru:20443` as `grpc + reality`
- keep `pimg.mycdn.me:10443` and `sun6-22.userapi.com:7443` as older control samples

Stable control stays:

- `www.cloudflare.com:443`

## Guardrails

- boot restore must stay off for this family
- stable `443` must remain untouched
- invite/autodeploy stays out of scope until the owner-only phone validation is repeatable

## Autonomous 4G batch

For repeatable field tests on a connected Android handset, use:

```bash
apps/desktop/scripts/android-reality-vps-lab-batch.sh \
  --dataset /tmp/odin-one-reality-vps-lab-promote-rerollout/dataset.json \
  --output-dir /tmp/odin-one-android-reality-vps-lab-batch-4g-live \
  --settle-seconds 12 \
  --test-timeout-seconds 60
```

This owner-only helper:

- derives a stable restore request from `last_request` or `last_attempted_request`
- switches each VPS candidate through the debug bridge without UI taps
- waits for `runtimeFamily = reality-vps-lab` and `status = running`
- runs the built-in Android connectivity test against `https://example.com`
- saves per-run snapshots, full device dumps, and raw runtime artifacts
- restores the stable `direct-reality` lane at the end

Latest 4G whitelist-only field run:

- batch output: `/tmp/odin-one-android-reality-vps-lab-batch-4g-live-v5`
- `ads.x5.ru:20443` surfaced and failed with `Read timed out`
- `sun6-22.userapi.com:7443` surfaced and failed with `connection closed`
- `pimg.mycdn.me:10443` surfaced and failed with `connection closed`

That means the Android/VPS orchestration is now repeatable, but these three endpoint shapes are not yet a confirmed whitelist-bypass win on the current mobile network.

For a single-candidate owner-only hit check with server-side `ss` sampling and a raw cellular port probe, use:

```bash
apps/desktop/scripts/android-reality-vps-hit-check.sh \
  --dataset /tmp/odin-one-reality-vps-lab-promote-after-id-eh/dataset.json \
  --tag reality-lab-id-x5-ru-tcp \
  --output-dir /tmp/odin-one-android-reality-vps-hit-check-id-x5
```

That helper is intentionally narrower than the batch:

- keeps one `reality-vps-lab` candidate active long enough to run an explicit test
- samples remote `ss` for the selected VPS lab port during the run-test window
- runs a second raw cellular port probe bound to the detected underlying interface
- restores stable `direct-reality` unless `--skip-restore` is used

Use it when the main question is no longer "did the hidden runtime surface?" but "did the handset reach our VPS lab port at all?"

Latest promoted VPS dataset:

- dataset: `/tmp/odin-one-reality-vps-lab-promote-after-id-eh/dataset.json`
- verify: `/tmp/odin-one-reality-vps-lab-verify-after-id-eh/summary.md`

First Android pass on the new `tcp + reality` pair:

- batch output: `/tmp/odin-one-android-reality-vps-lab-batch-id-eh-phone-pass`
- `id.x5.ru:30443`
  - surfaced as `reality-vps-lab / active / running`
  - built-in test failed with `Android VPN tunnel is not running.`
- `eh.vk.com:40443`
  - surfaced as `reality-vps-lab / active / running`
  - built-in test failed with `connection closed`
  - runtime log shows `dial tcp 95.81.120.226:40443: i/o timeout` on `rmnet_data2`
- restore returned the handset to stable `direct-reality / active / running`

So the new wave is already better than pure theory:

- the promoted VPS dataset is real
- Android hidden runtime selection is real
- stable restore is still clean

But the LTE data-plane is still not proven for the new pair.

## Edge / origin handoff

The next additive step is now scaffolded separately in:

- `docs/reality-whitelist-edge-origin-scaffolding.md`
- `apps/desktop/scripts/reality-whitelist-edge-origin-bundle.sh`

That helper rewrites selected VPS lab entries to a controlled edge host/port, emits pass-through edge configs, and writes an Android-oriented dataset that keeps:

- `port` as the hidden origin lab port
- `connectHost` / `connectPort` as the future client dial target

This is the safest way to move forward now that LTE reachability to raw `95.81.120.226:*` is the blocker rather than the REALITY config shape itself.

## Next step

Use the autonomous batch or the hidden Android owner lab launcher to validate new VPS candidates and confirm:

- `runtimeFamily = reality-vps-lab`
- `activationState = active`
- selected endpoint metadata matches the intended VPS candidate, including `frontConnectHost/frontConnectPort` when an edge dial override is present
- the built-in Android connectivity test reaches a terminal state
- stable lane still restores cleanly after the run
