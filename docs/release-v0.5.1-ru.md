# Odin's Cat 0.5.1

Релиз от 7 апреля 2026 года.

## Что исправлено

- Исправлен Android-регресс, из-за которого после redeploy и включения `YANDEX EDGE` VPN мог подниматься, но реальный интернет не проходил.
- Для режима `YANDEX EDGE` клиент теперь предпочитает exact REALITY credentials из `realityYandexEdge`, если direct fallback уже разъехался после нового deploy.
- Исправлен auto-port path для origin deploy:
  - direct `VLESS + REALITY` больше не пытается использовать плохой default path на `443`
  - авто-режим переиспользует уже живой порт сервера или выбирает свободный высокий порт
- Сглажено мигание deployment overlay во время переходов между шагами.

## Что проверено

- `YANDEX EDGE` после обновления снова проходит полевой Android-прогон.
- Проверки на устройстве:
  - `https://95-81-120-226.sslip.io/_odin_probe_204` -> `204`
  - `https://redirector.googlevideo.com/generate_204` -> `204`
  - `https://www.youtube.com/` -> `200`
- Server-side подтверждено, что path идёт через Yandex edge:
  - `62.84.123.148:443 -> 95.81.120.226:55555`

## Что приложено к релизу

- Android APK `0.5.1`
- Android AAB `0.5.1`
- Инструкция по подготовке SSH и созданию VM в Yandex Cloud:
  - `yandex-vm-ssh-phone-bootstrap-guide.pdf`
  - `yandex-vm-ssh-phone-bootstrap-guide.md`

## Заметка по White IP

Вкладка `WHITE IP` в клиенте нужна как быстрый preflight:

1. Открой `WHITE IP`.
2. Вставь IPv4 сервера.
3. Нажми `ПРОВЕРИТЬ IP`.

Клиент покажет:

- exact match в `ipwhitelist.txt`
- CIDR match в `cidrwhitelist.txt`
- список совпавших CIDR
- источник данных: `live`, `cache` или bundled fallback
