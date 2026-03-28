"use client";

import { useEffect, useState, useTransition } from "react";
import type {
  DeploymentState,
  DeployStage,
  InviteProfile,
  LocalTunnelState,
  OwnerAccessProfile,
  ServerDraft,
  SystemProxyState,
  ValidationResponse
} from "@whitelist/contracts";
import { SectionCard } from "@whitelist/ui/SectionCard";
import { StageList } from "@whitelist/ui/StageList";
import { ConnectScreenHero } from "@whitelist/ui/ConnectScreenHero";
import { useI18n } from "./i18n";

const apiBaseUrl = process.env.NEXT_PUBLIC_CORE_API_URL ?? "http://127.0.0.1:18088";

const initialDraft: ServerDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  transport: "vk-turn-proxy+xray",
  engine: "xray",
  protocol: "vless-reality"
};

type WorkspaceTab = "server" | "access" | "tunnel";
type AccessTab = "key" | "share" | "import";
type PendingAction =
  | "enableVpn"
  | "disableVpn"
  | "validate"
  | "deploy"
  | "startTunnel"
  | "startReality"
  | "stopTunnel"
  | "refreshTunnel"
  | "runTest"
  | "refreshOwnerProfile"
  | "enableSystemProxy"
  | "disableSystemProxy"
  | null;

const storageKey = "odin-one-vk-control-center-v2";

const normalizeTransport = (transport: string | undefined): ServerDraft["transport"] =>
  transport === "xray" || transport === "vk-turn-proxy+xray" ? transport : initialDraft.transport;

const normalizeEngine = (engine: string | undefined): NonNullable<ServerDraft["engine"]> =>
  engine === "sing-box" || engine === "xray" ? engine : "xray";

const normalizeProtocol = (protocol: string | undefined): NonNullable<ServerDraft["protocol"]> =>
  protocol === "vless-reality" || protocol === "direct-wireguard" ? protocol : "vless-reality";

type PersistedState = {
  activeTab: WorkspaceTab;
  activeAccessTab: AccessTab;
  draft: ServerDraft;
  secret: string;
  vkLink: string;
  validation: ValidationResponse | null;
};

type CoreHealthState = {
  service: string;
  status: string;
};

const formatProtocolEntry = (entry: NonNullable<OwnerAccessProfile["protocolPack"]>[number]) =>
  `${entry.label} / ${entry.scheme} / ${entry.network.toUpperCase()} ${entry.port}`;

export function ControlCenter() {
  const { locale, t } = useI18n();
  const [activeTab, setActiveTab] = useState<WorkspaceTab>("server");
  const [activeAccessTab, setActiveAccessTab] = useState<AccessTab>("key");
  const [draft, setDraft] = useState<ServerDraft>(initialDraft);
  const [secret, setSecret] = useState("");
  const [validation, setValidation] = useState<ValidationResponse | null>(null);
  const [showValidationOverlay, setShowValidationOverlay] = useState(false);
  const [plan, setPlan] = useState<DeployStage[]>([]);
  const [deployment, setDeployment] = useState<DeploymentState | null>(null);
  const [showDeploymentOverlay, setShowDeploymentOverlay] = useState(false);
  const [vkLink, setVKLink] = useState("");
  const [localTunnel, setLocalTunnel] = useState<LocalTunnelState | null>(null);
  const [systemProxy, setSystemProxy] = useState<SystemProxyState | null>(null);
  const [ownerProfile, setOwnerProfile] = useState<OwnerAccessProfile | null>(null);
  const [guestProfile, setGuestProfile] = useState<InviteProfile | null>(null);
  const [importShareCode, setImportShareCode] = useState("");
  const [importedProfile, setImportedProfile] = useState<InviteProfile | null>(null);
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const [coreHealth, setCoreHealth] = useState<CoreHealthState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [isPending, startTransition] = useTransition();
  const curlCommand = localTunnel?.socksAddress
    ? `curl --socks5-hostname ${localTunnel.socksAddress} -I https://example.com`
    : "";
  const requiresVKLink = draft.transport === "vk-turn-proxy+xray";
  const cooldownMinutes =
    localTunnel?.cooldownRemainingSeconds && localTunnel.cooldownRemainingSeconds > 0
      ? Math.ceil(localTunnel.cooldownRemainingSeconds / 60)
      : 0;
  const endpointPort = ownerProfile?.endpointPort ?? ownerProfile?.vkTurnProxyPort ?? 0;
  const deploymentPort =
    deployment?.transport === "vk-turn-proxy+xray" ? deployment.turnPort : deployment?.wireGuardPort;
  const systemProxyActive = systemProxy?.enabled ?? false;
  const vpnModeActive = localTunnel?.status === "running" && systemProxyActive;
  const stageStatusLabels = {
    queued: t("stageQueued"),
    current: t("stageCurrent"),
    done: t("stageDone"),
    failed: t("stageFailed")
  };

  const translateStage = (stage: DeployStage): DeployStage => {
    if (locale === "en") {
      return stage;
    }

    const labelMap: Record<string, string> = {
      "ssh-check": "Проверка SSH",
      "runtime-prep": "Подготовка окружения",
      "install-binaries": draft.transport === "xray" ? "Установка xray" : "Установка бинарников",
      "configure-services": "Настройка сервисов",
      "service-start": "Запуск сервисов",
      "egress-check": "Проверка исходящего трафика"
    };
    const descriptionMap: Record<string, string> = {
      "ssh-check": "Проверяет учётные данные, удалённую ОС и текущее состояние сервера.",
      "runtime-prep": "Создаёт изолированные директории Odin One и проверяет сетевую готовность.",
      "install-binaries": draft.transport === "xray"
        ? "Устанавливает xray на хост без зависимости от VK."
        : "Устанавливает xray и загружает бинарник vk-turn-proxy server на хост.",
      "configure-services": draft.transport === "xray"
        ? "Генерирует ключи, пишет direct-конфиг xray и ставит systemd unit-файлы."
        : "Генерирует ключи, пишет конфиги xray и Odin One и ставит systemd unit-файлы.",
      "service-start": draft.transport === "xray"
        ? "Запускает xray на публичном UDP порту и проверяет его состояние."
        : "Запускает xray и vk-turn-proxy на изолированных портах и проверяет их состояние.",
      "egress-check": "Проверяет DNS, HTTP и HTTPS egress на сервере после запуска сервисов."
    };

    return {
      ...stage,
      label: labelMap[stage.id] ?? stage.label,
      description: descriptionMap[stage.id] ?? stage.description
    };
  };

  const translateCheckLabel = (key: string, fallback: string) => {
    if (locale === "en") {
      return fallback;
    }

    const map: Record<string, string> = {
      "ssh-port": "SSH порт доступен",
      "tcp-connect": "TCP подключение",
      "remote-user": "Удалённый пользователь",
      "os-release": "Операционная система",
      "sudo-presence": "Наличие sudo",
      "docker-presence": "Наличие Docker",
      "curl-presence": "Наличие curl",
      "dns-resolution": "DNS резолвинг",
      "remote-http-egress": "Исходящий HTTP с сервера",
      "remote-https-egress": "Исходящий HTTPS с сервера"
    };

    return map[key] ?? fallback;
  };

  const translateCheckDetail = (detail: string) => {
    if (locale === "en") {
      return detail;
    }
    if (detail === "No output") {
      return "Нет вывода";
    }
    return detail.replace("Connected to ", "Подключено к ").replace("accepted the connection", "принял соединение");
  };

  const deploymentStatusLabel = deployment
    ? ({
        queued: t("deployStatusQueued"),
        running: t("deployStatusRunning"),
        done: t("deployStatusDone"),
        failed: t("deployStatusFailed")
      }[deployment.status] ?? deployment.status)
    : "";
  const tunnelStatusLabel = localTunnel
    ? ({
        idle: t("tunnelStatusIdle"),
        starting: t("tunnelStatusStarting"),
        running: t("tunnelStatusRunning"),
        stopped: t("tunnelStatusStopped"),
        failed: t("tunnelStatusFailed")
      }[localTunnel.status] ?? localTunnel.status)
    : "";
  const isBusy = (action: Exclude<PendingAction, null>) => pendingAction === action;
  const vpnButtonBusy = isBusy("enableVpn") || isBusy("disableVpn");
  const vpnButtonLabel = vpnButtonBusy
    ? isBusy("enableVpn")
      ? t("enablingVpn")
      : t("disablingVpn")
    : vpnModeActive
      ? t("disableVpn")
      : t("enableVpn");
  const currentHost = localTunnel?.serverHost || draft.host || "—";
  const currentTransport = draft.transport === "vk-turn-proxy+xray" ? t("transportVK") : t("transportDirect");
  const currentEngine = localTunnel?.engine ?? deployment?.engine ?? draft.engine ?? "xray";
  const currentProtocol = localTunnel?.protocol ?? deployment?.protocol ?? draft.protocol ?? "direct-wireguard";
  const deploymentHealthLabel = deployment?.healthChecks?.length
    ? deployment.healthChecks.every((check) => check.ok)
      ? t("remoteEgressReady")
      : t("remoteEgressBlocked")
    : t("tunnelStatusIdle");
  const tunnelHealthLabel = localTunnel?.lastTest
    ? localTunnel.lastTest.status === "passed"
      ? t("ready")
      : localTunnel.lastTest.status === "failed"
        ? t("fail")
        : localTunnel.lastTest.status === "running"
          ? t("testing")
          : t("tunnelStatusIdle")
    : t("tunnelStatusIdle");
  const primaryStatusBadge = vpnModeActive ? t("ready") : tunnelStatusLabel || t("tunnelStatusIdle");
  const primaryStatusText = vpnModeActive
    ? t("vpnEnabled")
    : localTunnel?.status === "running"
      ? t("lastTestIdle")
      : t("vpnDisabled");
  const coreRuntimeLabel = coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable");
  const profileCacheLabel = draft.host
    ? ownerProfile?.exists
      ? t("profileCacheReady")
      : t("profileCacheMissing")
    : t("profileCacheUnknown");
  const deployModeLabel = requiresVKLink ? t("deployModeVk") : t("deployModeDirect");
  const safetyPostureLabel = systemProxyActive ? t("safetySystemProxyOn") : t("safetyLocalhostOnly");
  const runtimeLogTail = localTunnel?.logTail ?? [];
  const operatorSummary = [
    coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable"),
    ownerProfile?.exists ? t("profileCacheReady") : t("profileCacheMissing"),
    localTunnel?.status === "running" ? tunnelStatusLabel : primaryStatusBadge,
    deploymentHealthLabel
  ].join(" / ");
  const recoveryHint = !validation?.ok
    ? t("recoveryHintValidate")
    : requiresVKLink && !vkLink
      ? t("recoveryHintVkLink")
      : cooldownMinutes > 0
        ? t("recoveryHintCooldown")
        : localTunnel?.status === "running"
          ? t("recoveryHintSystemProxy")
          : importedProfile?.localPath
            ? t("recoveryHintImport")
            : ownerProfile?.exists
              ? t("recoveryHintOwnerProfile")
              : t("recoveryHintGeneric");
  const currentProtocolPack = ownerProfile?.protocolPack ?? deployment?.protocolPack ?? validation?.protocolPack ?? [];
  const activeProtocolEntry = currentProtocolPack.find((entry) => entry.status === "active") ?? currentProtocolPack[0];
  const stagedProtocolEntries = currentProtocolPack.filter((entry) => entry.status !== "active");
  const protocolPackSummary = activeProtocolEntry
    ? `${activeProtocolEntry.label} / ${activeProtocolEntry.scheme} / ${activeProtocolEntry.network.toUpperCase()} ${activeProtocolEntry.port}`
    : t("diagnosticsEmpty");
  const stagedFallbackSummary = stagedProtocolEntries.length > 0
    ? stagedProtocolEntries.map((entry) => formatProtocolEntry(entry)).join("\n")
    : t("diagnosticsEmpty");

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const saved = window.localStorage.getItem(storageKey);
    if (!saved) {
      pollLocalTunnel(true);
      return;
    }

    try {
      const parsed = JSON.parse(saved) as Partial<PersistedState>;
      if (parsed.activeTab === "server" || parsed.activeTab === "access" || parsed.activeTab === "tunnel") {
        setActiveTab(parsed.activeTab);
      }
      if (parsed.activeAccessTab === "key" || parsed.activeAccessTab === "share" || parsed.activeAccessTab === "import") {
        setActiveAccessTab(parsed.activeAccessTab);
      }
      if (parsed.draft) {
        const normalizedTransportValue = normalizeTransport(parsed.draft.transport);
        const normalizedProtocolValue = normalizeProtocol(parsed.draft.protocol);
        setDraft({
          host: parsed.draft.host ?? initialDraft.host,
          port: parsed.draft.port ?? initialDraft.port,
          username: parsed.draft.username ?? initialDraft.username,
          authMethod: parsed.draft.authMethod ?? initialDraft.authMethod,
          transport: normalizedTransportValue,
          engine: normalizeEngine(parsed.draft.engine),
          protocol:
            normalizedTransportValue === "xray" && normalizedProtocolValue === "direct-wireguard"
              ? "vless-reality"
              : normalizedProtocolValue
        });
        if (parsed.draft.host) {
          void fetchOwnerProfile(parsed.draft.host);
        }
      }
      if (typeof parsed.secret === "string") {
        setSecret(parsed.secret);
      }
      if (typeof parsed.vkLink === "string") {
        setVKLink(parsed.vkLink);
      }
      if (parsed.validation) {
        setValidation(parsed.validation);
      }
    } catch {
      window.localStorage.removeItem(storageKey);
    }

    void fetchCoreHealth();
    void fetchSystemProxyStatus();
    pollLocalTunnel(true);
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const snapshot: PersistedState = {
      activeTab,
      activeAccessTab,
      draft,
      secret,
      vkLink,
      validation
    };
    window.localStorage.setItem(storageKey, JSON.stringify(snapshot));
  }, [activeAccessTab, activeTab, draft, secret, validation, vkLink]);

  const handleValidate = () => {
    setError(null);
    startTransition(async () => {
      try {
        const validateRes = await fetch(`${apiBaseUrl}/api/provision/validate`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: draft,
            secret
          })
        });

        const validateData = (await validateRes.json()) as ValidationResponse;
        setValidation(validateData);
        setShowValidationOverlay(true);

        const planRes = await fetch(`${apiBaseUrl}/api/provision/plan`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: draft,
            secret
          })
        });

        const planData = (await planRes.json()) as { steps: DeployStage[] };
        setPlan(planData.steps ?? []);

        if (!validateRes.ok && validateData.error) {
          setError(validateData.error);
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : "Unknown error";
        setError(message);
      }
    });
  };

  const handleDeploy = () => {
    setError(null);
    startTransition(async () => {
      try {
        const deployRes = await fetch(`${apiBaseUrl}/api/provision/deploy`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: draft,
            secret
          })
        });

        const deployData = (await deployRes.json()) as DeploymentState;
        setDeployment(deployData);
        setPlan(deployData.steps);
        setShowDeploymentOverlay(true);

        if (!deployRes.ok) {
          setError(t("deployStartFailed"));
          return;
        }

        const timer = window.setInterval(async () => {
          const statusRes = await fetch(`${apiBaseUrl}/api/provision/deploy/${deployData.deploymentId}`);
          const statusData = (await statusRes.json()) as DeploymentState;
          setDeployment(statusData);
          setPlan(statusData.steps);
          if (statusData.status === "done" || statusData.status === "failed") {
            window.clearInterval(timer);
            setShowDeploymentOverlay(false);
            if (statusData.status === "done") {
              void fetchOwnerProfile(draft.host);
            } else if (statusData.error) {
              setError(statusData.error);
            }
          }
        }, 1200);
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      }
    });
  };

  const fetchCoreHealth = async () => {
    try {
      const res = await fetch(`${apiBaseUrl}/healthz`);
      const data = (await res.json()) as CoreHealthState;
      setCoreHealth(data);
      return data;
    } catch {
      setCoreHealth(null);
      return null;
    }
  };

  const fetchOwnerProfile = async (host: string) => {
    if (!host) {
      return;
    }
    const res = await fetch(`${apiBaseUrl}/api/profile/owner?host=${encodeURIComponent(host)}`);
    const data = (await res.json()) as OwnerAccessProfile;
    setOwnerProfile(data);
    return data;
  };

  const pollLocalTunnel = (immediate = false) => {
    const run = async () => {
      try {
        const [tunnelRes, proxyRes] = await Promise.all([
          fetch(`${apiBaseUrl}/api/local-tunnel/status`),
          fetch(`${apiBaseUrl}/api/system-proxy/status`)
        ]);
        const tunnelData = (await tunnelRes.json()) as LocalTunnelState;
        const proxyData = (await proxyRes.json()) as SystemProxyState;
        setLocalTunnel(tunnelData);
        setSystemProxy(proxyData);
        if (tunnelData.status === "starting") {
          window.setTimeout(() => {
            void run();
          }, 1200);
        }
        return tunnelData;
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
        return null;
      }
    };

    if (immediate) {
      return run();
    } else {
      window.setTimeout(() => {
        void run();
      }, 1200);
      return Promise.resolve();
    }
  };

  const sleep = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));

  const waitForRunningTunnel = async (attempts = 8, delayMs = 900) => {
    let tunnelData = await pollLocalTunnel(true);
    if (tunnelData?.status === "running" && tunnelData.socksAddress) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (tunnelData?.status === "running" && tunnelData.socksAddress) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const runCurrentTunnelTest = async () => {
    const res = await fetch(`${apiBaseUrl}/api/local-tunnel/test`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        url: "https://example.com"
      })
    });
    const data = (await res.json()) as LocalTunnelState;
    setLocalTunnel(data);
    if (!res.ok) {
      setError(data.lastTest?.error ?? data.error ?? t("tunnelTestFailed"));
    }
    return data;
  };

  const runCurrentTunnelTestWithRetry = async (retries = 3, delayMs = 1500) => {
    let result = await runCurrentTunnelTest();
    if (result.lastTest?.ok) {
      return result;
    }

    for (let i = 0; i < retries; i += 1) {
      await sleep(delayMs);
      result = await runCurrentTunnelTest();
      if (result.lastTest?.ok) {
        return result;
      }
    }

    return result;
  };

  const fetchSystemProxyStatus = async () => {
    const res = await fetch(`${apiBaseUrl}/api/system-proxy/status`);
    const data = (await res.json()) as SystemProxyState;
    setSystemProxy(data);
    return data;
  };

  const matchesExpectedProxy = (state: SystemProxyState, socksAddress?: string) => {
    if (!socksAddress) {
      return state.enabled;
    }
    const [expectedHost, portText] = socksAddress.split(":");
    const parsedPort = Number.parseInt(portText ?? "", 10);
    return state.enabled && state.host === expectedHost && state.port === parsedPort;
  };

  const verifySystemProxy = async (socksAddress?: string) => {
    const first = await fetchSystemProxyStatus();
    if (matchesExpectedProxy(first, socksAddress)) {
      return first;
    }

    await new Promise((resolve) => window.setTimeout(resolve, 350));
    return fetchSystemProxyStatus();
  };

  const handleRefreshOverview = () => {
    startTransition(async () => {
      await Promise.all([
        fetchCoreHealth(),
        draft.host ? fetchOwnerProfile(draft.host) : Promise.resolve(),
        pollLocalTunnel(true)
      ]);
    });
  };

  const handleStartTunnel = () => {
    setError(null);
    setPendingAction("startTunnel");
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/local-tunnel/start-reality`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: draft,
            secret,
            vkLink
          })
        });
        const data = (await res.json()) as LocalTunnelState;
        setLocalTunnel(data);
        void fetchSystemProxyStatus();
        if (!res.ok) {
          setError(data.error ?? t("tunnelStartFailed"));
          return;
        }
        const tunnelData = await waitForRunningTunnel();
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          await runCurrentTunnelTestWithRetry();
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleStopTunnel = () => {
    setPendingAction("stopTunnel");
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/local-tunnel/stop`, {
          method: "POST"
        });
        const data = (await res.json()) as LocalTunnelState;
        setLocalTunnel(data);
        await verifySystemProxy();
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleStartRealityTunnel = () => {
    setError(null);
    setPendingAction("startReality");
    startTransition(async () => {
      try {
        const realityDraft: ServerDraft = {
          ...draft,
          transport: "xray",
          engine: "xray",
          protocol: "vless-reality"
        };
        setDraft(realityDraft);

        const res = await fetch(`${apiBaseUrl}/api/local-tunnel/start`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: realityDraft,
            secret,
            vkLink: ""
          })
        });
        const data = (await res.json()) as LocalTunnelState;
        setLocalTunnel(data);
        void fetchSystemProxyStatus();
        if (!res.ok) {
          setError(data.error ?? t("tunnelStartFailed"));
          return;
        }
        const tunnelData = await waitForRunningTunnel();
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          const testedTunnel = await runCurrentTunnelTestWithRetry(3, 1500);
          if (!testedTunnel.lastTest?.ok) {
            setError(testedTunnel.lastTest?.error ?? testedTunnel.error ?? t("tunnelTestFailed"));
          }
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleRefreshTunnelStatus = () => {
    setError(null);
    setPendingAction("refreshTunnel");
    startTransition(async () => {
      try {
        const tunnelData = await waitForRunningTunnel(2, 600);
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          await runCurrentTunnelTestWithRetry(1, 1000);
        }
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleRunTest = () => {
    setError(null);
    setPendingAction("runTest");
    startTransition(async () => {
      try {
        await runCurrentTunnelTest();
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleRefreshOwnerProfile = () => {
    setError(null);
    setPendingAction("refreshOwnerProfile");
    startTransition(async () => {
      try {
        const data = await fetchOwnerProfile(draft.host);
        if (data?.error) {
          setError(data.error);
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleEnableSystemProxy = () => {
    setError(null);
    setPendingAction("enableSystemProxy");
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/system-proxy/enable`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            socksAddress: localTunnel?.socksAddress ?? ""
          })
        });
        const data = (await res.json()) as SystemProxyState;
        const verified = res.ok ? await verifySystemProxy(localTunnel?.socksAddress) : data;
        setSystemProxy(verified);
        if (!res.ok) {
          setError(data.error ?? t("unknownError"));
          return;
        }
        if (!matchesExpectedProxy(verified, localTunnel?.socksAddress)) {
          setError(verified.error ?? "System SOCKS proxy did not become active on the expected local tunnel port");
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleEnableVPN = () => {
    setError(null);
    setPendingAction("enableVpn");
    startTransition(async () => {
      try {
        let tunnelData = localTunnel;
        if (!tunnelData || tunnelData.status !== "running" || !tunnelData.socksAddress) {
          const startRes = await fetch(`${apiBaseUrl}/api/local-tunnel/start`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json"
            },
            body: JSON.stringify({
              server: draft,
              secret,
              vkLink
            })
          });
          tunnelData = (await startRes.json()) as LocalTunnelState;
          setLocalTunnel(tunnelData);
          if (!startRes.ok) {
            setError(tunnelData.error ?? t("tunnelStartFailed"));
            return;
          }

          tunnelData = await waitForRunningTunnel(8, 900);
        }

        if (!tunnelData || tunnelData.status !== "running" || !tunnelData.socksAddress) {
          setError(t("tunnelStartFailed"));
          return;
        }

        const testedTunnel = await runCurrentTunnelTestWithRetry(3, 1500);
        if (!testedTunnel.lastTest?.ok) {
          setError(testedTunnel.lastTest?.error ?? testedTunnel.error ?? t("tunnelTestFailed"));
          return;
        }

        const proxyRes = await fetch(`${apiBaseUrl}/api/system-proxy/enable`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            socksAddress: tunnelData.socksAddress
          })
        });
        const proxyData = (await proxyRes.json()) as SystemProxyState;
        const verified = proxyRes.ok ? await verifySystemProxy(tunnelData.socksAddress) : proxyData;
        setSystemProxy(verified);
        if (!proxyRes.ok) {
          setError(proxyData.error ?? t("unknownError"));
          return;
        }
        if (!matchesExpectedProxy(verified, tunnelData.socksAddress)) {
          setError(verified.error ?? "System SOCKS proxy did not become active on the expected local tunnel port");
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleDisableVPN = () => {
    setError(null);
    setPendingAction("disableVpn");
    startTransition(async () => {
      try {
        const proxyRes = await fetch(`${apiBaseUrl}/api/system-proxy/disable`, {
          method: "POST"
        });
        const proxyData = (await proxyRes.json()) as SystemProxyState;
        const verifiedProxy = await verifySystemProxy();
        setSystemProxy(verifiedProxy);
        if (!proxyRes.ok) {
          setError(proxyData.error ?? t("unknownError"));
          return;
        }

        const stopRes = await fetch(`${apiBaseUrl}/api/local-tunnel/stop`, {
          method: "POST"
        });
        const stopData = (await stopRes.json()) as LocalTunnelState;
        setLocalTunnel(stopData);
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleDisableSystemProxy = () => {
    setError(null);
    setPendingAction("disableSystemProxy");
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/system-proxy/disable`, {
          method: "POST"
        });
        const data = (await res.json()) as SystemProxyState;
        const verified = await verifySystemProxy();
        setSystemProxy(verified);
        if (!res.ok) {
          setError(data.error ?? t("unknownError"));
          return;
        }
        if (verified.enabled) {
          setError(verified.error ?? "System SOCKS proxy is still enabled");
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleGenerateGuestProfile = () => {
    setError(null);
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/profile/guest`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            host: draft.host,
            name: ownerProfile?.name ?? "Odin One Access Key"
          })
        });
        const data = (await res.json()) as InviteProfile;
        setGuestProfile(data);
        setActiveTab("access");
        setActiveAccessTab("share");
        if (!res.ok) {
          setError(data.error ?? t("unknownError"));
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      }
    });
  };

  const handleImportProfile = () => {
    setError(null);
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/profile/import`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            shareCode: importShareCode
          })
        });
        const data = (await res.json()) as InviteProfile;
        setImportedProfile(data);
        setActiveTab("access");
        setActiveAccessTab("import");
        if (!res.ok) {
          setError(data.error ?? t("unknownError"));
        }
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      }
    });
  };

  const handleCopy = async (key: string, value?: string) => {
    if (!value) {
      return;
    }
    try {
      await navigator.clipboard.writeText(value);
      setCopiedKey(key);
      window.setTimeout(() => {
        setCopiedKey((current) => (current === key ? null : current));
      }, 1800);
    } catch (copyError) {
      const message = copyError instanceof Error ? copyError.message : t("unknownError");
      setError(message);
    }
  };

  return (
    <>
      <ConnectScreenHero
        eyebrow={t("vpnMode")}
        title="Odin One VK"
        description={primaryStatusText}
        facts={[
          { label: t("status"), value: primaryStatusBadge },
          { label: t("transport"), value: currentTransport },
          { label: t("activeProtocol"), value: currentProtocol === "vless-reality" ? t("protocolReality") : t("protocolWireGuard") },
          { label: t("host"), value: currentHost },
          { label: t("socksProxy"), value: localTunnel?.socksAddress ?? "—" },
          {
            label: t("systemProxy"),
            value: systemProxyActive ? t("systemProxyEnabled") : t("systemProxyDisabled")
          },
          { label: t("lastTest"), value: tunnelHealthLabel }
        ]}
        buttonLabel={vpnButtonLabel}
        buttonActive={vpnModeActive}
        buttonBusy={vpnButtonBusy}
        buttonDisabled={
          isPending ||
          (!vpnModeActive && (!validation?.ok || (requiresVKLink && (!vkLink || cooldownMinutes > 0))))
        }
        onButtonClick={vpnModeActive ? handleDisableVPN : handleEnableVPN}
        error={error}
      />

      <SectionCard eyebrow={t("controlPlane")} title={t("runtimeOverview")}>
        <p className="empty-state">{t("runtimeOverviewText")}</p>

        <div className="control-plane-grid">
          <div className="field">
            <span>{t("coreRuntime")}</span>
            <strong>{coreRuntimeLabel}</strong>
            <p>{coreHealth?.service ?? "whitelist-mvpd"}</p>
          </div>

          <div className="field">
            <span>{t("profileCache")}</span>
            <strong>{profileCacheLabel}</strong>
            <p>{draft.host || "—"}</p>
          </div>

          <div className="field">
            <span>{t("deployMode")}</span>
            <strong>{deployModeLabel}</strong>
            <p>{currentTransport}</p>
          </div>

          <div className="field">
            <span>{t("safetyPosture")}</span>
            <strong>{safetyPostureLabel}</strong>
            <p>{localTunnel?.socksAddress ?? "—"}</p>
          </div>

          <div className="field field-span">
            <span>{t("protocolPack")}</span>
            <strong>{activeProtocolEntry ? protocolPackSummary : t("diagnosticsEmpty")}</strong>
            <p>{activeProtocolEntry ? t("fallbackReady") : t("diagnosticsEmpty")}</p>
          </div>
        </div>

        <div className="inline-actions">
          <button className="ghost" type="button" onClick={handleRefreshOverview} disabled={isPending}>
            {t("refreshOverview")}
          </button>
        </div>
      </SectionCard>

      <div className="workspace-tabs" role="tablist" aria-label="Workspace sections">
        <button
          className={activeTab === "server" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("server")}
          type="button"
        >
          {t("tabServer")}
        </button>
        <button
          className={activeTab === "access" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("access")}
          type="button"
        >
          {t("tabAccess")}
        </button>
        <button
          className={activeTab === "tunnel" ? "workspace-tab is-active" : "workspace-tab"}
          onClick={() => setActiveTab("tunnel")}
          type="button"
        >
          {t("tabTunnel")}
        </button>
      </div>

      {activeTab === "server" ? (
      <SectionCard eyebrow={t("serverInput")} title={t("remoteNode")}>
        <div className="form-grid">
          <label className="input-field">
            <span>{t("host")}</span>
            <input
              value={draft.host}
              onChange={(event) => setDraft((current) => ({ ...current, host: event.target.value }))}
              placeholder="203.0.113.42"
            />
          </label>

          <label className="input-field">
            <span>{t("sshPort")}</span>
            <input
              value={draft.port}
              onChange={(event) =>
                setDraft((current) => ({ ...current, port: Number(event.target.value) || 22 }))
              }
              placeholder="22"
            />
          </label>

          <label className="input-field">
            <span>{t("user")}</span>
            <input
              value={draft.username}
              onChange={(event) => setDraft((current) => ({ ...current, username: event.target.value }))}
            />
          </label>

          <label className="input-field">
            <span>{t("authMethod")}</span>
            <select
              value={draft.authMethod}
              onChange={(event) =>
                setDraft((current) => ({
                  ...current,
                  authMethod: event.target.value as ServerDraft["authMethod"]
                }))
              }
            >
              <option value="password">{t("authPassword")}</option>
              <option value="private-key">{t("authPrivateKey")}</option>
            </select>
          </label>

          <label className="input-field input-span">
            <span>{t("transportStack")}</span>
            <select
              value={draft.transport}
              onChange={(event) =>
                setDraft((current) => ({
                  ...current,
                  transport: event.target.value as ServerDraft["transport"],
                  engine: event.target.value === "xray" ? current.engine ?? "xray" : "xray",
                  protocol: event.target.value === "xray" ? current.protocol ?? "vless-reality" : "direct-wireguard"
                }))
              }
            >
              <option value="vk-turn-proxy+xray">{t("transportVK")}</option>
              <option value="xray">{t("transportDirect")}</option>
            </select>
          </label>

          {!requiresVKLink ? (
            <label className="input-field input-span">
              <span>{t("protocolMode")}</span>
              <select
                value={draft.protocol ?? "direct-wireguard"}
                onChange={(event) =>
                  setDraft((current) => ({
                    ...current,
                    protocol: event.target.value as NonNullable<ServerDraft["protocol"]>,
                    engine: event.target.value === "vless-reality" ? "xray" : current.engine ?? "xray"
                  }))
                }
              >
                <option value="direct-wireguard">{t("protocolWireGuard")}</option>
                <option value="vless-reality">{t("protocolReality")}</option>
              </select>
            </label>
          ) : null}

          {!requiresVKLink ? (
            <label className="input-field input-span">
              <span>{t("engineStack")}</span>
              <select
                value={draft.engine ?? "xray"}
                onChange={(event) =>
                  setDraft((current) => ({
                    ...current,
                    engine: event.target.value as NonNullable<ServerDraft["engine"]>
                  }))
                }
              >
                <option value="xray">{t("engineXray")}</option>
                {draft.protocol !== "vless-reality" ? <option value="sing-box">{t("engineSingBox")}</option> : null}
              </select>
            </label>
          ) : null}

          <label className="input-field input-span">
            <span>{draft.authMethod === "password" ? t("password") : t("privateKey")}</span>
            <textarea
              value={secret}
              onChange={(event) => setSecret(event.target.value)}
              placeholder={draft.authMethod === "password" ? "server password" : "-----BEGIN OPENSSH PRIVATE KEY-----"}
            />
          </label>

          {requiresVKLink ? (
            <label className="input-field input-span">
              <span>{t("vkCallLink")}</span>
              <input
                value={vkLink}
                onChange={(event) => setVKLink(event.target.value)}
                placeholder="https://vk.com/call/join/..."
              />
            </label>
          ) : null}

        </div>

        <div className="inline-actions">
          <button className="primary" onClick={handleValidate} disabled={isPending}>
            {isPending ? t("checking") : t("validateServer")}
          </button>
          <button className="ghost" onClick={handleDeploy} disabled={isPending || !validation?.ok}>
            {t("startDeploy")}
          </button>
          <button
            className="ghost"
            onClick={() => {
              setActiveTab("server");
              setDraft(initialDraft);
              setSecret("");
              setValidation(null);
              setShowValidationOverlay(false);
              setPlan([]);
              setDeployment(null);
              setShowDeploymentOverlay(false);
              setOwnerProfile(null);
              setGuestProfile(null);
              setImportedProfile(null);
              setError(null);
              window.localStorage.removeItem(storageKey);
            }}
            disabled={isPending}
          >
            {t("reset")}
          </button>
        </div>

        {error ? <p className="status-banner status-error">{error}</p> : null}
        {deployment ? (
          <p className="status-banner">
            {t("deploymentPrefix")} {deployment.deploymentId} / {deploymentStatusLabel}
            {deploymentPort ? ` / UDP ${deploymentPort}` : ""}
          </p>
        ) : null}
      </SectionCard>
      ) : null}

      {activeTab === "tunnel" ? (
      <SectionCard eyebrow={t("macTest")} title={t("isolatedTunnel")}>
        <p className="empty-state">{requiresVKLink ? t("tunnelIntro") : t("directTunnelIntro")}</p>

        <div className="inline-actions">
          <button
            className={`primary ${isBusy("startTunnel") ? "button-busy" : ""}`}
            onClick={handleStartTunnel}
            disabled={isPending || (requiresVKLink && !vkLink) || !validation?.ok || (requiresVKLink && cooldownMinutes > 0)}
          >
            {isBusy("startTunnel") ? t("startingTunnel") : t("startTunnel")}
          </button>
          {!requiresVKLink ? (
            <button
              className={`ghost ${isBusy("startReality") ? "button-busy" : ""}`}
              onClick={handleStartRealityTunnel}
              disabled={isPending || !validation?.ok}
            >
              {isBusy("startReality") ? t("startingTunnel") : t("startRealityTunnel")}
            </button>
          ) : null}
          <button className={`ghost ${isBusy("stopTunnel") ? "button-busy" : ""}`} onClick={handleStopTunnel} disabled={isPending}>
            {isBusy("stopTunnel") ? t("stoppingTunnel") : t("stopTunnel")}
          </button>
          <button className={`ghost ${isBusy("refreshTunnel") ? "button-busy" : ""}`} onClick={handleRefreshTunnelStatus} disabled={isPending}>
            {isBusy("refreshTunnel") ? t("refreshing") : t("refreshStatus")}
          </button>
          <button
            className={`ghost ${isBusy("runTest") ? "button-busy" : ""}`}
            onClick={handleRunTest}
            disabled={isPending || localTunnel?.status !== "running" || !localTunnel?.socksAddress}
          >
            {isBusy("runTest") ? t("testing") : t("runTest")}
          </button>
        </div>

        {localTunnel ? (
          <div className="check-list" style={{ marginTop: 16 }}>
              <div className="check-row">
              <div>
                <strong>{t("status")}</strong>
                <p>{tunnelStatusLabel}</p>
              </div>
              <span className={localTunnel.status === "running" ? "pill pill-ok" : "pill pill-off"}>
                {tunnelStatusLabel}
              </span>
            </div>

            {localTunnel.socksAddress ? (
              <div className="check-row">
                <div>
                  <strong>{t("socksProxy")}</strong>
                  <p>{localTunnel.socksAddress}</p>
                </div>
                <span className="pill pill-ok">{t("ready")}</span>
              </div>
            ) : null}

            {localTunnel.bridgeAddress ? (
              <div className="check-row">
                <div>
                  <strong>{t("bridgePort")}</strong>
                  <p>{localTunnel.bridgeAddress}</p>
                </div>
                <span className="pill pill-off">{t("local")}</span>
              </div>
            ) : null}

            {localTunnel.socksAddress ? (
              <div className="command-card">
                <strong>{t("quickTest")}</strong>
                <p>{t("quickTestText")}</p>
                <textarea readOnly value={curlCommand} />
              </div>
            ) : null}

            {systemProxy?.supported ? (
              <div className="command-card">
                <strong>{t("systemProxy")}</strong>
                <p>{t("systemProxyText")}</p>
                <p>{systemProxyActive ? t("systemProxyEnabled") : t("systemProxyDisabled")}</p>
                {systemProxy.serviceName ? (
                  <p>
                    {t("networkService")}: {systemProxy.serviceName}
                    {systemProxy.host && systemProxy.port ? ` / ${systemProxy.host}:${systemProxy.port}` : ""}
                  </p>
                ) : null}
                <div className="inline-actions" style={{ marginTop: 0 }}>
                  <button
                    className={`ghost ${isBusy("enableSystemProxy") ? "button-busy" : ""}`}
                    type="button"
                    onClick={handleEnableSystemProxy}
                    disabled={isPending || localTunnel.status !== "running" || !localTunnel.socksAddress}
                  >
                    {isBusy("enableSystemProxy") ? t("enabling") : t("enableSystemProxy")}
                  </button>
                  <button
                    className={`ghost ${isBusy("disableSystemProxy") ? "button-busy" : ""}`}
                    type="button"
                    onClick={handleDisableSystemProxy}
                    disabled={isPending || !systemProxyActive}
                  >
                    {isBusy("disableSystemProxy") ? t("disabling") : t("disableSystemProxy")}
                  </button>
                </div>
              </div>
            ) : null}

            {requiresVKLink && cooldownMinutes > 0 ? (
              <div className="command-card">
                <strong>{t("tunnelCooldown")}</strong>
                <p>{t("tunnelCooldownText")}</p>
                <p>
                  {t("status")}: {cooldownMinutes} min
                  {localTunnel.cooldownUntil ? ` / ${localTunnel.cooldownUntil}` : ""}
                </p>
              </div>
            ) : null}

            {localTunnel.lastTest ? (
              <div className="command-card">
                <strong>{t("lastTest")}</strong>
                <p>
                  {localTunnel.lastTest.status === "passed"
                    ? requiresVKLink
                      ? t("lastTestPassedVK")
                      : t("lastTestPassedDirect")
                    : localTunnel.lastTest.status === "running"
                      ? t("lastTestRunning")
                      : localTunnel.lastTest.status === "failed"
                        ? t("lastTestFailed")
                        : t("lastTestIdle")}
                </p>
                <p>
                  {t("target")}: {localTunnel.lastTest.url}
                  {localTunnel.lastTest.checkedAt ? ` / ${localTunnel.lastTest.checkedAt}` : ""}
                </p>
                {localTunnel.lastTest.output ? <textarea readOnly value={localTunnel.lastTest.output} /> : null}
                {localTunnel.lastTest.error ? <p className="status-banner status-error">{localTunnel.lastTest.error}</p> : null}
              </div>
            ) : null}

            {localTunnel.error ? (
              <div className="check-row">
                <div>
                  <strong>{t("error")}</strong>
                  <p>{localTunnel.error}</p>
                </div>
                <span className="pill pill-off">{t("fail")}</span>
              </div>
            ) : null}

            {localTunnel.status === "running" ? (
              <div className="command-card">
                <strong>{t("safeMode")}</strong>
                <p>{t("safeModeText")}</p>
              </div>
            ) : null}

            <div className="command-card">
              <strong>{t("runtimeLog")}</strong>
              <p>{t("runtimeLogText")}</p>
              <textarea
                readOnly
                value={runtimeLogTail.length > 0 ? runtimeLogTail.join("\n") : t("diagnosticsEmpty")}
              />
            </div>

            <div className="check-list">
              <div className="check-row">
                <div>
                  <strong>{t("activeEndpoint")}</strong>
                  <p>{ownerProfile?.serverHost ? `${ownerProfile.serverHost}:${endpointPort || "—"}` : currentHost}</p>
                </div>
                <span className="pill pill-off">{t("endpoint")}</span>
              </div>

              <div className="check-row">
                <div>
                  <strong>{t("tunnelEngine")}</strong>
                  <p>{currentEngine} / {currentTransport}</p>
                </div>
                <span className="pill pill-off">{t("transport")}</span>
              </div>

              <div className="check-row">
                <div>
                  <strong>{t("activeProtocol")}</strong>
                  <p>{currentProtocol === "vless-reality" ? t("protocolReality") : t("protocolWireGuard")}</p>
                </div>
                <span className="pill pill-off">{t("protocolPack")}</span>
              </div>
            </div>
          </div>
        ) : null}
      </SectionCard>
      ) : null}

      {activeTab === "access" ? (
      <SectionCard eyebrow={t("sharing")} title={t("ownerProfile")}>
        <div className="workspace-tabs access-tabs" role="tablist" aria-label="Access sections">
          <button
            className={activeAccessTab === "key" ? "workspace-tab is-active" : "workspace-tab"}
            onClick={() => setActiveAccessTab("key")}
            type="button"
          >
            {t("accessKeyTab")}
          </button>
          <button
            className={activeAccessTab === "share" ? "workspace-tab is-active" : "workspace-tab"}
            onClick={() => setActiveAccessTab("share")}
            type="button"
          >
            {t("accessShareTab")}
          </button>
          <button
            className={activeAccessTab === "import" ? "workspace-tab is-active" : "workspace-tab"}
            onClick={() => setActiveAccessTab("import")}
            type="button"
          >
            {t("accessImportTab")}
          </button>
        </div>

        {activeAccessTab === "key" ? (
        <div className="access-layout access-layout--single">
          <div className="access-column">
            <p className="empty-state">{t("ownerProfileIntro")}</p>

            <div className="inline-actions">
              <button className="ghost" onClick={handleRefreshOwnerProfile} disabled={isPending || !draft.host}>
                {t("refreshProfile")}
              </button>
            </div>

            {ownerProfile ? (
              ownerProfile.exists ? (
                <div className="check-list access-stack" style={{ marginTop: 16 }}>
                  <div className="check-row">
                    <div>
                      <strong>{t("name")}</strong>
                      <p>{ownerProfile.name}</p>
                    </div>
                    <span className="pill pill-ok">{t("saved")}</span>
                  </div>

                  <div className="check-row">
                    <div>
                      <strong>{t("transport")}</strong>
                      <p>
                        {ownerProfile.transport} / {ownerProfile.serverHost}:{endpointPort}
                      </p>
                    </div>
                    <span className="pill pill-off">{t("owner")}</span>
                  </div>

                  {ownerProfile.protocolPack?.length ? (
                    <div className="command-card">
                      <strong>{t("protocolPack")}</strong>
                      <p>
                        {t("activeProtocol")}: {activeProtocolEntry ? formatProtocolEntry(activeProtocolEntry) : "—"}
                      </p>
                      <textarea readOnly value={stagedFallbackSummary} />
                    </div>
                  ) : null}

                  {ownerProfile.localPath ? (
                    <div className="command-card">
                      <strong>{t("localFile")}</strong>
                      <p>{t("localFileText")}</p>
                      <textarea readOnly value={ownerProfile.localPath} />
                    </div>
                  ) : null}

                  {ownerProfile.rawJson ? (
                    <div className="command-card">
                      <strong>{t("exportJson")}</strong>
                      <p>{t("exportJsonText")}</p>
                      <textarea readOnly value={ownerProfile.rawJson} />
                      <div className="inline-actions" style={{ marginTop: 0 }}>
                        <button
                          className="ghost"
                          type="button"
                          onClick={() => handleCopy("owner-json", ownerProfile.rawJson)}
                        >
                          {copiedKey === "owner-json" ? t("copied") : t("copyJson")}
                        </button>
                      </div>
                    </div>
                  ) : null}
                </div>
              ) : (
                <p className="empty-state" style={{ marginTop: 16 }}>
                  {t("noOwnerProfile")}
                </p>
              )
            ) : null}
          </div>
        </div>
        ) : null}

        {activeAccessTab === "share" ? (
        <div className="access-layout access-layout--single">
          <div className="access-column access-column--stack">
            <div className="command-card">
              <strong>{t("guestAccess")}</strong>
              <p>{t("guestAccessIntro")}</p>
              <div className="inline-actions" style={{ marginTop: 0 }}>
                <button
                  className="ghost"
                  onClick={handleGenerateGuestProfile}
                  disabled={isPending || !draft.host || !ownerProfile?.exists}
                >
                  {t("generateShareCode")}
                </button>
              </div>
              {!ownerProfile?.exists ? <p className="empty-state">{t("noGuestProfile")}</p> : null}
            </div>

            {guestProfile && !guestProfile.error ? (
              <div className="invite-card">
                <div className="check-row">
                  <div>
                    <strong>{t("name")}</strong>
                    <p>{guestProfile.name}</p>
                  </div>
                  <span className="pill pill-off">{t("guest")}</span>
                </div>

                <div className="check-row">
                  <div>
                    <strong>{t("endpoint")}</strong>
                    <p>{guestProfile.endpoint}</p>
                  </div>
                  <span className="pill pill-ok">{guestProfile.protocol}</span>
                </div>

                <div className="check-row">
                  <div>
                    <strong>{t("fingerprint")}</strong>
                    <p>{guestProfile.fingerprint}</p>
                  </div>
                  <span className="pill pill-off">{guestProfile.transport}</span>
                </div>

                <div className="share-code">
                  <span>{t("shareCode")}</span>
                  <textarea readOnly value={guestProfile.shareCode} />
                  <p className="empty-state">{t("shareCodeText")}</p>
                  <div className="inline-actions" style={{ marginTop: 0 }}>
                    <button
                      className="ghost"
                      type="button"
                      onClick={() => handleCopy("share-code", guestProfile.shareCode)}
                    >
                      {copiedKey === "share-code" ? t("copied") : t("copyShareCode")}
                    </button>
                    <button
                      className="ghost"
                      type="button"
                      onClick={() => handleCopy("guest-json", guestProfile.rawJson)}
                    >
                      {copiedKey === "guest-json" ? t("copied") : t("copyJson")}
                    </button>
                  </div>
                </div>
              </div>
            ) : null}
          </div>
        </div>
        ) : null}

        {activeAccessTab === "import" ? (
        <div className="access-layout access-layout--single">
          <div className="access-column access-column--stack">
            <div className="command-card">
              <strong>{t("importProfile")}</strong>
              <p>{t("importProfileIntro")}</p>
              <textarea
                value={importShareCode}
                onChange={(event) => setImportShareCode(event.target.value)}
                placeholder={t("importPlaceholder")}
              />
              <div className="inline-actions" style={{ marginTop: 0 }}>
                <button className="ghost" onClick={handleImportProfile} disabled={isPending || !importShareCode.trim()}>
                  {t("importProfile")}
                </button>
              </div>
            </div>

            {importedProfile && !importedProfile.error ? (
              <div className="check-list access-stack">
                <div className="check-row">
                  <div>
                    <strong>{t("importedProfile")}</strong>
                    <p>
                      {importedProfile.name} / {importedProfile.endpoint}
                    </p>
                  </div>
                  <span className="pill pill-ok">{t("imported")}</span>
                </div>

                <div className="check-row">
                  <div>
                    <strong>{t("importedAt")}</strong>
                    <p>{importedProfile.importedAt ?? "-"}</p>
                  </div>
                  <span className="pill pill-off">{importedProfile.role}</span>
                </div>

                {importedProfile.localPath ? (
                  <div className="command-card">
                    <strong>{t("localFile")}</strong>
                    <p>{t("localFileText")}</p>
                    <textarea readOnly value={importedProfile.localPath} />
                  </div>
                ) : null}

                <div className="command-card">
                  <strong>{t("importJson")}</strong>
                  <p>{t("importJsonText")}</p>
                  <textarea readOnly value={importedProfile.rawJson} />
                  <div className="inline-actions" style={{ marginTop: 0 }}>
                    <button
                      className="ghost"
                      type="button"
                      onClick={() => handleCopy("imported-json", importedProfile.rawJson)}
                    >
                      {copiedKey === "imported-json" ? t("copied") : t("copyJson")}
                    </button>
                  </div>
                </div>
              </div>
            ) : null}
          </div>
        </div>
        ) : null}
      </SectionCard>
      ) : null}

      <SectionCard eyebrow={t("desktopDiagnostics")} title={t("diagnosticsCenter")}>
        <p className="empty-state">{t("diagnosticsCenterText")}</p>

        <div className="control-plane-grid">
          <div className="command-card">
            <strong>{t("operatorNotes")}</strong>
            <p>{t("operatorNotesText")}</p>
            <textarea readOnly value={operatorSummary} />
          </div>

          <div className="command-card">
            <strong>{t("runtimeLog")}</strong>
            <p>{t("runtimeLogText")}</p>
            <textarea
              readOnly
              value={runtimeLogTail.length > 0 ? runtimeLogTail.join("\n") : t("diagnosticsEmpty")}
            />
          </div>
        </div>
      </SectionCard>

      <SectionCard eyebrow={t("recentSession")} title={t("sessionSnapshot")}>
        <p className="empty-state">{t("sessionSnapshotText")}</p>

        <div className="control-plane-grid">
          <div className="check-list">
            <div className="check-row">
              <div>
                <strong>{t("validation")}</strong>
                <p>{validation?.ok ? t("checkOk") : t("checkFail")}</p>
              </div>
              <span className={validation?.ok ? "pill pill-ok" : "pill pill-off"}>
                {validation?.ok ? t("ready") : t("validation")}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("provisioning")}</strong>
                <p>{deployment ? `${deployment.deploymentId} / ${deploymentStatusLabel}` : t("provisioningEmpty")}</p>
              </div>
              <span className={deployment?.status === "done" ? "pill pill-ok" : "pill pill-off"}>
                {deploymentStatusLabel || t("tunnelStatusIdle")}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("remoteEgressHealth")}</strong>
                <p>{deployment?.healthChecks?.length ? deploymentHealthLabel : t("diagnosticsEmpty")}</p>
              </div>
              <span
                className={
                  deployment?.healthChecks?.length && deployment.healthChecks.every((check) => check.ok)
                    ? "pill pill-ok"
                    : "pill pill-off"
                }
              >
                {deploymentHealthLabel}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("protocolPack")}</strong>
                <p>{activeProtocolEntry ? protocolPackSummary : t("diagnosticsEmpty")}</p>
              </div>
              <span className={stagedProtocolEntries.length > 0 ? "pill pill-ok" : "pill pill-off"}>
                {stagedProtocolEntries.length > 0 ? t("fallbackReady") : t("diagnosticsEmpty")}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("ownerProfile")}</strong>
                <p>{ownerProfile?.exists ? ownerProfile.localPath ?? ownerProfile.name ?? "owner" : t("noOwnerProfile")}</p>
              </div>
              <span className={ownerProfile?.exists ? "pill pill-ok" : "pill pill-off"}>
                {ownerProfile?.exists ? t("saved") : t("fail")}
              </span>
            </div>

            <div className="check-row">
              <div>
                <strong>{t("importedProfile")}</strong>
                <p>{importedProfile?.localPath ?? importedProfile?.name ?? t("importProfileIntro")}</p>
              </div>
              <span className={importedProfile?.localPath ? "pill pill-ok" : "pill pill-off"}>
                {importedProfile?.localPath ? t("imported") : t("local")}
              </span>
            </div>
          </div>

          <div className="command-card">
            <strong>{t("recoveryHints")}</strong>
            <p>{t("recoveryHintsText")}</p>
            <textarea readOnly value={recoveryHint} />
          </div>

          <div className="command-card">
            <strong>{t("stagedFallbacks")}</strong>
            <p>{t("protocolPack")}</p>
            <textarea readOnly value={stagedFallbackSummary} />
          </div>
        </div>
      </SectionCard>

      {showDeploymentOverlay && plan.length > 0 ? (
        <div className="deployment-overlay" role="dialog" aria-modal="true" aria-label={t("deploymentDetails")}>
          <div className="deployment-overlay__backdrop" onClick={() => setShowDeploymentOverlay(false)} />
          <div className="deployment-overlay__panel">
            <div className="deployment-overlay__head">
              <div>
                <span className="section-eyebrow">{t("provisioning")}</span>
                <h2 className="section-title">{t("deploymentDetails")}</h2>
              </div>
              <button className="ghost" onClick={() => setShowDeploymentOverlay(false)} type="button">
                {t("close")}
              </button>
            </div>

            <StageList stages={plan.map(translateStage)} statusLabels={stageStatusLabels} />

            {deployment?.healthChecks?.length ? (
              <div className="check-list" style={{ marginTop: 18 }}>
                {deployment.healthChecks.map((check) => (
                  <div className="check-row" key={check.key}>
                    <div>
                      <strong>{translateCheckLabel(check.key, check.label)}</strong>
                      <p>{translateCheckDetail(check.detail)}</p>
                    </div>
                    <span className={check.ok ? "pill pill-ok" : "pill pill-off"}>
                      {check.ok ? t("checkOk") : t("checkFail")}
                    </span>
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        </div>
      ) : null}

      {showValidationOverlay && validation ? (
        <div className="deployment-overlay" role="dialog" aria-modal="true" aria-label={t("validationDetails")}>
          <div className="deployment-overlay__backdrop" onClick={() => setShowValidationOverlay(false)} />
          <div className="deployment-overlay__panel">
            <div className="deployment-overlay__head">
              <div>
                <span className="section-eyebrow">{t("validation")}</span>
                <h2 className="section-title">{t("validationDetails")}</h2>
              </div>
              <button className="ghost" onClick={() => setShowValidationOverlay(false)} type="button">
                {t("close")}
              </button>
            </div>

            <div className="check-list">
              {validation.checks.map((check) => (
                <div className="check-row" key={check.key}>
                  <div>
                    <strong>{translateCheckLabel(check.key, check.label)}</strong>
                    <p>{translateCheckDetail(check.detail)}</p>
                  </div>
                  <span className={check.ok ? "pill pill-ok" : "pill pill-off"}>
                    {check.ok ? t("checkOk") : t("checkFail")}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
