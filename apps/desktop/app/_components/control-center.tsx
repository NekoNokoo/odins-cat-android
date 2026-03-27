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
import { useI18n } from "./i18n";

const apiBaseUrl = process.env.NEXT_PUBLIC_CORE_API_URL ?? "http://127.0.0.1:8088";

const initialDraft: ServerDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  transport: "vk-turn-proxy+xray"
};

type WorkspaceTab = "server" | "access" | "tunnel";
type AccessTab = "key" | "share" | "import";
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

const storageKey = "odin-one-control-center";

const normalizeTransport = (transport: string | undefined): ServerDraft["transport"] =>
  transport === "xray" || transport === "vk-turn-proxy+xray" ? transport : initialDraft.transport;

type PersistedState = {
  activeTab: WorkspaceTab;
  activeAccessTab: AccessTab;
  draft: ServerDraft;
  secret: string;
  vkLink: string;
  validation: ValidationResponse | null;
};

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
      "service-start": "Запуск сервисов"
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
        : "Запускает xray и vk-turn-proxy на изолированных портах и проверяет их состояние."
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
      "docker-presence": "Наличие Docker"
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
        setDraft({
          host: parsed.draft.host ?? initialDraft.host,
          port: parsed.draft.port ?? initialDraft.port,
          username: parsed.draft.username ?? initialDraft.username,
          authMethod: parsed.draft.authMethod ?? initialDraft.authMethod,
          transport: normalizeTransport(parsed.draft.transport)
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

  const handleStartTunnel = () => {
    setError(null);
    setPendingAction("startTunnel");
    startTransition(async () => {
      try {
        const res = await fetch(`${apiBaseUrl}/api/local-tunnel/start`, {
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
        const tunnelData = await pollLocalTunnel();
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          await runCurrentTunnelTest();
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
        const tunnelData = await pollLocalTunnel(true);
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          await runCurrentTunnelTest();
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

          for (let i = 0; i < 6; i += 1) {
            await new Promise((resolve) => window.setTimeout(resolve, 900));
            const statusRes = await fetch(`${apiBaseUrl}/api/local-tunnel/status`);
            tunnelData = (await statusRes.json()) as LocalTunnelState;
            setLocalTunnel(tunnelData);
            if (tunnelData.status === "running" && tunnelData.socksAddress) {
              break;
            }
          }
        }

        if (!tunnelData || tunnelData.status !== "running" || !tunnelData.socksAddress) {
          setError(t("tunnelStartFailed"));
          return;
        }

        const testedTunnel = await runCurrentTunnelTest();
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
                  transport: event.target.value as ServerDraft["transport"]
                }))
              }
            >
              <option value="vk-turn-proxy+xray">{t("transportVK")}</option>
              <option value="xray">{t("transportDirect")}</option>
            </select>
          </label>

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

        <div className="vpn-hero">
          <div className="vpn-hero__copy">
            <strong>{t("vpnMode")}</strong>
            <p>{t("vpnModeText")}</p>
            <p>{vpnModeActive ? t("vpnEnabled") : t("vpnDisabled")}</p>
          </div>
          <button
            className={[
              "vpn-orb",
              vpnModeActive ? "is-active" : "",
              vpnButtonBusy ? "is-busy" : ""
            ].filter(Boolean).join(" ")}
            onClick={vpnModeActive ? handleDisableVPN : handleEnableVPN}
            disabled={
              isPending ||
              (!vpnModeActive &&
                (!validation?.ok || (requiresVKLink && (!vkLink || cooldownMinutes > 0))))
            }
            type="button"
          >
            <span className="vpn-orb__ring" />
            <span className="vpn-orb__core">
              <span className="vpn-orb__label">{vpnButtonLabel}</span>
            </span>
          </button>
        </div>

        <div className="inline-actions">
          <button
            className={`primary ${isBusy("startTunnel") ? "button-busy" : ""}`}
            onClick={handleStartTunnel}
            disabled={isPending || (requiresVKLink && !vkLink) || !validation?.ok || (requiresVKLink && cooldownMinutes > 0)}
          >
            {isBusy("startTunnel") ? t("startingTunnel") : t("startTunnel")}
          </button>
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
