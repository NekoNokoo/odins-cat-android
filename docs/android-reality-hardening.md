# Android VLESS + REALITY Hardening

## Goal

Raise the Android `VLESS + REALITY` baseline without breaking the current working runtime path.

Safety rules for this track:

- keep the current stable path available and default
- make risky behavior opt-in
- prefer additive builders and runtime flags over in-place mutation
- keep `vk-turn-proxy` work out of scope for this document

## Current Android shape

The Android runtime currently uses:

- `libbox` / sing-box as the active Android `VpnService` data plane
- `VLESS + REALITY` for the direct stealth-oriented path
- owner/imported profile JSON as runtime input
- `LocalTunnelState`-compatible snapshots for shared UI parity

This means the safest hardening path is:

1. improve the current sing-box-based REALITY path first
2. keep stable and experimental behavior separate
3. only introduce a hybrid runtime after the existing Android path has better lifecycle, diagnostics, and leak controls

## Changes already implemented in this branch

### Phase 1 hardening now in code

- separate REALITY builders:
  - `buildRealityConfigStable`
  - `buildRealityConfigExperimental`
- explicit REALITY outbound mux disable with `multiplex.enabled = false`
- profile-aware runtime reuse using a `profileHash` instead of host/protocol-only matching
- richer Android tunnel snapshots with:
  - `profileHash`
  - `configMode`
  - `activeFeatures`
  - `alwaysOnEnabled`
  - `lockdownEnabled`
  - `resumeEligible`
  - `lastNetworkEvent`
  - `lastStartupDurationMs`
  - `sessionId`
  - `sessionStartedAt`
  - `sessionNetworkChangeCount`
  - `sessionReloadCount`
- startup diagnostics now record:
  - start source
  - config mode
  - active feature list
  - startup timing
- shared diagnostics UI now shows:
  - REALITY config mode
  - REALITY active features
  - Always-on / Lockdown state
  - resume eligibility
  - last network event
  - runtime startup duration
  - last startup stage
  - failure stage and failure code
  - recovery counters and last recovery action
- `NetworkCallback`-based default interface monitoring
- underlying-network selection now prefers `NOT_VPN` internet networks so runtime telemetry and reconnect hooks stop latching onto `tun0` after VPN activation
- graceful `VpnService` revoke handling via `onRevoke()`
- persisted last-good REALITY request for system-driven restore
- opt-in boot restore receiver for `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`
- actionless system `VpnService` startup now attempts restore only when a resume-eligible REALITY request exists
- `resumeEligible` guard so manual stop does not silently resurrect the tunnel later
- `VpnRuntimeService` now returns `START_STICKY` only for active or resume-eligible REALITY runs, while explicit stop remains non-sticky
- restore-state persistence now mirrors the last REALITY request and resume flags into device-protected storage, preparing safer reboot / Always-on experiments without switching the app to a direct-boot path yet
- when the app reads restore-state on an upgraded install, it now opportunistically backfills the device-protected mirror from the credential-protected copy, reducing the chance of an empty restore mirror after update
- restore-state writes for `last_request`, `resumeEligible`, and `bootRestoreEnabled` now commit synchronously, reducing the chance of losing reboot-critical flags during abrupt stop / crash / restart windows
- explicit `SUPPORTS_ALWAYS_ON` manifest metadata to keep the intended Android VPN posture visible in code review
- Kotlin unit coverage for REALITY runtime option normalization and request matching
- opt-in experimental network reload policy on interface changes with recovery counters in the runtime snapshot
- structured startup/failure telemetry for Android REALITY startup stages and coarse failure classification
- restore telemetry now records attempt, skip, and boot start-service failure reasons through `lastRecoveryAction`
- Android platform interface inventory now resolves the best underlying `NOT_VPN` network on Android 12+ and keeps a legacy fallback only for older APIs

### Why these changes are low risk

- stable mode remains the default
- no deploy path changes are required
- no invite/import schema migration is required
- no `vk-turn-proxy` runtime behavior is touched
- no production default is switched to the experimental builder

Separate third-mode scaffolding for the future Android `CDN / anti-whitelist` family is tracked in:

- `docs/android-cdn-anti-whitelist-scaffolding.md`
- `docs/android-cdn-anti-whitelist-validation.md`

Separate whitelist-assisted REALITY scaffolding for operator-curated `SNI / CIDR` hints is tracked in:

- `docs/android-reality-whitelist-assisted-scaffolding.md`

## Hidden experimental REALITY options

The Android runtime now understands an additive profile-local override block.
It is intentionally hidden from the UI until device validation is complete.

Example:

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "dnsMode": "doh",
      "strictRoute": true,
      "allowPrivateNetworkBypass": true,
      "autoRestoreOnBoot": true,
      "networkReloadOnChange": true,
      "networkReloadDebounceMs": 1500,
      "dnsServer": "dns.google",
      "dnsServerName": "dns.google",
      "dnsServerPort": 443,
      "dnsDohPath": "/resolve",
      "dnsStrategy": "prefer_ipv4",
      "dnsDisableCache": false,
      "dnsIndependentCache": false,
      "excludePackages": [
        "com.android.captiveportallogin"
      ],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
```

Supported fields:

- `mode`
  - `stable`
  - `experimental`
- `dnsMode`
  - `udp`
  - `dot`
  - `doh`
- `strictRoute`
  - boolean
- `allowPrivateNetworkBypass`
  - boolean
- `privateBypassCidrs`
  - optional list of explicit direct-bypass CIDRs
  - when present, it suppresses the broad `ip_is_private -> direct` rule and emits selective direct rules instead
- `tlsFragment`
  - boolean
- `recordFragment`
  - boolean
- `autoRestoreOnBoot`
  - boolean
- `networkReloadOnChange`
  - boolean
- `networkReloadDebounceMs`
  - integer, clamped to `250..5000`
- `dnsServer`
  - hostname or IP literal for the upstream resolver
- `dnsServerName`
  - required for encrypted DNS when `dnsServer` is a custom IP literal
- `dnsServerPort`
  - optional positive integer override
- `dnsDohPath`
  - optional DoH path, normalized to start with `/`
- `dnsStrategy`
  - `prefer_ipv4`
  - `prefer_ipv6`
  - `ipv4_only`
  - `ipv6_only`
- `dnsDisableCache`
  - boolean
- `dnsIndependentCache`
  - boolean
- `includePackages`
  - Android package allow-list for routed apps
- `excludePackages`
  - Android package bypass-list for routed apps
  - do not combine with `includePackages`

Default behavior if no block is provided:

- `mode = stable`
- `dnsMode = udp`
- `strictRoute = false`
- `multiplex.enabled = false`
- private network bypass enabled
- TLS fragmentation disabled
- boot restore disabled
- network reload on interface change disabled

Runtime restore semantics:

- app-driven start persists the last REALITY request
- successful REALITY runtime marks the request as `resumeEligible`
- explicit user stop clears `resumeEligible`
- boot restore runs only when both are true:
  - `autoRestoreOnBoot = true`
  - `resumeEligible = true`
- system-driven startup without explicit args can restore the last request only when it is still `resumeEligible`

## SPI tracking

Current working estimate:

- previous baseline: `55/100`
- after the current branch changes: `60-64/100`
- after the latest lifecycle and diagnostics pass: `64-68/100` pending device validation
- after enabling real system-driven restore handling: `65-69/100` pending device validation
- after handset validation of snapshot accuracy, non-`tun0` underlying tracking, and stable Wi-Fi <-> LTE survival: `71-75/100`

Reason for the uplift:

- less reuse ambiguity
- explicit mux posture
- better runtime observability
- clearer Always-on / Lockdown visibility for operator diagnostics
- better network-change handling
- safer restart continuity after reboot/app update when explicitly enabled
- easier handset debugging when Always-on or boot restore does not actually resume the tunnel

Items not counted yet:

- encrypted DNS validation on a real handset
- stronger leak enforcement on Always-on / Lockdown setups
- fragmentation behavior validation in hostile networks

## Latest handset validation notes

Validated on a physical Android 15 handset on `2026-03-31`.

Confirmed results:

- stable Android REALITY reaches and persists `lastStartupStage = running`
- persisted runtime snapshot now matches the live startup path after service start
- stable underlying-network telemetry no longer latches onto `tun0` after VPN activation
- a control `Wi-Fi -> LTE -> Wi-Fi` switch kept the tunnel in `status = running`
- stable mode kept `reloadCount = 0` during the network switch sequence, which is the intended control behavior
- Android quick test now reaches the native runtime path and persists a final `lastTest` result instead of staying stuck at `idle`
- a handset quick test completed with `lastTest.status = passed`
- the stable REALITY route now hijacks synthetic TUN DNS `172.19.0.2:853` before it can fall through the private-IP direct rule
- the previously observed `dial tcp 172.19.0.2:853 ... timeout` did not reproduce after that route fix
- `lastNetworkEvent` correctly moved through the real uplinks:
  - `default-interface:link-properties:rmnet_data2`
  - `default-interface:link-properties:wlan0`
- Android system settings now surface `always_on_vpn_app = com.odinone.desktop.vk`, and the running REALITY snapshot reflects that with `alwaysOnEnabled = true`
- after a manual stop under Always-on, the terminal snapshot now preserves the real system state:
  - `status = stopped`
  - `alwaysOnEnabled = true`
  - `resumeEligible = false`
- under Lockdown (`always_on_vpn_lockdown = 1`), the stable REALITY path still reached:
  - `status = running`
  - `alwaysOnEnabled = true`
  - `lockdownEnabled = true`
  - `lastStartupStage = running`
- the handset snapshot under Lockdown also retained a passing quick test result
- after a manual stop under Lockdown, the terminal snapshot preserved the strict system posture:
  - `status = stopped`
  - `alwaysOnEnabled = true`
  - `lockdownEnabled = true`
  - `resumeEligible = false`
- with armed restore prefs and a forced cold launch, the app resumed through boot restore as:
  - `startSource = boot_restore`
  - `status = running`
  - `boot_restore_enabled = true`
  - in both credential and device-protected stores
- after a real reboot and first unlock, the stable REALITY path resumed again as:
  - `startSource = boot_restore`
  - `status = running`
  - `restoreCount = 3`
  - `boot_restore_enabled = true`
  - with the service back in foreground state

Saved capture:

- `tmp/android-reality-device-dumps/20260331-130404-wifi-lte-wifi.txt`
- `tmp/android-reality-device-dumps/20260331-131314-quick-test-verified-2.txt`
- `tmp/android-reality-device-dumps/20260331-132222-dns-self-target-fixed.txt`
- `tmp/android-reality-device-dumps/20260331-142033-always-on-manual-stop.txt`
- `tmp/android-reality-device-dumps/20260331-142544-lockdown-running.txt`
- `tmp/android-reality-device-dumps/20260331-142835-lockdown-manual-stop.txt`
- `tmp/android-reality-device-dumps/20260331-171703-boot-restore-cold-start.txt`
- `tmp/android-reality-device-dumps/20260331-172541-boot-restore-reboot-post-unlock.txt`

Residual observations from the same handset run:

- background traffic still produced some DNS exchange timeouts after the switch sequence
- direct private-address bypass still showed timeouts to `172.16.0.1:993` on `wlan0`
- the current Android quick test passed through the built-in HTTP fallback path after app-side HTTPS certificate validation for `https://example.com`
- these observations do not currently flip the runtime out of `running`, but they should inform the next leak-policy and encrypted-DNS experiments

Validation tooling notes:

- handset dump capture now collects `VpnRuntimeService` logcat through host-side `adb logcat`, which is more reliable under `zsh` than the previous device-shell invocation
- handset dump capture now also tries to read the device-protected copy of `odin_one_vpn_runtime`, which is useful when debugging restore-state persistence around reboot and Always-on scenarios
- immediately after upgrading an already-running debug build, the device-protected copy can still be absent until the next fresh REALITY start persists the mirrored restore state at least once
- device-protected restore-state intentionally mirrors request / resume flags, not the full runtime snapshot, so a stopped capture can legitimately show `Snapshot summary: missing` for the device-protected store while still preserving the data needed for restore decisions
- the current branch validates reboot restore after the first unlock; pre-unlock restore is still out of scope until the Android runtime becomes `directBootAware` and explicitly handles `LOCKED_BOOT_COMPLETED`

Current experimental leak hardening behavior:

- DNS traffic is still matched by protocol and additionally by ports `53/853`
- `dnsMode = doh` is available as a hidden option using sing-box HTTPS DNS transport
- local/private IP direct bypass can be disabled for stricter leak tests through `allowPrivateNetworkBypass = false`
- selective private direct bypass can now be modeled through `privateBypassCidrs`
  - this is meant for handset experiments where `private-bypass:off` is too strict but broad `ip_is_private -> direct` is too loose
  - the first balanced preset keeps direct access for:
    - `10.0.0.0/8`
    - `192.168.0.0/16`
    - `169.254.0.0/16`
  - it intentionally excludes `172.16.0.0/12`, because that range produced the noisy direct tail `172.16.0.1:993` in stable validation
- experimental reconnect reload can be enabled with `networkReloadOnChange = true`; when active, Android records network-change counts, reload counts, and the last recovery action in `LocalTunnelState`
- encrypted DNS experiments can now override resolver target details without changing the stable default builder
- hidden DNS policy controls now allow query strategy and cache experiments without touching the stable default path
- hidden Android package filters now allow per-app split tunneling experiments without changing the stable default path
- encrypted DNS now fails earlier during normalization if `dot` or `doh` is configured with a domain `dnsServer` and no bootstrap resolver path exists
- persisted REALITY restore requests now intentionally drop transient session fields before being saved:
  - `startSource`
  - live test state
  - session counters
  - runtime-only diagnostics
  - this keeps `last_request` focused on the next restorable launch, while the live snapshot remains the source of truth for the current session
- isolated handset validation now confirms a stable-mode DoT run with:
  - `dnsServer = 8.8.8.8`
  - `dnsServerName = dns.google`
  - `status = running`
  - without changing reload or leak posture
- hidden preset preservation now keeps the same DoT override during a normal app-driven `Start REALITY` flow:
  - `startSource = app`
  - `configMode = stable`
  - `activeFeatures` still includes `dns:dot`
  - the rendered active REALITY config keeps DNS `type = tls` with `server = 8.8.8.8`
  - handset capture: `tmp/android-reality-device-dumps/20260331-175239-dot-google-app-start-preserved.txt`
- handset quick test now also passes on the preserved DoT runtime:
  - no `ACTION_STOP` or replacement `ACTION_START` appeared during the test
  - `lastTest.status = passed`
  - runtime stayed on `dns:dot`
  - the current quick-test success still comes from the built-in HTTP fallback after app-side HTTPS certificate validation
  - handset capture: `tmp/android-reality-device-dumps/20260331-175505-dot-google-quick-test-preserved.txt`
- isolated `leak-tight` validation now confirms the stricter route posture is real:
  - `strict_route = true`
  - `private-bypass:off`
  - the rendered route rules no longer contain `ip_is_private -> direct`
  - a previously direct private target (`172.16.0.1:993`) is attempted through `outbound/vless[main-out]`
  - handset capture: `tmp/android-reality-device-dumps/20260331-180029-leak-tight-running.txt`
- handset quick test also passes on the same `leak-tight` runtime:
  - no restart back to a softer path was observed
  - `lastTest.status = passed`
  - runtime stayed on `strict-route` and `private-bypass:off`
  - handset capture: `tmp/android-reality-device-dumps/20260331-180155-leak-tight-quick-test.txt`
- isolated `leak-balanced` validation now confirms the selective direct-bypass path is also real:
  - `strict_route = true`
  - `private-bypass:selective:3`
  - the rendered route rules now include only:
    - `10.0.0.0/8`
    - `192.168.0.0/16`
    - `169.254.0.0/16`
  - there is still no broad `ip_is_private -> direct` rule
  - the previous noisy private tail `172.16.0.1:993` is attempted through `outbound/vless[main-out]`
  - handset capture: `tmp/android-reality-device-dumps/20260331-184306-leak-balanced-running.txt`
- handset quick test also reaches the same `leak-balanced` runtime without a restart:
  - `VpnRuntimePlugin` and `VpnRuntimeService` both log the connectivity test request
  - `VpnRuntimeService` logs `Connectivity test passed for https://example.com.`
  - runtime still advertises `private-bypass:selective:3`
  - the quick-test snapshot persistence bug is now closed:
    - `lastTest.status = passed`
    - `lastTest.ok = true`
    - `profileHash` matches the persisted `last_request.profileHash`
  - handset capture: `tmp/android-reality-device-dumps/20260331-184850-leak-balanced-quick-test-2.txt`
- `network-reload` preset is now isolated as well:
  - it no longer pulls in `dns:dot` through `experimental` mode defaults
  - the helper now keeps DNS and leak posture on stable defaults so reconnect testing can be measured separately
- handset validation exposed a real reconnect bug in the experimental `networkReloadOnChange` path:
  - repeated identical `wlan0` callbacks were scheduling extra reloads
  - this caused a reload-storm and inflated `networkChangeCount` / `reloadCount`
- the current branch now adds an underlying-network dedupe guard before scheduling reloads
- post-fix handset rerun no longer showed the previous endless same-interface reschedule loop in live logcat:
  - reloads were tied to the actual transition sequence (`lost-replaced:wlan0` -> `available:rmnet_data2` -> `capabilities:wlan0`)
  - the saved rerun capture is `tmp/android-reality-device-dumps/20260331-180911-network-reload-rerun.txt`
  - cumulative counters remained noisy because they already contained pre-fix storm data, so this path should stay experimental until a fresh clean-slate pass is measured
- the branch now also stamps each REALITY start with a fresh recovery session marker:
  - `sessionId`
  - `sessionStartedAt`
  - `sessionNetworkChangeCount`
  - `sessionReloadCount`
  - this keeps reconnect validation readable even when long-lived cumulative counters already contain older noisy experiments
- after switching reconnect counters to per-session snapshots and making recovery writes atomic:
  - the handset rerun now reports `sessionReloadCount = 2`
  - live `VpnRuntimeService` logcat shows the same two reload completions
  - handset capture: `tmp/android-reality-device-dumps/20260331-182157-network-reload-atomic-rerun.txt`
- persisted REALITY restore-state now normalizes derived fields before write:
  - `last_request.profileHash` now matches the live runtime snapshot again
  - handset capture: `tmp/android-reality-device-dumps/20260331-182612-profile-hash-sync-check.txt`
- startup-stage diagnostics are now normalized as well:
  - a live `status = running` snapshot no longer persists `lastStartupStage = socks_ready`
  - handset capture: `tmp/android-reality-device-dumps/20260331-183157-startup-stage-check.txt`

## Recommended next steps

Device validation runbook:

- `docs/android-reality-device-validation.md`
- `docs/android-reality-profile-presets.md`
- `docs/android-reality-validation-report-template.md`
- `apps/desktop/scripts/android-reality-device-dump.sh`
- `apps/desktop/scripts/android-reality-capture-run.sh`
- `apps/desktop/scripts/android-runtime-compare-captures.sh`
- `apps/desktop/scripts/android-runtime-report-draft.sh`
- `apps/desktop/scripts/android-blocked-direct-checklist.sh`
- `apps/desktop/scripts/android-cdn-origin-lab.sh`
- `apps/desktop/scripts/android-reality-profile-preset.sh`
- `apps/desktop/scripts/android-reality-apply-preset.sh`

The capture helper now writes a sibling `.artifacts/` directory with raw XML/JSON files for each saved handset run.
Android Gradle commands should be launched through `apps/desktop/scripts/desktop-env.sh` when the host shell defaults to Java 25; the helper now auto-detects a working JDK 21, including IntelliJ IDEA's bundled JBR21 on macOS.

### Next low-risk work

- add a small debounce/guard note for experimental `networkReloadOnChange` validation runs
- keep collecting concrete restore skip reasons from device runs before changing any default lifecycle behavior

### Medium-risk isolated work

- validate `dnsMode = dot` on a real Android device
- validate `networkReloadOnChange = true` on Wi-Fi <-> LTE switches and captive-portal transitions
- tighten leak policy only in experimental mode first
- validate boot restore behavior

### High-risk work

- hybrid Android runtime:
  - sing-box for `VpnService` / routing
  - xray for stealth outbound
- selective fragmentation / anti-filter mode as a separate experimental runtime path

That hybrid path should stay outside the stable Android builder until it has clear device-level wins in:

- connection success rate
- network-switch recovery
- leak resistance
- battery behavior
