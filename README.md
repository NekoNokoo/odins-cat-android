# Odin's Cat для Android

Публичный Android-only репозиторий для дистрибуции приложения, релизов и пользовательской документации.

Здесь нет исходного кода. Репозиторий предназначен для тех, кому нужно:

- скачать актуальный Android APK
- посмотреть список изменений по релизам
- поднять свой сервер в Yandex Cloud
- подключить телефон и запустить VPN

## Что есть в этом репозитории

- релизные заметки на русском
- инструкция по поднятию сервера в Yandex Cloud
- PDF-версия инструкции
- ссылки и материалы для Android-релизов

## Текущая версия

- `0.6.0`

Что входит в `0.6.0`:

- Android-first MVP split tunneling через вкладку `Split App`
- выбор приложений, которые идут в обход VPN
- поддержка основных режимов:
  - `VLESS + REALITY`
  - `YANDEX EDGE`
  - `VK RELAY`

## Как начать

1. Открой раздел `Releases` этого репозитория и скачай свежий `APK`.
2. Установи приложение на Android-устройство.
3. Разверни сервер по инструкции:
   [Yandex Cloud Guide](./docs/guides/yandex-vm-ssh-phone-bootstrap-guide.md)
4. Подготовь доступ к серверу и импортируй профиль в приложение.
5. Включи VPN и при необходимости настрой `Split App`.

## Документация

- [Инструкция по серверу в Yandex Cloud](./docs/guides/yandex-vm-ssh-phone-bootstrap-guide.md)
- [Release notes 0.6.0](./docs/releases/v0.6.0.md)

## Что будет в GitHub Release

В релиз `0.6.0` рекомендуется прикладывать:

- `Odin-Cat-0.6.0.apk`
- `Odin-Cat-0.6.0.aab`
- `yandex-vm-ssh-phone-bootstrap-guide.pdf`

## Важно

- Исходный код в этот репозиторий не входит.
- Внутренние implementation details и dev-инструменты сюда не публикуются.
- Android package id для совместимости остаётся `com.odinone.desktop.vk`.
- Проверенный Android label релиза: `Odin's Cat 0.6.0`.
