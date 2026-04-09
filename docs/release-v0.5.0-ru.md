# Odin's Cat 0.5.0

Релиз от 7 апреля 2026 года.

## Что нового

- Добавлен пятый visible Android-режим `YANDEX EDGE`.
- Новый режим встроен в обычный продуктовый flow приложения, а не в hidden owner-only launcher.
- Для deploy теперь поддерживается двухшаговая схема:
  - `Origin deploy`
  - optional `Yandex edge attach`
- Invite/import/export flow расширен так, чтобы один ключ подключения мог нести все доступные режимы текущего owner profile.
- Добавлен импорт и экспорт invite key файлом.
- Добавлена вкладка `WHITE IP` для быстрой проверки IPv4:
  - по точному совпадению в `ipwhitelist.txt`
  - по вхождению в `cidrwhitelist.txt`
  - с offline-first fallback через cache и bundled snapshot
- Главный экран и нижняя навигация Android-клиента переработаны в более компактный UX.

## Как использовать Yandex edge

1. Сначала разверни обычный `Origin` на основном сервере.
2. Затем отдельно выполни `Yandex edge attach` на российской VM.
3. После этого в приложении появится visible режим `YANDEX EDGE`.
4. С owner-устройства можно перевыпустить invite key, чтобы новый режим попал в share/import flow.

Подробная инструкция по SSH и подготовке Yandex VM приложена к релизу отдельными файлами:

- `yandex-vm-ssh-phone-bootstrap-guide.pdf`
- `yandex-vm-ssh-phone-bootstrap-guide.md`

## Что делает White IP

Вкладка `WHITE IP` в клиенте помогает быстро проверить, попадает ли публичный IPv4 сервера в текущие community whitelist-списки.

Путь:

1. Открой `WHITE IP`.
2. Вставь IPv4 сервера.
3. Нажми `ПРОВЕРИТЬ IP`.

Результат покажет:

- точный whitelist-match
- CIDR-match
- список совпавших CIDR
- источник данных (`live` или `cache`)

Это не заменяет реальный полевой тест трафика, но хорошо подходит как быстрый фильтр для Yandex edge IP ещё до deploy и attach.

## Release assets

- Android APK `0.5.0`
- Android AAB `0.5.0`
- Инструкция по настройке Yandex VM для телефона
