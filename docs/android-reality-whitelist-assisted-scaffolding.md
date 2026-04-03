# Android REALITY Whitelist-Assisted Scaffolding

This track exists because the current evidence for Russian whitelist networks points more strongly toward curated `REALITY + allowed SNI/CIDR` experiments than toward an arbitrary own-domain CDN front.

The goal is not to replace the stable Android `VLESS + REALITY` lane.

The goal is to add a separate hidden family that can carry operator-curated whitelist hints while keeping:

- stable `direct-reality` as the default
- stable `direct-reality` as the control sample
- `cdn-anti-whitelist` available as a separate lab lane

## Current Status

The family is present in Android runtime normalization as:

- `reality-whitelist-assisted`

It is currently:

- hidden
- opt-in
- additive
- available as:
  - `scaffold_only` via `reality-whitelist-scaffold`
  - owner-only `lab-active` via `reality-whitelist-lab`

The runtime now emits:

- `runtimeFamily = reality-whitelist-assisted`
- `activationState = scaffold_only` for scaffold runs
- `activationState = active` for owner-only `lab` runs
- `selectedSniHint`
- `selectedCidrHint`
- `whitelistHintSource`
- `whitelistHintTag`

And writes a scaffold artifact at:

- `files/vpn-runtime/reality-whitelist-assisted-scaffold.json`

Operator-side curation can now be prepared through:

- `apps/desktop/scripts/android-reality-whitelist-curate.sh`
- `apps/desktop/scripts/android-reality-whitelist-curate-community.sh`
- `apps/desktop/scripts/android-reality-whitelist-session.sh`
- `apps/desktop/scripts/android-reality-whitelist-batch-session.sh`
- `apps/desktop/scripts/android-reality-whitelist-manual-session.sh`
- `apps/desktop/scripts/android-reality-whitelist-manual-batch.sh`
- `apps/desktop/scripts/android-runtime-service-control.sh`

There is now also a hidden in-app owner launcher on Android debug builds:

- open the `Logs & test` sheet
- tap the sheet title five times to unlock the owner lab panel
- choose `Stable control` or `Whitelist scaffold`
- launch the run through the normal app start path instead of the `adb` debug bridge

This keeps the stable user-facing buttons unchanged while giving owner-only runs a less flaky path than `adb` broadcast start attempts.

For these owner-lab scaffold starts, Android now persists a separate `last_attempted_request` alongside the restore-safe `last_request`. That keeps `scaffold_only` launches visible in device dumps and compare tooling without making them resume-eligible across boot or system restore.

For owner-only `lab` runs, the runtime now reuses the stable REALITY builder and overrides only the active `serverName` with the selected curated hint. This keeps the transport path additive while making the candidate lane actually runnable on a debug handset.

Owner-only `lab` runs now also support a quick probe matrix in `apps/desktop/scripts/android-reality-whitelist-session.sh`:

- `generic_primary` probes the configured `--test-url` and stays mirrored in `lastTest`
- `hint_https` probes `https://<selectedSniHint>/` when a hint is present
- the session writes `candidate-probe-matrix.json`
- the candidate capture artifacts include `reality-whitelist-probe-matrix.json`

The default `--test-mode auto` resolves to:

- `single` for scaffold runs
- `matrix` for `reality-whitelist-lab`

This is useful because it tells us whether a hint fails only on the generic probe or fails equally on its own whitelist-facing hostname.

There is now also a matching host-side manual session helper for the in-app launcher:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-session.sh begin
# run Stable control or Whitelist scaffold from the phone UI
apps/desktop/scripts/android-reality-whitelist-manual-session.sh candidate --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
apps/desktop/scripts/android-reality-whitelist-manual-session.sh restore --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
apps/desktop/scripts/android-reality-whitelist-manual-session.sh finalize --output-dir /tmp/odin-one-android-reality-whitelist-manual/<stamp>
```

That helper is meant for the newer in-app owner launcher path, not for the older debug-bridge candidate start.

For curated multi-hint sweeps through the same in-app launcher, there is now a matching manual batch helper:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders

# follow current-hint.md on the phone, then continue on the host:
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh advance \
  --output-dir /tmp/odin-one-android-reality-whitelist-manual-batch/<stamp>
```

That helper:

- captures stable control once per selected hint
- writes `current-hint.md` with the next handset values to enter
- captures the launched hidden candidate
- restores the stable lane
- finalizes compare/report/checklist artifacts for the completed hint
- prepares the next hint automatically until the batch completes

## Hidden Profile Shape

```json
{
  "androidRuntime": {
    "reality": {
      "mode": "stable"
    },
    "realityWhitelistHints": {
      "enabled": true,
      "mode": "scaffold",
      "selection": "ordered",
      "hints": [
        {
          "serverName": "allowed-sni-a.example.com",
          "cidrBucket": "white-cidr-a",
          "source": "operator-curated",
          "tag": "primary-whitelist"
        },
        {
          "serverName": "allowed-sni-b.example.com",
          "cidrBucket": "white-cidr-b",
          "source": "operator-curated",
          "tag": "backup-whitelist"
        }
      ],
      "bootstrap": "direct-reality"
    }
  }
}
```

## What This Gives Us

- a separate hidden family for whitelist-oriented REALITY experiments
- separate `profileHash` identity from stable `direct-reality`
- additive diagnostics for selected SNI/CIDR hint metadata
- operator capture, compare, and report tooling that can see this family
- a safe place to curate hint pools without changing the stable default path
- a first owner-only `lab-active` runtime path that can be started and then validated with a quick probe

## What It Does Not Do Yet

- no transport rewrite
- no production activation path
- no invite/import widening
- no auto-restore or boot-restore expansion
- no claim that a hinted SNI will work in a blocked-direct network without handset validation

## Guardrails

- stable `direct-reality` remains the default Android family
- `cdn-anti-whitelist` remains a separate research lane
- this family stays owner-only and hidden
- all hint changes remain additive to the access profile
- owner-only `lab` runs stay `resumeEligible = false` and must not become boot-restorable
- blocked-direct claims require handset captures plus compare/report artifacts

## Suggested Rollout

1. Curate one hidden SNI/CIDR hint candidate.
2. Apply `reality-whitelist-scaffold` on a debug handset.
3. Capture a stable control sample.
4. Capture the hidden candidate sample.
5. Review `selectedSniHint`, `selectedCidrHint`, and scaffold artifacts with compare/report/checklist tooling.
6. For hints that survive the scaffold pass, retry with `reality-whitelist-lab`.
7. Only after repeatable field validation consider anything wider than owner-only lab mode.

## Owner-Only Curation Workflow

Generate a curated dataset from local files, subscription files, or remote URLs:

```bash
apps/desktop/scripts/android-reality-whitelist-curate.sh \
  --input /tmp/white-sni.txt \
  --cidr-map /tmp/white-cidr-map.tsv
```

That helper writes:

- `dataset.json`
- `preset.json`
- `summary.md`

For a ready-made community bootstrap from public Russia whitelist sources, use:

```bash
apps/desktop/scripts/android-reality-whitelist-curate-community.sh \
  --output-dir /tmp/odin-one-reality-whitelist-community \
  --limit 12
```

That wrapper:

- fetches the selected public sources with `curl`
- defaults to `source-round-robin` so the top of the queue is not dominated by the first source file
- feeds the local copies into the existing curate helper
- normalizes hint tags into sequential `candidate-01-...` values
- writes `community-summary.md` plus `community-sources.json`

To build the next queue after an active owner-lab batch, exclude the already-tested hints:

```bash
apps/desktop/scripts/android-reality-whitelist-curate-community.sh \
  --output-dir /tmp/odin-one-reality-whitelist-community-next \
  --limit 12 \
  --exclude-results /tmp/odin-one-reality-whitelist-community-lab-batch/results.json
```

That keeps the next dataset additive while avoiding immediate retests of the same `serverName` or `tag`.

When the previous queue was an active `reality-whitelist-lab` batch, you can be stricter and skip entire domain families whose quick probes were all reachability-negative:

```bash
apps/desktop/scripts/android-reality-whitelist-curate-community.sh \
  --output-dir /tmp/odin-one-reality-whitelist-community-next \
  --limit 12 \
  --exclude-results /tmp/odin-one-reality-whitelist-community-lab-batch/results.json \
  --exclude-failed-families /tmp/odin-one-reality-whitelist-community-lab-batch/results.json \
  --max-per-family 1
```

That second-pass queue:

- skips already-tested `serverName` and `tag` values
- drops registrable domain families whose active-lab runs only failed probes
- caps the queue to one host per domain family before `--limit` is applied
- keeps `domainFamily` and `sourcesSeen` in `dataset.json` for operator review

Then drive the handset run directly from the curated dataset:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh
```

For blocked-direct field runs, prefer a single hint per session:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh --hint-tag candidate-01-max-ru
```

For the owner-only active lab path, switch to the dedicated preset:

```bash
ODIN_ONE_REALITY_HINTS_FILE=/tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  apps/desktop/scripts/android-reality-whitelist-session.sh \
  --preset reality-whitelist-lab \
  --hint-tag candidate-01-max-ru
```

To force or disable the probe matrix explicitly:

```bash
apps/desktop/scripts/android-reality-whitelist-session.sh \
  --preset reality-whitelist-lab \
  --hint-tag candidate-01-max-ru \
  --test-mode matrix
```

For operator sweeps across multiple curated hints, batch the same owner-only flow:

```bash
apps/desktop/scripts/android-reality-whitelist-batch-session.sh \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders
```

The batch helper will:

- reuse the first successful stable control capture when possible
- run one single-hint session per curated tag
- let the single-hint session retry candidate activation once by default before it writes the capture
- retry a hint once by default if the candidate unexpectedly comes back as the stable family
- keep restoring the handset back to `direct-reality`
- write `results.json` plus one markdown summary for fast operator review
- refresh that batch `summary.md` and `results.json` after each finished hint, not only at the end of the queue
- keep per-run probe matrix and health classification visible in the aggregated batch outputs

For the newer in-app owner launcher path, prefer the manual batch helper instead:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
  --hints-file /tmp/odin-one-reality-whitelist-curation/<stamp>/dataset.json \
  --skip-placeholders
```

Community bootstrap example:

```bash
apps/desktop/scripts/android-reality-whitelist-manual-batch.sh begin \
  --hints-file /tmp/odin-one-reality-whitelist-community/dataset.json \
  --skip-placeholders
```

Then repeat:

1. launch the current hint from the phone UI using `current-hint.md`
2. run `apps/desktop/scripts/android-reality-whitelist-manual-batch.sh advance --output-dir ...`

This keeps the hidden candidate on the normal app start path while still automating capture, restore, and per-hint reporting on the host side.

The single-hint `adb` session now wakes `MainActivity` before both the hidden candidate start and stable baseline starts. On this Xiaomi/Android 15 device that is the difference between a stale stable no-op and a real `reality-whitelist-assisted / scaffold_only` launch through the debug bridge, and it also avoids an extra restore timeout after scaffold runs.

The same single-hint helper now hard-stops the runtime before each stable baseline retry and requires `direct-reality / active / running` before it considers restore complete. The retry count is configurable through `ODIN_ONE_REALITY_STABLE_BASELINE_RETRY_COUNT`.

For `reality-whitelist-lab`, the same session helper can now also dispatch a debug-only quick connectivity probe after the candidate reaches `reality-whitelist-assisted / active / running`. That probe writes `lastTest` back into the persisted snapshot, and compare/report tooling now surfaces `lastTest.status`, `lastTest.output`, and `lastTest.error` so operator review can distinguish:

- the runtime came up and passed a quick probe
- the runtime came up but failed the quick probe
- the runtime came up but only showed repeated outbound `EOF` failures in `logTail`

Session and batch summaries now also classify `dispatch_noop` separately from a normal stable run. That label means the hidden request was preserved in prefs, but the handset kept the old stable snapshot instead of surfacing `reality-whitelist-assisted`, which points at Android orchestration flakiness rather than a bad curated hint. When the start goes through the in-app owner launcher, tooling prefers `last_attempted_request`; the restore-safe `last_request` intentionally stays on the stable lane.

Community curation now also records `sourcesSeen` and `domainFamily` in `dataset.json`, so operator review can tell whether a hinted hostname was observed in one public list or repeated across multiple community sources before it reaches a handset batch, and whether two different-looking hosts are really the same provider family in disguise.

The session helper now waits for:

- `direct-reality` + `running` before the control capture
- `reality-whitelist-assisted` + `scaffold_only` before scaffold candidate captures
- `reality-whitelist-assisted` + `active` + `running` before lab-active candidate captures
- `direct-reality` + `running` before the restore capture

This keeps the owner-only compare/report artifacts closer to the real device state instead of transitional `starting` snapshots.

Guardrails:

- keep the dataset owner-only
- do not widen invite/import
- treat community lists as raw operator input, not as a production dependency
- keep stable `direct-reality` as the control sample before and after every candidate run
