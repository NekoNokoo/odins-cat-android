# Android REALITY Validation Report Template

Use this template for each handset run so we can compare stable and experimental behavior consistently.

## Run metadata

- Date:
- Operator:
- Device model:
- Android version / SDK:
- App build:
- Branch:
- Scenario:
- Dump file:
- Related profile block:

## Expected behavior

- Startup expectation:
- Recovery expectation:
- DNS expectation:
- Leak expectation:

## Observed behavior

- Did the tunnel reach `running`:
- Quick test result:
- `configMode`:
- `activeFeatures`:
- `lastStartupStage`:
- `lastFailureStage`:
- `lastFailureCode`:
- `lastNetworkEvent`:
- `lastRecoveryAction`:
- `networkChangeCount`:
- `reloadCount`:
- `restoreCount`:
- Always-on / Lockdown state:

## Notes

- What changed from the control sample:
- Battery / thermal notes:
- Hostile-network notes:
- Per-app routing notes:

## Assessment

- Result:
  - pass
  - soft-pass
  - fail
- Estimated SPI movement from this finding:
- Next action:
