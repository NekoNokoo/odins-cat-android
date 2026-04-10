# Odin's Cat 0.6.1

Релиз от 10 апреля 2026 года.

## Что нового

- Доведён штатный `Yandex edge -> xray-proxy` path для обхода белых списков без ручных live-патчей.
- `edge-attach` deploy теперь сохраняет route-aware diagnostics и health checks для `tcp-forward`, `sni-router` и `xray-proxy`.
- Owner profile, invite и import flow синхронизированы для `realityYandexEdgeProxy`, чтобы новый edge mode корректно переносился на чистое устройство.

## Исправления

- Усилены preflight-проверки `edge-attach`:
  - usable `REALITY` fallback на origin
  - reachability `edge -> origin`
  - prerequisites для `xray-proxy`
- Усилены post-deploy проверки:
  - active edge service
  - listener на public port
  - manifest presence
  - `xray run -test -config` для proxy mode
- Android/mobile bridge теперь возвращает те же `edge-attach` diagnostics, что и Go backend.

## Что проверено

- `go test ./internal/provision`
- `cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml`
- Live `edge-attach` deploy в `xray-proxy` mode на Yandex edge VM:
  - новый additive public port `12443`
  - service active
  - listener active
  - `Configuration OK`
- Свежий guest invite и import после live deploy подтверждают `realityYandexEdgeProxy` на `62.84.123.148:12443`

## Что приложено к релизу

- signed Android APK `0.6.1`
- signed Android AAB `0.6.1`

## Что важно для релиза

`0.6.1` закрепляет именно whitelist-facing infrastructure path.

Это не новый risky transport, а доведение уже выбранной `Habr`-архитектуры до штатного owner deploy + invite + diagnostics flow, чтобы дальше можно было переходить к полевым Android-проверкам на реальных whitelist-сетях.
