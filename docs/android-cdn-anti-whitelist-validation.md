# Android CDN / Anti-Whitelist Validation Runbook

## Goal

Validate the hidden Android `cdn-anti-whitelist` family as a whitelist-front lane for Russian clients without weakening the stable `VLESS + REALITY` control path.

This runbook is intentionally split from the stable REALITY validation document because the third mode has different rollout gates:

- front reachability from whitelist-restricted networks
- explicit blocked-direct checks
- separate origin-side schema and path identity
- owner-only hidden rollout before any invite/import widening

## Current status

Right now the family has two hidden states:

- `cdn-scaffold`
  - remains `scaffold_only`
- `cdn-ws-lab`
  - activates only the narrow `VLESS + WS + TLS` lab path
  - stays owner-only
  - stays out of boot restore / system restore rollout

That means this runbook has two phases:

1. Pre-activation validation
   - confirm hidden profile blocks, scaffold output, diagnostics, and rollout metadata are correct
2. Lab activation validation
   - use the same matrix for the hidden `cdn-ws-lab` data plane without widening rollout

## Capture helper

Use the same handset capture helper as the stable REALITY track:

```bash
apps/desktop/scripts/android-reality-device-dump.sh
```

Or save a timestamped capture:

```bash
apps/desktop/scripts/android-reality-capture-run.sh cdn-scaffold
```

Also preserve:

- the exact hidden `androidRuntime.cdnAntiWhitelist` block
- the generated `files/vpn-runtime/cdn-anti-whitelist-scaffold.json`
- the selected front metadata shown in diagnostics
- the sibling `.artifacts/` directory created by `android-reality-capture-run.sh`

After collecting a stable control run and a whitelist-front candidate run, compare them with:

```bash
apps/desktop/scripts/android-runtime-compare-captures.sh \
  /tmp/odin-one-android-device-dumps/<stable>.txt \
  /tmp/odin-one-android-device-dumps/<candidate>.txt
```

Generate a short report draft from the same pair with:

```bash
apps/desktop/scripts/android-runtime-report-draft.sh \
  /tmp/odin-one-android-device-dumps/<stable>.txt \
  /tmp/odin-one-android-device-dumps/<candidate>.txt
```

Generate a blocked-direct review checklist with:

```bash
apps/desktop/scripts/android-blocked-direct-checklist.sh \
  /tmp/odin-one-android-device-dumps/<stable>.txt \
  /tmp/odin-one-android-device-dumps/<candidate>.txt
```

For owner-only debug starts and stops from the host, use:

```bash
apps/desktop/scripts/android-runtime-service-control.sh start-from-prefs
apps/desktop/scripts/android-runtime-service-control.sh stop
```

The helper now wakes `MainActivity` before sending the debug bridge broadcast, so a force-stopped debug install does not silently drop the host-triggered owner-lab action.

When the handset needs a fresh debug APK after Kotlin-only CDN runtime changes, prefer:

```bash
apps/desktop/scripts/android-gradle-reuse-native.sh :app:installUniversalDebug
```

That reuses the current Android native outputs, runs Gradle through `desktop-env.sh`, and avoids the current Tauri websocket rebuild blocker when the Rust / native layer itself has not changed.

For the full owner-lab loop, use:

```bash
ODIN_ONE_CDN_FRONT_HOST=edge.example.com \
ODIN_ONE_CDN_FRONT_PATH=/odin-ws \
ODIN_ONE_CDN_TLS_SERVER_NAME=edge.example.com \
ODIN_ONE_CDN_HOST_HEADER=edge.example.com \
ODIN_ONE_CDN_ORIGIN_HOST=origin.example.com \
ODIN_ONE_CDN_ORIGIN_PATH=/odin-origin \
  apps/desktop/scripts/android-cdn-lab-session.sh
```

That wrapper runs preflight, captures the stable control lane, applies the hidden candidate preset, builds compare/report/checklist artifacts, and restores the handset to baseline unless `--skip-restore` is used.

When the next goal is server-confirmed handset traffic rather than just candidate surfacing, use:

```bash
apps/desktop/scripts/android-cdn-front-hit-check.sh \
  --preset cdn-ws-lab \
  --plan-file /tmp/odin-one-cdn-plan.json \
  --plan-tag edge-primary
```

That owner-only wrapper leaves the candidate active long enough to run `run-test`, captures a bounded `journalctl` window from `whitelist-cdn-front-lab.service`, writes filtered front-hit evidence, and then restores the stable lane unless `--skip-restore` is used.

On LTE/mobile runs, the same helper now also saves owner-only device-side `curl --interface <cellular>` probes after the server-log window closes. That gives a separate network-level artifact showing whether the handset can reach the visible front on the raw cellular interface, without polluting the main front-hit evidence window.

When the next step is picking a better visible front candidate before touching the hidden CDN runtime again, use:

```bash
apps/desktop/scripts/android-whitelist-front-probe.sh \
  --urls-file /tmp/odin-one-front-candidates.txt
```

That owner-only helper does not touch the VPN runtime at all. It only probes candidate URLs from the handset's raw cellular interfaces, writes per-probe raw `curl` output, and produces a shortlist-friendly `summary.md` / `results.json` pair for the next front-selection pass.

If every raw-cellular probe times out on hostname resolution, rerun the same helper with host-side A-records preloaded through `--resolve host:port:ip` or `--resolve-file`. That keeps the pass additive while separating "interface DNS is unavailable" from "the candidate front IP itself is not reachable on LTE".

## Hidden preset

Start from:

```bash
apps/desktop/scripts/android-reality-profile-preset.sh cdn-scaffold
```

To exercise the first runnable transport path, use:

```bash
apps/desktop/scripts/android-reality-profile-preset.sh cdn-ws-lab
```

Both presets are intentionally owner-only and keep the family hidden.

To override the hidden owner-lab front/origin without editing code, export:

- `ODIN_ONE_CDN_PLAN_FILE`
- `ODIN_ONE_CDN_PLAN_SELECT_TAG`
- `ODIN_ONE_CDN_PLAN_SELECT_INDEX`
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

Example:

```bash
ODIN_ONE_CDN_PLAN_FILE=/tmp/odin-one-cdn-plan.json \
ODIN_ONE_CDN_PLAN_SELECT_TAG=edge-primary \
  apps/desktop/scripts/android-reality-profile-preset.sh cdn-ws-lab
```

The plan file can be either:

- a JSON object with `frontPool`, `origin`, optional `routingPolicy`, `provider`, `frontSelection`, and `bootstrap`
- or a bare JSON array of `frontPool` entries when the origin stays env-driven

Each `frontPool` entry may also carry optional `connectHost` / `connectPort` values. When present, host-side preflight and the hidden runtime dial that target while still presenting the visible front through `tlsServerName` / `hostHeader`.

Before the handset run, check the same owner-lab plan from the host:

```bash
ODIN_ONE_CDN_FRONT_HOST=edge.example.com \
ODIN_ONE_CDN_FRONT_PATH=/odin-ws \
ODIN_ONE_CDN_TLS_SERVER_NAME=edge.example.com \
ODIN_ONE_CDN_HOST_HEADER=edge.example.com \
ODIN_ONE_CDN_ORIGIN_HOST=origin.example.com \
ODIN_ONE_CDN_ORIGIN_PATH=/odin-origin \
  apps/desktop/scripts/android-cdn-lab-preflight.sh --preset cdn-ws-lab --strict
```

If that preflight returns `status: warn` while DNS/TCP/HTTP are otherwise reachable, the helper has usually separated a local Python certificate-store issue from raw front reachability. Treat that as an operator warning to review, not an automatic blocker for the handset run.

Before the first handset run, generate an owner-lab origin package from the same hidden preset:

```bash
apps/desktop/scripts/android-cdn-origin-lab.sh \
  --preset cdn-ws-lab \
  --output-dir /tmp/odin-one-android-cdn-origin-lab
```

That helper writes:

- `summary.md`
- `caddy.Caddyfile`
- `nginx.conf`
- `core-requirements.md`
- `plan.json`

Use it as a reverse-proxy and loopback-core checklist for the owner-only lab pass.

## Server profile schema checklist

Before any real activation, confirm the hidden profile carries:

- `frontPool[].host`
- `frontPool[].port`
- `frontPool[].connectHost` when the dial target differs from the visible front
- `frontPool[].connectPort` when the dial target differs from the visible front
- `frontPool[].path`
- `frontPool[].tlsServerName`
- `frontPool[].hostHeader`
- `origin.host`
- `origin.port`
- `origin.scheme`
- `origin.path`

Do not widen rollout if any of these are implicit or guessed during operator use.

## Rollout order

1. `owner-lab-single-front`
   - validate one whitelist-reachable front on one handset
2. `owner-lab-front-pool`
   - validate ordered selection and predictable retry behavior
3. `always-on-lockdown`
   - validate Always-on, Lockdown, and boot restore only after the owner lab passes
4. `owner-rollout`
   - wider hidden rollout for owner use only

## Scenario matrix

### Startup control

Run:

1. Cold start the app.
2. Apply the hidden `cdn-scaffold` or `cdn-ws-lab` preset.
3. Start the Android tunnel.
4. Confirm the family and selected front in diagnostics.

Record:

- `runtimeFamily`
- `activationState`
- `frontHost`
- `frontConnectHost`
- `frontConnectPort`
- `frontPath`
- scaffold output path
- log tail

Expected:

- `runtimeFamily = cdn-anti-whitelist`
- selected front matches the hidden preset
- for `cdn-scaffold`:
  - `activationState = scaffold_only`
- for `cdn-ws-lab`:
  - `activationState = active`
  - `active-cdn-anti-whitelist.json` is present in artifacts
- stable `direct-reality` remains available as the control lane

### Wi-Fi to LTE and LTE to Wi-Fi

Run:

1. Start the hidden family.
2. Toggle Wi-Fi off, then back on.
3. Confirm whether selected front metadata remains stable.

Record:

- selected front before and after each handoff
- `lastNetworkEvent`
- recovery counters
- helper output

Expected:

- front identity is either preserved or changes in a clearly observable way
- no silent mutation of the stable control lane

### Blocked-direct / whitelist-front survival

Run:

1. Establish a network where direct paths are blocked or heavily restricted.
2. Keep stable `direct-reality` as the control sample.
3. Attempt the hidden whitelist-front lane.
4. Save the scaffold file and handset dump.

Record:

- which front was selected
- whether the front host itself is reachable
- whether the stable control path remains testable before and after the run
- exact network conditions used for the test

Expected:

- whitelist-front candidate remains tied to a reachable front hostname
- diagnostics continue to expose the selected front clearly
- stable control path is not replaced, removed, or silently reconfigured

### Front-pool retry

Run:

1. Configure at least two hidden fronts.
2. Repeat several starts under the same operator conditions.
3. Confirm ordered selection and retry behavior stay predictable.

Record:

- selected front on each attempt
- whether fallback order matches the intended preset order
- whether path and host-header identity stay coherent

Expected:

- retries are deterministic
- diagnostics stay readable
- no hidden rewrite of front order occurs

### Always-on / Lockdown / Boot restore

Do not treat these as first-pass validation.

Only run them after:

- startup control passes
- handoff passes
- blocked-direct validation passes
- front-pool behavior is understood

For `cdn-ws-lab`, also keep these disabled until a later phase:

- system restore
- boot restore
- Always-on / Lockdown rollout

## Exit criteria before wider rollout

- one whitelist front survives owner-lab startup and blocked-direct checks
- front-pool ordering is predictable
- scaffold output matches the actual hidden profile block
- stable `direct-reality` stays the default, available, and testable
- no invite/import widening is needed yet
