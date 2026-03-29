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
import { StageList } from "@whitelist/ui/StageList";
import { useI18n } from "./i18n";

const apiBaseUrl = process.env.NEXT_PUBLIC_CORE_API_URL ?? "http://127.0.0.1:18088";

const initialDraft: ServerDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  transport: "xray",
  engine: "sing-box",
  protocol: "vless-reality"
};

type WorkspaceTab = "server" | "access" | "tunnel";
type AccessTab = "key" | "share" | "import";
type MobileSheet = "server" | "protocol" | "logs" | "more" | null;
type AccessMode = "vless-reality" | "vk-relay";
type DeployPortMode = "auto" | "manual";
type PendingAction =
  | "enableVpn"
  | "disableVpn"
  | "validate"
  | "deploy"
  | "startTunnel"
  | "stopTunnel"
  | "refreshTunnel"
  | "runTest"
  | "refreshOwnerProfile"
  | "enableSystemProxy"
  | "disableSystemProxy"
  | null;

const storageKey = "odin-one-vk-control-center-v4";

const normalizeTransport = (transport: string | undefined): ServerDraft["transport"] =>
  transport === "xray" || transport === "vk-turn-proxy+xray" ? transport : initialDraft.transport;

const normalizeEngine = (engine: string | undefined): NonNullable<ServerDraft["engine"]> =>
  engine === "sing-box" || engine === "xray" ? engine : "xray";

const normalizeProtocol = (protocol: string | undefined): NonNullable<ServerDraft["protocol"]> =>
  protocol === "vless-reality" || protocol === "direct-wireguard" ? protocol : "vless-reality";

const normalizePortHint = (port: number | undefined): number | undefined =>
  typeof port === "number" && Number.isInteger(port) && port > 0 && port <= 65535 ? port : undefined;

const normalizeInviteProtocol = (protocol: InviteProfile["protocol"] | undefined): NonNullable<ServerDraft["protocol"]> =>
  protocol === "wireguard" ? "direct-wireguard" : "vless-reality";

const resolveDraftEngine = (
  transport: ServerDraft["transport"] | undefined,
  protocol: ServerDraft["protocol"] | undefined,
  engine: string | undefined
): NonNullable<ServerDraft["engine"]> => {
  const normalizedTransportValue = normalizeTransport(transport);
  const normalizedProtocolValue =
    normalizedTransportValue === "xray" ? normalizeProtocol(protocol) : "direct-wireguard";
  if (normalizedProtocolValue === "vless-reality") {
    return "sing-box";
  }
  return normalizeEngine(engine);
};

const draftAccessMode = (serverDraft: ServerDraft): AccessMode =>
  serverDraft.transport === "vk-turn-proxy+xray" ? "vk-relay" : "vless-reality";

const applyAccessModeToDraft = (serverDraft: ServerDraft, mode: AccessMode): ServerDraft => {
  if (mode === "vk-relay") {
    return {
      ...serverDraft,
      transport: "vk-turn-proxy+xray",
      engine: "xray",
      protocol: "direct-wireguard"
    };
  }
  return {
    ...serverDraft,
    transport: "xray",
    engine: "sing-box",
    protocol: "vless-reality"
  };
};

const ownerProfileHasRealityFallback = (profile: OwnerAccessProfile | null) =>
  Boolean(profile?.stagedFallbacks && Object.prototype.hasOwnProperty.call(profile.stagedFallbacks, "vlessReality"));

const ownerProfileSupportsDraft = (profile: OwnerAccessProfile | null, serverDraft: ServerDraft) => {
  if (!profile?.exists) {
    return false;
  }
  const transport = normalizeTransport(serverDraft.transport);
  const protocol = normalizeProtocol(serverDraft.protocol);
  if (transport === "xray" && protocol === "vless-reality") {
    return ownerProfileHasRealityFallback(profile);
  }
  if (transport === "vk-turn-proxy+xray") {
    return Boolean(
      profile.vkTurnProxyPort &&
      profile.wireguard?.serverPublicKey &&
      profile.wireguard?.clientPrivateKey &&
      profile.wireguard?.address
    );
  }
  return Boolean(profile.wireguard?.serverPublicKey && profile.wireguard?.clientPrivateKey && profile.wireguard?.address);
};

const importedProfileSupportsDraft = (profile: InviteProfile | null, serverDraft: ServerDraft) => {
  if (!profile?.localPath) {
    return false;
  }
  const transport = normalizeTransport(serverDraft.transport);
  const protocol = normalizeProtocol(serverDraft.protocol);
  const importedProtocol = normalizeInviteProtocol(profile.protocol);
  if (transport === "xray" && protocol === "vless-reality") {
    return importedProtocol === "vless-reality";
  }
  if (transport === "vk-turn-proxy+xray") {
    return profile.transport === "vk-turn-proxy+xray" && profile.vkTurnProxyPort > 0;
  }
  return importedProtocol === "direct-wireguard";
};

type PersistedState = {
  activeTab: WorkspaceTab;
  activeAccessTab: AccessTab;
  draft: ServerDraft;
  deployPortMode: DeployPortMode;
  secret: string;
  vkLink: string;
  validation: ValidationResponse | null;
  importedProfile?: InviteProfile | null;
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
  const [activeSheet, setActiveSheet] = useState<MobileSheet>(null);
  const [draft, setDraft] = useState<ServerDraft>(initialDraft);
  const [deployPortMode, setDeployPortMode] = useState<DeployPortMode>("auto");
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
  const [successNotice, setSuccessNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [isPending, startTransition] = useTransition();
  const selectedAccessMode = draftAccessMode(draft);
  const curlCommand = localTunnel?.socksAddress
    ? `curl --socks5-hostname ${localTunnel.socksAddress} -I https://example.com`
    : "";
  const requiresVKLink = selectedAccessMode === "vk-relay";
  const cooldownMinutes =
    localTunnel?.cooldownRemainingSeconds && localTunnel.cooldownRemainingSeconds > 0
      ? Math.ceil(localTunnel.cooldownRemainingSeconds / 60)
      : 0;
  const endpointPort = ownerProfile?.endpointPort ?? ownerProfile?.vkTurnProxyPort ?? 0;
  const deploymentPortSummary = [
    deployment?.turnPort ? `VK UDP ${deployment.turnPort}` : "",
    deployment?.realityPort ? `REALITY TCP ${deployment.realityPort}` : ""
  ]
    .filter(Boolean)
    .join(" / ");
  const systemProxyActive = systemProxy?.enabled ?? false;
  const vpnModeActive = localTunnel?.status === "running" && systemProxyActive;
  const hasMatchingOwnerProfile = Boolean(
    ownerProfileSupportsDraft(ownerProfile, draft) && (!draft.host || ownerProfile?.serverHost === draft.host)
  );
  const hasMatchingImportedProfile = Boolean(
    importedProfileSupportsDraft(importedProfile, draft) && (!draft.host || importedProfile?.serverHost === draft.host)
  );
  const hasLocalAccessProfile = Boolean(hasMatchingOwnerProfile || hasMatchingImportedProfile);
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
      "install-binaries": "Установка бинарников",
      "configure-services": "Настройка сервисов",
      "service-start": "Запуск сервисов",
      "egress-check": "Проверка исходящего трафика"
    };
    const descriptionMap: Record<string, string> = {
      "ssh-check": "Проверяет учётные данные, удалённую ОС и текущее состояние сервера.",
      "runtime-prep": "Создаёт изолированные директории Odin One и проверяет сетевую готовность.",
      "install-binaries": "Устанавливает xray и загружает server-side vk-turn-proxy для общего dual-stack runtime.",
      "configure-services": "Генерирует ключи, пишет конфиги xray и ставит unit-файлы для REALITY и VK relay.",
      "service-start": "Запускает xray и vk-turn-proxy на одном сервере и проверяет оба входа.",
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
  const currentHost = localTunnel?.serverHost || draft.host || importedProfile?.serverHost || "—";
  const currentTransport =
    (localTunnel?.transport ?? draft.transport) === "vk-turn-proxy+xray" ? t("runtimeModeVk") : t("runtimeModeReality");
  const currentEngine = localTunnel?.engine ?? deployment?.engine ?? draft.engine ?? "xray";
  const currentProtocol = localTunnel?.protocol ?? deployment?.protocol ?? draft.protocol ?? "vless-reality";
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
  const primaryStatusText = vpnModeActive ? t("vpnEnabled") : t("vpnDisabled");
  const coreRuntimeLabel = coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable");
  const profileCacheLabel = draft.host
    ? ownerProfile?.exists
      ? t("profileCacheReady")
      : t("profileCacheMissing")
    : t("profileCacheUnknown");
  const manualPortConfigError =
    deployPortMode !== "manual"
      ? null
      : !draft.vkTurnProxyPort || !draft.realityPort
        ? t("manualPortsRequired")
        : draft.vkTurnProxyPort === draft.realityPort
          ? t("manualPortsDistinct")
          : null;
  const deployModeLabel = `${t("deployModeDual")} / ${deployPortMode === "manual" ? t("portSetupManual") : t("portSetupAuto")}`;
  const safetyPostureLabel = systemProxyActive ? t("safetySystemProxyOn") : t("safetyLocalhostOnly");
  const runtimeLogTail = localTunnel?.logTail ?? [];
  const operatorSummary = [
    coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable"),
    ownerProfile?.exists ? t("profileCacheReady") : t("profileCacheMissing"),
    localTunnel?.status === "running" ? tunnelStatusLabel : primaryStatusBadge,
    deploymentHealthLabel
  ].join(" / ");
  const recoveryHint = !draft.host || (!secret.trim() && !hasLocalAccessProfile)
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
        const normalizedDraftProtocol =
          normalizedTransportValue === "xray" && normalizedProtocolValue === "direct-wireguard"
            ? "vless-reality"
            : normalizedProtocolValue;
        setDraft({
          host: parsed.draft.host ?? initialDraft.host,
          port: parsed.draft.port ?? initialDraft.port,
          username: parsed.draft.username ?? initialDraft.username,
          authMethod: parsed.draft.authMethod ?? initialDraft.authMethod,
          transport: normalizedTransportValue,
          engine: resolveDraftEngine(normalizedTransportValue, normalizedDraftProtocol, parsed.draft.engine),
          protocol: normalizedDraftProtocol,
          vkTurnProxyPort: normalizePortHint(parsed.draft.vkTurnProxyPort),
          realityPort: normalizePortHint(parsed.draft.realityPort)
        });
        setDeployPortMode(
          parsed.deployPortMode === "manual" ||
          normalizePortHint(parsed.draft.vkTurnProxyPort) ||
          normalizePortHint(parsed.draft.realityPort)
            ? "manual"
            : "auto"
        );
        if (parsed.draft.host) {
          void fetchOwnerProfile(parsed.draft.host);
          void fetchImportedProfile(parsed.draft.host);
        }
      }
      if (parsed.importedProfile?.localPath) {
        setImportedProfile(parsed.importedProfile);
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
      deployPortMode,
      secret,
      vkLink,
      validation,
      importedProfile
    };
    window.localStorage.setItem(storageKey, JSON.stringify(snapshot));
  }, [activeAccessTab, activeTab, deployPortMode, draft, importedProfile, secret, validation, vkLink]);

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
    setSuccessNotice(null);
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
              setSuccessNotice(t("deploySuccess"));
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

  const fetchImportedProfile = async (host: string) => {
    if (!host) {
      return null;
    }
    const res = await fetch(`${apiBaseUrl}/api/profile/imported?host=${encodeURIComponent(host)}`);
    const data = (await res.json()) as InviteProfile;
    if (res.ok && data.localPath) {
      setImportedProfile(data);
      return data;
    }
    setImportedProfile(null);
    return null;
  };

  const applyImportedProfile = (profile: InviteProfile) => {
    const importedTransport = normalizeTransport(profile.transport);
    const importedProtocol = normalizeInviteProtocol(profile.protocol);
    setImportedProfile(profile);
    setDraft((current) => ({
      ...current,
      host: profile.serverHost || current.host,
      transport: importedTransport,
      engine: resolveDraftEngine(importedTransport, importedProtocol, current.engine),
      protocol: importedProtocol
    }));
    setSecret("");
  };

  const buildTunnelStartRequest = (baseDraft: ServerDraft = draft) => {
    const usingImportedProfile = Boolean(hasMatchingImportedProfile && !secret.trim() && !hasMatchingOwnerProfile);
    const serverDraft: ServerDraft =
      usingImportedProfile && importedProfile
        ? {
            ...baseDraft,
            host: importedProfile.serverHost || baseDraft.host,
            transport: normalizeTransport(importedProfile.transport),
            protocol: normalizeInviteProtocol(importedProfile.protocol),
            engine: resolveDraftEngine(
              normalizeTransport(importedProfile.transport),
              normalizeInviteProtocol(importedProfile.protocol),
              baseDraft.engine
            )
          }
        : baseDraft;
    const startUrl =
      !usingImportedProfile &&
      serverDraft.transport === "xray" &&
      (serverDraft.protocol ?? "vless-reality") === "vless-reality"
        ? `${apiBaseUrl}/api/local-tunnel/start-reality`
        : `${apiBaseUrl}/api/local-tunnel/start`;
    return { startUrl, serverDraft, usingImportedProfile };
  };

  const runningTunnelMatchesRequest = (tunnel: LocalTunnelState | null, serverDraft: ServerDraft) => {
    if (!tunnel || tunnel.status !== "running" || !tunnel.socksAddress) {
      return false;
    }
    const expectedHost = serverDraft.host?.trim();
    const expectedTransport = normalizeTransport(serverDraft.transport);
    const expectedProtocol = normalizeProtocol(serverDraft.protocol);
    if (expectedHost && tunnel.serverHost && tunnel.serverHost !== expectedHost) {
      return false;
    }
    return tunnel.transport === expectedTransport && normalizeProtocol(tunnel.protocol) === expectedProtocol;
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
      return Promise.resolve(null);
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

  const describeTunnelProbeFailure = (state: LocalTunnelState) => {
    const message = state.lastTest?.error ?? state.error ?? t("tunnelTestFailed");
    if (message.includes("exit status 28")) {
      return "Local SOCKS egress timed out (curl exit 28). System proxy was not enabled; the selected VPN path did not complete its outbound handshake.";
    }
    return message;
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

  const enableSystemProxyForTunnel = async (socksAddress?: string) => {
    try {
      const res = await fetch(`${apiBaseUrl}/api/system-proxy/enable`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          socksAddress: socksAddress ?? ""
        })
      });
      const data = (await res.json()) as SystemProxyState;
      const verified = res.ok ? await verifySystemProxy(socksAddress) : data;
      setSystemProxy(verified);
      if (!res.ok) {
        throw new Error(data.error ?? t("unknownError"));
      }
      if (!matchesExpectedProxy(verified, socksAddress)) {
        throw new Error(verified.error ?? "System SOCKS proxy did not become active on the expected local tunnel port");
      }
      return verified;
    } catch (error) {
      await fetch(`${apiBaseUrl}/api/system-proxy/disable`, {
        method: "POST"
      });
      await verifySystemProxy();
      throw error;
    }
  };

  const prepareTunnelForSystemProxy = async () => {
    const testedTunnel = await runCurrentTunnelTestWithRetry(3, 1500);
    if (!testedTunnel.lastTest?.ok || testedTunnel.status !== "running" || !testedTunnel.socksAddress) {
      throw new Error(describeTunnelProbeFailure(testedTunnel));
    }
    return testedTunnel;
  };

  const handleRefreshOverview = () => {
    startTransition(async () => {
      await Promise.all([
        fetchCoreHealth(),
        draft.host ? fetchOwnerProfile(draft.host) : Promise.resolve(),
        draft.host ? fetchImportedProfile(draft.host) : Promise.resolve(),
        pollLocalTunnel(true)
      ]);
    });
  };

  const handleStartTunnel = () => {
    setError(null);
    setPendingAction("startTunnel");
    startTransition(async () => {
      try {
        const { startUrl, serverDraft, usingImportedProfile } = buildTunnelStartRequest();
        const res = await fetch(startUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: serverDraft,
            secret: usingImportedProfile ? "" : secret,
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
          const testedTunnel = await prepareTunnelForSystemProxy();
          await enableSystemProxyForTunnel(testedTunnel.socksAddress);
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

  const handleRefreshTunnelStatus = () => {
    setError(null);
    setPendingAction("refreshTunnel");
    startTransition(async () => {
      try {
        await waitForRunningTunnel(2, 600);
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
        const testedTunnel = await prepareTunnelForSystemProxy();
        await enableSystemProxyForTunnel(testedTunnel.socksAddress);
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
        const { startUrl, serverDraft, usingImportedProfile } = buildTunnelStartRequest();
        let tunnelData = localTunnel;
        if (!runningTunnelMatchesRequest(tunnelData, serverDraft)) {
          const startRes = await fetch(startUrl, {
            method: "POST",
            headers: {
              "Content-Type": "application/json"
            },
            body: JSON.stringify({
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
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

        const testedTunnel = await prepareTunnelForSystemProxy();
        await enableSystemProxyForTunnel(testedTunnel.socksAddress);
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
        if (draft.host) {
          await fetchOwnerProfile(draft.host);
        }
        const res = await fetch(`${apiBaseUrl}/api/profile/guest`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            server: draft,
            secret,
            host: draft.host,
            name: ownerProfile?.name ?? "Odin One Access Key"
          })
        });
        const data = (await res.json()) as InviteProfile;
        setGuestProfile(data);
        if (res.ok) {
          setSuccessNotice(t("deploySuccess"));
        }
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
        if (res.ok) {
          applyImportedProfile(data);
          setImportShareCode("");
          setSuccessNotice(`${t("imported")}: ${data.name}`);
        }
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

  const handleResetState = () => {
    setActiveTab("server");
    setActiveAccessTab("key");
    setActiveSheet(null);
    setDraft(initialDraft);
    setDeployPortMode("auto");
    setSecret("");
    setValidation(null);
    setShowValidationOverlay(false);
    setPlan([]);
    setDeployment(null);
    setShowDeploymentOverlay(false);
    setOwnerProfile(null);
    setGuestProfile(null);
    setImportedProfile(null);
    setSuccessNotice(null);
    setError(null);
    if (typeof window !== "undefined") {
      window.localStorage.removeItem(storageKey);
    }
  };

  return (
    <>
      <div className="mobile-shell">
        <div className="home-scroll">
          <section className="phone-card home-stack">
            <div className="home-stack__scroll">
              <div className="home-section home-section--hero">
                <div className="phone-statusbar">
                  <span className={`phone-pill ${vpnModeActive ? "phone-pill--ok" : ""}`}>{primaryStatusBadge}</span>
                  <button className="ghost ghost--compact" type="button" onClick={handleRefreshOverview} disabled={isPending}>
                    {t("refreshStatus")}
                  </button>
                </div>

                <div className="phone-copy">
                  <span className="section-eyebrow">{t("vpnMode")}</span>
                  <h2 className="phone-title">{primaryStatusText}</h2>
                  <p className="phone-subtitle">{currentHost}</p>
                </div>

                <button
                  className={`phone-connect ${vpnModeActive ? "phone-connect--active" : ""}`}
                  type="button"
                  onClick={vpnModeActive ? handleDisableVPN : handleEnableVPN}
                  disabled={
                    isPending ||
                    (!vpnModeActive &&
                      (!draft.host ||
                        (!secret.trim() && !hasLocalAccessProfile) ||
                        (requiresVKLink && (!vkLink || cooldownMinutes > 0))))
                  }
                >
                  <span>{vpnButtonLabel}</span>
                </button>

                {error ? <p className="status-banner status-error">{error}</p> : null}
                {deployment ? (
                  <p className="status-banner">
                    {t("deploymentPrefix")} {deployment.deploymentId} / {deploymentStatusLabel}
                    {deploymentPortSummary ? ` / ${deploymentPortSummary}` : ""}
                  </p>
                ) : null}
              </div>

              <div className="home-divider" />

              <div className="home-section home-section--invite">
                <div className="invite-home__head">
                  <span className="section-eyebrow">{t("sharing")}</span>
                  <strong>{t("shareCode")}</strong>
                </div>

                <label className="input-field input-span input-field--compact">
                  <span>{t("importProfile")}</span>
                  <input
                    value={importShareCode}
                    onChange={(event) => setImportShareCode(event.target.value)}
                    placeholder={t("importPlaceholder")}
                  />
                </label>

                <div className="invite-home__actions">
                  <button
                    className="ghost"
                    type="button"
                    onClick={handleGenerateGuestProfile}
                    disabled={isPending || !draft.host || !ownerProfile?.exists || !secret.trim()}
                  >
                    {t("generateShareCode")}
                  </button>
                  <button
                    className="ghost"
                    type="button"
                    onClick={() => handleCopy("shareCode", guestProfile?.shareCode)}
                    disabled={!guestProfile?.shareCode}
                  >
                    {copiedKey === "shareCode" ? t("copied") : t("copyShareCode")}
                  </button>
                  <button
                    className="ghost"
                    type="button"
                    onClick={handleImportProfile}
                    disabled={isPending || !importShareCode.trim()}
                  >
                    {t("importProfile")}
                  </button>
                </div>

                {guestProfile?.shareCode ? (
                  <div className="invite-home__result">
                    <span>{t("shareCode")}</span>
                    <input readOnly value={guestProfile.shareCode} />
                  </div>
                ) : null}

                {importedProfile?.localPath ? (
                  <p className="status-banner status-success">
                    {t("importedProfile")}: {importedProfile.name}
                    {importedProfile.endpoint ? ` / ${importedProfile.endpoint}` : ""}
                  </p>
                ) : null}
              </div>
            </div>
          </section>
        </div>

        <nav className="mobile-dock" aria-label="Primary actions">
          <button
            className={activeSheet === "server" ? "mobile-dock__button is-active" : "mobile-dock__button"}
            type="button"
            onClick={() => setActiveSheet((current) => current === "server" ? null : "server")}
          >
            {t("tabServer")}
          </button>
          <button
            className={activeSheet === "protocol" ? "mobile-dock__button is-active" : "mobile-dock__button"}
            type="button"
            onClick={() => setActiveSheet((current) => current === "protocol" ? null : "protocol")}
          >
            {t("navProtocol")}
          </button>
          <button
            className={activeSheet === "logs" ? "mobile-dock__button is-active" : "mobile-dock__button"}
            type="button"
            onClick={() => setActiveSheet((current) => current === "logs" ? null : "logs")}
          >
            {t("navLogs")}
          </button>
          <button
            className={activeSheet === "more" ? "mobile-dock__button is-active" : "mobile-dock__button"}
            type="button"
            onClick={() => setActiveSheet((current) => current === "more" ? null : "more")}
          >
            {t("navMore")}
          </button>
        </nav>
      </div>

      {activeSheet === "server" ? (
        <div className="sheet-overlay" role="dialog" aria-modal="true" aria-label={t("sheetServerTitle")}>
          <button className="sheet-overlay__backdrop" onClick={() => setActiveSheet(null)} aria-label={t("close")} />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("serverInput")}</span>
                <h3 className="sheet-panel__title">{t("sheetServerTitle")}</h3>
              </div>
              <button className="ghost ghost--compact" type="button" onClick={() => setActiveSheet(null)}>
                {t("close")}
              </button>
            </div>

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
                  placeholder="root"
                />
              </label>

              <label className="input-field input-span">
                <div className="input-field__head">
                  <span>{draft.authMethod === "password" ? t("password") : t("privateKey")}</span>
                  <div className="lang-toggle" aria-label={t("authMethod")}>
                    <button
                      className={draft.authMethod === "password" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() =>
                        setDraft((current) => ({
                          ...current,
                          authMethod: "password"
                        }))
                      }
                    >
                      {t("authPassword")}
                    </button>
                    <button
                      className={draft.authMethod === "private-key" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() =>
                        setDraft((current) => ({
                          ...current,
                          authMethod: "private-key"
                        }))
                      }
                    >
                      {t("authPrivateKey")}
                    </button>
                  </div>
                </div>
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

            {successNotice ? <p className="status-banner status-success">{successNotice}</p> : null}
            {manualPortConfigError ? <p className="status-banner status-error">{manualPortConfigError}</p> : null}

            <div className="sheet-actions">
              <button
                className="primary"
                onClick={handleDeploy}
                disabled={isPending || !draft.host || !secret.trim() || Boolean(manualPortConfigError)}
              >
                {t("startDeploy")}
              </button>
              <button className="ghost" onClick={handleResetState} disabled={isPending}>
                {t("reset")}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "protocol" ? (
        <div className="sheet-overlay" role="dialog" aria-modal="true" aria-label={t("sheetProtocolTitle")}>
          <button className="sheet-overlay__backdrop" onClick={() => setActiveSheet(null)} aria-label={t("close")} />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("protocolPack")}</span>
                <h3 className="sheet-panel__title">{t("sheetProtocolTitle")}</h3>
              </div>
              <button className="ghost ghost--compact" type="button" onClick={() => setActiveSheet(null)}>
                {t("close")}
              </button>
            </div>

            <div className="phone-facts">
              <div className="phone-fact">
                <span>{t("runtimeMode")}</span>
                <strong>{currentTransport}</strong>
              </div>
              <div className="phone-fact">
                <span>{t("activeProtocol")}</span>
                <strong>{currentProtocol === "vless-reality" ? t("protocolReality") : t("protocolWireGuard")}</strong>
              </div>
              <div className="phone-fact">
                <span>{t("portSetup")}</span>
                <strong>{deployPortMode === "manual" ? t("portSetupManual") : t("portSetupAuto")}</strong>
              </div>
            </div>

            <div className="form-grid">
              <label className="input-field input-span">
                <div className="input-field__head">
                  <span>{t("runtimeMode")}</span>
                  <div className="lang-toggle" aria-label={t("runtimeMode")}>
                    <button
                      className={selectedAccessMode === "vless-reality" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() => setDraft((current) => applyAccessModeToDraft(current, "vless-reality"))}
                    >
                      {t("runtimeModeReality")}
                    </button>
                    <button
                      className={selectedAccessMode === "vk-relay" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() => setDraft((current) => applyAccessModeToDraft(current, "vk-relay"))}
                    >
                      {t("runtimeModeVk")}
                    </button>
                  </div>
                </div>
                <p className="compact-note">
                  {selectedAccessMode === "vk-relay" ? t("runtimeModeVkHint") : t("runtimeModeRealityHint")}
                </p>
              </label>

              <label className="input-field input-span">
                <div className="input-field__head">
                  <span>{t("portSetup")}</span>
                  <div className="lang-toggle" aria-label={t("portSetup")}>
                    <button
                      className={deployPortMode === "auto" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() => {
                        setDeployPortMode("auto");
                        setDraft((current) => ({
                          ...current,
                          vkTurnProxyPort: undefined,
                          realityPort: undefined
                        }));
                      }}
                    >
                      {t("portSetupAuto")}
                    </button>
                    <button
                      className={deployPortMode === "manual" ? "lang-button is-active" : "lang-button"}
                      type="button"
                      onClick={() => setDeployPortMode("manual")}
                    >
                      {t("portSetupManual")}
                    </button>
                  </div>
                </div>
                <p className="compact-note">
                  {deployPortMode === "manual" ? t("portSetupManualHint") : t("portSetupAutoHint")}
                </p>
              </label>

              {deployPortMode === "manual" ? (
                <>
                  <label className="input-field">
                    <span>{t("vkRelayPort")}</span>
                    <input
                      value={draft.vkTurnProxyPort ?? ""}
                      onChange={(event) =>
                        setDraft((current) => ({
                          ...current,
                          vkTurnProxyPort: normalizePortHint(Number.parseInt(event.target.value, 10))
                        }))
                      }
                      placeholder="56080"
                      inputMode="numeric"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("realityPort")}</span>
                    <input
                      value={draft.realityPort ?? ""}
                      onChange={(event) =>
                        setDraft((current) => ({
                          ...current,
                          realityPort: normalizePortHint(Number.parseInt(event.target.value, 10))
                        }))
                      }
                      placeholder="52443"
                      inputMode="numeric"
                    />
                  </label>
                </>
              ) : null}
            </div>

            {manualPortConfigError ? <p className="status-banner status-error">{manualPortConfigError}</p> : null}

            <div className="sheet-actions">
              <button
                className="primary"
                type="button"
                onClick={handleStartTunnel}
                disabled={isPending || !draft.host || !secret.trim() || (requiresVKLink && !vkLink) || (requiresVKLink && cooldownMinutes > 0)}
              >
                {isBusy("startTunnel") ? t("startingTunnel") : t("startTunnel")}
              </button>
              <button className="ghost" type="button" onClick={handleStopTunnel} disabled={isPending}>
                {isBusy("stopTunnel") ? t("stoppingTunnel") : t("stopTunnel")}
              </button>
              <button className="ghost" type="button" onClick={handleRunTest} disabled={isPending || localTunnel?.status !== "running"}>
                {isBusy("runTest") ? t("testing") : t("runTest")}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "logs" ? (
        <div className="sheet-overlay" role="dialog" aria-modal="true" aria-label={t("sheetLogsTitle")}>
          <button className="sheet-overlay__backdrop" onClick={() => setActiveSheet(null)} aria-label={t("close")} />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("runtimeLog")}</span>
                <h3 className="sheet-panel__title">{t("sheetLogsTitle")}</h3>
              </div>
              <button className="ghost ghost--compact" type="button" onClick={() => setActiveSheet(null)}>
                {t("close")}
              </button>
            </div>

            <div className="sheet-stack">
              <div className="sheet-actions">
                <button className="ghost" type="button" onClick={handleRefreshTunnelStatus} disabled={isPending}>
                  {t("refreshStatus")}
                </button>
                <button className="ghost" type="button" onClick={handleRunTest} disabled={isPending || localTunnel?.status !== "running"}>
                  {isBusy("runTest") ? t("testing") : t("runTest")}
                </button>
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeLog")}</strong>
                <textarea
                  readOnly
                  value={runtimeLogTail.length > 0 ? runtimeLogTail.join("\n") : t("diagnosticsEmpty")}
                />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lastTest")}</strong>
                <p className="compact-note">
                  {localTunnel?.lastTest?.url ?? "https://example.com"}
                  {localTunnel?.lastTest?.checkedAt ? ` / ${localTunnel.lastTest.checkedAt}` : ""}
                </p>
                <textarea
                  readOnly
                  value={localTunnel?.lastTest?.output ?? localTunnel?.lastTest?.error ?? t("diagnosticsEmpty")}
                />
              </div>

              {curlCommand ? (
                <div className="command-card">
                  <strong>{t("quickTest")}</strong>
                  <textarea readOnly value={curlCommand} />
                </div>
              ) : null}
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "more" ? (
        <div className="sheet-overlay" role="dialog" aria-modal="true" aria-label={t("sheetMoreTitle")}>
          <button className="sheet-overlay__backdrop" onClick={() => setActiveSheet(null)} aria-label={t("close")} />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("recoveryHints")}</span>
                <h3 className="sheet-panel__title">{t("sheetMoreTitle")}</h3>
              </div>
              <button className="ghost ghost--compact" type="button" onClick={() => setActiveSheet(null)}>
                {t("close")}
              </button>
            </div>

            <div className="sheet-stack">
              <div className="phone-facts phone-facts--stack">
                <div className="phone-fact">
                  <span>{t("activeEndpoint")}</span>
                  <strong>{ownerProfile?.serverHost ? `${ownerProfile.serverHost}:${endpointPort || "—"}` : currentHost}</strong>
                </div>
                <div className="phone-fact">
                  <span>{t("tunnelEngine")}</span>
                  <strong>{currentEngine}</strong>
                </div>
                <div className="phone-fact">
                  <span>{t("protocolPack")}</span>
                  <strong>{activeProtocolEntry ? protocolPackSummary : t("diagnosticsEmpty")}</strong>
                </div>
              </div>

              {stagedProtocolEntries.length > 0 ? (
                <div className="command-card command-card--compact">
                  <strong>{t("stagedFallbacks")}</strong>
                  <textarea readOnly value={stagedFallbackSummary} />
                </div>
              ) : null}

              <p className="compact-note compact-note--panel">{recoveryHint}</p>

              <div className="sheet-actions">
                <button className="ghost" type="button" onClick={handleRefreshOwnerProfile} disabled={isPending || !draft.host}>
                  {t("refreshProfile")}
                </button>
                <button
                  className="ghost"
                  type="button"
                  onClick={handleGenerateGuestProfile}
                  disabled={isPending || !draft.host || !ownerProfile?.exists || !secret.trim()}
                >
                  {t("generateShareCode")}
                </button>
                <button className="ghost" type="button" onClick={handleImportProfile} disabled={isPending || !importShareCode.trim()}>
                  {t("importProfile")}
                </button>
              </div>

              <label className="input-field input-span">
                <span>{t("importProfile")}</span>
                <textarea
                  value={importShareCode}
                  onChange={(event) => setImportShareCode(event.target.value)}
                  placeholder={t("importPlaceholder")}
                />
              </label>

              {guestProfile?.shareCode ? (
                <div className="command-card command-card--compact">
                  <strong>{t("shareCode")}</strong>
                  <textarea readOnly value={guestProfile.shareCode} />
                  <div className="sheet-actions">
                    <button className="ghost" type="button" onClick={() => handleCopy("shareCode", guestProfile.shareCode)}>
                      {copiedKey === "shareCode" ? t("copied") : t("copyShareCode")}
                    </button>
                    <button className="ghost" type="button" onClick={() => handleCopy("guestJson", guestProfile.rawJson)}>
                      {copiedKey === "guestJson" ? t("copied") : t("copyJson")}
                    </button>
                  </div>
                </div>
              ) : null}

              {importedProfile?.localPath ? (
                <div className="command-card command-card--compact">
                  <strong>{t("importedProfile")}</strong>
                  <p className="compact-note">
                    {importedProfile.name}
                    {importedProfile.endpoint ? ` / ${importedProfile.endpoint}` : ""}
                  </p>
                  <textarea readOnly value={importedProfile.rawJson} />
                </div>
              ) : null}
            </div>
          </div>
        </div>
      ) : null}

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
