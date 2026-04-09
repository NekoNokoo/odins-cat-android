# Публикация Android-only репозитория Odin's Cat

## Цель

Сделать публичный репозиторий, в котором есть только:

- Android-релизы
- пользовательская документация
- инструкции по развёртыванию сервера

Без исходного кода.

## Рекомендуемая схема

1. Исходный репозиторий `odins-cat` сделать `Private`.
2. Создать отдельный публичный репозиторий `odins-cat-android`.
3. Положить в него только README и документацию.
4. APK, AAB и PDF выкладывать как `Release assets`, а не как git-файлы.

## Что перенести в публичный репозиторий

- `README.md`
- `docs/releases/v0.6.0.md`
- `docs/guides/yandex-vm-ssh-phone-bootstrap-guide.md`
- `docs/guides/yandex-vm-ssh-phone-bootstrap-guide.pdf`

## Что не переносить

- исходники приложения
- runtime-код
- Android project files
- desktop/macOS tooling
- внутренние скрипты
- тесты
- provisioning internals

## Release assets для `0.6.0`

- `Odin-Cat-0.6.0.apk`
- `Odin-Cat-0.6.0.aab`
- `yandex-vm-ssh-phone-bootstrap-guide.pdf`
