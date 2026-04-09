# Odin's Cat: SSH для Yandex VM и телефона

Обновлено: 7 апреля 2026 года

## Зачем этот файл

Это короткая практическая инструкция, как:

1. На macOS и Windows создать свой SSH-ключ для новой VM в Yandex Cloud.
2. Правильно прописать его при создании VM.
3. Получить приватный ключ в том текстовом формате, который потом можно вставить в телефон для Odin's Cat.
4. Понять, что можно и что нельзя "вытащить" из уже существующей VM.

## Что потом нужно телефону

Для подключения из телефона нужен именно такой набор:

- `Host`: публичный IPv4 VM
- `Port`: `22`
- `User`: логин пользователя Linux на VM, например `odin`
- `Private key`: полный текст приватного ключа, который начинается с:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

Важно:

- телефону нужен именно текст приватного ключа
- нельзя вставлять `.pub`
- нельзя вставлять путь к файлу
- нельзя вставлять ZIP-архив
- нельзя вставлять пароль вместо ключа
- формат `PPK` для телефона не подходит, нужен OpenSSH private key

## Рекомендуемый путь

Для Odin's Cat сейчас самый безопасный сценарий такой:

1. Создать SSH-ключ локально у себя на Mac или Windows.
2. Создать VM в Yandex Cloud с доступом по `SSH key`, а не по `OS Login`.
3. В `Metadata -> user-data` явно создать пользователя, например `odin`, и дать ему `sudo NOPASSWD`.
4. В телефон вставлять:
   - `Host`
   - `User=odin`
   - полный текст приватного ключа

## Важно про OS Login

Для текущего телефонного deploy-flow `OS Login` не рекомендуется.

Причина простая:

- `OS Login` завязан на IAM и настройки организации
- доступ идёт не как обычный локальный `host + user + private key`
- для телефона и простого deploy-flow это сейчас лишняя сложность

Для Odin's Cat в MVP лучше использовать обычный `SSH key` плюс локального пользователя через `cloud-init`.

## Вариант 1. Создать свой SSH-ключ на macOS

### 1. Создать ключ

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/odin_yandex_vm -C "odin-yandex-vm"
chmod 600 ~/.ssh/odin_yandex_vm
chmod 644 ~/.ssh/odin_yandex_vm.pub
```

После этого у тебя будут файлы:

- `~/.ssh/odin_yandex_vm` — приватный ключ
- `~/.ssh/odin_yandex_vm.pub` — публичный ключ

### 2. Скопировать публичный ключ

```bash
pbcopy < ~/.ssh/odin_yandex_vm.pub
```

Проверить содержимое:

```bash
cat ~/.ssh/odin_yandex_vm.pub
```

### 3. Что вставлять в Yandex Cloud

При создании VM:

- в блоке `Access` выбери `SSH key`, не `OS Login`
- если интерфейс просит только ключ, вставь содержимое `.pub`
- если интерфейс просит пользователя отдельно, укажи `odin`
- если интерфейс просит формат `<username>:<key>`, используй:

```text
odin:ssh-ed25519 AAAA... комментарий
```

## Вариант 2. Создать свой SSH-ключ на Windows

Ниже команды для PowerShell.

### 1. Создать ключ

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\odin_yandex_vm" -C "odin-yandex-vm"
```

После этого у тебя будут файлы:

- `%USERPROFILE%\.ssh\odin_yandex_vm` — приватный ключ
- `%USERPROFILE%\.ssh\odin_yandex_vm.pub` — публичный ключ

### 2. Скопировать публичный ключ

```powershell
Get-Content "$env:USERPROFILE\.ssh\odin_yandex_vm.pub" | Set-Clipboard
```

Проверить содержимое:

```powershell
Get-Content "$env:USERPROFILE\.ssh\odin_yandex_vm.pub"
```

### 3. Что вставлять в Yandex Cloud

При создании VM:

- в блоке `Access` выбери `SSH key`, не `OS Login`
- если есть отдельное поле пользователя, укажи `odin`
- если нужен одинарный metadata-формат, используй:

```text
odin:ssh-ed25519 AAAA... комментарий
```

## Как правильно создать VM для телефона

Если цель: потом зайти на сервер с телефона и развернуть Odin's Cat, то лучше сразу задать локального пользователя через `Metadata -> user-data`.

Используй такой шаблон:

```yaml
#cloud-config
datasource:
  Ec2:
    strict_id: false
ssh_pwauth: no
users:
  - name: odin
    groups: sudo
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...твой_публичный_ключ...
```

Что здесь важно:

- `name: odin` — это будущий `User` для телефона
- `sudo NOPASSWD` нужен, чтобы deploy не упирался в ввод пароля
- в `ssh_authorized_keys` вставляется содержимое `.pub`

## Что потом вставлять в телефон

### macOS

Скопировать приватный ключ в буфер:

```bash
pbcopy < ~/.ssh/odin_yandex_vm
```

Показать текст ключа:

```bash
cat ~/.ssh/odin_yandex_vm
```

Проверить, что вход работает:

```bash
ssh -i ~/.ssh/odin_yandex_vm odin@<VM_PUBLIC_IP> 'echo ok'
```

### Windows

Скопировать приватный ключ в буфер:

```powershell
Get-Content -Raw "$env:USERPROFILE\.ssh\odin_yandex_vm" | Set-Clipboard
```

Показать текст ключа:

```powershell
Get-Content -Raw "$env:USERPROFILE\.ssh\odin_yandex_vm"
```

Проверить, что вход работает:

```powershell
ssh -i "$env:USERPROFILE\.ssh\odin_yandex_vm" odin@<VM_PUBLIC_IP> "echo ok"
```

## Если ключ сгенерировал сам Yandex Cloud

Yandex Cloud умеет сам сгенерировать пару ключей и скачать архив.

Это рабочий вариант, но есть важное ограничение:

- приватный ключ надо сохранить сразу
- если архив потерян, потом достать приватный ключ с VM нельзя

### Как разобрать архив на macOS

Пример:

```bash
mkdir -p ~/.ssh/yc-yandex-generated
unzip ~/Downloads/<yandex_key_archive>.zip -d ~/.ssh/yc-yandex-generated
chmod 700 ~/.ssh
find ~/.ssh/yc-yandex-generated -type f -maxdepth 1
chmod 600 ~/.ssh/yc-yandex-generated/*
```

Посмотреть, какие файлы появились:

```bash
ls -la ~/.ssh/yc-yandex-generated
```

Обычно тебе нужен файл без `.pub`.

Скопировать приватный ключ:

```bash
pbcopy < ~/.ssh/yc-yandex-generated/<private_key_file>
```

Проверить вход:

```bash
ssh -i ~/.ssh/yc-yandex-generated/<private_key_file> <username>@<VM_PUBLIC_IP> 'echo ok'
```

### Как разобрать архив на Windows

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh\yc-yandex-generated" | Out-Null
Expand-Archive -LiteralPath "$env:USERPROFILE\Downloads\<yandex_key_archive>.zip" -DestinationPath "$env:USERPROFILE\.ssh\yc-yandex-generated" -Force
Get-ChildItem "$env:USERPROFILE\.ssh\yc-yandex-generated"
```

Обычно приватный ключ — это файл без `.pub`.

Скопировать приватный ключ:

```powershell
Get-Content -Raw "$env:USERPROFILE\.ssh\yc-yandex-generated\<private_key_file>" | Set-Clipboard
```

Проверить вход:

```powershell
ssh -i "$env:USERPROFILE\.ssh\yc-yandex-generated\<private_key_file>" <username>@<VM_PUBLIC_IP> "echo ok"
```

## Если VM уже существует и надо понять, какой ключ у неё был

Важно:

- с самой Linux VM приватный ключ не восстановить
- на сервере хранится только `public key`
- искать надо только на своём локальном компьютере

### macOS: как найти существующий ключ

Проверить SSH-конфиг:

```bash
ssh -G <VM_PUBLIC_IP> | sed -n '1,120p'
```

Поиск по известным хостам и истории:

```bash
rg -n '<VM_PUBLIC_IP>|<username>' ~/.ssh ~/.zsh_history 2>/dev/null
```

Показать локальные ключи:

```bash
ls -la ~/.ssh
```

Проверить конкретный ключ:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -i ~/.ssh/<candidate_key> <username>@<VM_PUBLIC_IP> 'echo ok'
```

Если ответил `ok`, значит это нужный ключ.

### Windows: как найти существующий ключ

Показать локальные ключи:

```powershell
Get-ChildItem "$env:USERPROFILE\.ssh"
```

Поиск по истории PowerShell:

```powershell
Select-String -Path (Get-PSReadLineOption).HistorySavePath -Pattern "<VM_PUBLIC_IP>|<username>"
```

Проверить конкретный ключ:

```powershell
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -i "$env:USERPROFILE\.ssh\<candidate_key>" <username>@<VM_PUBLIC_IP> "echo ok"
```

## Если есть только `.ppk`

Для телефона нужен OpenSSH private key.

Если у тебя Windows-ключ в формате `.ppk`, конвертируй его через PuTTYgen:

```powershell
puttygen.exe .\key.ppk -O private-openssh -o .\key-openssh
```

Потом в телефон вставляй содержимое `key-openssh`.

## Как получить fingerprint хоста

Это полезно, если телефон или приложение просят сверить fingerprint SSH-хоста.

### macOS

```bash
ssh-keyscan -t ed25519 <VM_PUBLIC_IP> 2>/dev/null | ssh-keygen -lf -
```

### Windows

```powershell
ssh-keyscan -t ed25519 <VM_PUBLIC_IP> 2>$null | ssh-keygen -lf -
```

## Самая важная памятка

Для телефона нужен именно этот набор:

- `Host`: публичный IP VM
- `Port`: `22`
- `User`: `odin` или другой реальный Linux user
- `Private key`: полный текст приватного ключа в формате OpenSSH

Если архив с приватным ключом потерян и локального файла больше нет, приватный ключ с VM не восстановить. В таком случае нужно:

1. сгенерировать новую пару ключей
2. добавить новый `public key` на VM
3. использовать новый `private key` в телефоне

## Официальные источники Yandex Cloud

Ниже официальные страницы, по которым сверялась инструкция:

- `How to connect to a Linux VM over SSH`:
  [https://yandex.cloud/en/docs/compute/operations/vm-connect/ssh](https://yandex.cloud/en/docs/compute/operations/vm-connect/ssh)
- `Creating a VM with a custom configuration script`:
  [https://yandex.cloud/en/docs/compute/operations/vm-create/create-with-cloud-init-scripts](https://yandex.cloud/en/docs/compute/operations/vm-create/create-with-cloud-init-scripts)
- `Keys processed in public images`:
  [https://yandex.cloud/en/docs/compute/concepts/metadata/public-image-keys](https://yandex.cloud/en/docs/compute/concepts/metadata/public-image-keys)
- `Connecting to a VM via OS Login`:
  [https://yandex.cloud/en/docs/compute/operations/vm-connect/os-login](https://yandex.cloud/en/docs/compute/operations/vm-connect/os-login)
- `Creating a VM with OS Login`:
  [https://yandex.cloud/en/docs/compute/operations/vm-connect/os-login-create-vm](https://yandex.cloud/en/docs/compute/operations/vm-connect/os-login-create-vm)

## Как проверить белый IP в клиенте Odin's Cat

После того как у Yandex VM появился публичный IPv4, его можно сразу проверить прямо в Android-клиенте Odin's Cat.

Путь в приложении:

1. Открой нижнюю вкладку `WHITE IP`.
2. Вставь публичный IPv4 сервера.
3. Нажми `ПРОВЕРИТЬ IP`.

Что показывает клиент:

- есть ли точное совпадение в `ipwhitelist.txt`
- входит ли IP в разрешённый CIDR из `cidrwhitelist.txt`
- какие именно CIDR совпали
- из какого источника взяты списки: `live` или `cache`

Что важно:

- результат `Точный IP = Да` или `CIDR = Да` — это хороший быстрый сигнал, что адрес подходит под текущие community whitelist-списки
- отрицательный результат не доказывает, что IP бесполезен навсегда, но обычно это повод не тратить время на такой адрес
- вкладка `WHITE IP` работает в режиме `offline-first`: если GitHub временно недоступен, приложение использует сохранённый кэш и встроенный snapshot списков

Для Yandex edge это удобно использовать как первый фильтр ещё до attach и полевых тестов на реальной сети.
