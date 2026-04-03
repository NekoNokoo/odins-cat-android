# Android Reality Relay Autoselect Session

This owner-only wrapper ties together the full QR-driven relay workflow:

1. decode `vless://` entries from a QR subscription
2. pick the best relay with the rolling selector
3. feed the chosen relay into the hidden Android `reality-vps-lab` hit-check

The intent is to avoid pinning the system to one relay IP like `217.16.21.235:443`.
Each run reselects the best relay from the current QR/subscription snapshot.

## Default behavior

- prefer Russian-labelled relays with TCP latency `<= 300ms`
- if no Russian-labelled relay is under that threshold, fall back to the lowest-latency relay across the whole shortlist
- stop selector smoke early when a "good enough" relay is found
- then run Android hit-checks for:
  - `https://95-81-120-226.sslip.io/_odin_probe_204`
  - `https://redirector.googlevideo.com/generate_204`
  - `https://www.youtube.com/`

## Example

```bash
zsh apps/desktop/scripts/android-reality-relay-autoselect-session.sh \
  --qr-image "/Users/vladislav/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-7026999646167219681/postbox/media/telegram-cloud-photo-size-2-5366078946912440769-x.jpg" \
  --source-label goldcaviar-qr \
  --output-dir /tmp/odin-one-android-reality-relay-autoselect-session-goldcaviar
```

## Outputs

- `selection/`
- `tests/<slug>/`
- `session-summary.md`
- `session-results.json`

This keeps the relay selection step and the handset field-truth step bound together in one run without hardcoding one external relay.
