# Reality Whitelist Relay Autoselect

This runbook automates the safest owner-only version of a rolling external relay selector:

- fetch a community subscription from a QR, URL, or local file
- decode raw `vless://` entries into structured fields
- pre-rank likely candidates
- prefer Russian-labelled candidates with the lowest TCP latency first
- if no Russian-labelled candidate is at or below `300ms`, fall back to the
  lowest-latency candidate across the whole shortlist
- run isolated local smoke against several probe URLs
- keep a rolling history so dead or flaky entries slowly lose priority
- export one best candidate plus a few alternates for Odin Android owner-lab use

The scope is intentionally narrow:

- owner-only and additive
- no changes to stable `direct-reality`
- no remote rollout by default
- selection is still based on local smoke and should be confirmed on handset later

For hourly refresh, a raw subscription URL is the preferred source over a QR image:

- no QR decode/OCR fragility
- easier retries, diffing, and source replacement
- better fit for owner-only background refresh on Android
- one malformed entry no longer aborts the whole wave; the selector skips it and keeps searching

## Default probes

Unless you override them, the selector uses three probes:

- `owner` -> `https://95-81-120-226.sslip.io/_odin_probe_204` expecting `204`
- `googlevideo` -> `https://redirector.googlevideo.com/generate_204` expecting `204`
- `gstatic` -> `https://www.gstatic.com/generate_204` expecting `204`

The `owner` probe has the highest weight, so a candidate that can already reach the current owner server surface wins over a candidate that only passes generic internet probes.

The smoke wave is also short on purpose:

- candidates are tried one by one in priority order
- the wave stops as soon as one candidate passes the owner probe and at least one
  additional generic probe
- later alternates may still be pre-ranked, but they are not all smoke-verified

## QR-driven example

```bash
zsh apps/desktop/scripts/reality-whitelist-relay-autoselect.sh \
  --qr-image "/Users/vladislav/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-7026999646167219681/postbox/media/telegram-cloud-photo-size-2-5366078946912440769-x.jpg" \
  --source-label goldcaviar-qr \
  --output-dir /tmp/odin-one-reality-whitelist-relay-autoselect-goldcaviar
```

## URL-driven example

```bash
zsh apps/desktop/scripts/reality-whitelist-relay-autoselect.sh \
  --subscription-url https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt \
  --source-label igareck-mobile \
  --output-dir /tmp/odin-one-reality-whitelist-relay-autoselect-igareck
```

## Churn-aware behavior

The selector writes a rolling history file:

- default path: `tmp/reality-whitelist-relay-autoselect-history.json`

That history is advisory only:

- families and exact entries that fail repeatedly are demoted
- families that recover on a later run can climb back up
- the current smoke pass always matters more than stale history

Reset it when needed:

```bash
zsh apps/desktop/scripts/reality-whitelist-relay-autoselect.sh \
  --subscription-url https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt \
  --reset-history
```

## Outputs

The helper writes:

- `decoded/`
- `preselected.json`
- `preselected-subscription.txt`
- `smoke-<label>/`
- `ranking.json`
- `best-candidate.json`
- `best-subscription.txt`
- `alternates-subscription.txt`
- `android-dataset.json`
- `summary.md`

The most useful next step after a green wave is:

```bash
zsh apps/desktop/scripts/android-reality-vps-hit-check.sh \
  --dataset /tmp/odin-one-reality-whitelist-relay-autoselect-goldcaviar/android-dataset.json \
  --index 1 \
  --skip-server-ss \
  --test-url https://95-81-120-226.sslip.io/_odin_probe_204
```

That keeps the selection pipeline separate from the handset field-truth step.
