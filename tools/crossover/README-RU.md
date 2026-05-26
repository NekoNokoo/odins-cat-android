# Odin's Cat HALO в CrossOver

Запуск с Mac:

```bash
chmod +x ./run-odin-crossover.command
./run-odin-crossover.command
```

По умолчанию используется bottle `OdinOne`. Если bottle называется иначе:

```bash
CROSSOVER_BOTTLE="Windows 11" ./run-odin-crossover.command
```

Внутри bottle должны быть установлены:

- Node.js LTS for Windows
- Rust stable for Windows
- Visual Studio Build Tools с C++ toolchain
- Microsoft WebView2 Runtime

Файл `tools/crossover/odin-one-crossover.cmd` запускается внутри CrossOver,
ставит npm-зависимости, собирает Windows installer через
`npm run windows:tauri:build` и открывает найденный `.exe` или `.msi`.

Важно: профиль подключения остается тем же, что на Android:
`.odinone-access.json`.
