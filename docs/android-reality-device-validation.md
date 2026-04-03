# Android REALITY Device Validation

## Goal

Run repeatable handset checks for Android `VLESS + REALITY` without changing the stable default path.

This runbook is meant for:

- validating the current stable Android REALITY path
- exercising hidden experimental flags in isolation
- collecting operator-facing evidence before any default behavior change

## Safety rules

- use a dedicated test handset if possible
- keep the stable path as the control sample
- enable only one experimental knob group at a time
- do not combine `dnsMode`, leak hardening, and experimental reload tests in the same first pass
- record the exact profile block used for each run

## Capture helper

Use this helper after each handset run:

```bash
apps/desktop/scripts/android-reality-device-dump.sh
```

Or save a timestamped run automatically under `/tmp/odin-one-android-device-dumps`:

```bash
apps/desktop/scripts/android-reality-capture-run.sh baseline
```

Compare two saved runs quickly with:

```bash
apps/desktop/scripts/android-runtime-compare-captures.sh \
  /tmp/odin-one-android-device-dumps/<control>.txt \
  /tmp/odin-one-android-device-dumps/<candidate>.txt
```

Generate a short markdown draft for operator review with:

```bash
apps/desktop/scripts/android-runtime-report-draft.sh \
  /tmp/odin-one-android-device-dumps/<control>.txt \
  /tmp/odin-one-android-device-dumps/<candidate>.txt
```

Optional env vars:

- `ODIN_ONE_ANDROID_SERIAL`
  - target a specific connected device
- `ODIN_ONE_ANDROID_PACKAGE`
  - override the Android package name if needed
- `ODIN_ONE_ANDROID_LOG_LINES`
  - adjust filtered `VpnRuntimeService` logcat depth

Gradle note:

- if the shell defaults to Java 25, run Android Gradle commands through `apps/desktop/scripts/desktop-env.sh`
- the helper now auto-detects a valid JDK 21, including IntelliJ IDEA's bundled JBR21 on macOS
- example:

```bash
cd apps/desktop/src-tauri/gen/android
../../../scripts/desktop-env.sh ./gradlew :app:testUniversalDebugUnitTest \
  --tests com.odinone.desktop.vk.VpnRuntimeLibboxTest
```

Fresh debug repack note:

- when only Kotlin / Android debug tooling changed and the current Android native outputs can be reused, prefer `apps/desktop/scripts/android-gradle-reuse-native.sh`
- example:

```bash
apps/desktop/scripts/android-gradle-reuse-native.sh :app:installUniversalDebug
```

- this path keeps the Java 21 wrapper and forces `skipRustBuild`, which avoids the current Tauri websocket rebuild dependency during owner-lab handset iterations

What it captures:

- connected device summary
- VPN / Always-on / Lockdown hints from `dumpsys connectivity`
- `odin_one_vpn_runtime` shared prefs summary
- device-protected `odin_one_vpn_runtime` shared prefs summary when available
- the last persisted REALITY request
- the rendered `active-vless-reality.json`
- any readable `cdn-anti-whitelist` scaffold or runtime artifact for comparison
- filtered `VpnRuntimeService` logcat
- when run through `android-reality-capture-run.sh`, a sibling `.artifacts/` directory with raw XML/JSON files

Note:

- the helper now reads `VpnRuntimeService` logcat from the host-side `adb logcat` path, which avoids the previous `zsh` quoting issue around `*:S`
- the helper also attempts to read `/data/user_de/0/<package>/shared_prefs/odin_one_vpn_runtime.xml` via `run-as` so reboot and Always-on restore-state mirroring can be checked explicitly
- the helper now stages raw XML/JSON artifacts into a per-capture `.artifacts/` directory when used through `android-reality-capture-run.sh`
- right after updating an existing debug install, that device-protected file may still be absent until the next fresh REALITY start rewrites the mirrored restore state
- the runtime now also backfills the device-protected mirror when it reads restore-state on an upgraded install, so one normal app interaction should usually be enough to populate it
- restore-state writes are now committed synchronously, so `last_request` and resume flags are less likely to be lost if the process dies or the device reboots immediately after a start/stop transition
- the boot-restore toggle helper now force-stops the package after it edits prefs, so validate the next run as a cold app launch instead of reusing an already-running process

If `run-as` cannot read app files, the helper still prints device and logcat information but notes that the installed build is likely not debuggable.

Suggested companion note:

- `docs/android-reality-profile-presets.md`
- `docs/android-reality-validation-report-template.md`

Preset helper:

```bash
apps/desktop/scripts/android-reality-profile-preset.sh list
```

On-device preset helper:

```bash
apps/desktop/scripts/android-reality-apply-preset.sh dot-google
```

Use this when you want to patch the current debug handset directly instead of
copying the JSON block by hand.

Owner-lab debug bridge helper:

```bash
apps/desktop/scripts/android-runtime-service-control.sh start-from-prefs
apps/desktop/scripts/android-runtime-service-control.sh run-test --url https://example.com
apps/desktop/scripts/android-runtime-service-control.sh stop
```

Notes:

- the helper still supports a pure no-wake debug broadcast for simple stable starts
- on this Xiaomi / Android 15 handset, hidden whitelist-assisted starts need `ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true` before `start-from-prefs`; otherwise the debug bridge can stay on the stale stable lane
- the whitelist-assisted session helper now front-loads `ODIN_ONE_ANDROID_WAKE_MAIN_ACTIVITY=true` for hidden candidate starts and stable baseline starts, which avoids an extra restore timeout after scaffold runs on this handset
- the helper sends the persisted request as base64 in the debug extra, so hidden preset payloads are no longer mangled by `adb shell am --es` when owner-lab runs start from a force-stopped package
- the helper can now also dispatch the Android VPN connectivity probe through the same debug receiver, which lets owner-only `reality-whitelist-lab` runs record `lastTest` without a UI tap
- the session helper now hard-stops the runtime before each stable baseline retry and waits for `direct-reality / active / running`, which makes post-lab restore more reliable on this handset
- current-family starts now clear inactive runtime config artifacts, so fresh captures are easier to read after switching between stable REALITY and hidden `cdn-anti-whitelist`

Owner-lab in-app manual helpers:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-session.sh begin
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders
```

Use these when the hidden whitelist scaffold should be launched from the normal app UI instead of the older debug-broadcast path. The manual batch helper prepares one current hint at a time, captures stable control automatically, and writes `current-hint.md` with the next handset values to enter before each `advance` step.

For host-driven `adb` queues, `android-reality-whitelist-batch-session.sh` now refreshes its top-level `summary.md` and `results.json` after every completed hint. That makes long owner-only lab batches observable while they are still running. When you want the next queue rather than an immediate rerun of the same hints, pair the batch output with `android-reality-whitelist-curate-community.sh --exclude-results <results.json>` so the next dataset skips already-tested `serverName` and `tag` values. For `reality-whitelist-lab`, add `--exclude-failed-families <results.json> --max-per-family 1` when the previous batch only produced reachability-negative quick probes and you want the next queue to fan out across different registrable domain families instead of revisiting the same provider surface.

For the new owner-only active lane, prefer:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh \
  --preset reality-whitelist-lab \
  --hint-tag candidate-01-max-ru
```

That single-hint session now auto-runs a quick connectivity probe by default when the preset is `reality-whitelist-lab`, then persists the result into `lastTest` before the capture is taken.

Recommended first-pass presets:

- `baseline`
- `boot-restore`
- `dot-google`
- `network-reload`

## Recommended order

1. Validate stable baseline with no hidden Android REALITY overrides.
2. Validate `autoRestoreOnBoot` on its own.
3. Validate Always-on and Lockdown with stable mode first.
4. Validate encrypted DNS options (`dot`, then `doh`) in isolation before touching leak or reload posture.
5. Validate `networkReloadOnChange = true` only after the stable reconnect baseline is understood.
6. Validate per-app package filters only after the baseline and reconnect behavior are understood.

## Baseline profile

Use the default Android REALITY profile with no `androidRuntime.reality` block.

Expected snapshot characteristics:

- `configMode = stable`
- `activeFeatures` includes `mux:disabled`
- `alwaysOnEnabled` and `lockdownEnabled` reflect system state when available
- `sessionNetworkChangeCount = 0` after a fresh clean start
- `sessionReloadCount = 0`
- `networkChangeCount = 0` after a fresh clean start
- `reloadCount = 0`
- `restoreCount = 0`

## Scenario matrix

### Stable baseline

Run:

1. Cold start the app.
2. Start Android REALITY.
3. Wait for running state.
4. Run the quick test once.
5. Stop the tunnel.
6. Start it again.

Record:

- startup time
- `lastStartupStage`
- success/failure of quick test
- `lastNetworkEvent`
- `lastRecoveryAction`
- whether the runtime reuses the correct profile after restart
- helper output from `apps/desktop/scripts/android-reality-device-dump.sh`
- or a saved capture from `apps/desktop/scripts/android-reality-capture-run.sh baseline`

Expected:

- no forced restore
- no reload activity
- `reloadCount = 0`
- `restoreCount = 0`

Observed stable quick-test result on `2026-03-31`:

- Android native `runConnectivityTest` was invoked and logged by the runtime
- `lastTest.status = passed`
- persisted output:
  - `HTTPS probe hit app-side certificate validation; HTTP fallback via http://example.com succeeded (HTTP 200)`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-131314-quick-test-verified-2.txt`

Interpretation:

- the quick test path is working end-to-end again
- the current pass result is not a pure HTTPS success; it is a designed fallback success and should be treated as a diagnostic signal, not as a stealth-quality metric

Observed DNS self-target result on `2026-03-31`:

- after adding an explicit REALITY route rule for `172.19.0.2/32 + tcp + 853`, the previous synthetic DNS self-target timeout did not reproduce in the next handset run
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-132222-dns-self-target-fixed.txt`

Interpretation:

- this is a low-risk leak-hygiene improvement for the stable REALITY path
- private-address direct timeouts such as `172.16.0.1:993` still need separate evaluation and should not be conflated with the synthetic TUN DNS case

### Wi-Fi to LTE and LTE to Wi-Fi

Run:

1. Start Android REALITY.
2. Wait for running state.
3. Toggle Wi-Fi off and let mobile data take over.
4. Wait 10 to 15 seconds.
5. Toggle Wi-Fi back on.
6. Wait again.

Record:

- `sessionNetworkChangeCount`
- `sessionReloadCount`
- `networkChangeCount`
- `lastNetworkEvent`
- quick test result after each switch
- whether the runtime stayed alive or required manual restart
- helper output after each switch
- or one saved capture per switch state

Stable expectation:

- `sessionNetworkChangeCount` should move
- `sessionReloadCount` should stay `0`
- `networkChangeCount` should move
- `reloadCount` should stay `0`
- if the tunnel survives without manual restart, note that as the control result

Observed control result on `2026-03-31`:

- tunnel stayed in `status = running`
- `reloadCount = 0`
- underlying uplink telemetry moved from `wlan0` to `rmnet_data2` and back to `wlan0`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-130404-wifi-lte-wifi.txt`
- residual note:
  - background DNS exchange timeouts still appeared in the log tail after the switch, so encrypted-DNS and leak-policy experiments should be validated next in isolation

Experimental reload expectation:

- `reloadCount` should increase only when `networkReloadOnChange = true`
- `lastRecoveryAction` should show `reload:success:*` or `reload:failed:*`

### Captive portal / hostile Wi-Fi

Run:

1. Join a Wi-Fi network with login interception or partial internet.
2. Start Android REALITY.
3. If it comes up, switch back to a known-good network.

Record:

- whether startup completes
- whether the runtime gets stuck in `starting`
- `lastFailureStage`
- `lastFailureCode`
- `lastRecoveryAction`
- whether recovery succeeds after returning to a clean network
- helper output before and after returning to a clean network

### Boot restore

Profile block:

```json
{
  "androidRuntime": {
    "reality": {
      "autoRestoreOnBoot": true
    }
  }
}
```

Run:

1. Start Android REALITY and confirm running state.
2. Reboot the device.
3. Unlock and wait for app/service recovery.

Record:

- whether the runtime comes back without manual interaction
- `startSource`
- `restoreCount`
- `lastRecoveryAction`
- whether a manual stop before reboot correctly prevents restore
- helper output after unlock

Expected:

- `startSource = boot_restore` or `system_restore`
- `restoreCount` increments
- manual stop clears restore eligibility
- skipped runs should explain themselves via `lastRecoveryAction`, for example:
  - `restore:skip:boot:resume_ineligible`
  - `restore:skip:boot:boot_restore_disabled`
  - `restore:failed:boot:start_service`

Observed cold-start result on `2026-03-31`:

- armed restore prefs survived a forced cold app launch
- the tunnel resumed with `startSource = boot_restore`
- persisted restore-state stayed armed in both credential and device-protected stores
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-171703-boot-restore-cold-start.txt`

Observed reboot result on `2026-03-31`:

- after a real `adb reboot`, the tunnel resumed as `startSource = boot_restore`
- `status = running`
- `boot_restore_enabled = true`
- `restoreCount` increased again
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-172541-boot-restore-reboot-post-unlock.txt`

Current boundary:

- this reboot validation was confirmed after the first device unlock
- the current manifest is not `directBootAware`, and the receiver does not listen to `LOCKED_BOOT_COMPLETED`
- treat pre-unlock restore as a separate future enhancement, not as part of the current stable guarantee

### Always-on / Lockdown

Run:

1. Enable Android Always-on VPN for Odin One.
2. Repeat stable baseline.
3. If supported by the device policy, enable Lockdown VPN.
4. Repeat again.

Record:

- `alwaysOnEnabled`
- `lockdownEnabled`
- whether null-action service starts successfully restore the runtime
- `lastRecoveryAction` when system startup does not resume the tunnel
- whether traffic is blocked when the VPN is stopped under Lockdown
- helper output after each Always-on and Lockdown pass

Expected:

- state flags reflect the system configuration
- system-driven starts use the resume-eligible REALITY request
- skipped system restores should surface reasons such as `restore:skip:system:resume_ineligible`

Observed Always-on result on `2026-03-31`:

- `always_on_vpn_app = com.odinone.desktop.vk`
- while the REALITY tunnel was running, the runtime snapshot showed:
  - `alwaysOnEnabled = true`
  - `lockdownEnabled = false`
- after an explicit manual stop under Always-on, the terminal snapshot correctly kept:
  - `status = stopped`
  - `alwaysOnEnabled = true`
  - `resumeEligible = false`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-142033-always-on-manual-stop.txt`

Interpretation:

- Always-on assignment is now visible both from Android secure settings and from the app snapshot
- manual stop semantics stay intact under Always-on
- terminal-state diagnostics no longer under-report Always-on as `false` after shutdown

Observed Lockdown running result on `2026-03-31`:

- `always_on_vpn_app = com.odinone.desktop.vk`
- `always_on_vpn_lockdown = 1`
- with Lockdown enabled, the stable REALITY snapshot reached:
  - `status = running`
  - `alwaysOnEnabled = true`
  - `lockdownEnabled = true`
  - `resumeEligible = true`
  - `lastStartupStage = running`
- snapshot `lastTest.status = passed`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-142544-lockdown-running.txt`

Interpretation:

- the current stable Android REALITY path can come up successfully even in the stricter Lockdown posture
- the next remaining Lockdown-specific question is stop-path behavior, not basic startup

Observed Lockdown stop result on `2026-03-31`:

- with Lockdown still enabled, a manual stop produced:
  - `status = stopped`
  - `alwaysOnEnabled = true`
  - `lockdownEnabled = true`
  - `resumeEligible = false`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-142835-lockdown-manual-stop.txt`

Interpretation:

- terminal-state diagnostics now preserve the real system Lockdown posture after shutdown
- manual stop semantics still clear restore eligibility
- Android-side lifecycle handling for `Always-on + Lockdown` now looks materially healthier than the original baseline

### Experimental encrypted DNS

Profile block example:

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "dot",
      "dnsServer": "8.8.8.8",
      "dnsServerName": "dns.google"
    }
  }
}
```

Suggested resolver sets:

- Cloudflare DoT/DoH:
  - `dnsServer = 1.1.1.1`
  - `dnsServerName = cloudflare-dns.com`
  - `dnsDohPath = /dns-query`
- Google DoT/DoH:
  - `dnsServer = 8.8.8.8`
  - `dnsServerName = dns.google`
  - optional `dnsDohPath = /resolve`
- Quad9 DoT:
  - `dnsServer = 9.9.9.9`
  - `dnsServerName = dns.quad9.net`

Suggested DNS policy variants:

- default:
  - `dnsStrategy = prefer_ipv4`
  - `dnsDisableCache = false`
  - `dnsIndependentCache = false`
- IPv6 stress check:
  - `dnsStrategy = prefer_ipv6` or `ipv6_only`
- cache isolation check:
  - `dnsDisableCache = true`
  - or `dnsIndependentCache = true`

Repeat:

- stable baseline
- Wi-Fi to LTE switch
- one hostile network run if available

Record:

- startup success rate
- quick test success rate
- whether DNS-related failures appear in the runtime log
- exact resolver tuple used for the run
- exact DNS policy tuple used for the run
- helper output for each resolver / policy tuple

Notes:

- if `dnsServer` is a custom IP literal for `dot` or `doh`, also set `dnsServerName`
- the current Android REALITY path does not provide a bootstrap resolver for encrypted DNS server hostnames, so use IP literals for `dnsServer` and keep the TLS hostname in `dnsServerName`
- compare one resolver family at a time; do not mix resolver swaps with reload-policy tests in the same first pass

Observed isolated DoT result on `2026-03-31`:

- `dot-google` succeeded after switching to `dnsServer = 8.8.8.8`
- runtime reached `status = running`
- `configMode = stable`
- `activeFeatures` included:
  - `dns:dot`
  - `resolver:8.8.8.8`
- rendered active config used:
  - DNS `type = tls`
  - `server = 8.8.8.8`
  - `tls.server_name = dns.google`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-173854-dot-google-running.txt`

Observed app-driven DoT preservation result on `2026-03-31`:

- hidden preset markers survived a normal in-app `Start REALITY`
- runtime reached `status = running`
- `startSource = app`
- `configMode = stable`
- `activeFeatures` still included:
  - `dns:dot`
  - `resolver:8.8.8.8`
- persisted `last_request` kept:
  - `preserveHiddenRealityOverrides = true`
  - `debugRealityPreset = dot-google`
- rendered active config still used:
  - DNS `type = tls`
  - `server = 8.8.8.8`
  - `tls.server_name = dns.google`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-175239-dot-google-app-start-preserved.txt`

Observed DoT quick-test result on `2026-03-31`:

- `VpnRuntimePlugin` received `runConnectivityTest` without any runtime restart
- no `ACTION_STOP` or replacement `ACTION_START` appeared during the test window
- `lastTest.status = passed`
- runtime stayed on:
  - `startSource = app`
  - `configMode = stable`
  - `dns:dot`
  - `resolver:8.8.8.8`
- current quick-test output remained:
  - `HTTPS probe hit app-side certificate validation; HTTP fallback via http://example.com succeeded (HTTP 200)`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-175505-dot-google-quick-test-preserved.txt`

Observed `leak-tight` result on `2026-03-31`:

- hidden preset stayed isolated:
  - `configMode = stable`
  - `dnsMode = udp`
  - `strictRoute = true`
  - `allowPrivateNetworkBypass = false`
- `activeFeatures` included:
  - `strict-route`
  - `private-bypass:off`
- rendered active config used:
  - inbound `strict_route = true`
  - no `ip_is_private -> direct` route rule
- live runtime evidence showed the former private direct target `172.16.0.1:993` being attempted through `outbound/vless[main-out]`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-180029-leak-tight-running.txt`

Observed `leak-tight` quick-test result on `2026-03-31`:

- `VpnRuntimePlugin` received `runConnectivityTest` without a runtime restart
- `lastTest.status = passed`
- runtime stayed on:
  - `configMode = stable`
  - `strict-route`
  - `private-bypass:off`
  - `dns:udp`
- the stricter route posture remained visible in the rendered config:
  - `strict_route = true`
  - no `ip_is_private -> direct` rule
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-180155-leak-tight-quick-test.txt`

Next leak-policy preset queued for handset validation:

- `leak-balanced`
  - keeps `strictRoute = true`
  - disables the broad `ip_is_private -> direct` shortcut
  - reintroduces only selective direct CIDRs:
    - `10.0.0.0/8`
    - `192.168.0.0/16`
  - `169.254.0.0/16`
  - intentionally leaves `172.16.0.0/12` on the tunneled path so the earlier `172.16.0.1:993` tail can be measured separately from common home-LAN access

Observed `leak-balanced` result on `2026-03-31`:

- hidden preset stayed isolated:
  - `configMode = stable`
  - `dnsMode = udp`
  - `strictRoute = true`
  - `allowPrivateNetworkBypass = false`
  - `privateBypassCidrs = ["10.0.0.0/8", "192.168.0.0/16", "169.254.0.0/16"]`
- `activeFeatures` included:
  - `strict-route`
  - `private-bypass:selective:3`
- rendered active config used:
  - inbound `strict_route = true`
  - selective direct route rule only for:
    - `10.0.0.0/8`
    - `192.168.0.0/16`
    - `169.254.0.0/16`
  - no broad `ip_is_private -> direct` rule
- live runtime evidence again showed the noisy target `172.16.0.1:993` being attempted through `outbound/vless[main-out]`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-184306-leak-balanced-running.txt`

Observed `leak-balanced` quick-test result on `2026-03-31`:

- `VpnRuntimePlugin` received `runConnectivityTest` without a runtime restart
- `VpnRuntimeService` logged `Connectivity test passed for https://example.com.`
- runtime stayed on:
  - `configMode = stable`
  - `strict-route`
  - `private-bypass:selective:3`
  - `dns:udp`
- the selective route posture remained visible in the rendered config:
  - direct only for:
    - `10.0.0.0/8`
    - `192.168.0.0/16`
    - `169.254.0.0/16`
  - no broad `ip_is_private -> direct` rule
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-184610-leak-balanced-quick-test.txt`

Observed `leak-balanced` quick-test rerun after the snapshot fix on `2026-03-31`:

- `VpnRuntimePlugin` and `VpnRuntimeService` again logged the same successful connectivity test
- persisted snapshot now correctly shows:
  - `lastTest.status = passed`
  - `lastTest.ok = true`
  - fallback output via `http://example.com`
- `profileHash` also matches the persisted `last_request.profileHash`
- the runtime stayed on:
  - `configMode = stable`
  - `strict-route`
  - `private-bypass:selective:3`
- saved capture:
  - `tmp/android-reality-device-dumps/20260331-184850-leak-balanced-quick-test-2.txt`

Observed `network-reload` findings on `2026-03-31`:

- first handset run exposed a reload-storm:
  - repeated identical `wlan0` callbacks kept scheduling reload work
  - saved capture:
    - `tmp/android-reality-device-dumps/20260331-180414-network-reload-run.txt`
- the branch now includes an underlying-network dedupe guard in `VpnRuntimeService`
- post-fix rerun showed a healthier trigger pattern in live logcat:
  - `lost-replaced:wlan0`
  - `available:rmnet_data2`
  - `capabilities:wlan0`
- the old endless same-interface reschedule loop was no longer visible in the rerun log window
- saved rerun capture:
  - `tmp/android-reality-device-dumps/20260331-180911-network-reload-rerun.txt`
- keep this preset experimental for now:
  - `reloadCount` and `networkChangeCount` remain cumulative across runs
  - use `sessionNetworkChangeCount` / `sessionReloadCount` for fresh per-start comparison
  - use trigger sequences and fresh clean-slate reruns before promoting reconnect logic further
- after adding session-scoped recovery counters and atomic snapshot writes, a fresh handset rerun on `2026-03-31` produced:
  - `sessionNetworkChangeCount = 6`
  - `sessionReloadCount = 2`
  - live `VpnRuntimeService` logcat also showed exactly two reload completions
  - saved capture:
    - `tmp/android-reality-device-dumps/20260331-182157-network-reload-atomic-rerun.txt`
- persisted restore-state consistency check on `2026-03-31`:
  - `snapshot.profileHash` and `last_request.profileHash` matched again
  - saved capture:
    - `tmp/android-reality-device-dumps/20260331-182612-profile-hash-sync-check.txt`
- startup-stage consistency check on `2026-03-31`:
  - a running REALITY snapshot now also persisted `lastStartupStage = running`
  - saved capture:
    - `tmp/android-reality-device-dumps/20260331-183157-startup-stage-check.txt`

### Experimental reload policy

Profile block example:

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "networkReloadOnChange": true,
      "networkReloadDebounceMs": 1500
    }
  }
}
```

Repeat:

- Wi-Fi to LTE switch
- LTE to Wi-Fi switch
- rapid repeated toggles

Record:

- `sessionNetworkChangeCount`
- `sessionReloadCount`
- `networkChangeCount`
- `reloadCount`
- `lastRecoveryAction`
- whether deferred reloads appear instead of reload storms
- helper output after each repeated flap burst

Expected:

- reloads stay bounded
- repeated flaps can queue one deferred reload, not an unlimited chain

### Experimental per-app package filters

Profile block example:

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "excludePackages": [
        "com.android.captiveportallogin"
      ]
    }
  }
}
```

Or:

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "includePackages": [
        "com.android.chrome"
      ]
    }
  }
}
```

Record:

- package filter mode used
- whether target apps are actually routed or bypassed as expected
- whether Android REALITY still reaches running state cleanly
- whether `activeFeatures` reports `pkg-include:*` or `pkg-exclude:*`
- helper output showing the rendered active config and runtime snapshot

Expected:

- use only one mode at a time: include-list or exclude-list
- captive portal and system connectivity helpers can be excluded without disturbing the stable default path

## What to compare after each run

- startup success
- quick test success
- need for manual restart
- changes in `reloadCount`
- changes in `restoreCount`
- battery and thermal behavior if a run lasts longer than a few minutes

## Recommendation for current branch

Before enabling any experimental REALITY flags by default:

- collect one clean stable baseline on a real handset
- collect one Always-on run
- collect one Lockdown run if available
- collect one encrypted DNS run
- collect one experimental reload run with Wi-Fi/LTE switching

Until those results look good, keep:

- stable mode default
- experimental mode hidden
- network reload opt-in only
