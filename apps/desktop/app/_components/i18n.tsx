"use client";

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

export type Locale = "ru" | "en";

const dictionaries = {
  ru: {
    appTag: "macOS MVP / self-hosted",
    appSubtitle: "Self-hosted VPN deployer with an isolated test tunnel for macOS.",
    language: "Язык",
    ru: "RU",
    en: "EN",
    tabServer: "Сервер",
    tabAccess: "Доступ",
    tabTunnel: "Туннель",
    serverInput: "Данные сервера",
    remoteNode: "Удалённый узел",
    host: "Хост",
    sshPort: "SSH порт",
    user: "Пользователь",
    authMethod: "Метод входа",
    password: "Пароль",
    privateKey: "Приватный ключ",
    transportStack: "Транспортный стек",
    transportVK: "vk-turn-proxy + xray",
    transportDirect: "xray direct",
    vkCallLink: "Ссылка на звонок VK",
    validateServer: "Проверить сервер",
    checking: "Проверка...",
    refreshing: "Обновление...",
    enabling: "Включение...",
    disabling: "Выключение...",
    testing: "Тест...",
    startingTunnel: "Запуск...",
    stoppingTunnel: "Остановка...",
    startDeploy: "Развернуть",
    reset: "Сбросить",
    deploymentPrefix: "Развёртывание",
    deploymentDetails: "Ход развёртывания",
    validationDetails: "Результат проверки",
    close: "Закрыть",
    validation: "Проверка",
    serverChecks: "Проверки сервера",
    validationEmpty: "Запустите проверку, чтобы увидеть доступ по SSH, готовность сервера и пригодность для развёртывания.",
    provisioning: "Развёртывание",
    provisioningState: "Состояние развёртывания",
    provisioningEmpty: "План развёртывания появится после первого запроса к Go core.",
    macTest: "Тест на macOS",
    isolatedTunnel: "Локальный изолированный туннель",
    vpnMode: "Режим VPN для macOS",
    vpnModeText: "Одна кнопка поднимает direct-туннель Odin One и включает системный SOCKS proxy macOS для обычных приложений.",
    enableVpn: "Включить VPN",
    disableVpn: "Выключить VPN",
    enablingVpn: "Включаем VPN...",
    disablingVpn: "Выключаем VPN...",
    vpnEnabled: "VPN-режим включён: туннель работает, системный SOCKS proxy активен.",
    vpnDisabled: "VPN-режим выключен.",
    tunnelIntro: "Этот режим поднимает только локальный SOCKS-прокси. Системные маршруты и глобальные настройки интернета macOS не меняются.",
    directTunnelIntro: "Этот режим поднимает обычный прямой SOCKS-туннель через xray без VK. Системные маршруты и глобальные настройки интернета macOS не меняются.",
    startTunnel: "Запустить туннель",
    stopTunnel: "Остановить туннель",
    refreshStatus: "Обновить статус",
    runTest: "Запустить тест",
    status: "Статус",
    socksProxy: "SOCKS5 прокси",
    bridgePort: "Bridge порт",
    ready: "Готово",
    local: "Локально",
    quickTest: "Быстрый тест",
    quickTestText: "Приложение может безопасно выполнить эту проверку само, но команда остаётся доступной для ручного запуска.",
    systemProxy: "Системный прокси macOS",
    systemProxyText: "Этот режим явно включает системный SOCKS5 proxy для активного сетевого сервиса macOS. Default route не меняется, но обычные приложения начнут ходить через Odin One до выключения.",
    enableSystemProxy: "Включить для всей системы",
    disableSystemProxy: "Выключить системный прокси",
    systemProxyEnabled: "Системный SOCKS proxy включён.",
    systemProxyDisabled: "Системный SOCKS proxy сейчас выключен.",
    networkService: "Сетевой сервис",
    tunnelCooldown: "Пауза VK",
    tunnelCooldownText: "VK временно ограничил выдачу TURN-данных. Дождитесь окончания паузы, используйте новую ссылку и повторите только один запуск.",
    lastTest: "Последний тест",
    lastTestPassedVK: "Изолированный туннель успешно выполнил реальный исходящий запрос через VK и ваш сервер.",
    lastTestPassedDirect: "Изолированный туннель успешно выполнил реальный исходящий запрос напрямую через ваш сервер.",
    lastTestRunning: "Один запрос сейчас отправляется через локальный SOCKS-туннель.",
    lastTestFailed: "Последний изолированный запрос завершился ошибкой.",
    lastTestIdle: "Туннель готов к проверке одним нажатием.",
    target: "Цель",
    error: "Ошибка",
    fail: "Ошибка",
    safeMode: "Безопасный режим",
    safeModeText: "Приложение использует только localhost-порты. Нет смены default route, системного прокси или глобального VPN-профиля.",
    sharing: "Доступ",
    ownerProfile: "Ключ подключения",
    accessKeyTab: "Мой ключ",
    accessShareTab: "Передать",
    accessImportTab: "Импорт",
    ownerProfileIntro: "После успешного развёртывания Odin One сохраняет локальный ключ подключения для владельца сервера. Этот ключ можно экспортировать и передать другому пользователю для ручного импорта.",
    refreshProfile: "Обновить профиль",
    guestAccess: "Передача доступа",
    guestAccessIntro: "Здесь можно сгенерировать ключ подключения из уже сохранённого профиля владельца и передать его другому пользователю без SSH и без запуска туннеля.",
    generateShareCode: "Сгенерировать ключ подключения",
    copyShareCode: "Скопировать share code",
    copyJson: "Скопировать JSON",
    copied: "Скопировано",
    shareCode: "Share code",
    shareCodeText: "Эту строку можно передать другому пользователю для локального импорта подключения в Odin One.",
    fingerprint: "Fingerprint",
    endpoint: "Endpoint",
    importProfile: "Импортировать ключ",
    importProfileIntro: "Вставьте share code или raw JSON, чтобы сохранить его локально как импортированное подключение.",
    importPlaceholder: "odin1:...",
    importedProfile: "Импортированное подключение",
    imported: "Импортирован",
    importedAt: "Импортировано",
    noGuestProfile: "Сначала загрузите локальный ключ подключения для этого хоста, затем можно будет сгенерировать share code.",
    name: "Имя",
    saved: "Сохранено",
    transport: "Транспорт",
    owner: "Владелец",
    guest: "Ключ",
    localFile: "Локальный файл",
    localFileText: "Подключение закэшировано локально и может повторно использоваться приложением.",
    exportJson: "Экспорт JSON",
    exportJsonText: "Это текущий локальный ключ подключения, сгенерированный из развёрнутого узла.",
    importJson: "Импортированный JSON",
    importJsonText: "Это нормализованное локальное подключение, сохранённое после импорта share code.",
    noOwnerProfile: "Для этого хоста локальный ключ подключения пока не найден. Сначала выполните развёртывание, затем обновите эту карточку.",
    authPassword: "Пароль",
    authPrivateKey: "Приватный ключ",
    deployStartFailed: "Не удалось запустить развёртывание",
    tunnelStartFailed: "Не удалось запустить локальный туннель",
    tunnelTestFailed: "Тест туннеля завершился ошибкой",
    unknownError: "Неизвестная ошибка",
    checkOk: "ОК",
    checkFail: "Ошибка",
    stageQueued: "В очереди",
    stageCurrent: "В работе",
    stageDone: "Готово",
    stageFailed: "Ошибка",
    deployStatusQueued: "в очереди",
    deployStatusRunning: "в работе",
    deployStatusDone: "готово",
    deployStatusFailed: "ошибка",
    tunnelStatusIdle: "ожидание",
    tunnelStatusStarting: "запуск",
    tunnelStatusRunning: "работает",
    tunnelStatusStopped: "остановлен",
    tunnelStatusFailed: "ошибка"
  },
  en: {
    appTag: "macOS MVP / self-hosted",
    appSubtitle: "Self-hosted VPN deployer with an isolated test tunnel for macOS.",
    language: "Language",
    ru: "RU",
    en: "EN",
    tabServer: "Server",
    tabAccess: "Access",
    tabTunnel: "Tunnel",
    serverInput: "Server Input",
    remoteNode: "Remote node",
    host: "Host",
    sshPort: "SSH port",
    user: "User",
    authMethod: "Auth method",
    password: "Password",
    privateKey: "Private key",
    transportStack: "Transport stack",
    transportVK: "vk-turn-proxy + xray",
    transportDirect: "xray direct",
    vkCallLink: "VK call link",
    validateServer: "Validate server",
    checking: "Checking...",
    refreshing: "Refreshing...",
    enabling: "Enabling...",
    disabling: "Disabling...",
    testing: "Testing...",
    startingTunnel: "Starting...",
    stoppingTunnel: "Stopping...",
    startDeploy: "Start deploy",
    reset: "Reset",
    deploymentPrefix: "Deployment",
    deploymentDetails: "Deployment progress",
    validationDetails: "Validation result",
    close: "Close",
    validation: "Validation",
    serverChecks: "Server checks",
    validationEmpty: "Run validation to inspect SSH access, runtime readiness, and deployment fit.",
    provisioning: "Deployment",
    provisioningState: "Provisioning state",
    provisioningEmpty: "The deployment plan will appear after the first successful request to the Go core.",
    macTest: "macOS Test",
    isolatedTunnel: "Local isolated tunnel",
    vpnMode: "macOS VPN mode",
    vpnModeText: "One button starts the Odin One direct tunnel and enables the macOS system SOCKS proxy for regular apps.",
    enableVpn: "Enable VPN",
    disableVpn: "Disable VPN",
    enablingVpn: "Enabling VPN...",
    disablingVpn: "Disabling VPN...",
    vpnEnabled: "VPN mode is enabled: the tunnel is running and the system SOCKS proxy is active.",
    vpnDisabled: "VPN mode is disabled.",
    tunnelIntro: "This mode starts a local SOCKS proxy only. It does not change your system routes or global macOS internet settings.",
    directTunnelIntro: "This mode starts a regular direct SOCKS tunnel through xray without VK. It does not change your system routes or global macOS internet settings.",
    startTunnel: "Start tunnel",
    stopTunnel: "Stop tunnel",
    refreshStatus: "Refresh status",
    runTest: "Run test",
    status: "Status",
    socksProxy: "SOCKS5 proxy",
    bridgePort: "Bridge port",
    ready: "Ready",
    local: "Local",
    quickTest: "Quick test",
    quickTestText: "The app can now run this safely for you, but the raw command stays visible for manual checks.",
    systemProxy: "macOS system proxy",
    systemProxyText: "This explicitly enables a system SOCKS5 proxy for the active macOS network service. The default route stays unchanged, but regular apps will start using Odin One until you turn it off.",
    enableSystemProxy: "Enable for system",
    disableSystemProxy: "Disable system proxy",
    systemProxyEnabled: "The system SOCKS proxy is enabled.",
    systemProxyDisabled: "The system SOCKS proxy is currently disabled.",
    networkService: "Network service",
    tunnelCooldown: "VK cooldown",
    tunnelCooldownText: "VK temporarily limited TURN credential requests. Wait for the cooldown to expire, use a fresh call link, and retry only once.",
    lastTest: "Last test",
    lastTestPassedVK: "The isolated tunnel completed a real outbound request through VK and your server.",
    lastTestPassedDirect: "The isolated tunnel completed a real outbound request directly through your server.",
    lastTestRunning: "A single request is currently being sent through the local SOCKS tunnel.",
    lastTestFailed: "The last isolated request did not complete successfully.",
    lastTestIdle: "The tunnel is ready for a one-click connectivity check.",
    target: "Target",
    error: "Error",
    fail: "Fail",
    safeMode: "Safe mode",
    safeModeText: "The app is using isolated localhost ports only. No default route changes, no system proxy, and no global VPN profile are applied in this test mode.",
    sharing: "Sharing",
    ownerProfile: "Connection key",
    accessKeyTab: "My key",
    accessShareTab: "Share",
    accessImportTab: "Import",
    ownerProfileIntro: "After a successful deploy, Odin One stores a local connection key for the server owner. You can export this key and pass it to another user for manual import.",
    refreshProfile: "Refresh profile",
    guestAccess: "Access sharing",
    guestAccessIntro: "Generate a connection key from the saved owner profile and pass it to another user without SSH or starting a tunnel.",
    generateShareCode: "Generate connection key",
    copyShareCode: "Copy share code",
    copyJson: "Copy JSON",
    copied: "Copied",
    shareCode: "Share code",
    shareCodeText: "You can pass this string to another user so Odin One can import the connection locally.",
    fingerprint: "Fingerprint",
    endpoint: "Endpoint",
    importProfile: "Import key",
    importProfileIntro: "Paste a share code or raw JSON to save it locally as an imported connection.",
    importPlaceholder: "odin1:...",
    importedProfile: "Imported connection",
    imported: "Imported",
    importedAt: "Imported at",
    noGuestProfile: "Load the local connection key for this host first, then a share code can be generated.",
    name: "Name",
    saved: "Saved",
    transport: "Transport",
    owner: "Owner",
    guest: "Key",
    localFile: "Local file",
    localFileText: "The connection is cached locally and can be reused by the app.",
    exportJson: "Export JSON",
    exportJsonText: "This is the current local connection key generated from your server deployment.",
    importJson: "Imported JSON",
    importJsonText: "This is the normalized local connection saved after importing the share code.",
    noOwnerProfile: "No local connection key found yet for this host. Run deploy first, then refresh this card.",
    authPassword: "Password",
    authPrivateKey: "Private key",
    deployStartFailed: "Failed to start deployment",
    tunnelStartFailed: "Failed to start local tunnel",
    tunnelTestFailed: "Tunnel test failed",
    unknownError: "Unknown error",
    checkOk: "OK",
    checkFail: "Fail",
    stageQueued: "Queued",
    stageCurrent: "In progress",
    stageDone: "Done",
    stageFailed: "Failed",
    deployStatusQueued: "queued",
    deployStatusRunning: "running",
    deployStatusDone: "done",
    deployStatusFailed: "failed",
    tunnelStatusIdle: "idle",
    tunnelStatusStarting: "starting",
    tunnelStatusRunning: "running",
    tunnelStatusStopped: "stopped",
    tunnelStatusFailed: "failed"
  }
} as const;

type Dictionary = typeof dictionaries.ru;

const I18nContext = createContext<{
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: keyof Dictionary) => string;
} | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocale] = useState<Locale>("ru");

  useEffect(() => {
    const saved = window.localStorage.getItem("odin-one-locale");
    if (saved === "ru" || saved === "en") {
      setLocale(saved);
    }
  }, []);

  useEffect(() => {
    window.localStorage.setItem("odin-one-locale", locale);
    document.documentElement.lang = locale;
  }, [locale]);

  const value = useMemo(
    () => ({
      locale,
      setLocale,
      t: (key: keyof Dictionary) => dictionaries[locale][key]
    }),
    [locale]
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  const context = useContext(I18nContext);
  if (!context) {
    throw new Error("useI18n must be used inside I18nProvider");
  }
  return context;
}

export function LanguageToggle() {
  const { locale, setLocale, t } = useI18n();

  return (
    <div className="lang-toggle" aria-label={t("language")}>
      <button
        className={locale === "ru" ? "lang-button is-active" : "lang-button"}
        type="button"
        onClick={() => setLocale("ru")}
      >
        {t("ru")}
      </button>
      <button
        className={locale === "en" ? "lang-button is-active" : "lang-button"}
        type="button"
        onClick={() => setLocale("en")}
      >
        {t("en")}
      </button>
    </div>
  );
}
