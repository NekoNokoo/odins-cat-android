#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$APP_DIR/out"

mkdir -p "$OUT_DIR"

cp "$ROOT_DIR/packages/ui/src/odin-one-theme.css" "$OUT_DIR/theme.css"
cp "$APP_DIR/app/globals.css" "$OUT_DIR/mobile.css"

cat > "$OUT_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Odin One Mobile</title>
    <link rel="stylesheet" href="./theme.css" />
    <link rel="stylesheet" href="./mobile.css" />
    <style>
      body {
        font-family: "Space Grotesk", "Helvetica Neue", sans-serif;
      }

      .app-shell {
        padding-top: 12px;
      }
    </style>
  </head>
  <body>
    <main class="shell app-shell">
      <section class="topbar">
        <div class="topbar-copy">
          <div class="topbar-head">
            <span class="kicker" id="app-tag"></span>
            <div class="lang-toggle" aria-label="Language">
              <button class="lang-button is-active" type="button" data-locale="ru">RU</button>
              <button class="lang-button" type="button" data-locale="en">EN</button>
            </div>
          </div>
          <h1>Odin One</h1>
          <p id="app-subtitle"></p>
        </div>
      </section>

      <section class="workspace mobile-stack">
        <section class="connection-deck">
          <div class="connection-deck__hero">
            <div class="connection-deck__copy">
              <span class="section-eyebrow" id="hero-eyebrow"></span>
              <h2 class="connection-deck__title">Odin One</h2>
              <p id="hero-description"></p>
              <div class="connection-deck__facts" id="hero-facts"></div>
            </div>

            <button class="vpn-orb" id="preview-toggle" type="button">
              <span class="vpn-orb__ring"></span>
              <span class="vpn-orb__core">
                <span class="vpn-orb__label" id="preview-label"></span>
              </span>
            </button>
          </div>
        </section>

        <article class="section-card">
          <span class="section-eyebrow" id="server-input"></span>
          <h2 class="section-title" id="remote-node"></h2>
          <p class="empty-state" id="android-intro-copy"></p>

          <div class="mobile-form-grid">
            <label class="input-field">
              <span id="host-label"></span>
              <input placeholder="203.0.113.42" />
            </label>
            <label class="input-field">
              <span id="ssh-port-label"></span>
              <input value="22" />
            </label>
            <label class="input-field">
              <span id="user-label"></span>
              <input value="root" />
            </label>
            <label class="input-field">
              <span id="transport-stack-label"></span>
              <select>
                <option>vk-turn-proxy + xray</option>
                <option>xray direct</option>
              </select>
            </label>
            <label class="input-field mobile-span">
              <span id="vk-call-link-label"></span>
              <input placeholder="https://vk.com/call/join/..." />
            </label>
          </div>

          <div class="inline-actions">
            <button class="primary" type="button" id="shell-ready-button"></button>
            <button class="ghost" type="button" id="bridge-pending-button" disabled></button>
          </div>
        </article>

        <article class="section-card">
          <span class="section-eyebrow" id="shell-ready-eyebrow"></span>
          <h2 class="section-title" id="shared-ui-title"></h2>

          <div class="mobile-note-grid">
            <div class="command-card">
              <strong id="entry-point-title"></strong>
              <textarea readonly>/Users/vladislav/Documents/VPN White List VK/apps/mobile/app/page.tsx</textarea>
            </div>
            <div class="command-card">
              <strong id="build-path-title"></strong>
              <textarea readonly>npm run mobile:tauri:android:init && npm run mobile:tauri:android:build</textarea>
            </div>
            <div class="command-card">
              <strong id="shared-ui-card-title"></strong>
              <p id="shared-ui-copy"></p>
            </div>
            <div class="command-card">
              <strong id="icons-card-title"></strong>
              <p id="icons-copy"></p>
            </div>
          </div>

          <div class="mobile-status-grid check-list">
            <div class="check-row">
              <div>
                <strong id="native-bridge-title"></strong>
                <p id="native-bridge-copy"></p>
              </div>
              <span class="pill pill-off" id="native-bridge-pill"></span>
            </div>
            <div class="check-row">
              <div>
                <strong id="status-title"></strong>
                <p id="status-copy"></p>
              </div>
              <span class="pill pill-ok" id="status-pill"></span>
            </div>
          </div>
        </article>
      </section>
    </main>

    <script>
      const dictionaries = {
        ru: {
          appTag: "Android shell / VK-focused",
          appSubtitle: "Shared Odin One UI packaged as an Android shell while the native tunnel bridge is still being ported.",
          heroEyebrow: "Android connect screen",
          heroDescription: "Android-порт уже использует общий Odin One UI-слой и сохраняет тот же visual language, но native tunnel bridge пока не реализован.",
          status: "Статус",
          transport: "Транспорт",
          host: "Хост",
          plannedSocks: "Планируемый SOCKS",
          buildPath: "Сборочный путь",
          nativeBridge: "Native bridge",
          shellReady: "Android shell готов",
          bridgePending: "native bridge pending",
          preview: "Превью",
          serverInput: "Данные сервера",
          remoteNode: "Удалённый узел",
          sshPort: "SSH порт",
          user: "Пользователь",
          transportStack: "Транспортный стек",
          vkCallLink: "Ссылка на звонок VK",
          sharedUi: "Shared UI",
          entryPoint: "Точка входа",
          icons: "Android assets",
          sharedUiCopy: "Этот экран собран из общего AppShell, общего hero-блока и общих словарей i18n, которые теперь переиспользуются и desktop, и mobile.",
          iconsCopy: "Android launcher assets подключаются из этой VK-копии проекта и синхронизированы рядом с mobile shell.",
          nativeBridgeCopy: "Android VpnService bridge и tunnel lifecycle пока намеренно не подключены.",
          statusCopy: "Static Android shell, shared UX layer, build config, and icon assets are now in place."
        },
        en: {
          appTag: "Android shell / VK-focused",
          appSubtitle: "Shared Odin One UI packaged as an Android shell while the native tunnel bridge is still being ported.",
          heroEyebrow: "Android connect screen",
          heroDescription: "The Android port already uses the shared Odin One UI layer and preserves the same visual language, but the native tunnel bridge is still not implemented.",
          status: "Status",
          transport: "Transport",
          host: "Host",
          plannedSocks: "Planned SOCKS",
          buildPath: "Build path",
          nativeBridge: "Native bridge",
          shellReady: "Android shell ready",
          bridgePending: "native bridge pending",
          preview: "Preview",
          serverInput: "Server Input",
          remoteNode: "Remote node",
          sshPort: "SSH port",
          user: "User",
          transportStack: "Transport stack",
          vkCallLink: "VK call link",
          sharedUi: "Shared UI",
          entryPoint: "Entry point",
          icons: "Android assets",
          sharedUiCopy: "This screen is built from the shared AppShell, the shared hero block, and the shared i18n dictionaries now reused by both desktop and mobile.",
          iconsCopy: "Android launcher assets are wired from this VK copy of the project and mirrored next to the mobile shell.",
          nativeBridgeCopy: "Android VpnService bridge and tunnel lifecycle are intentionally not wired yet.",
          statusCopy: "Static Android shell, shared UX layer, build config, and icon assets are now in place."
        }
      };

      let locale = "ru";
      let previewActive = false;

      function renderFacts(dict) {
        const facts = [
          [dict.status, previewActive ? dict.shellReady : dict.bridgePending],
          [dict.transport, "vk-turn-proxy + xray"],
          [dict.host, "—"],
          [dict.plannedSocks, "127.0.0.1:58371"],
          [dict.buildPath, "Static export + Tauri 2"],
          [dict.nativeBridge, dict.bridgePending]
        ];
        const root = document.getElementById("hero-facts");
        root.innerHTML = "";
        for (const [label, value] of facts) {
          const node = document.createElement("div");
          node.className = "summary-pill";
          node.innerHTML = `<span>${label}</span><strong>${value}</strong>`;
          root.appendChild(node);
        }
      }

      function render() {
        const dict = dictionaries[locale];
        document.documentElement.lang = locale;
        document.getElementById("app-tag").textContent = dict.appTag;
        document.getElementById("app-subtitle").textContent = dict.appSubtitle;
        document.getElementById("hero-eyebrow").textContent = dict.heroEyebrow;
        document.getElementById("hero-description").textContent = dict.heroDescription;
        document.getElementById("preview-label").textContent = dict.preview;
        document.getElementById("server-input").textContent = dict.serverInput;
        document.getElementById("remote-node").textContent = dict.remoteNode;
        document.getElementById("android-intro-copy").textContent = dict.heroDescription;
        document.getElementById("host-label").textContent = dict.host;
        document.getElementById("ssh-port-label").textContent = dict.sshPort;
        document.getElementById("user-label").textContent = dict.user;
        document.getElementById("transport-stack-label").textContent = dict.transportStack;
        document.getElementById("vk-call-link-label").textContent = dict.vkCallLink;
        document.getElementById("shell-ready-button").textContent = dict.shellReady;
        document.getElementById("bridge-pending-button").textContent = dict.bridgePending;
        document.getElementById("shell-ready-eyebrow").textContent = dict.shellReady;
        document.getElementById("shared-ui-title").textContent = dict.sharedUi;
        document.getElementById("entry-point-title").textContent = dict.entryPoint;
        document.getElementById("build-path-title").textContent = dict.buildPath;
        document.getElementById("shared-ui-card-title").textContent = dict.sharedUi;
        document.getElementById("icons-card-title").textContent = dict.icons;
        document.getElementById("shared-ui-copy").textContent = dict.sharedUiCopy;
        document.getElementById("icons-copy").textContent = dict.iconsCopy;
        document.getElementById("native-bridge-title").textContent = dict.nativeBridge;
        document.getElementById("native-bridge-copy").textContent = dict.nativeBridgeCopy;
        document.getElementById("native-bridge-pill").textContent = dict.bridgePending;
        document.getElementById("status-title").textContent = dict.status;
        document.getElementById("status-copy").textContent = dict.statusCopy;
        document.getElementById("status-pill").textContent = dict.shellReady;

        const previewToggle = document.getElementById("preview-toggle");
        previewToggle.classList.toggle("is-active", previewActive);
        renderFacts(dict);

        document.querySelectorAll("[data-locale]").forEach((button) => {
          button.classList.toggle("is-active", button.dataset.locale === locale);
        });
      }

      document.querySelectorAll("[data-locale]").forEach((button) => {
        button.addEventListener("click", () => {
          locale = button.dataset.locale;
          render();
        });
      });

      document.getElementById("preview-toggle").addEventListener("click", () => {
        previewActive = !previewActive;
        render();
      });

      document.getElementById("shell-ready-button").addEventListener("click", () => {
        previewActive = true;
        render();
      });

      render();
    </script>
  </body>
</html>
EOF
