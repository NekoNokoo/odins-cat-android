"use client";

import { useEffect, useState, useTransition } from "react";
import type {
  DeploymentState,
  DeployStage,
  InviteProfile,
  LocalTunnelState,
  OwnerRuntimeLabRequest,
  OwnerAccessProfile,
  ServerDraft,
  SystemProxyState,
  ValidationResponse
} from "@whitelist/contracts";
import { StageList } from "@whitelist/ui/StageList";
import { coreApi, type CoreHealthState } from "../_core/core-api";
import { useI18n } from "./i18n";

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
type AccessMode = "vless-reality" | "vk-relay" | "relay-via-server" | "relay-direct";
type DeployPortMode = "auto" | "manual";
type PendingAction =
  | "enableVpn"
  | "disableVpn"
  | "validate"
  | "deploy"
  | "startTunnel"
  | "startOwnerRuntimeLab"
  | "stopTunnel"
  | "refreshTunnel"
  | "runTest"
  | "refreshOwnerProfile"
  | "enableSystemProxy"
  | "disableSystemProxy"
  | null;

type OwnerRuntimeLabMode =
  | "off"
  | "reality-whitelist-scaffold"
  | "reality-whitelist-lab"
  | "reality-vps-scaffold"
  | "reality-vps-lab"
  | "reality-vps-relay-lab";

type OwnerRuntimeLabTransport = "tcp" | "grpc";

type OwnerRuntimeLabState = {
  mode: OwnerRuntimeLabMode;
  hintServerName: string;
  hintCidrBucket: string;
  hintSource: string;
  hintTag: string;
  vpsServerName: string;
  vpsPort: string;
  vpsTransport: OwnerRuntimeLabTransport;
  vpsFlow: string;
  vpsFingerprint: string;
  vpsGrpcServiceName: string;
  vpsGrpcAuthority: string;
  vpsSource: string;
  vpsTag: string;
  vpsUseOwnerRealityEgress: boolean;
  vpsUseRelayAutoselect: boolean;
  vpsRelaySubscriptionUrl: string;
  vpsRelaySourceLabel: string;
};

const storageKey = "odin-one-vk-control-center-v4";
const ownerRuntimeLabStorageKey = "odin-one-owner-runtime-lab-v1";
const ownerRuntimeLabUnlockStorageKey = "odin-one-owner-runtime-lab-unlocked-v1";
const ownerRuntimeLabUnlockTapTarget = 5;
const defaultOwnerRuntimeLabRelaySubscriptionUrl =
  "https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt";
const defaultOwnerRuntimeLabRelaySourceLabel = "igareck-mobile-hourly";
const diagnosticsPreviewMaxLines = 8;
const diagnosticsPreviewMaxChars = 720;
const diagnosticsLogPreviewMaxLines = 24;
const diagnosticsLogPreviewMaxChars = 2800;
const defaultOwnerRuntimeLabState: OwnerRuntimeLabState = {
  mode: "off",
  hintServerName: "max.ru",
  hintCidrBucket: "cidr-max",
  hintSource: "operator-curated",
  hintTag: "candidate-max-ru",
  vpsServerName: "pimg.mycdn.me",
  vpsPort: "10443",
  vpsTransport: "tcp",
  vpsFlow: "xtls-rprx-vision",
  vpsFingerprint: "chrome",
  vpsGrpcServiceName: "",
  vpsGrpcAuthority: "",
  vpsSource: "operator-curated:vps-lab",
  vpsTag: "reality-lab-pimg-mycdn-me-tcp",
  vpsUseOwnerRealityEgress: true,
  vpsUseRelayAutoselect: false,
  vpsRelaySubscriptionUrl: defaultOwnerRuntimeLabRelaySubscriptionUrl,
  vpsRelaySourceLabel: defaultOwnerRuntimeLabRelaySourceLabel
};

const withIgareckRelayDefaults = (current: OwnerRuntimeLabState): OwnerRuntimeLabState => ({
  ...current,
  vpsUseOwnerRealityEgress: current.vpsUseOwnerRealityEgress,
  vpsUseRelayAutoselect: true,
  vpsRelaySubscriptionUrl: current.vpsRelaySubscriptionUrl.trim() || defaultOwnerRuntimeLabRelaySubscriptionUrl,
  vpsRelaySourceLabel: current.vpsRelaySourceLabel.trim() || defaultOwnerRuntimeLabRelaySourceLabel,
  vpsServerName: current.vpsServerName.trim() || "id.x5.ru",
  vpsPort:
    Number.isInteger(Number.parseInt(current.vpsPort, 10)) && Number.parseInt(current.vpsPort, 10) > 0
      ? current.vpsPort
      : "443",
  vpsTransport: "tcp",
  vpsFlow: current.vpsFlow.trim() || "xtls-rprx-vision",
  vpsFingerprint: current.vpsFingerprint.trim() || "chrome"
});

const isOwnerRuntimeLabVpsMode = (mode: OwnerRuntimeLabMode) =>
  mode === "reality-vps-scaffold" || mode === "reality-vps-lab" || mode === "reality-vps-relay-lab";

const isOwnerRuntimeLabRelayOwnerMode = (mode: OwnerRuntimeLabMode) => mode === "reality-vps-relay-lab";

const normalizeTransport = (transport: string | undefined): ServerDraft["transport"] =>
  transport === "xray" || transport === "vk-turn-proxy+xray" ? transport : initialDraft.transport;

const normalizeEngine = (engine: string | undefined): NonNullable<ServerDraft["engine"]> =>
  engine === "sing-box" || engine === "xray" ? engine : "xray";

const normalizeProtocol = (protocol: string | undefined): NonNullable<ServerDraft["protocol"]> =>
  protocol === "vless-reality" || protocol === "direct-wireguard" ? protocol : "vless-reality";

const normalizePortHint = (port: number | undefined): number | undefined =>
  typeof port === "number" && Number.isInteger(port) && port > 0 && port <= 65535 ? port : undefined;

const normalizeHostValue = (host: string | null | undefined) => host?.trim().toLowerCase() ?? "";

const hostsMatch = (left: string | null | undefined, right: string | null | undefined) => {
  const normalizedLeft = normalizeHostValue(left);
  const normalizedRight = normalizeHostValue(right);
  if (!normalizedLeft || !normalizedRight) {
    return true;
  }
  return normalizedLeft === normalizedRight;
};

const normalizeInviteProtocol = (protocol: InviteProfile["protocol"] | undefined): NonNullable<ServerDraft["protocol"]> =>
  protocol === "wireguard" ? "direct-wireguard" : "vless-reality";

const importedProfileHasReality = (profile: InviteProfile | null) =>
  Boolean(profile?.supportsReality ?? profile?.vlessReality?.port);

const importedProfileHasVKRelay = (profile: InviteProfile | null) =>
  Boolean(profile?.supportsVKRelay ?? (profile?.vkTurnProxyPort && profile?.wireGuardPort));

const ownerProfileHasRealityRelay = (profile: OwnerAccessProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
      (Object.prototype.hasOwnProperty.call(profile.stagedFallbacks, "realityRelayOwnerEgress") ||
        Object.prototype.hasOwnProperty.call(profile.stagedFallbacks, "vlessReality"))
  );

const importedProfileHasRealityRelay = (profile: InviteProfile | null) =>
  Boolean(
    profile?.supportsRealityRelay ??
      (profile?.stagedFallbacks &&
        Object.prototype.hasOwnProperty.call(profile.stagedFallbacks, "realityRelayOwnerEgress"))
  );

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

const clampDiagnosticText = (value: string, maxLines = diagnosticsPreviewMaxLines, maxChars = diagnosticsPreviewMaxChars) => {
  const normalized = value.replace(/\r\n/g, "\n").trim();
  if (!normalized) {
    return "";
  }

  const lines = normalized.split("\n");
  const cappedLines = lines.slice(0, maxLines);
  let output = cappedLines.join("\n");

  if (output.length > maxChars) {
    output = output.slice(0, maxChars).trimEnd();
  }

  if (lines.length > cappedLines.length || normalized.length > output.length) {
    output = `${output}\n...`;
  }

  return output;
};

const formatDiagnosticLogTail = (lines: string[], fallback: string) => {
  if (lines.length === 0) {
    return fallback;
  }

  const relevantLines = lines.slice(-diagnosticsLogPreviewMaxLines);
  return clampDiagnosticText(relevantLines.join("\n"), diagnosticsLogPreviewMaxLines, diagnosticsLogPreviewMaxChars);
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
  if (transport === "xray" && normalizeProtocol(serverDraft.protocol) === "vless-reality") {
    return importedProfileHasReality(profile);
  }
  if (transport === "vk-turn-proxy+xray") {
    return importedProfileHasVKRelay(profile);
  }
  return importedProfileHasVKRelay(profile);
};

const ownerProfileSupportsRelayMode = (profile: OwnerAccessProfile | null, serverDraft: ServerDraft) =>
  ownerProfileSupportsDraft(profile, serverDraft) && ownerProfileHasRealityRelay(profile);

const importedProfileSupportsRelayMode = (profile: InviteProfile | null, serverDraft: ServerDraft) =>
  importedProfileSupportsDraft(profile, serverDraft) && importedProfileHasRealityRelay(profile);

const importedProfileMatchesHost = (profile: InviteProfile | null, host: string | null | undefined) =>
  Boolean(profile?.localPath && hostsMatch(host, profile?.serverHost));

type PersistedState = {
  activeTab: WorkspaceTab;
  activeAccessTab: AccessTab;
  accessMode?: AccessMode;
  draft: ServerDraft;
  deployPortMode: DeployPortMode;
  secret: string;
  vkLink: string;
  validation: ValidationResponse | null;
  importedProfile?: InviteProfile | null;
};

const formatProtocolEntry = (entry: NonNullable<OwnerAccessProfile["protocolPack"]>[number]) =>
  `${entry.label} / ${entry.scheme} / ${entry.network.toUpperCase()} ${entry.port}`;

export function ControlCenter() {
  const { locale, t } = useI18n();
  const [activeTab, setActiveTab] = useState<WorkspaceTab>("server");
  const [activeAccessTab, setActiveAccessTab] = useState<AccessTab>("key");
  const [activeSheet, setActiveSheet] = useState<MobileSheet>(null);
  const [draft, setDraft] = useState<ServerDraft>(initialDraft);
  const [selectedAccessMode, setSelectedAccessMode] = useState<AccessMode>("vless-reality");
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
  const [androidVpnVisualOverride, setAndroidVpnVisualOverride] = useState(false);
  const [ownerRuntimeLabUnlocked, setOwnerRuntimeLabUnlocked] = useState(false);
  const [ownerRuntimeLabUnlockTapCount, setOwnerRuntimeLabUnlockTapCount] = useState(0);
  const [ownerRuntimeLab, setOwnerRuntimeLab] = useState<OwnerRuntimeLabState>(defaultOwnerRuntimeLabState);
  const isAndroidClient =
    coreHealth?.service === "odin-one-mobile-bridge" ||
    (typeof window !== "undefined" && /Android/i.test(window.navigator.userAgent));
  const curlCommand = localTunnel?.socksAddress
    ? `curl --socks5-hostname ${localTunnel.socksAddress} -I https://example.com`
    : "";
  const requiresVKLink = selectedAccessMode === "vk-relay";
  const resolvedDraftHost = draft.host.trim() || importedProfile?.serverHost?.trim() || ownerProfile?.serverHost?.trim() || "";
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
  const isAndroidVpnRuntime = systemProxy?.serviceName === "Android VpnService";
  const androidInterfaceEstablished =
    isAndroidClient &&
    Boolean(
      localTunnel &&
        localTunnel.status !== "idle" &&
        localTunnel.status !== "stopped" &&
        localTunnel.status !== "failed" &&
        localTunnel.logTail?.some((line) => line.includes("Android VpnService established the system VPN interface."))
    );
  const runtimeTunnelActive = localTunnel?.status === "running" || androidInterfaceEstablished;
  const vpnModeActive = runtimeTunnelActive && (isAndroidClient || isAndroidVpnRuntime || systemProxyActive);
  const ownerRuntimeLabRealityDraft: ServerDraft = {
    ...draft,
    transport: "xray",
    engine: "sing-box",
    protocol: "vless-reality"
  };
  const hasMatchingOwnerProfile = Boolean(
    ownerProfileSupportsDraft(ownerProfile, draft) && hostsMatch(draft.host, ownerProfile?.serverHost)
  );
  const hasMatchingImportedProfile = Boolean(
    importedProfileSupportsDraft(importedProfile, draft) && hostsMatch(draft.host, importedProfile?.serverHost)
  );
  const hasImportedProfileForHost = importedProfileMatchesHost(importedProfile, draft.host || resolvedDraftHost);
  const hasLocalAccessProfile = Boolean(hasMatchingOwnerProfile || hasMatchingImportedProfile || hasImportedProfileForHost);
  const hasLocalRelayAccessProfile = Boolean(
    (ownerProfileSupportsRelayMode(ownerProfile, ownerRuntimeLabRealityDraft) &&
      hostsMatch(draft.host || resolvedDraftHost, ownerProfile?.serverHost)) ||
      (importedProfileSupportsRelayMode(importedProfile, ownerRuntimeLabRealityDraft) &&
        hostsMatch(draft.host || resolvedDraftHost, importedProfile?.serverHost))
  );
  const hasLocalAccessProfileForSelectedMode =
    selectedAccessMode === "relay-via-server" ? hasLocalRelayAccessProfile : hasLocalAccessProfile;
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
  const vpnActionActive = runtimeTunnelActive || vpnModeActive || (isAndroidClient && androidVpnVisualOverride);
  const vpnVisualActive = vpnActionActive;
  const vpnButtonLabel = isBusy("disableVpn")
    ? t("disablingVpn")
    : vpnActionActive
      ? t("disableVpn")
      : isBusy("enableVpn") && !runtimeTunnelActive
        ? t("enablingVpn")
        : t("enableVpn");
  const currentHost = localTunnel?.serverHost || draft.host || importedProfile?.serverHost || "—";
  const relayRuntimeActive = Boolean(
    localTunnel?.runtimeFamily === "reality-vps-lab" &&
      localTunnel?.activationState === "active" &&
      localTunnel?.relayAutoselectEnabled &&
      localTunnel?.frontConnectHost
  );
  const relayOwnerRuntimeActive = Boolean(
    relayRuntimeActive && localTunnel?.activeFeatures?.includes("reality-vps-owner-egress:on")
  );
  const relayDirectRuntimeActive = Boolean(
    relayRuntimeActive && localTunnel?.activeFeatures?.includes("reality-vps-owner-egress:off")
  );
  const currentTransport =
    relayOwnerRuntimeActive || selectedAccessMode === "relay-via-server"
      ? t("runtimeModeRelayOwner")
      : relayDirectRuntimeActive || selectedAccessMode === "relay-direct"
        ? t("runtimeModeRelayDirect")
      : (localTunnel?.transport ?? draft.transport) === "vk-turn-proxy+xray"
        ? t("runtimeModeVk")
        : t("runtimeModeReality");
  const selectedAccessModeHint =
    selectedAccessMode === "relay-via-server"
      ? t("runtimeModeRelayOwnerHint")
      : selectedAccessMode === "relay-direct"
        ? t("runtimeModeRelayDirectHint")
      : selectedAccessMode === "vk-relay"
        ? t("runtimeModeVkHint")
        : t("runtimeModeRealityHint");
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
  const primaryStatusBadge = vpnVisualActive ? t("ready") : tunnelStatusLabel || t("tunnelStatusIdle");
  const primaryStatusText = vpnVisualActive ? t("vpnEnabled") : t("vpnDisabled");
  const relayOwnerConnectAnimation =
    (selectedAccessMode === "relay-via-server" || selectedAccessMode === "relay-direct") &&
    !vpnVisualActive &&
    (isBusy("enableVpn") || isBusy("startTunnel") || localTunnel?.status === "starting");
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
  const runtimeStartSource = localTunnel?.startSource ?? t("diagnosticsEmpty");
  const runtimeFamily = localTunnel?.runtimeFamily ?? t("diagnosticsEmpty");
  const runtimeActivationState = localTunnel?.activationState ?? t("diagnosticsEmpty");
  const runtimeFrontHost = localTunnel?.frontHost ?? t("diagnosticsEmpty");
  const runtimeFrontPath = localTunnel?.frontPath ?? t("diagnosticsEmpty");
  const runtimeFrontProvider = localTunnel?.frontProvider ?? t("diagnosticsEmpty");
  const runtimeFrontTag = localTunnel?.frontTag ?? t("diagnosticsEmpty");
  const runtimeRelayAutoselectSummary = localTunnel?.relayAutoselectEnabled
    ? [
        `status: ${localTunnel.relayAutoselectStatus ?? t("diagnosticsEmpty")}`,
        `source: ${localTunnel.relayAutoselectSourceLabel ?? t("diagnosticsEmpty")}`,
        `best: ${localTunnel.relayAutoselectBestSni ?? t("diagnosticsEmpty")} -> ${
          localTunnel.relayAutoselectBestHost ?? t("diagnosticsEmpty")
        }${localTunnel.relayAutoselectBestPort ? `:${localTunnel.relayAutoselectBestPort}` : ""}`,
        `latencyMs: ${
          typeof localTunnel.relayAutoselectBestLatencyMs === "number"
            ? localTunnel.relayAutoselectBestLatencyMs.toString()
            : t("diagnosticsEmpty")
        }`,
        `candidates: ${
          typeof localTunnel.relayAutoselectCandidateCount === "number"
            ? localTunnel.relayAutoselectCandidateCount.toString()
            : t("diagnosticsEmpty")
        }`,
        `lastRefreshAt: ${localTunnel.relayAutoselectLastRefreshAt ?? t("diagnosticsEmpty")}`,
        `lastError: ${localTunnel.relayAutoselectLastError ?? t("diagnosticsEmpty")}`
      ].join("\n")
    : t("diagnosticsEmpty");
  const runtimeSelectedSniHint = localTunnel?.selectedSniHint ?? t("diagnosticsEmpty");
  const runtimeSelectedCidrHint = localTunnel?.selectedCidrHint ?? t("diagnosticsEmpty");
  const runtimeWhitelistHintSource = localTunnel?.whitelistHintSource ?? t("diagnosticsEmpty");
  const runtimeWhitelistHintTag = localTunnel?.whitelistHintTag ?? t("diagnosticsEmpty");
  const realityConfigMode = localTunnel?.configMode ?? t("diagnosticsEmpty");
  const runtimeAlwaysOnState =
    typeof localTunnel?.alwaysOnEnabled === "boolean"
      ? localTunnel.alwaysOnEnabled
        ? t("stateEnabled")
        : t("stateDisabled")
      : t("diagnosticsEmpty");
  const runtimeLockdownState =
    typeof localTunnel?.lockdownEnabled === "boolean"
      ? localTunnel.lockdownEnabled
        ? t("stateEnabled")
        : t("stateDisabled")
      : t("diagnosticsEmpty");
  const runtimeResumeState =
    typeof localTunnel?.resumeEligible === "boolean"
      ? localTunnel.resumeEligible
        ? t("stateEnabled")
        : t("stateDisabled")
      : t("diagnosticsEmpty");
  const runtimeNetworkEvent = localTunnel?.lastNetworkEvent ?? t("diagnosticsEmpty");
  const runtimeStartupDuration =
    typeof localTunnel?.lastStartupDurationMs === "number"
      ? `${localTunnel.lastStartupDurationMs} ms`
      : t("diagnosticsEmpty");
  const runtimeStartupStage = localTunnel?.lastStartupStage ?? t("diagnosticsEmpty");
  const runtimeFailureStage = localTunnel?.lastFailureStage ?? t("diagnosticsEmpty");
  const runtimeFailureCode = localTunnel?.lastFailureCode ?? t("diagnosticsEmpty");
  const runtimeRecoveryCounters = localTunnel
    ? `restore=${localTunnel.restoreCount ?? 0} / reload=${localTunnel.reloadCount ?? 0} / network=${localTunnel.networkChangeCount ?? 0}`
    : t("diagnosticsEmpty");
  const runtimeRecoveryAction = localTunnel?.lastRecoveryAction ?? t("diagnosticsEmpty");
  const realityFeatureSummary =
    localTunnel?.activeFeatures && localTunnel.activeFeatures.length > 0
      ? localTunnel.activeFeatures.join(" / ")
      : t("diagnosticsEmpty");
  const runtimeRelayAutoselectSummaryDisplay = clampDiagnosticText(runtimeRelayAutoselectSummary);
  const runtimeLogDisplay = formatDiagnosticLogTail(runtimeLogTail, t("diagnosticsEmpty"));
  const runtimeLastTestDisplay = clampDiagnosticText(
    localTunnel?.lastTest?.output ?? localTunnel?.lastTest?.error ?? t("diagnosticsEmpty"),
    12,
    1400
  );
  const operatorSummary = [
    coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable"),
    ownerProfile?.exists ? t("profileCacheReady") : t("profileCacheMissing"),
    localTunnel?.status === "running" ? tunnelStatusLabel : primaryStatusBadge,
    deploymentHealthLabel
  ].join(" / ");
  const recoveryHint = !resolvedDraftHost || (!secret.trim() && !hasLocalAccessProfile)
    ? t("recoveryHintValidate")
    : requiresVKLink && !vkLink.trim()
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
  const ownerRuntimeLabPanelVisible = isAndroidClient && ownerRuntimeLabUnlocked;
  const ownerRuntimeLabHintInputsVisible =
    ownerRuntimeLab.mode === "reality-whitelist-scaffold" || ownerRuntimeLab.mode === "reality-whitelist-lab";
  const ownerRuntimeLabVpsInputsVisible = isOwnerRuntimeLabVpsMode(ownerRuntimeLab.mode);
  const ownerRuntimeLabVpsRelayOwnerMode = isOwnerRuntimeLabRelayOwnerMode(ownerRuntimeLab.mode);
  const ownerRuntimeLabVpsManualInputsVisible =
    ownerRuntimeLabVpsInputsVisible &&
    !ownerRuntimeLabVpsRelayOwnerMode &&
    !ownerRuntimeLab.vpsUseRelayAutoselect;
  const ownerRuntimeLabVpsRelayInputsVisible =
    ownerRuntimeLabVpsInputsVisible &&
    (ownerRuntimeLabVpsRelayOwnerMode || ownerRuntimeLab.vpsUseRelayAutoselect);
  const ownerRuntimeLabRequiresOwnerProfile =
    !ownerProfileSupportsDraft(ownerProfile, ownerRuntimeLabRealityDraft) ||
    !hostsMatch(resolvedDraftHost, ownerProfile?.serverHost);
  const ownerRuntimeLabDisabledReason = ownerRuntimeLabRequiresOwnerProfile ? t("ownerLabNeedsOwnerProfile") : null;

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
        if (
          parsed.accessMode === "vless-reality" ||
          parsed.accessMode === "vk-relay" ||
          parsed.accessMode === "relay-via-server" ||
          parsed.accessMode === "relay-direct"
        ) {
          setSelectedAccessMode(parsed.accessMode);
        } else {
          setSelectedAccessMode(draftAccessMode(parsed.draft));
        }
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

    try {
      const savedOwnerRuntimeLab = window.localStorage.getItem(ownerRuntimeLabStorageKey);
      if (savedOwnerRuntimeLab) {
        const parsed = JSON.parse(savedOwnerRuntimeLab) as Partial<OwnerRuntimeLabState>;
        setOwnerRuntimeLab({
          mode:
            parsed.mode === "reality-whitelist-scaffold" ||
            parsed.mode === "reality-whitelist-lab" ||
            parsed.mode === "reality-vps-scaffold" ||
            parsed.mode === "reality-vps-lab" ||
            parsed.mode === "reality-vps-relay-lab"
              ? parsed.mode
              : "off",
          hintServerName: parsed.hintServerName ?? defaultOwnerRuntimeLabState.hintServerName,
          hintCidrBucket: parsed.hintCidrBucket ?? defaultOwnerRuntimeLabState.hintCidrBucket,
          hintSource: parsed.hintSource ?? defaultOwnerRuntimeLabState.hintSource,
          hintTag: parsed.hintTag ?? defaultOwnerRuntimeLabState.hintTag,
          vpsServerName: parsed.vpsServerName ?? defaultOwnerRuntimeLabState.vpsServerName,
          vpsPort: parsed.vpsPort ?? defaultOwnerRuntimeLabState.vpsPort,
          vpsTransport: parsed.vpsTransport === "grpc" ? "grpc" : defaultOwnerRuntimeLabState.vpsTransport,
          vpsFlow: parsed.vpsFlow ?? defaultOwnerRuntimeLabState.vpsFlow,
          vpsFingerprint: parsed.vpsFingerprint ?? defaultOwnerRuntimeLabState.vpsFingerprint,
          vpsGrpcServiceName: parsed.vpsGrpcServiceName ?? defaultOwnerRuntimeLabState.vpsGrpcServiceName,
          vpsGrpcAuthority: parsed.vpsGrpcAuthority ?? defaultOwnerRuntimeLabState.vpsGrpcAuthority,
          vpsSource: parsed.vpsSource ?? defaultOwnerRuntimeLabState.vpsSource,
          vpsTag: parsed.vpsTag ?? defaultOwnerRuntimeLabState.vpsTag,
          vpsUseOwnerRealityEgress:
            typeof parsed.vpsUseOwnerRealityEgress === "boolean"
              ? parsed.vpsUseOwnerRealityEgress
              : defaultOwnerRuntimeLabState.vpsUseOwnerRealityEgress,
          vpsUseRelayAutoselect:
            typeof parsed.vpsUseRelayAutoselect === "boolean"
              ? parsed.vpsUseRelayAutoselect
              : defaultOwnerRuntimeLabState.vpsUseRelayAutoselect,
          vpsRelaySubscriptionUrl:
            parsed.vpsRelaySubscriptionUrl ?? defaultOwnerRuntimeLabState.vpsRelaySubscriptionUrl,
          vpsRelaySourceLabel:
            parsed.vpsRelaySourceLabel ?? defaultOwnerRuntimeLabState.vpsRelaySourceLabel
        });
      }
    } catch {
      window.localStorage.removeItem(ownerRuntimeLabStorageKey);
    }

    if (window.localStorage.getItem(ownerRuntimeLabUnlockStorageKey) === "true") {
      setOwnerRuntimeLabUnlocked(true);
    }

    void fetchCoreHealth();
    void fetchSystemProxyStatus();
    pollLocalTunnel(true);
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || !isAndroidClient) {
      return;
    }
    if (localTunnel?.status !== "running" && localTunnel?.status !== "starting") {
      return;
    }

    const intervalId = window.setInterval(() => {
      void pollLocalTunnel(true);
    }, activeSheet === "logs" ? 4000 : 1500);

    return () => window.clearInterval(intervalId);
  }, [activeSheet, isAndroidClient, localTunnel?.status]);

  useEffect(() => {
    if (!isAndroidClient) {
      return;
    }
    if (!localTunnel || localTunnel.status === "idle" || localTunnel.status === "stopped" || localTunnel.status === "failed") {
      setAndroidVpnVisualOverride(false);
    }
  }, [isAndroidClient, localTunnel]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const snapshot: PersistedState = {
      activeTab,
      activeAccessTab,
      accessMode: selectedAccessMode,
      draft,
      deployPortMode,
      secret,
      vkLink,
      validation,
      importedProfile
    };
    window.localStorage.setItem(storageKey, JSON.stringify(snapshot));
  }, [activeAccessTab, activeTab, deployPortMode, draft, importedProfile, secret, selectedAccessMode, validation, vkLink]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(ownerRuntimeLabStorageKey, JSON.stringify(ownerRuntimeLab));
  }, [ownerRuntimeLab]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    if (ownerRuntimeLabUnlocked) {
      window.localStorage.setItem(ownerRuntimeLabUnlockStorageKey, "true");
    } else {
      window.localStorage.removeItem(ownerRuntimeLabUnlockStorageKey);
    }
  }, [ownerRuntimeLabUnlocked]);

  const handleValidate = () => {
    setError(null);
    startTransition(async () => {
      try {
        const validateRes = await coreApi.validateProvision({
          server: draft,
          secret
        });
        const validateData = validateRes.data;
        setValidation(validateData);
        setShowValidationOverlay(true);

        const planRes = await coreApi.getProvisionPlan({
          server: draft,
          secret
        });
        const planData = planRes.data;
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
        const deployRes = await coreApi.startDeployment({
          server: draft,
          secret
        });
        const deployData = deployRes.data;
        setDeployment(deployData);
        setPlan(deployData.steps);
        setShowDeploymentOverlay(true);

        if (!deployRes.ok) {
          setError(t("deployStartFailed"));
          return;
        }

        const timer = window.setInterval(async () => {
          const statusRes = await coreApi.getDeployment(deployData.deploymentId);
          const statusData = statusRes.data;
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
      const res = await coreApi.getHealth();
      const data = res.data;
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
    const res = await coreApi.getOwnerProfile(host);
    const data = res.data;
    setOwnerProfile(data);
    return data;
  };

  const fetchImportedProfile = async (host: string) => {
    if (!host) {
      return null;
    }
    const res = await coreApi.getImportedProfile(host);
    const data = res.data;
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
    setSelectedAccessMode(draftAccessMode({ ...initialDraft, transport: importedTransport, protocol: importedProtocol }));
    setDraft((current) => ({
      ...current,
      host: profile.serverHost || current.host,
      transport: importedTransport,
      engine: resolveDraftEngine(importedTransport, importedProtocol, current.engine),
      protocol: importedProtocol
    }));
    setSecret("");
  };

  const resolveRuntimeIdentity = (serverDraft: ServerDraft, ownerRuntimeLabRequest?: OwnerRuntimeLabRequest) => {
    const transport = normalizeTransport(serverDraft.transport);
    const protocol =
      transport === "xray" ? normalizeProtocol(serverDraft.protocol) : "direct-wireguard";
    if (transport === "vk-turn-proxy+xray") {
      return { runtimeFamily: "vk-relay", activationState: "active" };
    }
    if (transport === "xray" && protocol === "vless-reality") {
      if (ownerRuntimeLabRequest?.mode === "reality-vps-scaffold") {
        return { runtimeFamily: "reality-vps-lab", activationState: "scaffold_only" };
      }
      if (
        ownerRuntimeLabRequest?.mode === "reality-vps-lab" ||
        ownerRuntimeLabRequest?.mode === "reality-vps-relay-lab"
      ) {
        return { runtimeFamily: "reality-vps-lab", activationState: "active" };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-whitelist-scaffold") {
        return { runtimeFamily: "reality-whitelist-assisted", activationState: "scaffold_only" };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-whitelist-lab") {
        return { runtimeFamily: "reality-whitelist-assisted", activationState: "active" };
      }
      return { runtimeFamily: "direct-reality", activationState: "active" };
    }
    return { runtimeFamily: "", activationState: "" };
  };

  const buildTunnelStartRequest = (
    baseDraft: ServerDraft = draft,
    ownerRuntimeLabMode: OwnerRuntimeLabMode = "off",
    options?: {
      allowImportedProfileForOwnerRuntimeLab?: boolean;
      requireRelaySupport?: boolean;
      forceRelayAutoselectDefaults?: boolean;
    }
  ) => {
    const allowImportedProfileForOwnerRuntimeLab = options?.allowImportedProfileForOwnerRuntimeLab ?? false;
    const requireRelaySupport = options?.requireRelaySupport ?? false;
    const forceRelayAutoselectDefaults = options?.forceRelayAutoselectDefaults ?? false;
    const effectiveOwnerRuntimeLab =
      allowImportedProfileForOwnerRuntimeLab &&
      forceRelayAutoselectDefaults &&
      (ownerRuntimeLabMode === "reality-vps-relay-lab" || ownerRuntimeLabMode === "reality-vps-lab")
        ? withIgareckRelayDefaults(ownerRuntimeLab)
        : ownerRuntimeLab;
    const effectiveBaseDraft: ServerDraft =
      ownerRuntimeLabMode === "off"
        ? baseDraft
        : {
            ...baseDraft,
            transport: "xray",
            engine: "sing-box",
            protocol: "vless-reality"
          };
    const normalizedHost =
      effectiveBaseDraft.host.trim() || importedProfile?.serverHost?.trim() || ownerProfile?.serverHost?.trim() || "";
    const ownerProfileAvailable = Boolean(
      (requireRelaySupport
        ? ownerProfileSupportsRelayMode(ownerProfile, effectiveBaseDraft)
        : ownerProfileSupportsDraft(ownerProfile, effectiveBaseDraft)) &&
        hostsMatch(normalizedHost, ownerProfile?.serverHost)
    );
    const importedProfileAvailable = Boolean(
      importedProfileMatchesHost(importedProfile, normalizedHost) &&
        (requireRelaySupport
          ? importedProfileSupportsRelayMode(importedProfile, effectiveBaseDraft)
          : importedProfileSupportsDraft(importedProfile, effectiveBaseDraft))
    );
    const usingImportedProfile = Boolean(
      ((ownerRuntimeLabMode === "off" || allowImportedProfileForOwnerRuntimeLab) &&
        importedProfileAvailable &&
        !secret.trim() &&
        !ownerProfileAvailable)
    );
    const serverDraft: ServerDraft =
      usingImportedProfile && importedProfile
        ? {
            ...effectiveBaseDraft,
            host: importedProfile.serverHost || normalizedHost || baseDraft.host,
            engine: resolveDraftEngine(effectiveBaseDraft.transport, effectiveBaseDraft.protocol, effectiveBaseDraft.engine)
          }
        : {
            ...effectiveBaseDraft,
            host: normalizedHost || baseDraft.host
          };
    const useRealityStartEndpoint =
      !usingImportedProfile &&
      serverDraft.transport === "xray" &&
      (serverDraft.protocol ?? "vless-reality") === "vless-reality";
    let ownerRuntimeLabRequest: OwnerRuntimeLabRequest | undefined;
    if (
      ownerRuntimeLabMode === "reality-whitelist-scaffold" ||
      ownerRuntimeLabMode === "reality-whitelist-lab" ||
      ownerRuntimeLabMode === "reality-vps-scaffold" ||
      ownerRuntimeLabMode === "reality-vps-lab" ||
      ownerRuntimeLabMode === "reality-vps-relay-lab"
    ) {
      if (!isAndroidClient) {
        throw new Error(t("ownerLabAndroidOnly"));
      }
      if (!ownerProfileAvailable && !usingImportedProfile) {
        throw new Error(
          allowImportedProfileForOwnerRuntimeLab ? t("ownerLabNeedsAccessProfile") : t("ownerLabNeedsOwnerProfile")
        );
      }
      if (isOwnerRuntimeLabVpsMode(ownerRuntimeLabMode)) {
        const usingRelayOwnerMode = isOwnerRuntimeLabRelayOwnerMode(ownerRuntimeLabMode);
        const usingRelayAutoselect = usingRelayOwnerMode || effectiveOwnerRuntimeLab.vpsUseRelayAutoselect;
        const vpsServerName = (
          effectiveOwnerRuntimeLab.vpsServerName.trim().toLowerCase() ||
          (usingRelayAutoselect ? "id.x5.ru" : "")
        );
        if (!vpsServerName) {
          throw new Error(t("ownerLabVpsServerRequired"));
        }
        const parsedVpsPort = Number.parseInt(effectiveOwnerRuntimeLab.vpsPort, 10);
        const vpsPort =
          Number.isInteger(parsedVpsPort) && parsedVpsPort > 0 && parsedVpsPort <= 65535
            ? parsedVpsPort
            : usingRelayAutoselect
              ? 443
              : Number.NaN;
        if (!Number.isInteger(vpsPort) || vpsPort <= 0 || vpsPort > 65535) {
          throw new Error(t("ownerLabVpsPortRequired"));
        }
        ownerRuntimeLabRequest = {
          mode: ownerRuntimeLabMode,
          hintServerName: "",
          vpsServerName,
          vpsPort,
          vpsTransport: usingRelayAutoselect ? "tcp" : effectiveOwnerRuntimeLab.vpsTransport,
          ...((effectiveOwnerRuntimeLab.vpsFlow.trim() || usingRelayAutoselect)
            ? { vpsFlow: effectiveOwnerRuntimeLab.vpsFlow.trim() || "xtls-rprx-vision" }
            : {}),
          ...((effectiveOwnerRuntimeLab.vpsFingerprint.trim() || usingRelayAutoselect)
            ? { vpsFingerprint: effectiveOwnerRuntimeLab.vpsFingerprint.trim() || "chrome" }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsGrpcServiceName.trim()
            ? { vpsGrpcServiceName: effectiveOwnerRuntimeLab.vpsGrpcServiceName.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsGrpcAuthority.trim()
            ? { vpsGrpcAuthority: effectiveOwnerRuntimeLab.vpsGrpcAuthority.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsSource.trim() ? { vpsSource: effectiveOwnerRuntimeLab.vpsSource.trim() } : {}),
          ...(effectiveOwnerRuntimeLab.vpsTag.trim() ? { vpsTag: effectiveOwnerRuntimeLab.vpsTag.trim() } : {}),
          ...(usingRelayOwnerMode ? { vpsOwnerRealityEgress: true } : {}),
          ...(usingRelayAutoselect
            ? {
                vpsRelayAutoselect: {
                  enabled: true,
                  ...(effectiveOwnerRuntimeLab.vpsRelaySubscriptionUrl.trim()
                    ? { subscriptionUrl: effectiveOwnerRuntimeLab.vpsRelaySubscriptionUrl.trim() }
                    : {}),
                  ...(effectiveOwnerRuntimeLab.vpsRelaySourceLabel.trim()
                    ? { sourceLabel: effectiveOwnerRuntimeLab.vpsRelaySourceLabel.trim() }
                    : {})
                }
              }
            : {})
        };
      } else {
        const hintServerName = effectiveOwnerRuntimeLab.hintServerName.trim().toLowerCase();
        if (!hintServerName) {
          throw new Error(t("ownerLabHintServerRequired"));
        }
        ownerRuntimeLabRequest = {
          mode: ownerRuntimeLabMode,
          hintServerName,
          ...(effectiveOwnerRuntimeLab.hintCidrBucket.trim()
            ? { hintCidrBucket: effectiveOwnerRuntimeLab.hintCidrBucket.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.hintSource.trim() ? { hintSource: effectiveOwnerRuntimeLab.hintSource.trim() } : {}),
          ...(effectiveOwnerRuntimeLab.hintTag.trim() ? { hintTag: effectiveOwnerRuntimeLab.hintTag.trim() } : {})
        };
      }
    }
    return { serverDraft, useRealityStartEndpoint, usingImportedProfile, ownerRuntimeLabRequest };
  };

  const buildCurrentTunnelStartRequest = (baseDraft: ServerDraft = draft) => {
    if (selectedAccessMode === "relay-via-server") {
      return buildTunnelStartRequest(baseDraft, "reality-vps-relay-lab", {
        allowImportedProfileForOwnerRuntimeLab: true,
        requireRelaySupport: true,
        forceRelayAutoselectDefaults: true
      });
    }
    if (selectedAccessMode === "relay-direct") {
      return buildTunnelStartRequest(baseDraft, "reality-vps-lab", {
        allowImportedProfileForOwnerRuntimeLab: true,
        forceRelayAutoselectDefaults: true
      });
    }
    return buildTunnelStartRequest(baseDraft);
  };

  const runningTunnelMatchesRequest = (
    tunnel: LocalTunnelState | null,
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest
  ) => {
    if (!tunnel || tunnel.status !== "running" || !tunnel.socksAddress) {
      return false;
    }
    const expectedHost = serverDraft.host?.trim();
    const expectedTransport = normalizeTransport(serverDraft.transport);
    const expectedProtocol = normalizeProtocol(serverDraft.protocol);
    const expectedRuntimeIdentity = resolveRuntimeIdentity(serverDraft, ownerRuntimeLabRequest);
    if (expectedHost && tunnel.serverHost && tunnel.serverHost !== expectedHost) {
      return false;
    }
    if (tunnel.transport !== expectedTransport || normalizeProtocol(tunnel.protocol) !== expectedProtocol) {
      return false;
    }
    if (expectedRuntimeIdentity.runtimeFamily && tunnel.runtimeFamily && tunnel.runtimeFamily !== expectedRuntimeIdentity.runtimeFamily) {
      return false;
    }
    if (
      expectedRuntimeIdentity.activationState &&
      tunnel.activationState &&
      tunnel.activationState !== expectedRuntimeIdentity.activationState
    ) {
      return false;
    }
    return true;
  };

  const pollLocalTunnel = (immediate = false) => {
    const run = async () => {
      try {
        const [tunnelRes, proxyRes] = await Promise.all([
          coreApi.getLocalTunnelStatus(),
          coreApi.getSystemProxyStatus()
        ]);
        const tunnelData = tunnelRes.data;
        const proxyData = proxyRes.data;
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

  const waitForRunningTunnel = async (attempts = 18, delayMs = 1000) => {
    let tunnelData = await pollLocalTunnel(true);
    if (tunnelData?.status === "running" && tunnelData.socksAddress) {
      return tunnelData;
    }
    if (tunnelData && (tunnelData.status === "failed" || tunnelData.status === "stopped")) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (tunnelData?.status === "running" && tunnelData.socksAddress) {
        return tunnelData;
      }
      if (tunnelData && (tunnelData.status === "failed" || tunnelData.status === "stopped")) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const waitForStoppedTunnel = async (attempts = 20, delayMs = 300) => {
    let tunnelData = await pollLocalTunnel(true);
    if (!tunnelData || tunnelData.status === "stopped" || tunnelData.status === "idle" || tunnelData.status === "failed") {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (!tunnelData || tunnelData.status === "stopped" || tunnelData.status === "idle" || tunnelData.status === "failed") {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const waitForTunnelIdentity = async (
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest,
    attempts = 18,
    delayMs = 700
  ) => {
    const expectedRuntimeIdentity = resolveRuntimeIdentity(serverDraft, ownerRuntimeLabRequest);
    let tunnelData = await pollLocalTunnel(true);
    if (runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)) {
      return tunnelData;
    }
    if (
      tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
      tunnelData.activationState === expectedRuntimeIdentity.activationState
    ) {
      return tunnelData;
    }
    if (tunnelData && (tunnelData.status === "failed" || tunnelData.status === "stopped")) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)) {
        return tunnelData;
      }
      if (
        tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
        tunnelData.activationState === expectedRuntimeIdentity.activationState
      ) {
        return tunnelData;
      }
      if (tunnelData && (tunnelData.status === "failed" || tunnelData.status === "stopped")) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const unlockOwnerRuntimeLab = () => {
    if (!isAndroidClient || ownerRuntimeLabUnlocked) {
      return;
    }
    setOwnerRuntimeLabUnlockTapCount((current) => {
      const next = current + 1;
      if (next >= ownerRuntimeLabUnlockTapTarget) {
        setOwnerRuntimeLabUnlocked(true);
        setSuccessNotice(t("ownerLabUnlocked"));
        return 0;
      }
      return next;
    });
  };

  const handleStartOwnerRuntimeLab = () => {
    setError(null);
    setPendingAction("startOwnerRuntimeLab");
    startTransition(async () => {
      try {
        const { serverDraft, useRealityStartEndpoint, usingImportedProfile, ownerRuntimeLabRequest } = buildTunnelStartRequest(
          draft,
          ownerRuntimeLab.mode
        );
        let tunnelData = localTunnel;
        if (
          tunnelData &&
          (tunnelData.status === "running" || tunnelData.status === "starting") &&
          !runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          tunnelData = await waitForStoppedTunnel();
          setLocalTunnel(tunnelData ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }

        if (!runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)) {
          const startApi =
            isAndroidClient && ownerRuntimeLabRequest ? coreApi.startLocalTunnelFast : coreApi.startLocalTunnel;
          const startRes = await startApi(
            {
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
              vkLink,
              ...(ownerRuntimeLabRequest ? { ownerRuntimeLab: ownerRuntimeLabRequest } : {})
            },
            useRealityStartEndpoint
          );
          tunnelData = startRes.data;
          setLocalTunnel(tunnelData);
          if (!startRes.ok) {
            setError(tunnelData.error ?? t("tunnelStartFailed"));
            return;
          }
        }

        if (isAndroidClient && ownerRuntimeLabRequest) {
          void fetchSystemProxyStatus();
          void pollLocalTunnel();
          setSuccessNotice(t("ownerLabStartRequested"));
          return;
        }

        tunnelData = await waitForTunnelIdentity(serverDraft, ownerRuntimeLabRequest);
        setLocalTunnel(tunnelData ?? localTunnel);

        if (ownerRuntimeLabRequest) {
          const whitelistRuntimeReady =
            tunnelData?.runtimeFamily === "reality-whitelist-assisted" &&
            ((ownerRuntimeLabRequest.mode === "reality-whitelist-scaffold" && tunnelData.activationState === "scaffold_only") ||
              (ownerRuntimeLabRequest.mode === "reality-whitelist-lab" &&
                tunnelData.activationState === "active" &&
                tunnelData.status === "running" &&
                Boolean(tunnelData.socksAddress)));
          const vpsRuntimeReady =
            tunnelData?.runtimeFamily === "reality-vps-lab" &&
            ((ownerRuntimeLabRequest.mode === "reality-vps-scaffold" && tunnelData.activationState === "scaffold_only") ||
              ((ownerRuntimeLabRequest.mode === "reality-vps-lab" ||
                ownerRuntimeLabRequest.mode === "reality-vps-relay-lab") &&
                tunnelData.activationState === "active" &&
                tunnelData.status === "running" &&
                Boolean(tunnelData.socksAddress)));
          if (whitelistRuntimeReady || vpsRuntimeReady) {
            setSuccessNotice(
              ownerRuntimeLabRequest.mode === "reality-whitelist-lab"
                ? t("ownerLabWhitelistLabReady")
                : ownerRuntimeLabRequest.mode === "reality-vps-relay-lab"
                  ? t("ownerLabVpsRelayLabReady")
                : ownerRuntimeLabRequest.mode === "reality-vps-lab"
                  ? t("ownerLabVpsLabReady")
                  : ownerRuntimeLabRequest.mode === "reality-vps-scaffold"
                    ? t("ownerLabVpsScaffoldReady")
                    : t("ownerLabWhitelistReady")
            );
            return;
          }
          setError(
            tunnelData?.error ??
              (ownerRuntimeLabRequest.mode === "reality-whitelist-lab"
                ? t("ownerLabWhitelistLabFailed")
                : ownerRuntimeLabRequest.mode === "reality-vps-relay-lab"
                  ? t("ownerLabVpsRelayLabFailed")
                : ownerRuntimeLabRequest.mode === "reality-vps-lab"
                  ? t("ownerLabVpsLabFailed")
                  : ownerRuntimeLabRequest.mode === "reality-vps-scaffold"
                    ? t("ownerLabVpsScaffoldFailed")
                    : t("ownerLabWhitelistFailed"))
          );
          return;
        }

        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          setSuccessNotice(t("ownerLabControlReady"));
          return;
        }

        setError(tunnelData?.error ?? t("tunnelStartFailed"));
      } catch (requestError) {
        const message = requestError instanceof Error ? requestError.message : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const runCurrentTunnelTest = async () => {
    const res = await coreApi.runLocalTunnelTest("https://example.com");
    const data = res.data;
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
    const res = await coreApi.getSystemProxyStatus();
    const data = res.data;
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
      const res = await coreApi.enableSystemProxy({
        socksAddress: socksAddress ?? ""
      });
      const data = res.data;
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
      await coreApi.disableSystemProxy();
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

  const handleAccessModeChange = (mode: AccessMode) => {
    setSelectedAccessMode(mode);
    setDraft((current) => {
      if (draftAccessMode(current) === mode) {
        return current;
      }
      return applyAccessModeToDraft(current, mode);
    });
  };

  const renderAccessModeToggle = (className?: string) => (
    <div className={["lang-toggle", className].filter(Boolean).join(" ")} aria-label={t("runtimeMode")}>
      <button
        className={selectedAccessMode === "vless-reality" ? "lang-button is-active" : "lang-button"}
        type="button"
        aria-pressed={selectedAccessMode === "vless-reality"}
        title={t("runtimeModeRealityHint")}
        onClick={() => handleAccessModeChange("vless-reality")}
      >
        {t("runtimeModeReality")}
      </button>
      <button
        className={selectedAccessMode === "vk-relay" ? "lang-button is-active" : "lang-button"}
        type="button"
        aria-pressed={selectedAccessMode === "vk-relay"}
        title={t("runtimeModeVkHint")}
        onClick={() => handleAccessModeChange("vk-relay")}
      >
        {t("runtimeModeVk")}
      </button>
      {isAndroidClient ? (
        <button
          className={selectedAccessMode === "relay-via-server" ? "lang-button is-active" : "lang-button"}
          type="button"
          aria-pressed={selectedAccessMode === "relay-via-server"}
          title={t("runtimeModeRelayOwnerHint")}
          onClick={() => handleAccessModeChange("relay-via-server")}
        >
          {t("runtimeModeRelayOwner")}
        </button>
      ) : null}
      {isAndroidClient ? (
        <button
          className={selectedAccessMode === "relay-direct" ? "lang-button is-active" : "lang-button"}
          type="button"
          aria-pressed={selectedAccessMode === "relay-direct"}
          title={t("runtimeModeRelayDirectHint")}
          onClick={() => handleAccessModeChange("relay-direct")}
        >
          {t("runtimeModeRelayDirect")}
        </button>
      ) : null}
    </div>
  );

  const handleStartTunnel = () => {
    setError(null);
    setPendingAction("startTunnel");
    startTransition(async () => {
      try {
        const { serverDraft, useRealityStartEndpoint, usingImportedProfile, ownerRuntimeLabRequest } =
          buildCurrentTunnelStartRequest();
        if (
          isAndroidClient &&
          localTunnel &&
          (localTunnel.status === "running" || localTunnel.status === "starting") &&
          !runningTunnelMatchesRequest(localTunnel, serverDraft, ownerRuntimeLabRequest)
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }
        const startApi =
          isAndroidClient && ownerRuntimeLabRequest ? coreApi.startLocalTunnelFast : coreApi.startLocalTunnel;
        const res = await startApi(
          {
            server: serverDraft,
            secret: usingImportedProfile ? "" : secret,
            vkLink,
            ...(ownerRuntimeLabRequest ? { ownerRuntimeLab: ownerRuntimeLabRequest } : {})
          },
          useRealityStartEndpoint
        );
        const data = res.data;
        setLocalTunnel(data);
        void fetchSystemProxyStatus();
        if (!res.ok) {
          setError(data.error ?? t("tunnelStartFailed"));
          return;
        }
        if (isAndroidClient && ownerRuntimeLabRequest) {
          void pollLocalTunnel();
          return;
        }
        const tunnelData = await waitForRunningTunnel();
        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          if (isAndroidClient) {
            setAndroidVpnVisualOverride(true);
            void fetchSystemProxyStatus();
            return;
          }
          const testedTunnel = await prepareTunnelForSystemProxy();
          await enableSystemProxyForTunnel(testedTunnel.socksAddress);
          return;
        }
        setError(tunnelData?.error ?? t("tunnelStartFailed"));
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
        const res = await coreApi.stopLocalTunnel();
        const data = res.data;
        setLocalTunnel(data);
        if (isAndroidClient) {
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? data);
          setAndroidVpnVisualOverride(false);
          return;
        }
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
        const { serverDraft, useRealityStartEndpoint, usingImportedProfile, ownerRuntimeLabRequest } =
          buildCurrentTunnelStartRequest();
        let tunnelData = localTunnel;
        if (
          isAndroidClient &&
          tunnelData &&
          (tunnelData.status === "running" || tunnelData.status === "starting") &&
          !runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          tunnelData = await waitForStoppedTunnel();
          setLocalTunnel(tunnelData ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }
        if (!runningTunnelMatchesRequest(tunnelData, serverDraft, ownerRuntimeLabRequest)) {
          const startApi =
            isAndroidClient && ownerRuntimeLabRequest ? coreApi.startLocalTunnelFast : coreApi.startLocalTunnel;
          const startRes = await startApi(
            {
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
              vkLink,
              ...(ownerRuntimeLabRequest ? { ownerRuntimeLab: ownerRuntimeLabRequest } : {})
            },
            useRealityStartEndpoint
          );
          tunnelData = startRes.data;
          setLocalTunnel(tunnelData);
          if (!startRes.ok) {
            setError(tunnelData.error ?? t("tunnelStartFailed"));
            return;
          }

          if (isAndroidClient && ownerRuntimeLabRequest) {
            void fetchSystemProxyStatus();
            void pollLocalTunnel();
            return;
          }

          tunnelData = await waitForRunningTunnel(18, 1000);
        }

        if (!tunnelData || tunnelData.status !== "running" || !tunnelData.socksAddress) {
          if (isAndroidClient) {
            setAndroidVpnVisualOverride(false);
          }
          setError(
            tunnelData?.error ??
              (tunnelData?.status === "starting"
                ? "Android local tunnel is still starting. Check the runtime log and try again in a few seconds."
                : t("tunnelStartFailed"))
          );
          return;
        }

        if (isAndroidClient) {
          setAndroidVpnVisualOverride(true);
          void fetchSystemProxyStatus();
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
        if (isAndroidClient) {
          const stopRes = await coreApi.stopLocalTunnel();
          const stopData = stopRes.data;
          setLocalTunnel(stopData);
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? stopData);
          setAndroidVpnVisualOverride(false);
          return;
        }

        const proxyRes = await coreApi.disableSystemProxy();
        const proxyData = proxyRes.data;
        const verifiedProxy = await verifySystemProxy();
        setSystemProxy(verifiedProxy);
        if (!proxyRes.ok) {
          setError(proxyData.error ?? t("unknownError"));
          return;
        }

        const stopRes = await coreApi.stopLocalTunnel();
        const stopData = stopRes.data;
        setLocalTunnel(stopData);
        if (isAndroidClient && (stopData.status === "stopped" || stopData.status === "idle" || stopData.status === "failed")) {
          setAndroidVpnVisualOverride(false);
        }
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
        const res = await coreApi.disableSystemProxy();
        const data = res.data;
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
        const res = await coreApi.generateGuestProfile({
          server: draft,
          secret,
          host: draft.host,
          name: ownerProfile?.name ?? "Odin One Access Key"
        });
        const data = res.data;
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
        const res = await coreApi.importProfile({
          shareCode: importShareCode
        });
        const data = res.data;
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
    setSelectedAccessMode("vless-reality");
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
                  <span className={`phone-pill ${vpnVisualActive ? "phone-pill--ok" : ""}`}>{primaryStatusBadge}</span>
                  {renderAccessModeToggle("home-mode-toggle")}
                </div>

                <div className="phone-copy">
                  <h2 className="phone-title">{primaryStatusText}</h2>
                  <p className="phone-subtitle">{currentHost}</p>
                </div>

                <button
                  className={`phone-connect ${vpnVisualActive ? "phone-connect--active" : ""} ${
                    relayOwnerConnectAnimation ? "phone-connect--connecting" : ""
                  }`}
                  type="button"
                  onClick={vpnActionActive ? handleDisableVPN : handleEnableVPN}
                  disabled={
                    vpnActionActive
                      ? isBusy("disableVpn")
                      : isPending ||
                        !resolvedDraftHost ||
                        (selectedAccessMode === "relay-via-server"
                          ? !hasLocalAccessProfileForSelectedMode
                          : !secret.trim() && !hasLocalAccessProfileForSelectedMode) ||
                        (requiresVKLink && (!vkLink.trim() || cooldownMinutes > 0))
                  }
                >
                  <span className="phone-connect__label">{vpnButtonLabel}</span>
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
                  {renderAccessModeToggle()}
                </div>
                <p className="compact-note">
                  {selectedAccessModeHint}
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
                disabled={
                  isPending ||
                  !resolvedDraftHost ||
                  (!secret.trim() && !hasLocalAccessProfile) ||
                  (requiresVKLink && !vkLink.trim()) ||
                  (requiresVKLink && cooldownMinutes > 0)
                }
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
                <h3
                  className="sheet-panel__title"
                  onClick={unlockOwnerRuntimeLab}
                  title={
                    ownerRuntimeLabUnlocked
                      ? t("ownerLabTitle")
                      : `${ownerRuntimeLabUnlockTapCount}/${ownerRuntimeLabUnlockTapTarget}`
                  }
                >
                  {t("sheetLogsTitle")}
                </h3>
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

              {ownerRuntimeLabPanelVisible ? (
                <div className="command-card">
                  <strong>{t("ownerLabTitle")}</strong>
                  <p className="compact-note compact-note--panel">{t("ownerLabText")}</p>

                  <div className="owner-lab-mode-stack" aria-label={t("ownerLabMode")}>
                    <button
                      className={ownerRuntimeLab.mode === "off" ? "lang-button owner-lab-mode-button is-active" : "lang-button owner-lab-mode-button"}
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "off"}
                      onClick={() => setOwnerRuntimeLab((current) => ({ ...current, mode: "off" }))}
                    >
                      {t("ownerLabModeStable")}
                    </button>
                    <button
                      className={
                        ownerRuntimeLab.mode === "reality-whitelist-scaffold"
                          ? "lang-button owner-lab-mode-button is-active"
                          : "lang-button owner-lab-mode-button"
                      }
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "reality-whitelist-scaffold"}
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({ ...current, mode: "reality-whitelist-scaffold" }))
                      }
                    >
                      {t("ownerLabModeWhitelist")}
                    </button>
                    <button
                      className={
                        ownerRuntimeLab.mode === "reality-vps-scaffold"
                          ? "lang-button owner-lab-mode-button is-active"
                          : "lang-button owner-lab-mode-button"
                      }
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "reality-vps-scaffold"}
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...current,
                          mode: "reality-vps-scaffold",
                          vpsUseOwnerRealityEgress: false
                        }))
                      }
                    >
                      {t("ownerLabModeVpsScaffold")}
                    </button>
                    <button
                      className={
                        ownerRuntimeLab.mode === "reality-vps-lab"
                          ? "lang-button owner-lab-mode-button is-active"
                          : "lang-button owner-lab-mode-button"
                      }
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "reality-vps-lab"}
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...current,
                          mode: "reality-vps-lab",
                          vpsUseOwnerRealityEgress: false
                        }))
                      }
                    >
                      {t("ownerLabModeVpsLab")}
                    </button>
                    <button
                      className={
                        ownerRuntimeLab.mode === "reality-vps-relay-lab"
                          ? "lang-button owner-lab-mode-button is-active"
                          : "lang-button owner-lab-mode-button"
                      }
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "reality-vps-relay-lab"}
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...withIgareckRelayDefaults(current),
                          mode: "reality-vps-relay-lab",
                          vpsUseOwnerRealityEgress: true,
                          vpsUseRelayAutoselect: true
                        }))
                      }
                    >
                      {t("ownerLabModeVpsRelayLab")}
                    </button>
                  </div>

                  {ownerRuntimeLabHintInputsVisible ? (
                    <>
                      <label className="input-field input-span">
                        <span>{t("ownerLabHintServerName")}</span>
                        <input
                          value={ownerRuntimeLab.hintServerName}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, hintServerName: event.target.value }))
                          }
                          placeholder="max.ru"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintCidrBucket")}</span>
                        <input
                          value={ownerRuntimeLab.hintCidrBucket}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, hintCidrBucket: event.target.value }))
                          }
                          placeholder="cidr-max"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintSource")}</span>
                        <input
                          value={ownerRuntimeLab.hintSource}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, hintSource: event.target.value }))
                          }
                          placeholder="operator-curated"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintTag")}</span>
                        <input
                          value={ownerRuntimeLab.hintTag}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, hintTag: event.target.value }))
                          }
                          placeholder="candidate-max-ru"
                        />
                      </label>
                    </>
                  ) : null}

                  {ownerRuntimeLabVpsInputsVisible ? (
                    <>
                      {!ownerRuntimeLabVpsRelayOwnerMode ? (
                        <label className="input-field input-span">
                          <span>{t("ownerLabVpsRelayMode")}</span>
                          <div className="lang-toggle">
                            <button
                              className={!ownerRuntimeLab.vpsUseRelayAutoselect ? "lang-button is-active" : "lang-button"}
                              type="button"
                              aria-pressed={!ownerRuntimeLab.vpsUseRelayAutoselect}
                              onClick={() =>
                                setOwnerRuntimeLab((current) => ({ ...current, vpsUseRelayAutoselect: false }))
                              }
                            >
                              {t("ownerLabVpsManualRelay")}
                            </button>
                            <button
                              className={ownerRuntimeLab.vpsUseRelayAutoselect ? "lang-button is-active" : "lang-button"}
                              type="button"
                              aria-pressed={ownerRuntimeLab.vpsUseRelayAutoselect}
                              onClick={() => setOwnerRuntimeLab((current) => withIgareckRelayDefaults(current))}
                            >
                              {t("ownerLabVpsIgareckRelay")}
                            </button>
                          </div>
                        </label>
                      ) : (
                        <p className="compact-note compact-note--panel">{t("ownerLabVpsRelayLockedText")}</p>
                      )}

                      {ownerRuntimeLabVpsRelayInputsVisible ? (
                        <>
                          <p className="compact-note compact-note--panel">{t("ownerLabVpsRelayText")}</p>

                          {ownerRuntimeLabVpsRelayOwnerMode ? (
                            <p className="compact-note compact-note--panel">{t("ownerLabVpsRelayOwnerText")}</p>
                          ) : null}

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsRelaySubscriptionUrl")}</span>
                            <input
                              value={ownerRuntimeLab.vpsRelaySubscriptionUrl}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsRelaySubscriptionUrl: event.target.value
                                }))
                              }
                              placeholder={defaultOwnerRuntimeLabRelaySubscriptionUrl}
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsRelaySourceLabel")}</span>
                            <input
                              value={ownerRuntimeLab.vpsRelaySourceLabel}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsRelaySourceLabel: event.target.value
                                }))
                              }
                              placeholder={defaultOwnerRuntimeLabRelaySourceLabel}
                            />
                          </label>
                        </>
                      ) : null}

                      {ownerRuntimeLabVpsManualInputsVisible ? (
                        <>
                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsServerName")}</span>
                        <input
                          value={ownerRuntimeLab.vpsServerName}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsServerName: event.target.value }))
                          }
                          placeholder="pimg.mycdn.me"
                        />
                      </label>

                      <label className="input-field">
                        <span>{t("ownerLabVpsPort")}</span>
                        <input
                          value={ownerRuntimeLab.vpsPort}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsPort: event.target.value }))
                          }
                          placeholder="10443"
                          inputMode="numeric"
                        />
                      </label>

                      <label className="input-field">
                        <span>{t("ownerLabVpsTransport")}</span>
                        <div className="lang-toggle">
                          <button
                            className={ownerRuntimeLab.vpsTransport === "tcp" ? "lang-button is-active" : "lang-button"}
                            type="button"
                            aria-pressed={ownerRuntimeLab.vpsTransport === "tcp"}
                            onClick={() => setOwnerRuntimeLab((current) => ({ ...current, vpsTransport: "tcp" }))}
                          >
                            TCP
                          </button>
                          <button
                            className={ownerRuntimeLab.vpsTransport === "grpc" ? "lang-button is-active" : "lang-button"}
                            type="button"
                            aria-pressed={ownerRuntimeLab.vpsTransport === "grpc"}
                            onClick={() => setOwnerRuntimeLab((current) => ({ ...current, vpsTransport: "grpc" }))}
                          >
                            gRPC
                          </button>
                        </div>
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsFlow")}</span>
                        <input
                          value={ownerRuntimeLab.vpsFlow}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsFlow: event.target.value }))
                          }
                          placeholder="xtls-rprx-vision"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsFingerprint")}</span>
                        <input
                          value={ownerRuntimeLab.vpsFingerprint}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsFingerprint: event.target.value }))
                          }
                          placeholder={ownerRuntimeLab.vpsTransport === "grpc" ? "firefox" : "chrome"}
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsGrpcServiceName")}</span>
                        <input
                          value={ownerRuntimeLab.vpsGrpcServiceName}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsGrpcServiceName: event.target.value }))
                          }
                          placeholder="grpc serviceName"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsGrpcAuthority")}</span>
                        <input
                          value={ownerRuntimeLab.vpsGrpcAuthority}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsGrpcAuthority: event.target.value }))
                          }
                          placeholder="grpc authority"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsSource")}</span>
                        <input
                          value={ownerRuntimeLab.vpsSource}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsSource: event.target.value }))
                          }
                          placeholder="operator-curated:vps-lab"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabVpsTag")}</span>
                        <input
                          value={ownerRuntimeLab.vpsTag}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({ ...current, vpsTag: event.target.value }))
                          }
                          placeholder="reality-lab-pimg-mycdn-me-tcp"
                        />
                      </label>
                        </>
                      ) : null}
                    </>
                  ) : null}

                  {ownerRuntimeLabDisabledReason ? (
                    <p className="compact-note compact-note--panel">{ownerRuntimeLabDisabledReason}</p>
                  ) : null}

                  <div className="sheet-actions">
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleStartOwnerRuntimeLab}
                      disabled={isPending || Boolean(ownerRuntimeLabDisabledReason)}
                    >
                      {isBusy("startOwnerRuntimeLab") ? t("startingTunnel") : t("ownerLabStart")}
                    </button>
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleStopTunnel}
                      disabled={isPending || (!localTunnel || localTunnel.status === "idle" || localTunnel.status === "stopped")}
                    >
                      {isBusy("stopTunnel") ? t("stoppingTunnel") : t("stopTunnel")}
                    </button>
                  </div>
                </div>
              ) : null}

              <div className="command-card command-card--compact">
                <strong>{t("runtimeStartSource")}</strong>
                <textarea readOnly value={runtimeStartSource} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeFamily")}</strong>
                <textarea readOnly value={runtimeFamily} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeActivationState")}</strong>
                <textarea readOnly value={runtimeActivationState} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeFrontHost")}</strong>
                <textarea readOnly value={runtimeFrontHost} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeFrontPath")}</strong>
                <textarea readOnly value={runtimeFrontPath} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeFrontProvider")}</strong>
                <textarea readOnly value={runtimeFrontProvider} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeFrontTag")}</strong>
                <textarea readOnly value={runtimeFrontTag} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeRelayAutoselect")}</strong>
                <pre className="command-card__output">{runtimeRelayAutoselectSummaryDisplay}</pre>
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeSelectedSniHint")}</strong>
                <textarea readOnly value={runtimeSelectedSniHint} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeSelectedCidrHint")}</strong>
                <textarea readOnly value={runtimeSelectedCidrHint} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeWhitelistHintSource")}</strong>
                <textarea readOnly value={runtimeWhitelistHintSource} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeWhitelistHintTag")}</strong>
                <textarea readOnly value={runtimeWhitelistHintTag} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("realityConfigMode")}</strong>
                <textarea readOnly value={realityConfigMode} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("realityFeatures")}</strong>
                <textarea readOnly value={realityFeatureSummary} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("alwaysOnMode")}</strong>
                <textarea readOnly value={runtimeAlwaysOnState} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lockdownMode")}</strong>
                <textarea readOnly value={runtimeLockdownState} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("resumeEligibility")}</strong>
                <textarea readOnly value={runtimeResumeState} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lastNetworkEvent")}</strong>
                <textarea readOnly value={runtimeNetworkEvent} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("startupDuration")}</strong>
                <textarea readOnly value={runtimeStartupDuration} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("startupStage")}</strong>
                <textarea readOnly value={runtimeStartupStage} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("failureStage")}</strong>
                <textarea readOnly value={runtimeFailureStage} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("failureCode")}</strong>
                <textarea readOnly value={runtimeFailureCode} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("recoveryCounters")}</strong>
                <textarea readOnly value={runtimeRecoveryCounters} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lastRecoveryAction")}</strong>
                <textarea readOnly value={runtimeRecoveryAction} />
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("runtimeLog")}</strong>
                <pre className="command-card__output command-card__output--long">{runtimeLogDisplay}</pre>
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lastTest")}</strong>
                <p className="compact-note">
                  {localTunnel?.lastTest?.url ?? "https://example.com"}
                  {localTunnel?.lastTest?.checkedAt ? ` / ${localTunnel.lastTest.checkedAt}` : ""}
                </p>
                <pre className="command-card__output">{runtimeLastTestDisplay}</pre>
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
