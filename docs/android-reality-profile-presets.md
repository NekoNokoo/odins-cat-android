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
