# macOS Yandex VM Bootstrap

Этот набор нужен для простого онбординга на macOS:

1. создать или переиспользовать локальный SSH-ключ для новой `Yandex Cloud VM`;
2. получить готовые файлы, которые можно вставить в `Yandex Cloud`;
3. после создания VM собрать `SSH handoff bundle` для deploy-flow в `Odin's Cat`.

## Что лежит в папке

- [macos-yandex-vm-bootstrap.zsh](/Users/vladislav/Downloads/odin-one-vk-git/tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh)
- этот `README`

## Быстрый старт

Создать или переиспользовать SSH-ключ:

```bash
zsh /Users/vladislav/Downloads/odin-one-vk-git/tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh ensure-local-key --copy-public-key
```

После этого скрипт создаст bundle в `/tmp/odin-one-macos-yandex-vm-bootstrap/<stamp>` и положит туда:

- `odin-one-yandex-vm.key`
- `odin-one-yandex-vm.pub`
- `yandex-cloud-public-key.txt`
- `yandex-cloud-metadata-line.txt`
- `yandex-cloud-user-data.yaml`
- `local-key-summary.txt`

Что использовать в `Yandex Cloud`:

- если UI просит только `SSH key`: `yandex-cloud-public-key.txt`
- если нужен формат `<username>:<key>`: `yandex-cloud-metadata-line.txt`
- если хочешь сразу создать пользователя с `sudo NOPASSWD`: `yandex-cloud-user-data.yaml`

## После создания VM

Собрать handoff bundle для Android app / SSH deploy:

```bash
zsh /Users/vladislav/Downloads/odin-one-vk-git/tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh build-vm-handoff \
  --vm-host 62.84.123.148 \
  --vm-user odin \
  --key-path ~/.ssh/odin_one_yandex_vm \
  --check-vm-ssh
```

Результат:

- `vm-ssh-handoff.json`
- `ssh-into-vm.sh`
- `app-deploy-notes.txt`
- при `--check-vm-ssh` ещё:
  - `vm-hostkey-scan.txt`
  - `vm-ssh-check.txt`

## Команда “всё сразу”

```bash
zsh /Users/vladislav/Downloads/odin-one-vk-git/tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh full \
  --vm-host 62.84.123.148 \
  --vm-user odin \
  --copy-public-key \
  --check-vm-ssh
```

## Что важно

- Для `Odin's Cat` нужен именно текст приватного ключа OpenSSH, не путь и не `.pub`.
- `vm-ssh-handoff.json` уже содержит `secret` как полный текст приватного ключа, потому что именно это ожидает provisioning backend.
- Скрипт пока сделан только для macOS.
