# Odin One 0.5.2

Релиз от 8 апреля 2026 года.

## Что нового

- Добавлен полноценный `YANDEX EDGE` как пятый visible-режим в обычном Android UI и invite-flow.
- Появилась вкладка `WHITE IP` с offline-first проверкой IP/CIDR по community whitelist.
- Добавлен импорт и экспорт invite-файлом, включая Android share flow.
- Обновлён Android UX:
  - выбор режима перенесён в верхний блок
  - убраны лишние owner-only и дублирующие панели
  - обновлена шапка и нижняя навигация
- Добавлен route-lens блок с отображением foreign server и tunnel hop.

## Исправления

- Исправлен Android `YANDEX EDGE` path после redeploy и обновлённой REALITY-конфигурации.
- Исправлена генерация invite для гостя:
  - staged REALITY credentials теперь синхронизируются корректно
  - `ownerEgressPort` больше не остаётся stale
- Исправлен запуск `VK RELAY` с новой VK captcha:
  - manual captcha открывается в браузере
  - системный VPN для `VK RELAY` теперь поднимается только после relay warmup
  - UI больше не показывает ложную ошибку запуска, если relay уже живой
- Дефолтное число `VK` streams/bots уменьшено до `1`, чтобы снизить captcha pressure.

## Что приложено к релизу

- signed Android APK `0.5.2`
- signed Android AAB `0.5.2`
- инструкция по развёртыванию Yandex VM и подготовке SSH для деплоя с телефона:
  - `yandex-vm-ssh-phone-bootstrap-guide.pdf`

## Коротко про White IP

Вкладка `WHITE IP` нужна как быстрый preflight для российского edge IP:

1. Открой `WHITE IP`.
2. Вставь IPv4.
3. Нажми проверку.

Клиент покажет:

- exact match в `ipwhitelist.txt`
- CIDR match в `cidrwhitelist.txt`
- источник данных: `live`, `cache` или bundled snapshot
