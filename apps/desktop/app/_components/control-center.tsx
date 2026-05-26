"use client";

import {
  useEffect,
  useEffectEvent,
  useRef,
  useState,
  useTransition,
  type ChangeEvent,
} from "react";
import type {
  AuthMethod,
  DeploymentState,
  DeployStage,
  EdgeAttachDraft,
  EdgeRoutingMode,
  InstalledAppInfo,
  InviteProfile,
  LocalTunnelState,
  MobileNetworkEndpoint,
  MobileNetworkLensResult,
  OwnerRuntimeLabRequest,
  OwnerAccessProfile,
  ProtocolPackEntry,
  ProvisionFlow,
  ServerDraft,
  SplitTunnelSelection,
  SystemProxyState,
  ValidationResponse,
  WhitelistLookupResult,
} from "@whitelist/contracts";
import { StageList } from "@whitelist/ui/StageList";
import {
  coreApi,
  type CoreHealthState,
  type TunnelSpeedTestResult,
} from "../_core/core-api";
import { useI18n } from "./i18n";

const initialDraft: ServerDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  transport: "xray",
  engine: "sing-box",
  protocol: "vless-reality",
};

type WorkspaceTab = "server" | "access" | "tunnel";
type AccessTab = "key";
type MobileSheet =
  | "server"
  | "apps"
  | "mode-picker"
  | "speedtest"
  | "whitelist"
  | "logs"
  | "more"
  | null;
type AccessMode =
  | "vless-reality"
  | "yandex-edge"
  | "yandex-edge-proxy"
  | "vk-relay"
  | "relay-via-server"
  | "relay-direct";
type DeployPortMode = "auto" | "manual";
type PendingAction =
  | "enableVpn"
  | "disableVpn"
  | "runSpeedTest"
  | "toggleNextVpnLog"
  | "runWhitelistDebugProbe"
  | "validate"
  | "deploy"
  | "exportInviteFile"
  | "startTunnel"
  | "startOwnerRuntimeLab"
  | "stopTunnel"
  | "refreshTunnel"
  | "runTest"
  | "checkWhitelist"
  | "refreshOwnerProfile"
  | "enableSystemProxy"
  | "disableSystemProxy"
  | null;

type ControlCenterProps = {
  onNetworkLensChange?: (lens: MobileNetworkLensResult | null) => void;
};

type RuntimeIdentity = {
  runtimeFamily: string;
  activationState: string;
};

type WhitelistDebugProbeVariant = {
  id: string;
  label: string;
  description: string;
  resolve: () => {
    serverDraft: ServerDraft;
    useRealityStartEndpoint: boolean;
    usingImportedProfile: boolean;
    excludePackages: string[];
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest;
    runtimeIdentityOverride?: RuntimeIdentity;
  };
};

type WhitelistDebugProbeAttempt = {
  id: string;
  label: string;
  description: string;
  startedAt: string;
  finishedAt: string;
  runtimeFamily: string;
  activationState: string;
  ownerRuntimeLabMode: string;
  status: string;
  passed: boolean;
  selectedSniHint?: string;
  frontTag?: string;
  lastTestStatus?: string;
  lastTestError?: string;
  runtimeError?: string;
};

const WHITELIST_DEBUG_PROBE_VARIANT_TIMEOUT_MS = 40_000;
const SPEED_TEST_TOTAL_DURATION_MS = 10_000;
const SPEED_TEST_WARMUP_DURATION_MS = 2_000;
const SPEED_TEST_MEASURE_DURATION_MS =
  SPEED_TEST_TOTAL_DURATION_MS - SPEED_TEST_WARMUP_DURATION_MS;
const SPEED_TEST_STREAM_COUNT = 8;

const formatSpeedTestLatency = (
  value: number | undefined,
  emptyLabel: string,
) => (typeof value === "number" && Number.isFinite(value) ? `${Math.round(value)} ms` : emptyLabel);

const formatSpeedTestDownload = (
  value: number | undefined,
  emptyLabel: string,
) =>
  typeof value === "number" && Number.isFinite(value)
    ? `${value.toFixed(1)} Mbps`
    : emptyLabel;

type WhitelistDebugProbeExecution = {
  attempt: WhitelistDebugProbeAttempt;
  passed: boolean;
};

type OwnerRuntimeLabMode =
  | "off"
  | "reality-whitelist-scaffold"
  | "reality-whitelist-lab"
  | "reality-vps-scaffold"
  | "reality-vps-lab"
  | "reality-vps-relay-lab"
  | "reality-yandex-edge"
  | "reality-yandex-edge-proxy";

type OwnerRuntimeLabTransport = "tcp" | "grpc";
type EdgeDraft = {
  host: string;
  port: number;
  username: string;
  authMethod: AuthMethod;
  secret: string;
  publicPort: number;
  routingMode: EdgeRoutingMode;
};

type OwnerRuntimeLabState = {
  mode: OwnerRuntimeLabMode;
  hintServerName: string;
  hintCidrBucket: string;
  hintSource: string;
  hintTag: string;
  vpsServerName: string;
  vpsPort: string;
  vpsConnectHost: string;
  vpsConnectPort: string;
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

const storageKey = "odin-one-vk-control-center-v5";
const ownerRuntimeLabStorageKey = "odin-one-owner-runtime-lab-v1";
const ownerRuntimeLabUnlockStorageKey =
  "odin-one-owner-runtime-lab-unlocked-v1";
const ownerRuntimeLabUnlockTapTarget = 5;
const defaultOwnerRuntimeLabRelaySubscriptionUrl =
  "https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt";
const defaultOwnerRuntimeLabRelaySourceLabel = "igareck-mobile-hourly";
const yandexEdgeConnectHost = "62.84.123.148";
const yandexEdgeConnectPort = 443;
const yandexEdgeSource = "operator-curated:yandex-edge";
const yandexEdgeTag = "yandex-edge-62-84-123-148";
const inviteFileExtension = ".odinone-access.json";
const androidTunnelStartingWarning =
  "Android local tunnel is still starting. Check the runtime log and try again in a few seconds.";
const initialEdgeDraft: EdgeDraft = {
  host: "",
  port: 22,
  username: "root",
  authMethod: "password",
  secret: "",
  publicPort: 443,
  routingMode: "xray-proxy",
};

const normalizeEdgeRoutingMode = (
  value: string | undefined,
): EdgeRoutingMode => {
  if (value === "sni-router" || value === "xray-proxy") {
    return value;
  }
  return "xray-proxy";
};
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
  vpsConnectHost: "",
  vpsConnectPort: "",
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
  vpsRelaySourceLabel: defaultOwnerRuntimeLabRelaySourceLabel,
};

const withIgareckRelayDefaults = (
  current: OwnerRuntimeLabState,
): OwnerRuntimeLabState => ({
  ...current,
  vpsUseOwnerRealityEgress: current.vpsUseOwnerRealityEgress,
  vpsUseRelayAutoselect: true,
  vpsRelaySubscriptionUrl:
    current.vpsRelaySubscriptionUrl.trim() ||
    defaultOwnerRuntimeLabRelaySubscriptionUrl,
  vpsRelaySourceLabel:
    current.vpsRelaySourceLabel.trim() ||
    defaultOwnerRuntimeLabRelaySourceLabel,
  vpsServerName: current.vpsServerName.trim() || "id.x5.ru",
  vpsPort:
    Number.isInteger(Number.parseInt(current.vpsPort, 10)) &&
    Number.parseInt(current.vpsPort, 10) > 0
      ? current.vpsPort
      : "443",
  vpsTransport: "tcp",
  vpsFlow: current.vpsFlow.trim() || "xtls-rprx-vision",
  vpsFingerprint: current.vpsFingerprint.trim() || "chrome",
});

const isOwnerRuntimeLabVpsMode = (mode: OwnerRuntimeLabMode) =>
  mode === "reality-vps-scaffold" ||
  mode === "reality-vps-lab" ||
  mode === "reality-vps-relay-lab";

const isOwnerRuntimeLabRelayOwnerMode = (mode: OwnerRuntimeLabMode) =>
  mode === "reality-vps-relay-lab";

const normalizeTransport = (
  transport: string | undefined,
): ServerDraft["transport"] =>
  transport === "xray" || transport === "vk-turn-proxy+xray"
    ? transport
    : initialDraft.transport;

const normalizeEngine = (
  engine: string | undefined,
): NonNullable<ServerDraft["engine"]> =>
  engine === "sing-box" || engine === "xray" ? engine : "xray";

const normalizeProtocol = (
  protocol: string | undefined,
): NonNullable<ServerDraft["protocol"]> =>
  protocol === "vless-reality" || protocol === "direct-wireguard"
    ? protocol
    : "vless-reality";

const normalizePortHint = (port: number | undefined): number | undefined =>
  typeof port === "number" &&
  Number.isInteger(port) &&
  port > 0 &&
  port <= 65535
    ? port
    : undefined;

const normalizeVkTurnStreamCount = (
  count: number | undefined,
): number | undefined =>
  typeof count === "number" &&
  Number.isInteger(count) &&
  count >= 1 &&
  count <= 16
    ? count
    : undefined;

const normalizeHostValue = (host: string | null | undefined) =>
  host?.trim().toLowerCase() ?? "";

const hostsMatch = (
  left: string | null | undefined,
  right: string | null | undefined,
) => {
  const normalizedLeft = normalizeHostValue(left);
  const normalizedRight = normalizeHostValue(right);
  if (!normalizedLeft || !normalizedRight) {
    return true;
  }
  return normalizedLeft === normalizedRight;
};

const normalizeInviteProtocol = (
  protocol: InviteProfile["protocol"] | undefined,
): NonNullable<ServerDraft["protocol"]> =>
  protocol === "wireguard" ? "direct-wireguard" : "vless-reality";

const importedProfileHasReality = (profile: InviteProfile | null) =>
  Boolean(profile?.supportsReality ?? profile?.vlessReality?.port);

const importedProfileHasVKRelay = (profile: InviteProfile | null) =>
  Boolean(
    profile?.supportsVKRelay ??
    (profile?.vkTurnProxyPort && profile?.wireGuardPort),
  );

type CdnAntiWhitelistRuntimeSummary = {
  frontHost: string;
  connectHost: string;
  connectPort: number;
  tlsServerName: string;
  hostHeader: string;
  tlsAllowInsecure: boolean;
};

const resolveProfileCdnAntiWhitelistRuntime = (
  profile:
    | Pick<InviteProfile, "androidRuntime">
    | Pick<OwnerAccessProfile, "androidRuntime">
    | null
    | undefined,
): CdnAntiWhitelistRuntimeSummary | null => {
  const runtime = profile?.androidRuntime;
  if (!runtime || typeof runtime !== "object") {
    return null;
  }
  const cdnAntiWhitelist = (runtime as Record<string, unknown>).cdnAntiWhitelist;
  if (!cdnAntiWhitelist || typeof cdnAntiWhitelist !== "object") {
    return null;
  }
  const candidate = cdnAntiWhitelist as Record<string, unknown>;
  if (candidate.enabled !== true) {
    return null;
  }
  const frontHost =
    typeof candidate.frontHost === "string" ? candidate.frontHost.trim() : "";
  const connectHost =
    typeof candidate.connectHost === "string"
      ? candidate.connectHost.trim()
      : "";
  const connectPort =
    typeof candidate.connectPort === "number"
      ? candidate.connectPort
      : typeof candidate.connectPort === "string"
        ? Number.parseInt(candidate.connectPort, 10)
        : Number.NaN;
  if (
    !frontHost ||
    !connectHost ||
    !Number.isInteger(connectPort) ||
    connectPort <= 0 ||
    connectPort > 65535
  ) {
    return null;
  }
  return {
    frontHost,
    connectHost,
    connectPort,
    tlsServerName:
      typeof candidate.tlsServerName === "string"
        ? candidate.tlsServerName.trim()
        : "",
    hostHeader:
      typeof candidate.hostHeader === "string"
        ? candidate.hostHeader.trim()
        : "",
    tlsAllowInsecure: candidate.tlsAllowInsecure === true,
  };
};

const importedProfileHasCdnAntiWhitelist = (profile: InviteProfile | null) =>
  Boolean(resolveProfileCdnAntiWhitelistRuntime(profile));

const ownerProfileHasCdnAntiWhitelist = (profile: OwnerAccessProfile | null) =>
  Boolean(resolveProfileCdnAntiWhitelistRuntime(profile));

const importedProfilePrefersCdnYandexMode = (
  profile: InviteProfile | null,
) => importedProfileHasCdnAntiWhitelist(profile);

const profileProtocolPackHasEntry = (
  profile:
    | Pick<OwnerAccessProfile, "protocolPack">
    | Pick<InviteProfile, "protocolPack">
    | null
    | undefined,
  id: string,
) => Boolean(profile?.protocolPack?.some((entry) => entry.id === id));

type EdgeFallbackRuntimeConfig = {
  connectHost: string;
  connectPort: number;
  source: string;
  tag: string;
  ownerRealityEgress: boolean;
};

type RealityFallbackRuntimeConfig = {
  port: number;
  serverName: string;
  flow: string;
};

const asEdgeFallbackRuntimeConfig = (
  value: unknown,
): EdgeFallbackRuntimeConfig | null => {
  if (!value || typeof value !== "object") {
    return null;
  }
  const candidate = value as Record<string, unknown>;
  const connectHost =
    typeof candidate.connectHost === "string"
      ? candidate.connectHost.trim()
      : "";
  const connectPort =
    typeof candidate.connectPort === "number"
      ? candidate.connectPort
      : typeof candidate.connectPort === "string"
        ? Number.parseInt(candidate.connectPort, 10)
        : Number.NaN;
  const source =
    typeof candidate.source === "string" ? candidate.source.trim() : "";
  const tag = typeof candidate.tag === "string" ? candidate.tag.trim() : "";
  const ownerRealityEgress = candidate.ownerRealityEgress === true;
  if (
    !connectHost ||
    !Number.isInteger(connectPort) ||
    connectPort <= 0 ||
    connectPort > 65535
  ) {
    return null;
  }
  return {
    connectHost,
    connectPort,
    source,
    tag,
    ownerRealityEgress,
  };
};

const asRealityFallbackRuntimeConfig = (
  value: unknown,
): RealityFallbackRuntimeConfig | null => {
  if (!value || typeof value !== "object") {
    return null;
  }
  const candidate = value as Record<string, unknown>;
  const port =
    typeof candidate.port === "number"
      ? candidate.port
      : typeof candidate.port === "string"
        ? Number.parseInt(candidate.port, 10)
        : Number.NaN;
  const serverName =
    typeof candidate.serverName === "string"
      ? candidate.serverName.trim()
      : "";
  const flow =
    typeof candidate.flow === "string" ? candidate.flow.trim() : "";
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    return null;
  }
  return {
    port,
    serverName,
    flow,
  };
};

const resolveProfileEdgeFallback = (
  profile:
    | Pick<OwnerAccessProfile, "stagedFallbacks">
    | Pick<InviteProfile, "stagedFallbacks">
    | null
    | undefined,
  key: "realityYandexEdge" | "realityYandexEdgeProxy",
) => asEdgeFallbackRuntimeConfig(profile?.stagedFallbacks?.[key]);

const resolveProfileRealityFallback = (
  profile:
    | Pick<OwnerAccessProfile, "stagedFallbacks">
    | Pick<InviteProfile, "stagedFallbacks" | "vlessReality">
    | null
    | undefined,
) =>
  asRealityFallbackRuntimeConfig(
    profile?.stagedFallbacks?.["vlessReality"] ??
      ("vlessReality" in (profile ?? {}) ? profile?.vlessReality : null),
  );

const mergeProtocolPackEntries = (
  ...packs: Array<ProtocolPackEntry[] | null | undefined>
) => {
  const merged = new Map<string, ProtocolPackEntry>();
  for (const pack of packs) {
    for (const entry of pack ?? []) {
      if (!merged.has(entry.id)) {
        merged.set(entry.id, entry);
      }
    }
  }
  return Array.from(merged.values());
};

const ownerProfileHasYandexEdge = (profile: OwnerAccessProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
      (Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "realityYandexEdge",
      ) ||
        Object.prototype.hasOwnProperty.call(
          profile.stagedFallbacks,
          "realityYandexEdgeProxy",
        )),
  ) ||
  profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge") ||
  profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge-proxy");

const ownerProfileHasCurrentYandexEdge = (profile: OwnerAccessProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
      Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "realityYandexEdgeProxy",
      ),
  ) || profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge-proxy");

const importedProfileHasYandexEdge = (profile: InviteProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
      (Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "realityYandexEdge",
      ) ||
        Object.prototype.hasOwnProperty.call(
          profile.stagedFallbacks,
          "realityYandexEdgeProxy",
        )),
  ) ||
  profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge") ||
  profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge-proxy");

const importedProfileHasCurrentYandexEdge = (profile: InviteProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
      Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "realityYandexEdgeProxy",
      ),
  ) || profileProtocolPackHasEntry(profile, "vless-reality-yandex-edge-proxy");

const importedProfilePrefersYandexEdgeMode = (
  profile: InviteProfile | null,
) =>
  importedProfileHasCdnAntiWhitelist(profile) ||
  importedProfileHasYandexEdge(profile);

const ownerProfileHasRealityRelay = (profile: OwnerAccessProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
    (Object.prototype.hasOwnProperty.call(
      profile.stagedFallbacks,
      "realityRelayOwnerEgress",
    ) ||
      Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "vlessReality",
      )),
  );

const importedProfileHasRealityRelay = (profile: InviteProfile | null) =>
  Boolean(
    profile?.supportsRealityRelay ??
    (profile?.stagedFallbacks &&
      Object.prototype.hasOwnProperty.call(
        profile.stagedFallbacks,
        "realityRelayOwnerEgress",
      )),
  );

const resolveDraftEngine = (
  transport: ServerDraft["transport"] | undefined,
  protocol: ServerDraft["protocol"] | undefined,
  engine: string | undefined,
): NonNullable<ServerDraft["engine"]> => {
  const normalizedTransportValue = normalizeTransport(transport);
  const normalizedProtocolValue =
    normalizedTransportValue === "xray"
      ? normalizeProtocol(protocol)
      : "direct-wireguard";
  if (normalizedProtocolValue === "vless-reality") {
    return "sing-box";
  }
  return normalizeEngine(engine);
};

const draftAccessMode = (serverDraft: ServerDraft): AccessMode =>
  serverDraft.transport === "vk-turn-proxy+xray" ? "vk-relay" : "vless-reality";

const applyAccessModeToDraft = (
  serverDraft: ServerDraft,
  mode: AccessMode,
): ServerDraft => {
  if (mode === "vk-relay") {
    return {
      ...serverDraft,
      transport: "vk-turn-proxy+xray",
      engine: "xray",
      protocol: "direct-wireguard",
    };
  }
  return {
    ...serverDraft,
    transport: "xray",
    engine: "sing-box",
    protocol: "vless-reality",
  };
};

const clampDiagnosticText = (
  value: string,
  maxLines = diagnosticsPreviewMaxLines,
  maxChars = diagnosticsPreviewMaxChars,
) => {
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
  return clampDiagnosticText(
    relevantLines.join("\n"),
    diagnosticsLogPreviewMaxLines,
    diagnosticsLogPreviewMaxChars,
  );
};

const ownerProfileHasRealityFallback = (profile: OwnerAccessProfile | null) =>
  Boolean(
    profile?.stagedFallbacks &&
    Object.prototype.hasOwnProperty.call(
      profile.stagedFallbacks,
      "vlessReality",
    ),
  );

const ownerProfileSupportsDraft = (
  profile: OwnerAccessProfile | null,
  serverDraft: ServerDraft,
) => {
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
      profile.wireguard?.address,
    );
  }
  return Boolean(
    profile.wireguard?.serverPublicKey &&
    profile.wireguard?.clientPrivateKey &&
    profile.wireguard?.address,
  );
};

const importedProfileSupportsDraft = (
  profile: InviteProfile | null,
  serverDraft: ServerDraft,
) => {
  if (!profile?.localPath) {
    return false;
  }
  const transport = normalizeTransport(serverDraft.transport);
  if (
    transport === "xray" &&
    normalizeProtocol(serverDraft.protocol) === "vless-reality"
  ) {
    return importedProfileHasReality(profile);
  }
  if (transport === "vk-turn-proxy+xray") {
    return importedProfileHasVKRelay(profile);
  }
  return importedProfileHasVKRelay(profile);
};

const ownerProfileSupportsRelayMode = (
  profile: OwnerAccessProfile | null,
  serverDraft: ServerDraft,
) =>
  ownerProfileSupportsDraft(profile, serverDraft) &&
  ownerProfileHasRealityRelay(profile);

const importedProfileSupportsRelayMode = (
  profile: InviteProfile | null,
  serverDraft: ServerDraft,
) =>
  importedProfileSupportsDraft(profile, serverDraft) &&
  importedProfileHasRealityRelay(profile);

const ownerProfileSupportsYandexEdgeMode = (
  profile: OwnerAccessProfile | null,
  serverDraft: ServerDraft,
) =>
  ownerProfileSupportsDraft(profile, serverDraft) &&
  (ownerProfileHasYandexEdge(profile) ||
    ownerProfileHasCurrentYandexEdge(profile) ||
    ownerProfileHasCdnAntiWhitelist(profile));

const importedProfileSupportsYandexEdgeMode = (
  profile: InviteProfile | null,
  serverDraft: ServerDraft,
) =>
  importedProfileSupportsDraft(profile, serverDraft) &&
  (importedProfileHasYandexEdge(profile) ||
    importedProfileHasCurrentYandexEdge(profile) ||
    importedProfileHasCdnAntiWhitelist(profile));

const importedProfileMatchesHost = (
  profile: InviteProfile | null,
  host: string | null | undefined,
) => Boolean(profile?.localPath && hostsMatch(host, profile?.serverHost));

type PersistedState = {
  activeTab: WorkspaceTab;
  activeAccessTab: AccessTab;
  accessMode?: AccessMode;
  draft: ServerDraft;
  edgeDraft?: EdgeDraft;
  deployPortMode: DeployPortMode;
  secret: string;
  vkLink: string;
  whitelistIp?: string;
  validation: ValidationResponse | null;
  importedProfile?: InviteProfile | null;
};

const formatProtocolEntry = (
  entry: ProtocolPackEntry,
) =>
  `${entry.label} / ${entry.scheme} / ${entry.network.toUpperCase()} ${entry.port}`;

const sanitizeInviteFilePart = (value: string) =>
  value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "odin-one";

const buildInviteFileName = (profile: InviteProfile) =>
  `${sanitizeInviteFilePart(profile.serverHost || "server")}-${sanitizeInviteFilePart(profile.name || "invite")}${inviteFileExtension}`;

const regionDisplayLocale = (locale: "ru" | "en") =>
  locale === "ru" ? "ru-RU" : "en-US";

const countryFlagFromCode = (countryCode?: string | null) => {
  const normalized = countryCode?.trim().toUpperCase();
  if (!normalized || normalized.length !== 2) {
    return "";
  }
  return String.fromCodePoint(
    normalized.charCodeAt(0) - 65 + 0x1f1e6,
    normalized.charCodeAt(1) - 65 + 0x1f1e6,
  );
};

const normalizePackageNames = (packages?: string[] | null) =>
  Array.from(
    new Set(
      (packages ?? [])
        .map((value) => value.trim().toLowerCase())
        .filter(Boolean),
    ),
  ).sort((left, right) => left.localeCompare(right));

const samePackageSelection = (
  left?: string[] | null,
  right?: string[] | null,
) => {
  const normalizedLeft = normalizePackageNames(left);
  const normalizedRight = normalizePackageNames(right);
  if (normalizedLeft.length !== normalizedRight.length) {
    return false;
  }
  return normalizedLeft.every((value, index) => value === normalizedRight[index]);
};

const looksLikeInviteJsonPayload = (value: string) => {
  const trimmed = value.trim();
  return trimmed.startsWith("{") || trimmed.startsWith("[");
};

const formatInviteExportNotice = (
  t: ReturnType<typeof useI18n>["t"],
  fileName: string,
  exportPath: string,
) => {
  const normalizedPath = exportPath.replace(/\\/g, "/");
  if (
    normalizedPath.includes("/Download/Odin One/") ||
    normalizedPath.includes("/Download/Odin's Cat/")
  ) {
    return `${t("saved")}: ${fileName}\n${t("exportProfileFileSavedDownload")}`;
  }
  if (normalizedPath.includes("/exports/")) {
    return `${t("saved")}: ${fileName}\n${t("exportProfileFileSavedLocal")}`;
  }
  return `${t("saved")}: ${fileName}`;
};

export function ControlCenter({ onNetworkLensChange }: ControlCenterProps) {
  const { locale, t } = useI18n();
  const [activeTab, setActiveTab] = useState<WorkspaceTab>("server");
  const [activeAccessTab, setActiveAccessTab] = useState<AccessTab>("key");
  const [activeSheet, setActiveSheet] = useState<MobileSheet>(null);
  const [draft, setDraft] = useState<ServerDraft>(initialDraft);
  const [edgeDraft, setEdgeDraft] = useState<EdgeDraft>(initialEdgeDraft);
  const [selectedAccessMode, setSelectedAccessMode] =
    useState<AccessMode>("vless-reality");
  const [deployPortMode, setDeployPortMode] = useState<DeployPortMode>("auto");
  const [secret, setSecret] = useState("");
  const [validation, setValidation] = useState<ValidationResponse | null>(null);
  const [plan, setPlan] = useState<DeployStage[]>([]);
  const [deployment, setDeployment] = useState<DeploymentState | null>(null);
  const [showDeploymentOverlay, setShowDeploymentOverlay] = useState(false);
  const [vkLink, setVKLink] = useState("");
  const [whitelistIp, setWhitelistIp] = useState("");
  const [whitelistLookup, setWhitelistLookup] =
    useState<WhitelistLookupResult | null>(null);
  const [whitelistLookupError, setWhitelistLookupError] = useState<
    string | null
  >(null);
  const [mobileNetworkLens, setMobileNetworkLens] =
    useState<MobileNetworkLensResult | null>(null);
  const [speedTestResult, setSpeedTestResult] =
    useState<TunnelSpeedTestResult | null>(null);
  const [speedTestCountdownEndsAt, setSpeedTestCountdownEndsAt] =
    useState<number | null>(null);
  const [speedTestCountdownRemainingMs, setSpeedTestCountdownRemainingMs] =
    useState(0);
  const importProfileFileInputRef = useRef<HTMLInputElement | null>(null);
  const [localTunnel, setLocalTunnel] = useState<LocalTunnelState | null>(null);
  const [systemProxy, setSystemProxy] = useState<SystemProxyState | null>(null);
  const [installedApps, setInstalledApps] = useState<InstalledAppInfo[]>([]);
  const [splitTunnelSelection, setSplitTunnelSelection] =
    useState<SplitTunnelSelection>({ excludePackages: [] });
  const [splitTunnelAppsLoaded, setSplitTunnelAppsLoaded] = useState(false);
  const [splitTunnelAppsLoading, setSplitTunnelAppsLoading] = useState(false);
  const [splitTunnelSaving, setSplitTunnelSaving] = useState(false);
  const [splitTunnelError, setSplitTunnelError] = useState<string | null>(null);
  const [splitTunnelSearch, setSplitTunnelSearch] = useState("");
  const [recordNextVpnSessionLog, setRecordNextVpnSessionLog] =
    useState(false);
  const [nextVpnSessionLogError, setNextVpnSessionLogError] =
    useState<string | null>(null);
  const [whitelistDebugProbeNotice, setWhitelistDebugProbeNotice] = useState<
    string | null
  >(null);
  const [ownerProfile, setOwnerProfile] = useState<OwnerAccessProfile | null>(
    null,
  );
  const [guestProfile, setGuestProfile] = useState<InviteProfile | null>(null);
  const [importedProfile, setImportedProfile] = useState<InviteProfile | null>(
    null,
  );
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const [coreHealth, setCoreHealth] = useState<CoreHealthState | null>(null);
  const [successNotice, setSuccessNotice] = useState<string | null>(null);
  const [inviteFileNotice, setInviteFileNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction>(null);
  const [isPending, startTransition] = useTransition();
  const [androidVpnVisualOverride, setAndroidVpnVisualOverride] =
    useState(false);
  const [androidUserAgentMatch, setAndroidUserAgentMatch] = useState(false);
  const [ownerRuntimeLabUnlocked, setOwnerRuntimeLabUnlocked] = useState(false);
  const [ownerRuntimeLabUnlockTapCount, setOwnerRuntimeLabUnlockTapCount] =
    useState(0);
  const [ownerRuntimeLab, setOwnerRuntimeLab] = useState<OwnerRuntimeLabState>(
    defaultOwnerRuntimeLabState,
  );
  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    setAndroidUserAgentMatch(/Android/i.test(window.navigator.userAgent));
  }, []);

  useEffect(() => {
    if (!speedTestCountdownEndsAt) {
      setSpeedTestCountdownRemainingMs(0);
      return;
    }

    const tick = () => {
      const remaining = Math.max(0, speedTestCountdownEndsAt - Date.now());
      setSpeedTestCountdownRemainingMs(remaining);
      if (remaining <= 0) {
        setSpeedTestCountdownEndsAt(null);
      }
    };

    tick();
    const intervalId = window.setInterval(tick, 200);
    return () => window.clearInterval(intervalId);
  }, [speedTestCountdownEndsAt]);

  const isAndroidClient =
    coreHealth?.service === "odin-one-mobile-bridge" || androidUserAgentMatch;
  const curlCommand = localTunnel?.socksAddress
    ? `curl --socks5-hostname ${localTunnel.socksAddress} -I https://example.com`
    : "";
  const splitTunnelExcludePackages = normalizePackageNames(
    splitTunnelSelection.excludePackages,
  );
  const requiresVKLink = selectedAccessMode === "vk-relay";
  const selectedModeUsesStandalonePublicRelay =
    selectedAccessMode === "relay-direct";
  const resolvedDraftHost =
    draft.host.trim() ||
    importedProfile?.serverHost?.trim() ||
    ownerProfile?.serverHost?.trim() ||
    "";
  const cooldownMinutes =
    localTunnel?.cooldownRemainingSeconds &&
    localTunnel.cooldownRemainingSeconds > 0
      ? Math.ceil(localTunnel.cooldownRemainingSeconds / 60)
      : 0;
  const deploymentPortSummary = [
    deployment?.turnPort ? `VK UDP ${deployment.turnPort}` : "",
    deployment?.realityPort ? `REALITY TCP ${deployment.realityPort}` : "",
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
      localTunnel.logTail?.some((line) =>
        line.includes(
          "Android VpnService established the system VPN interface.",
        ),
      ),
    );
  const runtimeTunnelActive =
    localTunnel?.status === "running" || androidInterfaceEstablished;
  const activeTunnelExcludePackages = normalizePackageNames(
    localTunnel?.excludePackages,
  );
  const splitTunnelReconnectRequired =
    isAndroidClient &&
    runtimeTunnelActive &&
    !samePackageSelection(
      activeTunnelExcludePackages,
      splitTunnelExcludePackages,
    );
  const vpnModeActive =
    runtimeTunnelActive &&
    (isAndroidClient || isAndroidVpnRuntime || systemProxyActive);
  const ownerRuntimeLabRealityDraft: ServerDraft = {
    ...draft,
    transport: "xray",
    engine: "sing-box",
    protocol: "vless-reality",
  };
  const hasMatchingOwnerProfile = Boolean(
    ownerProfileSupportsDraft(ownerProfile, draft) &&
    hostsMatch(draft.host, ownerProfile?.serverHost),
  );
  const hasMatchingImportedProfile = Boolean(
    importedProfileSupportsDraft(importedProfile, draft) &&
    hostsMatch(draft.host, importedProfile?.serverHost),
  );
  const hasImportedProfileForHost = importedProfileMatchesHost(
    importedProfile,
    draft.host || resolvedDraftHost,
  );
  const hasLocalAccessProfile = Boolean(
    hasMatchingOwnerProfile ||
    hasMatchingImportedProfile ||
    hasImportedProfileForHost,
  );
  const hasLocalRelayAccessProfile = Boolean(
    (ownerProfileSupportsRelayMode(ownerProfile, ownerRuntimeLabRealityDraft) &&
      hostsMatch(draft.host || resolvedDraftHost, ownerProfile?.serverHost)) ||
    (importedProfileSupportsRelayMode(
      importedProfile,
      ownerRuntimeLabRealityDraft,
    ) &&
      hostsMatch(draft.host || resolvedDraftHost, importedProfile?.serverHost)),
  );
  const hasLocalYandexEdgeAccessProfile = Boolean(
    (ownerProfileSupportsYandexEdgeMode(
      ownerProfile,
      ownerRuntimeLabRealityDraft,
    ) &&
      hostsMatch(draft.host || resolvedDraftHost, ownerProfile?.serverHost)) ||
      (importedProfileSupportsYandexEdgeMode(
        importedProfile,
        ownerRuntimeLabRealityDraft,
      ) &&
        hostsMatch(draft.host || resolvedDraftHost, importedProfile?.serverHost)),
  );
  const whitelistDebugProbeAvailable =
    isAndroidClient &&
    (hasLocalYandexEdgeAccessProfile || hasLocalAccessProfile);
  const hasLocalAccessProfileForSelectedMode =
    selectedAccessMode === "yandex-edge" ||
    selectedAccessMode === "yandex-edge-proxy"
      ? hasLocalYandexEdgeAccessProfile
      : selectedAccessMode === "relay-direct"
      ? true
      : selectedAccessMode === "relay-via-server"
      ? hasLocalRelayAccessProfile
      : hasLocalAccessProfile;
  const canGenerateGuestProfile = Boolean(
    resolvedDraftHost && ownerProfile?.exists && secret.trim(),
  );
  const guestProfileHint =
    importedProfile?.localPath && !ownerProfile?.exists
      ? t("guestAccessOwnerOnly")
      : ownerProfile?.exists && !secret.trim()
        ? t("guestAccessNeedsSecret")
        : !ownerProfile?.exists
          ? ""
          : "";
  const stageStatusLabels = {
    queued: t("stageQueued"),
    current: t("stageCurrent"),
    done: t("stageDone"),
    failed: t("stageFailed"),
  };

  const translateStage = (stage: DeployStage): DeployStage => {
    if (locale === "en") {
      return stage;
    }

    const labelMap: Record<string, string> = {
      "ssh-check": "Проверка SSH",
      "origin-ssh-check": "Проверка origin",
      "edge-ssh-check": "Проверка edge",
      "runtime-prep": "Подготовка окружения",
      "edge-runtime-prep": "Подготовка edge",
      "install-binaries": "Установка бинарников",
      "configure-services": "Настройка сервисов",
      "edge-configure": "Настройка edge",
      "service-start": "Запуск сервисов",
      "edge-service-start": "Запуск edge",
      "egress-check": "Проверка исходящего трафика",
      "profile-refresh": "Обновление профиля",
    };
    const descriptionMap: Record<string, string> = {
      "ssh-check":
        "Проверяет учётные данные, удалённую ОС и текущее состояние сервера.",
      "origin-ssh-check":
        "Читает live owner profile на origin и подтверждает текущий REALITY inbound.",
      "edge-ssh-check":
        "Проверяет Yandex edge-хост и возможность аккуратно выполнить privileged setup.",
      "runtime-prep":
        "Создаёт изолированные директории Odin's Cat и проверяет сетевую готовность.",
      "edge-runtime-prep":
        "Готовит выбранный edge-runtime и пишет manifest для нового входа.",
      "install-binaries":
        "Устанавливает xray и загружает server-side vk-turn-proxy для общего dual-stack runtime.",
      "configure-services":
        "Генерирует ключи, пишет конфиги xray и ставит unit-файлы для REALITY и VK relay.",
      "edge-configure":
        "Ставит systemd-сервис для выбранного edge path и поднимает новый вход через Yandex edge.",
      "service-start":
        "Запускает xray и vk-turn-proxy на одном сервере и проверяет оба входа.",
      "edge-service-start":
        "Запускает edge-сервис и проверяет reachability до текущего REALITY origin.",
      "egress-check":
        "Проверяет DNS, HTTP и HTTPS egress на сервере после запуска сервисов.",
      "profile-refresh":
        "Патчит owner profile и protocol pack, чтобы новый visible режим попал в один invite key.",
    };

    return {
      ...stage,
      label: labelMap[stage.id] ?? stage.label,
      description: descriptionMap[stage.id] ?? stage.description,
    };
  };

  const translateCheckLabel = (key: string, fallback: string) => {
    if (locale === "en") {
      return fallback;
    }

    const map: Record<string, string> = {
      "ssh-port": "SSH порт доступен",
      "tcp-connect": "TCP подключение",
      "origin-tcp-connect": "TCP до origin",
      "origin-owner-profile": "Owner profile origin",
      "edge-tcp-connect": "TCP до edge",
      "edge-remote-user": "Пользователь на edge",
      "edge-os-release": "ОС на edge",
      "edge-sudo-ready": "Sudo на edge",
      "edge-public-port": "Публичный порт edge",
      "remote-user": "Удалённый пользователь",
      "os-release": "Операционная система",
      "sudo-presence": "Наличие sudo",
      "docker-presence": "Наличие Docker",
      "curl-presence": "Наличие curl",
      "dns-resolution": "DNS резолвинг",
      "remote-http-egress": "Исходящий HTTP с сервера",
      "remote-https-egress": "Исходящий HTTPS с сервера",
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
    return detail
      .replace("Connected to ", "Подключено к ")
      .replace("accepted the connection", "принял соединение");
  };

  const deploymentStatusLabel = deployment
    ? ({
        queued: t("deployStatusQueued"),
        running: t("deployStatusRunning"),
        done: t("deployStatusDone"),
        failed: t("deployStatusFailed"),
      }[deployment.status] ?? deployment.status)
    : "";
  const tunnelStatusLabel = localTunnel
    ? ({
        idle: t("tunnelStatusIdle"),
        starting: t("tunnelStatusStarting"),
        running: t("tunnelStatusRunning"),
        stopped: t("tunnelStatusStopped"),
        failed: t("tunnelStatusFailed"),
      }[localTunnel.status] ?? localTunnel.status)
    : "";
  const isBusy = (action: Exclude<PendingAction, null>) =>
    pendingAction === action;
  const vpnButtonBusy = isBusy("enableVpn") || isBusy("disableVpn");
  const vpnActionActive =
    runtimeTunnelActive ||
    vpnModeActive ||
    (isAndroidClient && androidVpnVisualOverride);
  const vpnVisualActive = vpnActionActive;
  const modeTriggerError = Boolean(error) || localTunnel?.status === "failed";
  const modeTriggerConnecting =
    !modeTriggerError &&
    !vpnVisualActive &&
    (isBusy("enableVpn") || localTunnel?.status === "starting");
  const modeTriggerClassName = [
    "home-mode-trigger",
    modeTriggerError
      ? "home-mode-trigger--error"
      : vpnVisualActive
        ? "home-mode-trigger--active"
        : modeTriggerConnecting
          ? "home-mode-trigger--connecting"
          : "",
  ]
    .filter(Boolean)
    .join(" ");
  const whitelistLookupSummary =
    whitelistLookup && whitelistLookup.valid
      ? whitelistLookup.matchedIp && whitelistLookup.matchedCidr
        ? t("whitelistResultExactAndCidr")
        : whitelistLookup.matchedIp
          ? t("whitelistResultIpOnly")
          : whitelistLookup.matchedCidr
            ? t("whitelistResultCidrOnly")
            : t("whitelistResultMissing")
      : "";
  const pendingVkCaptchaUrl = localTunnel?.pendingCaptchaUrl?.trim() ?? "";
  const androidVkRelayWarmupPending = Boolean(
    isAndroidClient &&
      localTunnel?.runtimeFamily === "vk-relay" &&
      localTunnel?.activationState === "active" &&
      localTunnel?.status === "starting",
  );
  const androidTunnelOperational = Boolean(
    isAndroidClient &&
      localTunnel?.status === "running" &&
      (localTunnel?.socksAddress || localTunnel?.runtimeFamily === "vk-relay"),
  );
  const exportableInviteProfile = ownerProfile?.exists
    ? guestProfile
    : guestProfile ?? importedProfile;
  const exportableInviteFileName = exportableInviteProfile
    ? buildInviteFileName(exportableInviteProfile)
    : "";
  const vpnButtonLabel = isBusy("disableVpn")
    ? t("disablingVpn")
    : vpnActionActive
      ? t("disableVpn")
      : isBusy("enableVpn") && !runtimeTunnelActive
        ? t("enablingVpn")
        : t("enableVpn");
  const relayRuntimeActive = Boolean(
    localTunnel?.runtimeFamily === "reality-vps-lab" &&
    localTunnel?.activationState === "active" &&
    localTunnel?.relayAutoselectEnabled &&
    localTunnel?.frontConnectHost,
  );
  const relayOwnerRuntimeActive = Boolean(
    relayRuntimeActive &&
    localTunnel?.activeFeatures?.includes("reality-vps-owner-egress:on"),
  );
  const relayDirectRuntimeActive = Boolean(
    relayRuntimeActive &&
    localTunnel?.activeFeatures?.includes("reality-vps-owner-egress:off"),
  );
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
  const primaryStatusBadge = vpnVisualActive
    ? t("ready")
    : tunnelStatusLabel || t("tunnelStatusIdle");
  const primaryStatusText = vpnVisualActive
    ? t("vpnEnabled")
    : t("vpnDisabled");
  const speedTestReady =
    runtimeTunnelActive && localTunnel?.status === "running" && !!localTunnel?.socksAddress;
  const speedTestLatencyLabel = formatSpeedTestLatency(
    speedTestResult?.latencyMs,
    t("speedTestIdleValue"),
  );
  const speedTestDownloadLabel = formatSpeedTestDownload(
    speedTestResult?.downloadMbps,
    t("speedTestIdleValue"),
  );
  const speedTestCountdownRemainingSeconds =
    speedTestCountdownRemainingMs > 0
      ? Math.ceil(speedTestCountdownRemainingMs / 1000)
      : 0;
  const speedTestDownloadDisplayLabel =
    speedTestCountdownRemainingSeconds > 0
      ? locale === "ru"
        ? `${speedTestCountdownRemainingSeconds} сек`
        : `${speedTestCountdownRemainingSeconds}s`
      : speedTestDownloadLabel;
  const speedTestCheckedAt = speedTestResult?.checkedAt
    ? new Date(speedTestResult.checkedAt).toLocaleTimeString(locale === "ru" ? "ru-RU" : "en-US", {
        hour: "2-digit",
        minute: "2-digit",
      })
    : null;
  const relayOwnerConnectAnimation =
    (selectedAccessMode === "yandex-edge" ||
      selectedAccessMode === "yandex-edge-proxy" ||
      selectedAccessMode === "relay-via-server" ||
      selectedAccessMode === "relay-direct") &&
    !vpnVisualActive &&
    (isBusy("enableVpn") ||
      isBusy("startTunnel") ||
      localTunnel?.status === "starting");
  const coreRuntimeLabel =
    coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable");
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
          : draft.yandexEdgeOriginPort &&
              (draft.yandexEdgeOriginPort === draft.realityPort ||
                draft.yandexEdgeOriginPort === draft.vkTurnProxyPort)
            ? t("yandexEdgeOriginPortDistinct")
          : null;
  const deployModeLabel = `${t("deployModeDual")} / ${deployPortMode === "manual" ? t("portSetupManual") : t("portSetupAuto")}`;
  const importedProfileForCurrentHost = importedProfileMatchesHost(
    importedProfile,
    resolvedDraftHost,
  );
  const ownerYandexEdgeReady = ownerProfileHasCurrentYandexEdge(ownerProfile);
  const importedYandexEdgeReady = importedProfileHasCurrentYandexEdge(
    importedProfile,
  );
  const importedYandexEdgeStale = Boolean(
    importedProfileForCurrentHost &&
      ownerYandexEdgeReady &&
      !importedYandexEdgeReady,
  );
  const originValidation =
    validation && validation.deployFlow !== "edge-attach" ? validation : null;
  const edgeAttachValidation =
    validation?.deployFlow === "edge-attach" ? validation : null;
  const safetyPostureLabel = systemProxyActive
    ? t("safetySystemProxyOn")
    : t("safetyLocalhostOnly");
  const runtimeLogTail = localTunnel?.logTail ?? [];
  const runtimeStartSource = localTunnel?.startSource ?? t("diagnosticsEmpty");
  const runtimeFamily = localTunnel?.runtimeFamily ?? t("diagnosticsEmpty");
  const runtimeActivationState =
    localTunnel?.activationState ?? t("diagnosticsEmpty");
  const runtimeFrontHost = localTunnel?.frontHost ?? t("diagnosticsEmpty");
  const runtimeFrontPath = localTunnel?.frontPath ?? t("diagnosticsEmpty");
  const runtimeFrontProvider =
    localTunnel?.frontProvider ?? t("diagnosticsEmpty");
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
        `lastError: ${localTunnel.relayAutoselectLastError ?? t("diagnosticsEmpty")}`,
      ].join("\n")
    : t("diagnosticsEmpty");
  const runtimeSelectedSniHint =
    localTunnel?.selectedSniHint ?? t("diagnosticsEmpty");
  const runtimeSelectedCidrHint =
    localTunnel?.selectedCidrHint ?? t("diagnosticsEmpty");
  const runtimeWhitelistHintSource =
    localTunnel?.whitelistHintSource ?? t("diagnosticsEmpty");
  const runtimeWhitelistHintTag =
    localTunnel?.whitelistHintTag ?? t("diagnosticsEmpty");
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
  const runtimeNetworkEvent =
    localTunnel?.lastNetworkEvent ?? t("diagnosticsEmpty");
  const runtimeStartupDuration =
    typeof localTunnel?.lastStartupDurationMs === "number"
      ? `${localTunnel.lastStartupDurationMs} ms`
      : t("diagnosticsEmpty");
  const runtimeStartupStage =
    localTunnel?.lastStartupStage ?? t("diagnosticsEmpty");
  const runtimeFailureStage =
    localTunnel?.lastFailureStage ?? t("diagnosticsEmpty");
  const runtimeFailureCode =
    localTunnel?.lastFailureCode ?? t("diagnosticsEmpty");
  const runtimeRecoveryCounters = localTunnel
    ? `restore=${localTunnel.restoreCount ?? 0} / reload=${localTunnel.reloadCount ?? 0} / network=${localTunnel.networkChangeCount ?? 0}`
    : t("diagnosticsEmpty");
  const runtimeRecoveryAction =
    localTunnel?.lastRecoveryAction ?? t("diagnosticsEmpty");
  const realityFeatureSummary =
    localTunnel?.activeFeatures && localTunnel.activeFeatures.length > 0
      ? localTunnel.activeFeatures.join(" / ")
      : t("diagnosticsEmpty");
  const runtimeRelayAutoselectSummaryDisplay = clampDiagnosticText(
    runtimeRelayAutoselectSummary,
  );
  const runtimeLogDisplay = formatDiagnosticLogTail(
    runtimeLogTail,
    t("diagnosticsEmpty"),
  );
  const runtimeLastTestDisplay = clampDiagnosticText(
    localTunnel?.lastTest?.output ??
      localTunnel?.lastTest?.error ??
      t("diagnosticsEmpty"),
    12,
    1400,
  );
  const operatorSummary = [
    coreHealth?.status === "ok" ? t("runtimeHealthy") : t("runtimeUnavailable"),
    ownerProfile?.exists ? t("profileCacheReady") : t("profileCacheMissing"),
    localTunnel?.status === "running" ? tunnelStatusLabel : primaryStatusBadge,
    deploymentHealthLabel,
  ].join(" / ");
  const currentProtocolPack = mergeProtocolPackEntries(
    importedProfile?.protocolPack,
    ownerProfile?.protocolPack,
    deployment?.protocolPack,
    validation?.protocolPack,
  );
  const protocolEntryById = new Map(
    currentProtocolPack.map((entry) => [entry.id, entry]),
  );
  const resolvedYandexEdgeProxyFallback =
    resolveProfileEdgeFallback(importedProfile, "realityYandexEdgeProxy") ??
    resolveProfileEdgeFallback(ownerProfile, "realityYandexEdgeProxy");
  const resolvedYandexEdgeFallback =
    resolvedYandexEdgeProxyFallback ??
    resolveProfileEdgeFallback(importedProfile, "realityYandexEdge") ??
    resolveProfileEdgeFallback(ownerProfile, "realityYandexEdge");
  const resolvedYandexEdgeRuntime =
    resolveProfileCdnAntiWhitelistRuntime(importedProfile) ??
    resolveProfileCdnAntiWhitelistRuntime(ownerProfile);
  const yandexEdgeRuntimeHint = null;
  const importedProfileOffersYandexEdge =
    isAndroidClient && importedProfilePrefersYandexEdgeMode(importedProfile);
  const ownerProfileOffersYandexEdge =
    isAndroidClient &&
    (ownerProfileHasCurrentYandexEdge(ownerProfile) ||
      ownerProfileHasCdnAntiWhitelist(ownerProfile));
  const localProfileOffersYandexEdge =
    importedProfileOffersYandexEdge || ownerProfileOffersYandexEdge;
  const accessModeCards = [
    {
      mode: "vless-reality" as const,
      label: t("runtimeModeReality"),
      hint: t("runtimeModeRealityHint"),
      status:
        protocolEntryById.get("vless-reality")?.status === "active"
          ? t("modeStatusLive")
          : t("modeStatusReady"),
      available: true,
    },
    {
      mode: "yandex-edge" as const,
      label: t("runtimeModeYandexEdge"),
      hint: yandexEdgeRuntimeHint ?? t("runtimeModeYandexEdgeHint"),
      status: protocolEntryById.has("vless-reality-yandex-edge-proxy")
        ? t("modeStatusOptional")
        : localProfileOffersYandexEdge
          ? t("modeStatusReady")
          : t("modeStatusLocked"),
      available:
        isAndroidClient &&
        (protocolEntryById.has("vless-reality-yandex-edge-proxy") ||
          localProfileOffersYandexEdge),
    },
    {
      mode: "vk-relay" as const,
      label: t("runtimeModeVk"),
      hint: t("runtimeModeVkHint"),
      status:
        protocolEntryById.get("vk-turn-wireguard")?.status === "active"
          ? t("modeStatusLive")
          : t("modeStatusReady"),
      available: true,
    },
    {
      mode: "relay-via-server" as const,
      label: t("runtimeModeRelayOwner"),
      hint: t("runtimeModeRelayOwnerHint"),
      status: protocolEntryById.has("vless-reality-relay-owner")
        ? t("modeStatusOptional")
        : t("modeStatusLocked"),
      available:
        isAndroidClient && protocolEntryById.has("vless-reality-relay-owner"),
    },
    {
      mode: "relay-direct" as const,
      label: t("runtimeModeRelayDirect"),
      hint: t("runtimeModeRelayDirectHint"),
      status: protocolEntryById.has("vless-reality-relay-direct")
        ? t("modeStatusOptional")
        : t("modeStatusReady"),
      available: isAndroidClient,
    },
  ];
  const selectedAccessModeCard =
    accessModeCards.find((entry) => entry.mode === selectedAccessMode) ??
    accessModeCards[0];
  const regionNames =
    typeof Intl !== "undefined" && "DisplayNames" in Intl
      ? new Intl.DisplayNames([regionDisplayLocale(locale)], {
          type: "region",
        })
      : null;
  const formatNetworkEndpoint = (endpoint?: MobileNetworkEndpoint | null) => {
    const countryCode = endpoint?.countryCode?.trim().toUpperCase() ?? "";
    const localizedCountry =
      (countryCode && regionNames?.of(countryCode)) ||
      endpoint?.country?.trim() ||
      t("routeLensUnknownCountry");
    const flag = countryFlagFromCode(countryCode);
    return {
      host: endpoint?.host?.trim() ?? "",
      ip: endpoint?.ip?.trim() ?? "",
      countryCode,
      country: localizedCountry,
      flag,
      error: endpoint?.error?.trim() ?? "",
    };
  };
  const routeLensOrigin = formatNetworkEndpoint(mobileNetworkLens?.origin);
  const routeLensTunnel = formatNetworkEndpoint(mobileNetworkLens?.tunnel);
  const routeLensOriginDisplay = routeLensOrigin.ip || routeLensOrigin.host;
  const routeLensTunnelDisplay = routeLensTunnel.ip || routeLensTunnel.host;
  const yandexTunnelRuntimeActive =
    (selectedAccessMode === "yandex-edge" ||
      selectedAccessMode === "yandex-edge-proxy") &&
    runtimeTunnelActive;
  const activeYandexTunnelHost =
    yandexTunnelRuntimeActive
      ? localTunnel?.frontConnectHost?.trim() ||
        resolvedYandexEdgeRuntime?.connectHost ||
        resolvedYandexEdgeProxyFallback?.connectHost ||
        resolvedYandexEdgeFallback?.connectHost ||
        yandexEdgeConnectHost
      : "";
  const activeRelayTunnelHost =
    relayRuntimeActive ? localTunnel?.frontConnectHost?.trim() || "" : "";
  const activeFrontTunnelHost = activeYandexTunnelHost || activeRelayTunnelHost;
  const routeLensNetworkLabel =
    mobileNetworkLens?.networkType === "cellular"
      ? t("routeLensNetworkCellular")
      : mobileNetworkLens?.networkType === "wifi"
        ? t("routeLensNetworkWifi")
        : mobileNetworkLens?.networkType === "ethernet"
          ? t("routeLensNetworkEthernet")
          : mobileNetworkLens?.networkType === "other"
            ? t("routeLensNetworkOther")
            : t("routeLensNetworkUnknown");
  const routeLensWhitelistLabel =
    mobileNetworkLens?.whitelistStatus === "active"
      ? t("whitelistStateActive")
      : mobileNetworkLens?.whitelistStatus === "inactive"
        ? t("whitelistStateInactive")
        : t("whitelistStateUnknown");
  const routeLensWhitelistTone =
    mobileNetworkLens?.whitelistStatus === "active"
      ? "active"
      : mobileNetworkLens?.whitelistStatus === "inactive"
        ? "inactive"
        : "unknown";
  const routeLensNote =
    mobileNetworkLens?.note?.trim() ||
    ((yandexTunnelRuntimeActive && yandexEdgeRuntimeHint) || "") ||
    (!mobileNetworkLens?.isCellular ? t("whitelistProbeCellularOnly") : "");
  const routeLensVisible = Boolean(
    isAndroidClient &&
      (routeLensOriginDisplay ||
        ((yandexTunnelRuntimeActive || relayRuntimeActive) &&
          routeLensTunnelDisplay)),
  );
  useEffect(() => {
    if (!speedTestReady && speedTestResult) {
      setSpeedTestResult(null);
    }
  }, [speedTestReady, speedTestResult]);
  const ownerRuntimeLabPanelVisible =
    isAndroidClient && ownerRuntimeLabUnlocked;
  const ownerRuntimeLabHintInputsVisible =
    ownerRuntimeLab.mode === "reality-whitelist-scaffold" ||
    ownerRuntimeLab.mode === "reality-whitelist-lab";
  const ownerRuntimeLabVpsInputsVisible = isOwnerRuntimeLabVpsMode(
    ownerRuntimeLab.mode,
  );
  const ownerRuntimeLabVpsRelayOwnerMode = isOwnerRuntimeLabRelayOwnerMode(
    ownerRuntimeLab.mode,
  );
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
  const ownerRuntimeLabDisabledReason = ownerRuntimeLabRequiresOwnerProfile
    ? t("ownerLabNeedsOwnerProfile")
    : null;
  const splitTunnelSelectedSet = new Set(splitTunnelExcludePackages);
  const splitTunnelSearchQuery = splitTunnelSearch.trim().toLowerCase();
  const splitTunnelVisibleApps = [...installedApps]
    .filter((app) => {
      if (!splitTunnelSearchQuery) {
        return true;
      }
      const packageName = app.packageName.trim().toLowerCase();
      const appName = app.appName.trim().toLowerCase();
      return (
        appName.includes(splitTunnelSearchQuery) ||
        packageName.includes(splitTunnelSearchQuery)
      );
    })
    .sort((left, right) => {
      const leftSelected = splitTunnelSelectedSet.has(
        left.packageName.trim().toLowerCase(),
      );
      const rightSelected = splitTunnelSelectedSet.has(
        right.packageName.trim().toLowerCase(),
      );
      if (leftSelected !== rightSelected) {
        return leftSelected ? -1 : 1;
      }
      if ((left.systemApp ?? false) !== (right.systemApp ?? false)) {
        return left.systemApp ? 1 : -1;
      }
      return (
        left.appName.localeCompare(right.appName, locale) ||
        left.packageName.localeCompare(right.packageName)
      );
    });
  const splitTunnelStatusLabel =
    splitTunnelExcludePackages.length > 0
      ? `${t("splitTunnelSelectedApps")}: ${splitTunnelExcludePackages.length}`
      : t("splitTunnelStatusOff");

  const loadSplitTunnelSelection = async () => {
    if (!isAndroidClient) {
      return;
    }

    try {
      const res = await coreApi.getSplitTunnelSelection();
      const data = res.data;
      setSplitTunnelSelection({
        excludePackages: normalizePackageNames(data.excludePackages),
        ...(data.updatedAt ? { updatedAt: data.updatedAt } : {}),
      });
      if (!res.ok) {
        const nextError = (data as { error?: string }).error ?? t("unknownError");
        setSplitTunnelError(nextError);
      }
    } catch (requestError) {
      const message =
        requestError instanceof Error
          ? requestError.message
          : t("unknownError");
      setSplitTunnelError(message);
    }
  };

  const loadInstalledApps = async () => {
    if (!isAndroidClient) {
      return;
    }

    setSplitTunnelAppsLoading(true);
    setSplitTunnelError(null);
    try {
      const res = await coreApi.listInstalledApps();
      const data = res.data;
      setInstalledApps(data.apps ?? []);
      setSplitTunnelAppsLoaded(true);
      if (!res.ok) {
        throw new Error(
          (data as { error?: string }).error ?? t("unknownError"),
        );
      }
    } catch (requestError) {
      const message =
        requestError instanceof Error
          ? requestError.message
          : t("unknownError");
      setSplitTunnelError(message);
    } finally {
      setSplitTunnelAppsLoading(false);
    }
  };

  const persistSplitTunnelSelection = async (nextPackages: string[]) => {
    if (!isAndroidClient) {
      return;
    }

    const previousSelection = splitTunnelSelection;
    const normalizedPackages = normalizePackageNames(nextPackages);
    setSplitTunnelSaving(true);
    setSplitTunnelError(null);
    setSplitTunnelSelection({
      excludePackages: normalizedPackages,
      updatedAt: previousSelection.updatedAt,
    });

    try {
      const res = await coreApi.setSplitTunnelSelection({
        excludePackages: normalizedPackages,
      });
      const data = res.data;
      setSplitTunnelSelection({
        excludePackages: normalizePackageNames(data.excludePackages),
        ...(data.updatedAt ? { updatedAt: data.updatedAt } : {}),
      });
      if (!res.ok) {
        throw new Error(
          (data as { error?: string }).error ?? t("unknownError"),
        );
      }
    } catch (requestError) {
      const message =
        requestError instanceof Error
          ? requestError.message
          : t("unknownError");
      setSplitTunnelSelection(previousSelection);
      setSplitTunnelError(message);
    } finally {
      setSplitTunnelSaving(false);
    }
  };

  const handleToggleSplitTunnelPackage = (packageName: string) => {
    if (splitTunnelSaving) {
      return;
    }
    const normalizedPackage = packageName.trim().toLowerCase();
    if (!normalizedPackage) {
      return;
    }
    const nextPackages = splitTunnelSelectedSet.has(normalizedPackage)
      ? splitTunnelExcludePackages.filter((value) => value !== normalizedPackage)
      : [...splitTunnelExcludePackages, normalizedPackage];
    void persistSplitTunnelSelection(nextPackages);
  };

  const handleClearSplitTunnelSelection = () => {
    if (splitTunnelSaving || splitTunnelExcludePackages.length === 0) {
      return;
    }
    void persistSplitTunnelSelection([]);
  };

  const loadNextVpnSessionLogState = async () => {
    if (!isAndroidClient) {
      return;
    }

    try {
      const res = await coreApi.getNextVpnSessionLogState();
      const data = res.data;
      setRecordNextVpnSessionLog(Boolean(data.enabled));
      if (!res.ok) {
        const nextError =
          (data as { error?: string }).error ?? t("unknownError");
        setNextVpnSessionLogError(nextError);
      } else {
        setNextVpnSessionLogError(null);
      }
    } catch (requestError) {
      const message =
        requestError instanceof Error
          ? requestError.message
          : t("unknownError");
      setNextVpnSessionLogError(message);
    }
  };

  const handleToggleNextVpnSessionLog = () => {
    if (!isAndroidClient || isBusy("toggleNextVpnLog")) {
      return;
    }

    const nextEnabled = !recordNextVpnSessionLog;
    setPendingAction("toggleNextVpnLog");
    setNextVpnSessionLogError(null);
    startTransition(async () => {
      try {
        const res = await coreApi.setNextVpnSessionLogState(nextEnabled);
        const data = res.data;
        setRecordNextVpnSessionLog(Boolean(data.enabled));
        if (!res.ok) {
          throw new Error(
            (data as { error?: string }).error ?? t("unknownError"),
          );
        }
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
        setNextVpnSessionLogError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleRunWhitelistDebugProbe = () => {
    if (!isAndroidClient || isBusy("runWhitelistDebugProbe")) {
      return;
    }

    const variants = buildWhitelistDebugProbeVariants();
    if (variants.length === 0) {
      setError(t("whitelistDebugProbeUnavailable"));
      return;
    }

    setError(null);
    setSuccessNotice(null);
    setWhitelistDebugProbeNotice(null);
    setPendingAction("runWhitelistDebugProbe");
    startTransition(async () => {
      const attempts: WhitelistDebugProbeAttempt[] = [];
      let winner: WhitelistDebugProbeAttempt | null = null;
      let probeFatalError: string | null = null;

      try {
        for (let variantIndex = 0; variantIndex < variants.length; variantIndex += 1) {
          const variant = variants[variantIndex];
          if (!variant) {
            continue;
          }
          const result = await runWhitelistDebugProbeVariant(
            variant,
            variantIndex,
            variants.length,
          );
          attempts.push(result.attempt);
          if (result.passed) {
            winner ??= result.attempt;
          }
        }

        if (!winner) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }
      } catch (requestError) {
        probeFatalError =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
      } finally {
        const fileName = buildWhitelistDebugProbeFileName();
        const logContents = renderWhitelistDebugProbeLog(
          attempts,
          variants,
          winner,
        );
        const exportRes = await coreApi.exportDebugLog(fileName, logContents);

        if (exportRes.ok) {
          setWhitelistDebugProbeNotice(
            `${t("saved")}: ${fileName}\n${exportRes.data.exportPath}`,
          );
        } else {
          const exportError = (exportRes.data as { error?: string }).error;
          setError(exportError ?? t("unknownError"));
        }

        if (probeFatalError) {
          setError(probeFatalError);
        } else if (winner) {
          setSuccessNotice(
            `${t("whitelistDebugProbeSucceeded")}: ${winner.label}`,
          );
        } else {
          setError(t("whitelistDebugProbeFailed"));
        }
        setPendingAction(null);
      }
    });
  };

  const loadSplitTunnelSelectionEffect = useEffectEvent(() => {
    void loadSplitTunnelSelection();
  });
  const loadInstalledAppsEffect = useEffectEvent(() => {
    void loadInstalledApps();
  });
  const loadNextVpnSessionLogStateEffect = useEffectEvent(() => {
    void loadNextVpnSessionLogState();
  });

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
      if (
        parsed.activeTab === "server" ||
        parsed.activeTab === "access" ||
        parsed.activeTab === "tunnel"
      ) {
        setActiveTab(parsed.activeTab);
      }
      if (parsed.activeAccessTab === "key") {
        setActiveAccessTab(parsed.activeAccessTab);
      }
      if (parsed.draft) {
        const normalizedTransportValue = normalizeTransport(
          parsed.draft.transport,
        );
        const normalizedProtocolValue = normalizeProtocol(
          parsed.draft.protocol,
        );
        const normalizedDraftProtocol =
          normalizedTransportValue === "xray" &&
          normalizedProtocolValue === "direct-wireguard"
            ? "vless-reality"
            : normalizedProtocolValue;
        setDraft({
          host: parsed.draft.host ?? initialDraft.host,
          port: parsed.draft.port ?? initialDraft.port,
          username: parsed.draft.username ?? initialDraft.username,
          authMethod: parsed.draft.authMethod ?? initialDraft.authMethod,
          transport: normalizedTransportValue,
          engine: resolveDraftEngine(
            normalizedTransportValue,
            normalizedDraftProtocol,
            parsed.draft.engine,
          ),
          protocol: normalizedDraftProtocol,
          vkTurnStreamCount: normalizeVkTurnStreamCount(
            parsed.draft.vkTurnStreamCount,
          ),
          vkTurnProxyPort: normalizePortHint(parsed.draft.vkTurnProxyPort),
          realityPort: normalizePortHint(parsed.draft.realityPort),
          yandexEdgeOriginPort: normalizePortHint(
            parsed.draft.yandexEdgeOriginPort,
          ),
        });
        if (
          parsed.accessMode === "vless-reality" ||
          parsed.accessMode === "yandex-edge" ||
          parsed.accessMode === "yandex-edge-proxy" ||
          parsed.accessMode === "vk-relay" ||
          parsed.accessMode === "relay-via-server" ||
          parsed.accessMode === "relay-direct"
        ) {
          setSelectedAccessMode(
            parsed.accessMode === "yandex-edge-proxy"
              ? "yandex-edge"
              : parsed.accessMode,
          );
        } else {
          setSelectedAccessMode(draftAccessMode(parsed.draft));
        }
        setDeployPortMode(
          parsed.deployPortMode === "manual" ||
            normalizePortHint(parsed.draft.vkTurnProxyPort) ||
            normalizePortHint(parsed.draft.realityPort) ||
            normalizePortHint(parsed.draft.yandexEdgeOriginPort)
            ? "manual"
            : "auto",
        );
        if (parsed.draft.host) {
          void fetchOwnerProfile(parsed.draft.host);
          void fetchImportedProfile(parsed.draft.host);
        }
      }
      if (parsed.edgeDraft) {
        setEdgeDraft({
          host: parsed.edgeDraft.host ?? initialEdgeDraft.host,
          port: parsed.edgeDraft.port ?? initialEdgeDraft.port,
          username: parsed.edgeDraft.username ?? initialEdgeDraft.username,
          authMethod:
            parsed.edgeDraft.authMethod === "private-key" ||
            parsed.edgeDraft.authMethod === "password"
              ? parsed.edgeDraft.authMethod
              : initialEdgeDraft.authMethod,
          secret: parsed.edgeDraft.secret ?? initialEdgeDraft.secret,
          publicPort:
            typeof parsed.edgeDraft.publicPort === "number" &&
            parsed.edgeDraft.publicPort > 0
              ? parsed.edgeDraft.publicPort
              : initialEdgeDraft.publicPort,
          routingMode: normalizeEdgeRoutingMode(parsed.edgeDraft.routingMode),
        });
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
      if (typeof parsed.whitelistIp === "string" && parsed.whitelistIp.trim()) {
        setWhitelistIp(parsed.whitelistIp);
      }
      if (parsed.validation) {
        setValidation(parsed.validation);
      }
    } catch {
      window.localStorage.removeItem(storageKey);
    }

    try {
      const savedOwnerRuntimeLab = window.localStorage.getItem(
        ownerRuntimeLabStorageKey,
      );
      if (savedOwnerRuntimeLab) {
        const parsed = JSON.parse(
          savedOwnerRuntimeLab,
        ) as Partial<OwnerRuntimeLabState>;
        setOwnerRuntimeLab({
          mode:
            parsed.mode === "reality-whitelist-scaffold" ||
            parsed.mode === "reality-whitelist-lab" ||
            parsed.mode === "reality-vps-scaffold" ||
            parsed.mode === "reality-vps-lab" ||
            parsed.mode === "reality-vps-relay-lab" ||
            parsed.mode === "reality-yandex-edge" ||
            parsed.mode === "reality-yandex-edge-proxy"
              ? parsed.mode
              : "off",
          hintServerName:
            parsed.hintServerName ?? defaultOwnerRuntimeLabState.hintServerName,
          hintCidrBucket:
            parsed.hintCidrBucket ?? defaultOwnerRuntimeLabState.hintCidrBucket,
          hintSource:
            parsed.hintSource ?? defaultOwnerRuntimeLabState.hintSource,
          hintTag: parsed.hintTag ?? defaultOwnerRuntimeLabState.hintTag,
          vpsServerName:
            parsed.vpsServerName ?? defaultOwnerRuntimeLabState.vpsServerName,
          vpsPort: parsed.vpsPort ?? defaultOwnerRuntimeLabState.vpsPort,
          vpsConnectHost:
            parsed.vpsConnectHost ??
            defaultOwnerRuntimeLabState.vpsConnectHost,
          vpsConnectPort:
            parsed.vpsConnectPort ??
            defaultOwnerRuntimeLabState.vpsConnectPort,
          vpsTransport:
            parsed.vpsTransport === "grpc"
              ? "grpc"
              : defaultOwnerRuntimeLabState.vpsTransport,
          vpsFlow: parsed.vpsFlow ?? defaultOwnerRuntimeLabState.vpsFlow,
          vpsFingerprint:
            parsed.vpsFingerprint ?? defaultOwnerRuntimeLabState.vpsFingerprint,
          vpsGrpcServiceName:
            parsed.vpsGrpcServiceName ??
            defaultOwnerRuntimeLabState.vpsGrpcServiceName,
          vpsGrpcAuthority:
            parsed.vpsGrpcAuthority ??
            defaultOwnerRuntimeLabState.vpsGrpcAuthority,
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
            parsed.vpsRelaySubscriptionUrl ??
            defaultOwnerRuntimeLabState.vpsRelaySubscriptionUrl,
          vpsRelaySourceLabel:
            parsed.vpsRelaySourceLabel ??
            defaultOwnerRuntimeLabState.vpsRelaySourceLabel,
        });
      }
    } catch {
      window.localStorage.removeItem(ownerRuntimeLabStorageKey);
    }

    if (
      window.localStorage.getItem(ownerRuntimeLabUnlockStorageKey) === "true"
    ) {
      setOwnerRuntimeLabUnlocked(true);
    }

    void fetchCoreHealth();
    void fetchSystemProxyStatus();
    pollLocalTunnel(true);
    void refreshMobileNetworkLens();
  }, []);

  useEffect(() => {
    if (!isAndroidClient) {
      return;
    }
    loadSplitTunnelSelectionEffect();
  }, [isAndroidClient]);

  useEffect(() => {
    if (
      !isAndroidClient ||
      activeSheet !== "apps" ||
      splitTunnelAppsLoaded ||
      splitTunnelAppsLoading
    ) {
      return;
    }
    loadInstalledAppsEffect();
  }, [
    activeSheet,
    isAndroidClient,
    splitTunnelAppsLoaded,
    splitTunnelAppsLoading,
  ]);

  useEffect(() => {
    if (!isAndroidClient || activeSheet !== "apps") {
      return;
    }
    loadNextVpnSessionLogStateEffect();
  }, [activeSheet, isAndroidClient]);

  useEffect(() => {
    if (typeof window === "undefined" || !isAndroidClient) {
      return;
    }
    if (
      localTunnel?.status !== "running" &&
      localTunnel?.status !== "starting"
    ) {
      return;
    }

    const intervalId = window.setInterval(
      () => {
        void pollLocalTunnel(true);
      },
      activeSheet === "logs" ? 4000 : 1500,
    );

    return () => window.clearInterval(intervalId);
  }, [activeSheet, isAndroidClient, localTunnel?.status]);

  useEffect(() => {
    if (!isAndroidClient) {
      setMobileNetworkLens(null);
      return;
    }
    void refreshMobileNetworkLens(true);
  }, [
    activeFrontTunnelHost,
    activeYandexTunnelHost,
    isAndroidClient,
    localTunnel?.activationState,
    localTunnel?.frontConnectHost,
    localTunnel?.runtimeFamily,
    localTunnel?.status,
    resolvedDraftHost,
    selectedAccessMode,
    selectedModeUsesStandalonePublicRelay,
  ]);

  useEffect(() => {
    if (!isAndroidClient || !error) {
      return;
    }

    const normalizedError = error.trim();
    const startupWarningVisible =
      normalizedError === androidTunnelStartingWarning ||
      normalizedError === t("tunnelStartFailed");
    if (!startupWarningVisible) {
      return;
    }

    if (
      androidTunnelOperational ||
      (androidVkRelayWarmupPending && Boolean(pendingVkCaptchaUrl))
    ) {
      setError(null);
    }
  }, [
    androidTunnelOperational,
    androidVkRelayWarmupPending,
    error,
    isAndroidClient,
    pendingVkCaptchaUrl,
    t,
  ]);

  useEffect(() => {
    if (!isAndroidClient) {
      return;
    }

    const intervalId = window.setInterval(() => {
      void refreshMobileNetworkLens(true);
    }, 30000);

    return () => window.clearInterval(intervalId);
  }, [
    activeYandexTunnelHost,
    isAndroidClient,
    resolvedDraftHost,
    selectedAccessMode,
  ]);

  useEffect(() => {
    onNetworkLensChange?.(mobileNetworkLens);
  }, [mobileNetworkLens, onNetworkLensChange]);

  useEffect(() => {
    if (!isAndroidClient) {
      return;
    }
    if (
      !localTunnel ||
      localTunnel.status === "idle" ||
      localTunnel.status === "stopped" ||
      localTunnel.status === "failed"
    ) {
      setAndroidVpnVisualOverride(false);
    }
  }, [isAndroidClient, localTunnel]);

  useEffect(() => {
    if (selectedAccessMode === "yandex-edge-proxy") {
      setSelectedAccessMode("yandex-edge");
      return;
    }
    if (
      selectedAccessMode === "yandex-edge" &&
      !(
        protocolEntryById.has("vless-reality-yandex-edge-proxy") ||
        localProfileOffersYandexEdge
      )
    ) {
      setSelectedAccessMode("vless-reality");
      return;
    }
    if (selectedAccessModeCard.available) {
      return;
    }
    setSelectedAccessMode("vless-reality");
  }, [
    importedProfileOffersYandexEdge,
    localProfileOffersYandexEdge,
    protocolEntryById,
    selectedAccessMode,
    selectedAccessModeCard.available,
  ]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const snapshot: PersistedState = {
      activeTab,
      activeAccessTab,
      accessMode: selectedAccessMode,
      draft,
      edgeDraft,
      deployPortMode,
      secret,
      vkLink,
      whitelistIp,
      validation,
      importedProfile,
    };
    window.localStorage.setItem(storageKey, JSON.stringify(snapshot));
  }, [
    activeAccessTab,
    activeTab,
    deployPortMode,
    draft,
    edgeDraft,
    importedProfile,
    secret,
    selectedAccessMode,
    validation,
    whitelistIp,
    vkLink,
  ]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(
      ownerRuntimeLabStorageKey,
      JSON.stringify(ownerRuntimeLab),
    );
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

  const buildProvisionPayload = (
    flow: ProvisionFlow = "origin",
  ): {
    server: ServerDraft;
    secret: string;
    flow: ProvisionFlow;
    edge?: EdgeAttachDraft;
  } => {
    if (flow === "edge-attach") {
      return {
        server: draft,
        secret,
        flow,
        edge: {
          enabled: true,
          provider: "yandex-edge",
          server: {
            host: edgeDraft.host,
            port: edgeDraft.port,
            username: edgeDraft.username,
            authMethod: edgeDraft.authMethod,
          },
          secret: edgeDraft.secret,
          publicPort: edgeDraft.publicPort,
          routingMode: normalizeEdgeRoutingMode(edgeDraft.routingMode),
        },
      };
    }

    return {
      server: draft,
      secret,
      flow,
    };
  };

  const handleValidate = (flow: ProvisionFlow = "origin") => {
    setError(null);
    startTransition(async () => {
      try {
        const payload = buildProvisionPayload(flow);
        console.info("[provision] validate request", {
          flow,
          host: payload.server.host,
          user: payload.server.username,
          edgeEnabled: payload.edge?.enabled ?? false,
          edgeHost: payload.edge?.server.host ?? "",
          edgePort: payload.edge?.publicPort ?? 0,
        });
        const validateRes = await coreApi.validateProvision(payload);
        const validateData = validateRes.data;
        console.info("[provision] validate response", {
          requestedFlow: flow,
          resolvedFlow: validateData?.deployFlow ?? "",
          ok: validateData?.ok ?? false,
          error: validateData?.error ?? "",
        });
        setValidation(validateData);

        const planRes = await coreApi.getProvisionPlan(payload);
        const planData = planRes.data;
        setPlan(planData.steps ?? []);

        if (validateData.error) {
          setError(validateData.error);
        }
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : "Unknown error";
        setError(message);
      }
    });
  };

  const handleDeploy = (flow: ProvisionFlow = "origin") => {
    setError(null);
    setSuccessNotice(null);
    startTransition(async () => {
      try {
        const payload = buildProvisionPayload(flow);
        console.info("[provision] deploy request", {
          flow,
          host: payload.server.host,
          user: payload.server.username,
          edgeEnabled: payload.edge?.enabled ?? false,
          edgeHost: payload.edge?.server.host ?? "",
          edgePort: payload.edge?.publicPort ?? 0,
        });
        const deployRes = await coreApi.startDeployment(payload);
        const deployData = deployRes.data;
        console.info("[provision] deploy response", {
          requestedFlow: flow,
          resolvedFlow: deployData?.deployFlow ?? "",
          deploymentId: deployData?.deploymentId ?? "",
          status: deployData?.status ?? "",
          error: deployData?.error ?? "",
        });
        setDeployment(deployData);
        setPlan(deployData.steps);
        setShowDeploymentOverlay(true);

        if (!deployRes.ok) {
          setError(t("deployStartFailed"));
          return;
        }

        const timer = window.setInterval(async () => {
          const statusRes = await coreApi.getDeployment(
            deployData.deploymentId,
          );
          const statusData = statusRes.data;
          setDeployment(statusData);
          setPlan(statusData.steps);
          if (statusData.status === "done" || statusData.status === "failed") {
            window.clearInterval(timer);
            setShowDeploymentOverlay(false);
            if (statusData.status === "done") {
              setGuestProfile(null);
              setSuccessNotice(
                flow === "edge-attach"
                  ? t("edgeAttachSuccess")
                  : t("deploySuccess"),
              );
              void fetchOwnerProfile(draft.host);
            } else if (statusData.error) {
              setError(statusData.error);
            }
          }
        }, 1200);
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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

  const refreshMobileNetworkLens = async (quiet = false) => {
    if (!isAndroidClient) {
      setMobileNetworkLens(null);
      return null;
    }

    const originHost = selectedModeUsesStandalonePublicRelay
      ? ""
      : resolvedDraftHost.trim();
    const tunnelHost = activeFrontTunnelHost;
    if (!originHost && !tunnelHost) {
      setMobileNetworkLens(null);
      return null;
    }

    try {
      const result = await coreApi.inspectMobileNetworkLens({
        originHost,
        ...(tunnelHost ? { tunnelHost } : {}),
        cellularOnly: true,
      });
      const data = result.data;
      if (data) {
        setMobileNetworkLens(data);
      } else if (!quiet) {
        setMobileNetworkLens(null);
      }
      return data ?? null;
    } catch {
      if (!quiet) {
        setMobileNetworkLens(null);
      }
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
    if (res.ok && typeof data.vkTurnStreamCount === "number") {
      setDraft((current) =>
        current.host.trim() === host.trim() && current.vkTurnStreamCount == null
          ? {
              ...current,
              vkTurnStreamCount: normalizeVkTurnStreamCount(
                data.vkTurnStreamCount,
              ),
            }
          : current,
      );
    }
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

  const handleCheckWhitelistIp = () => {
    startTransition(() => {
      setPendingAction("checkWhitelist");
      setWhitelistLookupError(null);
      void coreApi
        .checkWhitelistIp(whitelistIp)
        .then((res) => {
          if (!res.ok) {
            setWhitelistLookup(null);
            setWhitelistLookupError(res.data.error ?? t("unknownError"));
            return;
          }
          setWhitelistLookup(res.data);
        })
        .catch((requestError) => {
          const message =
            requestError instanceof Error
              ? requestError.message
              : t("unknownError");
          setWhitelistLookup(null);
          setWhitelistLookupError(message);
        })
        .finally(() => {
          setPendingAction(null);
        });
    });
  };

  const applyImportedProfile = (profile: InviteProfile) => {
    const importedTransport = normalizeTransport(profile.transport);
    const importedProtocol = normalizeInviteProtocol(profile.protocol);
    setGuestProfile(null);
    setImportedProfile(profile);
    setSelectedAccessMode(
      importedProfilePrefersCdnYandexMode(profile)
        ? "yandex-edge"
        : importedProfilePrefersYandexEdgeMode(profile)
          ? "yandex-edge"
        : draftAccessMode({
            ...initialDraft,
            transport: importedTransport,
            protocol: importedProtocol,
          }),
    );
    setDraft((current) => ({
      ...current,
      host: profile.serverHost || current.host,
      transport: importedTransport,
      engine: resolveDraftEngine(
        importedTransport,
        importedProtocol,
        current.engine,
      ),
      protocol: importedProtocol,
      vkTurnStreamCount:
        normalizeVkTurnStreamCount(profile.vkTurnStreamCount) ??
        current.vkTurnStreamCount,
    }));
    setSecret("");
  };

  const resolveRuntimeIdentity = (
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest,
    runtimeIdentityOverride?: RuntimeIdentity,
  ) => {
    if (runtimeIdentityOverride) {
      return runtimeIdentityOverride;
    }
    const transport = normalizeTransport(serverDraft.transport);
    const protocol =
      transport === "xray"
        ? normalizeProtocol(serverDraft.protocol)
        : "direct-wireguard";
    if (transport === "vk-turn-proxy+xray") {
      return { runtimeFamily: "vk-relay", activationState: "active" };
    }
    if (transport === "xray" && protocol === "vless-reality") {
      if (ownerRuntimeLabRequest?.mode === "reality-yandex-edge") {
        return { runtimeFamily: "reality-vps-lab", activationState: "active" };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-yandex-edge-proxy") {
        return {
          runtimeFamily: "cdn-anti-whitelist",
          activationState: "active",
        };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-vps-scaffold") {
        return {
          runtimeFamily: "reality-vps-lab",
          activationState: "scaffold_only",
        };
      }
      if (
        ownerRuntimeLabRequest?.mode === "reality-vps-lab" ||
        ownerRuntimeLabRequest?.mode === "reality-vps-relay-lab"
      ) {
        return { runtimeFamily: "reality-vps-lab", activationState: "active" };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-whitelist-scaffold") {
        return {
          runtimeFamily: "reality-whitelist-assisted",
          activationState: "scaffold_only",
        };
      }
      if (ownerRuntimeLabRequest?.mode === "reality-whitelist-lab") {
        return {
          runtimeFamily: "reality-whitelist-assisted",
          activationState: "active",
        };
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
      requireYandexEdgeSupport?: boolean;
      forceRelayAutoselectDefaults?: boolean;
      allowSyntheticRelayProfile?: boolean;
    },
  ) => {
    const allowImportedProfileForOwnerRuntimeLab =
      options?.allowImportedProfileForOwnerRuntimeLab ?? false;
    const requireRelaySupport = options?.requireRelaySupport ?? false;
    const requireYandexEdgeSupport =
      options?.requireYandexEdgeSupport ?? false;
    const forceRelayAutoselectDefaults =
      options?.forceRelayAutoselectDefaults ?? false;
    const allowSyntheticRelayProfile =
      options?.allowSyntheticRelayProfile ?? false;
    const effectiveOwnerRuntimeLab =
      allowImportedProfileForOwnerRuntimeLab &&
      forceRelayAutoselectDefaults &&
      (ownerRuntimeLabMode === "reality-vps-relay-lab" ||
        ownerRuntimeLabMode === "reality-vps-lab")
        ? withIgareckRelayDefaults(ownerRuntimeLab)
        : ownerRuntimeLab;
    const effectiveBaseDraft: ServerDraft =
      ownerRuntimeLabMode === "off"
        ? baseDraft
        : {
            ...baseDraft,
            transport: "xray",
            engine: "sing-box",
            protocol: "vless-reality",
          };
    const normalizedHost =
      effectiveBaseDraft.host.trim() ||
      importedProfile?.serverHost?.trim() ||
      ownerProfile?.serverHost?.trim() ||
      (allowSyntheticRelayProfile ? "public-relay.local" : "");
    const ownerProfileAvailable = Boolean(
      (requireYandexEdgeSupport
        ? ownerProfileSupportsYandexEdgeMode(ownerProfile, effectiveBaseDraft)
        : requireRelaySupport
          ? ownerProfileSupportsRelayMode(ownerProfile, effectiveBaseDraft)
          : ownerProfileSupportsDraft(ownerProfile, effectiveBaseDraft)) &&
      hostsMatch(normalizedHost, ownerProfile?.serverHost),
    );
    const importedProfileAvailable = Boolean(
      importedProfileMatchesHost(importedProfile, normalizedHost) &&
      (requireYandexEdgeSupport
        ? importedProfileSupportsYandexEdgeMode(
            importedProfile,
            effectiveBaseDraft,
          )
        : requireRelaySupport
          ? importedProfileSupportsRelayMode(
              importedProfile,
              effectiveBaseDraft,
            )
          : importedProfileSupportsDraft(importedProfile, effectiveBaseDraft)),
    );
    const usingImportedProfile = Boolean(
      (ownerRuntimeLabMode === "off" ||
        allowImportedProfileForOwnerRuntimeLab) &&
      importedProfileAvailable &&
      !secret.trim() &&
      !ownerProfileAvailable,
    );
    const usingSyntheticRelayProfile = Boolean(
      allowSyntheticRelayProfile &&
        ownerRuntimeLabMode === "reality-vps-lab" &&
        !ownerProfileAvailable &&
        !usingImportedProfile,
    );
    const serverDraft: ServerDraft =
      usingImportedProfile && importedProfile
        ? {
            ...effectiveBaseDraft,
            host:
              importedProfile.serverHost || normalizedHost || baseDraft.host,
            engine: resolveDraftEngine(
              effectiveBaseDraft.transport,
              effectiveBaseDraft.protocol,
              effectiveBaseDraft.engine,
            ),
          }
        : {
            ...effectiveBaseDraft,
            host: normalizedHost || baseDraft.host,
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
      ownerRuntimeLabMode === "reality-vps-relay-lab" ||
      ownerRuntimeLabMode === "reality-yandex-edge" ||
      ownerRuntimeLabMode === "reality-yandex-edge-proxy"
    ) {
      if (!isAndroidClient) {
        throw new Error(t("ownerLabAndroidOnly"));
      }
      if (
        !ownerProfileAvailable &&
        !usingImportedProfile &&
        !usingSyntheticRelayProfile
      ) {
        throw new Error(
          allowImportedProfileForOwnerRuntimeLab
            ? t("ownerLabNeedsAccessProfile")
            : t("ownerLabNeedsOwnerProfile"),
        );
      }
      if (ownerRuntimeLabMode === "reality-yandex-edge") {
        const yandexEdgeFallback = resolvedYandexEdgeFallback;
        ownerRuntimeLabRequest = {
          mode: ownerRuntimeLabMode,
          hintServerName: "",
          vpsServerName:
            yandexEdgeFallback?.serverName?.trim() || "www.cloudflare.com",
          vpsPort:
            yandexEdgeFallback?.originPort ??
            ownerProfile?.vlessReality?.port ??
            importedProfile?.vlessReality?.port ??
            52443,
          vpsConnectHost:
            yandexEdgeFallback?.connectHost ?? yandexEdgeConnectHost,
          vpsConnectPort:
            yandexEdgeFallback?.connectPort ?? yandexEdgeConnectPort,
          vpsTransport: "tcp",
          vpsFlow: yandexEdgeFallback?.flow?.trim() || "xtls-rprx-vision",
          vpsFingerprint:
            yandexEdgeFallback?.fingerprint?.trim() || "chrome",
          vpsSource: yandexEdgeFallback?.source || yandexEdgeSource,
          vpsTag: yandexEdgeFallback?.tag || yandexEdgeTag,
        };
      } else if (ownerRuntimeLabMode === "reality-yandex-edge-proxy") {
        const yandexEdgeProxyFallback = resolvedYandexEdgeProxyFallback;
        ownerRuntimeLabRequest = {
          mode: ownerRuntimeLabMode,
          hintServerName: "",
          vpsServerName:
            yandexEdgeProxyFallback?.serverName?.trim() ||
            "www.cloudflare.com",
          vpsPort:
            yandexEdgeProxyFallback?.originPort ??
            ownerProfile?.vlessReality?.port ??
            importedProfile?.vlessReality?.port ??
            52443,
          vpsConnectHost:
            yandexEdgeProxyFallback?.connectHost ?? yandexEdgeConnectHost,
          vpsConnectPort:
            yandexEdgeProxyFallback?.connectPort ?? yandexEdgeConnectPort,
          vpsTransport: "tcp",
          vpsFlow:
            yandexEdgeProxyFallback?.flow?.trim() || "xtls-rprx-vision",
          vpsFingerprint:
            yandexEdgeProxyFallback?.fingerprint?.trim() || "chrome",
          vpsSource:
            yandexEdgeProxyFallback?.source || `${yandexEdgeSource}:proxy`,
          vpsTag: yandexEdgeProxyFallback?.tag || `${yandexEdgeTag}-proxy`,
          vpsOwnerRealityEgress: false,
        };
      } else if (isOwnerRuntimeLabVpsMode(ownerRuntimeLabMode)) {
        const usingRelayOwnerMode =
          isOwnerRuntimeLabRelayOwnerMode(ownerRuntimeLabMode);
        const usingRelayAutoselect =
          usingRelayOwnerMode || effectiveOwnerRuntimeLab.vpsUseRelayAutoselect;
        const vpsServerName =
          effectiveOwnerRuntimeLab.vpsServerName.trim().toLowerCase() ||
          (usingRelayAutoselect ? "id.x5.ru" : "");
        if (!vpsServerName) {
          throw new Error(t("ownerLabVpsServerRequired"));
        }
        const parsedVpsPort = Number.parseInt(
          effectiveOwnerRuntimeLab.vpsPort,
          10,
        );
        const vpsPort =
          Number.isInteger(parsedVpsPort) &&
          parsedVpsPort > 0 &&
          parsedVpsPort <= 65535
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
          ...(effectiveOwnerRuntimeLab.vpsConnectHost.trim()
            ? { vpsConnectHost: effectiveOwnerRuntimeLab.vpsConnectHost.trim() }
            : {}),
          ...(Number.isInteger(
            Number.parseInt(effectiveOwnerRuntimeLab.vpsConnectPort, 10),
          ) &&
          Number.parseInt(effectiveOwnerRuntimeLab.vpsConnectPort, 10) > 0 &&
          Number.parseInt(effectiveOwnerRuntimeLab.vpsConnectPort, 10) <= 65535
            ? {
                vpsConnectPort: Number.parseInt(
                  effectiveOwnerRuntimeLab.vpsConnectPort,
                  10,
                ),
              }
            : {}),
          vpsTransport: usingRelayAutoselect
            ? "tcp"
            : effectiveOwnerRuntimeLab.vpsTransport,
          ...(effectiveOwnerRuntimeLab.vpsFlow.trim() || usingRelayAutoselect
            ? {
                vpsFlow:
                  effectiveOwnerRuntimeLab.vpsFlow.trim() || "xtls-rprx-vision",
              }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsFingerprint.trim() ||
          usingRelayAutoselect
            ? {
                vpsFingerprint:
                  effectiveOwnerRuntimeLab.vpsFingerprint.trim() || "chrome",
              }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsGrpcServiceName.trim()
            ? {
                vpsGrpcServiceName:
                  effectiveOwnerRuntimeLab.vpsGrpcServiceName.trim(),
              }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsGrpcAuthority.trim()
            ? {
                vpsGrpcAuthority:
                  effectiveOwnerRuntimeLab.vpsGrpcAuthority.trim(),
              }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsSource.trim()
            ? { vpsSource: effectiveOwnerRuntimeLab.vpsSource.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.vpsTag.trim()
            ? { vpsTag: effectiveOwnerRuntimeLab.vpsTag.trim() }
            : {}),
          ...(usingRelayOwnerMode ? { vpsOwnerRealityEgress: true } : {}),
          ...(usingRelayAutoselect
            ? {
                vpsRelayAutoselect: {
                  enabled: true,
                  ...(effectiveOwnerRuntimeLab.vpsRelaySubscriptionUrl.trim()
                    ? {
                        subscriptionUrl:
                          effectiveOwnerRuntimeLab.vpsRelaySubscriptionUrl.trim(),
                      }
                    : {}),
                  ...(effectiveOwnerRuntimeLab.vpsRelaySourceLabel.trim()
                    ? {
                        sourceLabel:
                          effectiveOwnerRuntimeLab.vpsRelaySourceLabel.trim(),
                      }
                    : {}),
                },
              }
            : {}),
        };
      } else {
        const hintServerName = effectiveOwnerRuntimeLab.hintServerName
          .trim()
          .toLowerCase();
        if (!hintServerName) {
          throw new Error(t("ownerLabHintServerRequired"));
        }
        ownerRuntimeLabRequest = {
          mode: ownerRuntimeLabMode,
          hintServerName,
          ...(effectiveOwnerRuntimeLab.hintCidrBucket.trim()
            ? { hintCidrBucket: effectiveOwnerRuntimeLab.hintCidrBucket.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.hintSource.trim()
            ? { hintSource: effectiveOwnerRuntimeLab.hintSource.trim() }
            : {}),
          ...(effectiveOwnerRuntimeLab.hintTag.trim()
            ? { hintTag: effectiveOwnerRuntimeLab.hintTag.trim() }
            : {}),
        };
      }
    }
    return {
      serverDraft,
      useRealityStartEndpoint,
      usingImportedProfile,
      excludePackages: splitTunnelExcludePackages,
      ownerRuntimeLabRequest,
      runtimeIdentityOverride: undefined as RuntimeIdentity | undefined,
    };
  };

  const buildCurrentTunnelStartRequest = (baseDraft: ServerDraft = draft) => {
    const importedProfileUsesCdnYandexEdge =
      !secret.trim() &&
      importedProfileMatchesHost(
        importedProfile,
        baseDraft.host || resolvedDraftHost,
      ) &&
      importedProfileHasCdnAntiWhitelist(importedProfile);
    const importedProfileSupportsCurrentYandexEdge =
      !secret.trim() &&
      importedProfileMatchesHost(
        importedProfile,
        baseDraft.host || resolvedDraftHost,
      ) &&
      importedProfileHasCurrentYandexEdge(importedProfile);
    const ownerProfileUsesCdnYandexEdge =
      !secret.trim() &&
      hostsMatch(baseDraft.host || resolvedDraftHost, ownerProfile?.serverHost) &&
      ownerProfileHasCdnAntiWhitelist(ownerProfile);
    const ownerProfileSupportsCurrentYandexEdge =
      !secret.trim() &&
      hostsMatch(baseDraft.host || resolvedDraftHost, ownerProfile?.serverHost) &&
      ownerProfileHasCurrentYandexEdge(ownerProfile);
    const localProfileUsesCdnYandexEdge =
      importedProfileUsesCdnYandexEdge ||
      importedProfileSupportsCurrentYandexEdge ||
      ownerProfileUsesCdnYandexEdge ||
      ownerProfileSupportsCurrentYandexEdge;
    if (selectedAccessMode === "vless-reality") {
      if (importedProfileUsesCdnYandexEdge) {
        return {
          ...buildTunnelStartRequest(baseDraft),
          runtimeIdentityOverride: {
            runtimeFamily: "direct-reality",
            activationState: "active",
          },
        };
      }
      return buildTunnelStartRequest(baseDraft);
    }
    if (selectedAccessMode === "yandex-edge") {
      return buildTunnelStartRequest(baseDraft, "reality-yandex-edge", {
        allowImportedProfileForOwnerRuntimeLab: true,
        requireYandexEdgeSupport: true,
      });
    }
    if (selectedAccessMode === "yandex-edge-proxy") {
      if (localProfileUsesCdnYandexEdge) {
        return {
          ...buildTunnelStartRequest(baseDraft),
          runtimeIdentityOverride: {
            runtimeFamily: "cdn-anti-whitelist",
            activationState: "active",
          },
        };
      }
      return buildTunnelStartRequest(baseDraft, "reality-yandex-edge-proxy", {
        allowImportedProfileForOwnerRuntimeLab: true,
        requireYandexEdgeSupport: true,
      });
    }
    if (selectedAccessMode === "relay-via-server") {
      return buildTunnelStartRequest(baseDraft, "reality-vps-relay-lab", {
        allowImportedProfileForOwnerRuntimeLab: true,
        requireRelaySupport: true,
        forceRelayAutoselectDefaults: true,
      });
    }
    if (selectedAccessMode === "relay-direct") {
      return buildTunnelStartRequest(baseDraft, "reality-vps-lab", {
        allowImportedProfileForOwnerRuntimeLab: true,
        forceRelayAutoselectDefaults: true,
        allowSyntheticRelayProfile: true,
      });
    }
    return buildTunnelStartRequest(baseDraft);
  };

  const buildWhitelistDebugProbeVariants = (
    baseDraft: ServerDraft = draft,
  ): WhitelistDebugProbeVariant[] => {
    const variants: WhitelistDebugProbeVariant[] = [];
    const realityProbeCandidates = [
      {
        id: "reality-sni-max-ru",
        serverName: "max.ru",
        label: t("whitelistDebugProbeVariantMaxRu"),
        description: t("whitelistDebugProbeVariantMaxRuText"),
      },
      {
        id: "reality-sni-vkvideo-ru",
        serverName: "vkvideo.ru",
        label: t("whitelistDebugProbeVariantVkVideoRu"),
        description: t("whitelistDebugProbeVariantVkVideoRuText"),
      },
      {
        id: "reality-sni-ads-x5-ru",
        serverName: "ads.x5.ru",
        label: t("whitelistDebugProbeVariantAdsX5Ru"),
        description: t("whitelistDebugProbeVariantAdsX5RuText"),
      },
      {
        id: "reality-sni-ya-ru",
        serverName: "ya.ru",
        label: t("whitelistDebugProbeVariantYaRu"),
        description: t("whitelistDebugProbeVariantYaRuText"),
      },
      {
        id: "reality-sni-yandex-net",
        serverName: "yandex.net",
        label: t("whitelistDebugProbeVariantYandexNet"),
        description: t("whitelistDebugProbeVariantYandexNetText"),
      },
    ];

    if (hasLocalYandexEdgeAccessProfile) {
      variants.push({
        id: "reality-yandex-edge",
        label: t("whitelistDebugProbeVariantRealityEdge"),
        description: t("whitelistDebugProbeVariantRealityEdgeText"),
        resolve: () =>
          buildTunnelStartRequest(baseDraft, "reality-yandex-edge", {
            allowImportedProfileForOwnerRuntimeLab: true,
            requireYandexEdgeSupport: true,
          }),
      });
      variants.push({
        id: "reality-yandex-edge-proxy",
        label: t("whitelistDebugProbeVariantProxyEdge"),
        description: t("whitelistDebugProbeVariantProxyEdgeText"),
        resolve: () =>
          buildTunnelStartRequest(baseDraft, "reality-yandex-edge-proxy", {
            allowImportedProfileForOwnerRuntimeLab: true,
            requireYandexEdgeSupport: true,
          }),
      });
    }

    if (hasLocalAccessProfile) {
      variants.push({
        id: "direct-reality",
        label: t("whitelistDebugProbeVariantDirectReality"),
        description: t("whitelistDebugProbeVariantDirectRealityText"),
        resolve: () => buildTunnelStartRequest(baseDraft),
      });
    }

    if (hasLocalYandexEdgeAccessProfile) {
      for (const candidate of realityProbeCandidates) {
        variants.push({
          id: candidate.id,
          label: candidate.label,
          description: candidate.description,
          resolve: () => ({
            ...buildTunnelStartRequest(baseDraft, "reality-yandex-edge", {
              allowImportedProfileForOwnerRuntimeLab: true,
              requireYandexEdgeSupport: true,
            }),
            ownerRuntimeLabRequest: {
              mode: "reality-yandex-edge",
              hintServerName: "",
              edgeServerName: candidate.serverName,
            },
          }),
        });
      }
    }

    return variants.filter(
      (variant, index, list) =>
        list.findIndex((entry) => entry.id === variant.id) === index,
    );
  };

  const buildWhitelistDebugProbeFileName = () => {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    return `whitelist-probe-${stamp}.log.txt`;
  };

  const renderWhitelistDebugProbeLog = (
    attempts: WhitelistDebugProbeAttempt[],
    variants: WhitelistDebugProbeVariant[],
    winner: WhitelistDebugProbeAttempt | null,
  ) =>
    [
      `timestamp=${new Date().toISOString()}`,
      `host=${resolvedDraftHost}`,
      `networkType=${mobileNetworkLens?.networkType ?? "unknown"}`,
      `whitelistStatus=${mobileNetworkLens?.whitelistStatus ?? "unknown"}`,
      `variantCount=${variants.length}`,
      `winner=${winner?.id ?? ""}`,
      "",
      ...attempts.flatMap((attempt, index) => [
        `attempt=${index + 1}`,
        `id=${attempt.id}`,
        `label=${attempt.label}`,
        `description=${attempt.description}`,
        `startedAt=${attempt.startedAt}`,
        `finishedAt=${attempt.finishedAt}`,
        `runtimeFamily=${attempt.runtimeFamily}`,
        `activationState=${attempt.activationState}`,
        `ownerRuntimeLabMode=${attempt.ownerRuntimeLabMode}`,
        `status=${attempt.status}`,
        `passed=${attempt.passed}`,
        `selectedSniHint=${attempt.selectedSniHint ?? ""}`,
        `frontTag=${attempt.frontTag ?? ""}`,
        `lastTestStatus=${attempt.lastTestStatus ?? ""}`,
        `lastTestError=${attempt.lastTestError ?? ""}`,
        `runtimeError=${attempt.runtimeError ?? ""}`,
        "",
      ]),
    ].join("\n");

  const runningTunnelMatchesRequest = (
    tunnel: LocalTunnelState | null,
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest,
    excludePackages: string[] = splitTunnelExcludePackages,
    runtimeIdentityOverride?: RuntimeIdentity,
  ) => {
    if (!tunnel || tunnel.status !== "running" || !tunnel.socksAddress) {
      return false;
    }
    const expectedHost = serverDraft.host?.trim();
    const expectedTransport = normalizeTransport(serverDraft.transport);
    const expectedProtocol = normalizeProtocol(serverDraft.protocol);
    const expectedRuntimeIdentity = resolveRuntimeIdentity(
      serverDraft,
      ownerRuntimeLabRequest,
      runtimeIdentityOverride,
    );
    if (
      expectedHost &&
      tunnel.serverHost &&
      tunnel.serverHost !== expectedHost
    ) {
      return false;
    }
    if (
      tunnel.transport !== expectedTransport ||
      normalizeProtocol(tunnel.protocol) !== expectedProtocol
    ) {
      return false;
    }
    if (
      expectedRuntimeIdentity.runtimeFamily &&
      tunnel.runtimeFamily &&
      tunnel.runtimeFamily !== expectedRuntimeIdentity.runtimeFamily
    ) {
      return false;
    }
    if (
      expectedRuntimeIdentity.activationState &&
      tunnel.activationState &&
      tunnel.activationState !== expectedRuntimeIdentity.activationState
    ) {
      return false;
    }
    if (!samePackageSelection(tunnel.excludePackages, excludePackages)) {
      return false;
    }
    return true;
  };

  const pollLocalTunnel = (immediate = false) => {
    const run = async () => {
      try {
        const [tunnelRes, proxyRes] = await Promise.all([
          coreApi.getLocalTunnelStatus(),
          coreApi.getSystemProxyStatus(),
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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

  const sleep = (ms: number) =>
    new Promise((resolve) => window.setTimeout(resolve, ms));

  const withTimeout = async <T,>(
    promise: Promise<T>,
    timeoutMs: number,
    errorMessage: string,
  ) => {
    let timeoutId: number | null = null;
    try {
      return await Promise.race([
        promise,
        new Promise<T>((_, reject) => {
          timeoutId = window.setTimeout(() => {
            reject(new Error(errorMessage));
          }, timeoutMs);
        }),
      ]);
    } finally {
      if (timeoutId !== null) {
        window.clearTimeout(timeoutId);
      }
    }
  };

  const waitForRunningTunnel = async (attempts = 18, delayMs = 1000) => {
    let tunnelData = await pollLocalTunnel(true);
    if (tunnelData?.status === "running" && tunnelData.socksAddress) {
      return tunnelData;
    }
    if (
      tunnelData &&
      (tunnelData.status === "failed" || tunnelData.status === "stopped")
    ) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (tunnelData?.status === "running" && tunnelData.socksAddress) {
        return tunnelData;
      }
      if (
        tunnelData &&
        (tunnelData.status === "failed" || tunnelData.status === "stopped")
      ) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const waitForStoppedTunnel = async (attempts = 20, delayMs = 300) => {
    let tunnelData = await pollLocalTunnel(true);
    if (
      !tunnelData ||
      tunnelData.status === "stopped" ||
      tunnelData.status === "idle" ||
      tunnelData.status === "failed"
    ) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (
        !tunnelData ||
        tunnelData.status === "stopped" ||
        tunnelData.status === "idle" ||
        tunnelData.status === "failed"
      ) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const waitForTunnelIdentity = async (
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest,
    excludePackages: string[] = splitTunnelExcludePackages,
    attempts = 18,
    delayMs = 700,
  ) => {
    const expectedRuntimeIdentity = resolveRuntimeIdentity(
      serverDraft,
      ownerRuntimeLabRequest,
    );
    let tunnelData = await pollLocalTunnel(true);
    if (
      runningTunnelMatchesRequest(
        tunnelData,
        serverDraft,
        ownerRuntimeLabRequest,
        excludePackages,
      )
    ) {
      return tunnelData;
    }
    if (
      tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
      tunnelData.activationState === expectedRuntimeIdentity.activationState
    ) {
      return tunnelData;
    }
    if (
      tunnelData &&
      (tunnelData.status === "failed" || tunnelData.status === "stopped")
    ) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (
        runningTunnelMatchesRequest(
          tunnelData,
          serverDraft,
          ownerRuntimeLabRequest,
          excludePackages,
        )
      ) {
        return tunnelData;
      }
      if (
        tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
        tunnelData.activationState === expectedRuntimeIdentity.activationState
      ) {
        return tunnelData;
      }
      if (
        tunnelData &&
        (tunnelData.status === "failed" || tunnelData.status === "stopped")
      ) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const waitForProbeReadyTunnel = async (
    serverDraft: ServerDraft,
    ownerRuntimeLabRequest?: OwnerRuntimeLabRequest,
    excludePackages: string[] = splitTunnelExcludePackages,
    runtimeIdentityOverride?: RuntimeIdentity,
    attempts = 24,
    delayMs = 900,
  ) => {
    const expectedRuntimeIdentity = resolveRuntimeIdentity(
      serverDraft,
      ownerRuntimeLabRequest,
      runtimeIdentityOverride,
    );
    let tunnelData = await pollLocalTunnel(true);

    const probeReady = (tunnel: LocalTunnelState | null) =>
      runningTunnelMatchesRequest(
        tunnel,
        serverDraft,
        ownerRuntimeLabRequest,
        excludePackages,
        runtimeIdentityOverride,
      );

    const sameIdentity =
      tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
      tunnelData.activationState === expectedRuntimeIdentity.activationState;

    if (probeReady(tunnelData)) {
      return tunnelData;
    }
    if (
      sameIdentity &&
      tunnelData?.status === "running" &&
      tunnelData.socksAddress
    ) {
      return tunnelData;
    }
    if (
      tunnelData &&
      (tunnelData.status === "failed" || tunnelData.status === "stopped")
    ) {
      return tunnelData;
    }

    for (let i = 0; i < attempts; i += 1) {
      await sleep(delayMs);
      tunnelData = await pollLocalTunnel(true);
      if (probeReady(tunnelData)) {
        return tunnelData;
      }
      if (
        tunnelData?.runtimeFamily === expectedRuntimeIdentity.runtimeFamily &&
        tunnelData.activationState === expectedRuntimeIdentity.activationState &&
        tunnelData.status === "running" &&
        tunnelData.socksAddress
      ) {
        return tunnelData;
      }
      if (
        tunnelData &&
        (tunnelData.status === "failed" || tunnelData.status === "stopped")
      ) {
        return tunnelData;
      }
    }

    return tunnelData;
  };

  const runWhitelistDebugProbeVariant = async (
    variant: WhitelistDebugProbeVariant,
    variantIndex: number,
    totalVariants: number,
  ): Promise<WhitelistDebugProbeExecution> => {
    const startedAt = new Date().toISOString();
    const {
      serverDraft,
      useRealityStartEndpoint,
      usingImportedProfile,
      excludePackages,
      ownerRuntimeLabRequest,
      runtimeIdentityOverride,
    } = variant.resolve();
    const runtimeIdentity = resolveRuntimeIdentity(
      serverDraft,
      ownerRuntimeLabRequest,
      runtimeIdentityOverride,
    );

    setWhitelistDebugProbeNotice(
      `${t("whitelistDebugProbeRunning")} (${variantIndex + 1}/${totalVariants}): ${variant.label}`,
    );

    try {
      const attempt = await withTimeout(
        (async (): Promise<WhitelistDebugProbeAttempt> => {
          let tunnelData = await pollLocalTunnel(true);
          if (
            tunnelData &&
            (tunnelData.status === "running" ||
              tunnelData.status === "starting") &&
            !runningTunnelMatchesRequest(
              tunnelData,
              serverDraft,
              ownerRuntimeLabRequest,
              excludePackages,
              runtimeIdentityOverride,
            )
          ) {
            const stopRes = await coreApi.stopLocalTunnel();
            setLocalTunnel(stopRes.data);
            tunnelData = await waitForStoppedTunnel();
            setLocalTunnel(tunnelData ?? stopRes.data);
            setAndroidVpnVisualOverride(false);
          }

          const startApi =
            isAndroidClient && ownerRuntimeLabRequest
              ? coreApi.startLocalTunnelFast
              : coreApi.startLocalTunnel;
          const startRes = await startApi(
            {
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
              vkLink,
              runtimeFamily: runtimeIdentity.runtimeFamily,
              activationState: runtimeIdentity.activationState,
              ...(isAndroidClient && excludePackages.length > 0
                ? { excludePackages }
                : {}),
              ...(ownerRuntimeLabRequest
                ? { ownerRuntimeLab: ownerRuntimeLabRequest }
                : {}),
            },
            useRealityStartEndpoint,
          );

          tunnelData = startRes.data;
          setLocalTunnel(tunnelData);

          if (startRes.ok) {
            tunnelData = ownerRuntimeLabRequest
              ? await waitForProbeReadyTunnel(
                  serverDraft,
                  ownerRuntimeLabRequest,
                  excludePackages,
                  runtimeIdentityOverride,
                )
              : await waitForRunningTunnel(18, 1000);
            setLocalTunnel(tunnelData ?? startRes.data);
          }

          let testedTunnel = tunnelData;
          if (
            startRes.ok &&
            tunnelData?.status === "running" &&
            tunnelData.socksAddress
          ) {
            await sleep(1200);
            testedTunnel = await runCurrentTunnelTestWithRetry(2, 1200);
            setLocalTunnel(testedTunnel);
          }

          const attempt: WhitelistDebugProbeAttempt = {
            id: variant.id,
            label: variant.label,
            description: variant.description,
            startedAt,
            finishedAt: new Date().toISOString(),
            runtimeFamily: runtimeIdentity.runtimeFamily,
            activationState: runtimeIdentity.activationState,
            ownerRuntimeLabMode: ownerRuntimeLabRequest?.mode ?? "direct",
            status: testedTunnel?.status ?? "unknown",
            passed: Boolean(testedTunnel?.lastTest?.ok),
            selectedSniHint: testedTunnel?.selectedSniHint,
            frontTag: testedTunnel?.frontTag,
            lastTestStatus: testedTunnel?.lastTest?.status,
            lastTestError:
              testedTunnel?.lastTest?.error ?? testedTunnel?.lastTest?.output,
            runtimeError: testedTunnel?.error,
          };

          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? stopRes.data);
          setAndroidVpnVisualOverride(false);

          return attempt;
        })(),
        WHITELIST_DEBUG_PROBE_VARIANT_TIMEOUT_MS,
        `Whitelist debug probe timed out for ${variant.label}.`,
      );

      return {
        attempt,
        passed: attempt.passed,
      };
    } catch (variantError) {
      const latestTunnel = await pollLocalTunnel(true);
      const message =
        variantError instanceof Error ? variantError.message : t("unknownError");

      const stopRes = await coreApi.stopLocalTunnel();
      setLocalTunnel(stopRes.data);
      const stoppedTunnel = await waitForStoppedTunnel();
      setLocalTunnel(stoppedTunnel ?? stopRes.data);
      setAndroidVpnVisualOverride(false);

      return {
        attempt: {
          id: variant.id,
          label: variant.label,
          description: variant.description,
          startedAt,
          finishedAt: new Date().toISOString(),
          runtimeFamily: runtimeIdentity.runtimeFamily,
          activationState: runtimeIdentity.activationState,
          ownerRuntimeLabMode: ownerRuntimeLabRequest?.mode ?? "direct",
          status: latestTunnel?.status ?? "failed",
          passed: false,
          selectedSniHint: latestTunnel?.selectedSniHint,
          frontTag: latestTunnel?.frontTag,
          lastTestStatus: latestTunnel?.lastTest?.status ?? "failed",
          lastTestError:
            latestTunnel?.lastTest?.error ??
            latestTunnel?.lastTest?.output ??
            message,
          runtimeError: latestTunnel?.error ?? message,
        },
        passed: false,
      };
    }
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
        const {
          serverDraft,
          useRealityStartEndpoint,
          usingImportedProfile,
          excludePackages,
          ownerRuntimeLabRequest,
        } = buildTunnelStartRequest(draft, ownerRuntimeLab.mode);
        let tunnelData = localTunnel;
        if (
          tunnelData &&
          (tunnelData.status === "running" ||
            tunnelData.status === "starting") &&
          !runningTunnelMatchesRequest(
            tunnelData,
            serverDraft,
            ownerRuntimeLabRequest,
            excludePackages,
          )
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          tunnelData = await waitForStoppedTunnel();
          setLocalTunnel(tunnelData ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }

        if (
          !runningTunnelMatchesRequest(
            tunnelData,
            serverDraft,
            ownerRuntimeLabRequest,
            excludePackages,
          )
        ) {
          const startApi =
            isAndroidClient && ownerRuntimeLabRequest
              ? coreApi.startLocalTunnelFast
              : coreApi.startLocalTunnel;
          const startRes = await startApi(
            {
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
              vkLink,
              ...(isAndroidClient && excludePackages.length > 0
                ? { excludePackages }
                : {}),
              ...(ownerRuntimeLabRequest
                ? { ownerRuntimeLab: ownerRuntimeLabRequest }
                : {}),
            },
            useRealityStartEndpoint,
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

        tunnelData = await waitForTunnelIdentity(
          serverDraft,
          ownerRuntimeLabRequest,
          excludePackages,
        );
        setLocalTunnel(tunnelData ?? localTunnel);

        if (ownerRuntimeLabRequest) {
          const whitelistRuntimeReady =
            tunnelData?.runtimeFamily === "reality-whitelist-assisted" &&
            ((ownerRuntimeLabRequest.mode === "reality-whitelist-scaffold" &&
              tunnelData.activationState === "scaffold_only") ||
              (ownerRuntimeLabRequest.mode === "reality-whitelist-lab" &&
                tunnelData.activationState === "active" &&
                tunnelData.status === "running" &&
                Boolean(tunnelData.socksAddress)));
          const vpsRuntimeReady =
            tunnelData?.runtimeFamily === "reality-vps-lab" &&
            ((ownerRuntimeLabRequest.mode === "reality-vps-scaffold" &&
              tunnelData.activationState === "scaffold_only") ||
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
                      : t("ownerLabWhitelistReady"),
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
                      : t("ownerLabWhitelistFailed")),
          );
          return;
        }

        if (tunnelData?.status === "running" && tunnelData.socksAddress) {
          setSuccessNotice(t("ownerLabControlReady"));
          return;
        }

        setError(tunnelData?.error ?? t("tunnelStartFailed"));
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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

  const handleRunSpeedTest = () => {
    if (!speedTestReady) {
      return;
    }
    const countdownEndsAt = Date.now() + SPEED_TEST_TOTAL_DURATION_MS;
    setSpeedTestCountdownEndsAt(countdownEndsAt);
    setPendingAction("runSpeedTest");
    startTransition(async () => {
      try {
        const res = await coreApi.runLocalTunnelSpeedTest({
          warmupDurationMs: SPEED_TEST_WARMUP_DURATION_MS,
          measureDurationMs: SPEED_TEST_MEASURE_DURATION_MS,
          streamCount: SPEED_TEST_STREAM_COUNT,
        });
        setSpeedTestResult(res.data);
      } catch (requestError) {
        setSpeedTestResult({
          ok: false,
          status: "failed",
          checkedAt: new Date().toISOString(),
          error:
            requestError instanceof Error
              ? requestError.message
              : t("speedTestFailed"),
        });
      } finally {
        setSpeedTestCountdownEndsAt(null);
        setPendingAction(null);
      }
    });
  };

  const describeTunnelProbeFailure = (state: LocalTunnelState) => {
    const message =
      state.lastTest?.error ?? state.error ?? t("tunnelTestFailed");
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

  const matchesExpectedProxy = (
    state: SystemProxyState,
    socksAddress?: string,
  ) => {
    if (!socksAddress) {
      return state.enabled;
    }
    const [expectedHost, portText] = socksAddress.split(":");
    const parsedPort = Number.parseInt(portText ?? "", 10);
    return (
      state.enabled && state.host === expectedHost && state.port === parsedPort
    );
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
        socksAddress: socksAddress ?? "",
      });
      const data = res.data;
      const verified = res.ok ? await verifySystemProxy(socksAddress) : data;
      setSystemProxy(verified);
      if (!res.ok) {
        throw new Error(data.error ?? t("unknownError"));
      }
      if (!matchesExpectedProxy(verified, socksAddress)) {
        throw new Error(
          verified.error ??
            "System SOCKS proxy did not become active on the expected local tunnel port",
        );
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
    if (
      !testedTunnel.lastTest?.ok ||
      testedTunnel.status !== "running" ||
      !testedTunnel.socksAddress
    ) {
      throw new Error(describeTunnelProbeFailure(testedTunnel));
    }
    return testedTunnel;
  };

  const handleAccessModeChange = (mode: AccessMode) => {
    const nextMode = accessModeCards.find((entry) => entry.mode === mode);
    if (!nextMode?.available) {
      return;
    }
    setSelectedAccessMode(mode);
    setDraft((current) => {
      if (draftAccessMode(current) === mode) {
        return current;
      }
      return applyAccessModeToDraft(current, mode);
    });
  };

  const renderAccessModeCards = ({
    className,
    closeOnSelect = false,
  }: {
    className?: string;
    closeOnSelect?: boolean;
  } = {}) => (
    <div
      className={["mode-grid", className].filter(Boolean).join(" ")}
      aria-label={t("runtimeMode")}
    >
      {accessModeCards.map((entry) => (
        <button
          key={entry.mode}
          className={[
            "mode-card",
            selectedAccessMode === entry.mode ? "is-active" : "",
            entry.available ? "" : "is-disabled",
          ]
            .filter(Boolean)
            .join(" ")}
          type="button"
          aria-pressed={selectedAccessMode === entry.mode}
          disabled={!entry.available}
          onClick={() => {
            handleAccessModeChange(entry.mode);
            if (closeOnSelect && entry.available) {
              setActiveSheet(null);
            }
          }}
        >
          <span className="mode-card__status">{entry.status}</span>
          <strong>{entry.label}</strong>
          <span>{entry.hint}</span>
        </button>
      ))}
    </div>
  );

  const handleStartTunnel = () => {
    setError(null);
    setPendingAction("startTunnel");
    startTransition(async () => {
      try {
        const {
          serverDraft,
          useRealityStartEndpoint,
          usingImportedProfile,
          excludePackages,
          ownerRuntimeLabRequest,
          runtimeIdentityOverride,
        } = buildCurrentTunnelStartRequest();
        if (
          isAndroidClient &&
          localTunnel &&
          (localTunnel.status === "running" ||
            localTunnel.status === "starting") &&
          !runningTunnelMatchesRequest(
            localTunnel,
            serverDraft,
            ownerRuntimeLabRequest,
            excludePackages,
            runtimeIdentityOverride,
          )
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          const stoppedTunnel = await waitForStoppedTunnel();
          setLocalTunnel(stoppedTunnel ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }
        const startApi =
          isAndroidClient && ownerRuntimeLabRequest
            ? coreApi.startLocalTunnelFast
            : coreApi.startLocalTunnel;
        const res = await startApi(
          {
            server: serverDraft,
            secret: usingImportedProfile ? "" : secret,
            vkLink,
            ...(isAndroidClient && excludePackages.length > 0
              ? { excludePackages }
              : {}),
            ...(ownerRuntimeLabRequest
              ? { ownerRuntimeLab: ownerRuntimeLabRequest }
              : {}),
          },
          useRealityStartEndpoint,
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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
        const {
          serverDraft,
          useRealityStartEndpoint,
          usingImportedProfile,
          excludePackages,
          ownerRuntimeLabRequest,
          runtimeIdentityOverride,
        } = buildCurrentTunnelStartRequest();
        const runtimeIdentity = resolveRuntimeIdentity(
          serverDraft,
          ownerRuntimeLabRequest,
          runtimeIdentityOverride,
        );
        console.info("[vpn-enable] request", {
          selectedAccessMode,
          serverHost: serverDraft.host,
          usingImportedProfile,
          ownerRuntimeLabMode: ownerRuntimeLabRequest?.mode ?? "",
          runtimeFamily: runtimeIdentity.runtimeFamily,
          activationState: runtimeIdentity.activationState,
          runtimeIdentityOverride:
            runtimeIdentityOverride?.runtimeFamily ?? "",
          hasLocalYandexEdgeAccessProfile,
          localProfileOffersYandexEdge,
          ownerProfileHasCdnAntiWhitelist:
            ownerProfileHasCdnAntiWhitelist(ownerProfile),
          importedProfileHasCdnAntiWhitelist:
            importedProfileHasCdnAntiWhitelist(importedProfile),
          ownerProfileHasCurrentYandexEdge:
            ownerProfileHasCurrentYandexEdge(ownerProfile),
          importedProfileHasCurrentYandexEdge:
            importedProfileHasCurrentYandexEdge(importedProfile),
        });
        let tunnelData = localTunnel;
        if (
          isAndroidClient &&
          tunnelData &&
          (tunnelData.status === "running" ||
            tunnelData.status === "starting") &&
          !runningTunnelMatchesRequest(
            tunnelData,
            serverDraft,
            ownerRuntimeLabRequest,
            excludePackages,
            runtimeIdentityOverride,
          )
        ) {
          const stopRes = await coreApi.stopLocalTunnel();
          setLocalTunnel(stopRes.data);
          tunnelData = await waitForStoppedTunnel();
          setLocalTunnel(tunnelData ?? stopRes.data);
          setAndroidVpnVisualOverride(false);
        }
        if (
          !runningTunnelMatchesRequest(
            tunnelData,
            serverDraft,
            ownerRuntimeLabRequest,
            excludePackages,
            runtimeIdentityOverride,
          )
        ) {
          const startApi =
            isAndroidClient && ownerRuntimeLabRequest
              ? coreApi.startLocalTunnelFast
              : coreApi.startLocalTunnel;
          const startRes = await startApi(
            {
              server: serverDraft,
              secret: usingImportedProfile ? "" : secret,
              vkLink,
              runtimeFamily: runtimeIdentity.runtimeFamily,
              activationState: runtimeIdentity.activationState,
              ...(isAndroidClient && excludePackages.length > 0
                ? { excludePackages }
                : {}),
              ...(ownerRuntimeLabRequest
                ? { ownerRuntimeLab: ownerRuntimeLabRequest }
                : {}),
            },
            useRealityStartEndpoint,
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

        if (
          isAndroidClient &&
          tunnelData?.runtimeFamily === "vk-relay" &&
          tunnelData?.activationState === "active" &&
          tunnelData?.status === "starting"
        ) {
          void pollLocalTunnel();
          return;
        }

        if (
          !tunnelData ||
          tunnelData.status !== "running" ||
          !tunnelData.socksAddress
        ) {
          if (isAndroidClient) {
            setAndroidVpnVisualOverride(false);
          }
          setError(
            tunnelData?.error ??
              (tunnelData?.status === "starting"
                ? androidTunnelStartingWarning
                : t("tunnelStartFailed")),
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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
        if (
          isAndroidClient &&
          (stopData.status === "stopped" ||
            stopData.status === "idle" ||
            stopData.status === "failed")
        ) {
          setAndroidVpnVisualOverride(false);
        }
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    });
  };

  const handleGenerateGuestProfile = () => {
    setError(null);
    setInviteFileNotice(null);
    startTransition(async () => {
      try {
        const host = resolvedDraftHost.trim();
        if (!host) {
          setError("Host is required");
          return;
        }
        const refreshedOwnerProfile = await fetchOwnerProfile(host);
        const res = await coreApi.generateGuestProfile({
          server: {
            ...draft,
            host,
          },
          secret,
          host,
          name:
            refreshedOwnerProfile?.name ??
            ownerProfile?.name ??
            "Odin's Cat Access Key",
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
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
        setError(message);
      }
    });
  };

  const importProfileFromContents = (
    contents: string,
    options?: {
      fileName?: string;
    },
  ) => {
    setError(null);
    setInviteFileNotice(null);
    startTransition(async () => {
      try {
        if (!looksLikeInviteJsonPayload(contents)) {
          setError(t("importJsonOnlyError"));
          return;
        }
        const res = await coreApi.importProfile({
          shareCode: contents,
        });
        const data = res.data;
        if (res.ok) {
          applyImportedProfile(data);
          if (options?.fileName) {
            setInviteFileNotice(
              `${t("importedProfileFile")}: ${options.fileName}`,
            );
          }
          setSuccessNotice(`${t("imported")}: ${data.name}`);
        }
        if (!res.ok) {
          setError(data.error ?? t("unknownError"));
        }
      } catch (requestError) {
        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
        setError(message);
      }
    });
  };

  const handleOpenImportProfileFile = () => {
    setError(null);
    importProfileFileInputRef.current?.click();
  };

  const handleOpenPendingVkCaptcha = () => {
    if (!pendingVkCaptchaUrl) {
      return;
    }

    setError(null);
    startTransition(async () => {
      const res = await coreApi.openExternalUrl(pendingVkCaptchaUrl);
      if (!res.ok) {
        setError(
          (res.data as { error?: string } | undefined)?.error ??
            t("unknownError"),
        );
      }
    });
  };

  const handleImportProfileFile = async (
    event: ChangeEvent<HTMLInputElement>,
  ) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) {
      return;
    }

    try {
      const contents = await file.text();
      importProfileFromContents(contents, { fileName: file.name });
    } catch (requestError) {
      const message =
        requestError instanceof Error
          ? requestError.message
          : t("unknownError");
      setError(message);
    }
  };

  const triggerBrowserInviteFileDownload = (rawJson: string, fileName: string) => {
    const blob = new Blob([rawJson], { type: "application/json" });
    const objectUrl = window.URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = objectUrl;
    anchor.download = fileName;
    anchor.rel = "noopener";
    anchor.click();
    window.URL.revokeObjectURL(objectUrl);
  };

  const handleExportInviteFile = () => {
    if (!exportableInviteProfile?.rawJson) {
      return;
    }

    setError(null);
    setInviteFileNotice(null);
    setPendingAction("exportInviteFile");
    void (async () => {
      let androidShareOpened = false;
      if (isAndroidClient) {
        const shareRes = await coreApi.shareInviteFile(
          exportableInviteFileName,
          exportableInviteProfile.rawJson,
        );
        if (!shareRes.ok) {
          setError((shareRes.data as { error?: string }).error ?? t("unknownError"));
          setPendingAction(null);
          return;
        }
        androidShareOpened = true;
        const shareData = shareRes.data as {
          exportPath?: string;
          fileName?: string;
        };
        if (shareData.exportPath) {
          setInviteFileNotice(
            formatInviteExportNotice(
              t,
              shareData.fileName || exportableInviteFileName,
              shareData.exportPath,
            ),
          );
          setPendingAction(null);
          return;
        }
      }

      try {
        const res = await coreApi.exportInviteFile(exportableInviteProfile.rawJson);
        const data = res.data;
        if (res.ok && data.exportPath) {
          setInviteFileNotice(
            formatInviteExportNotice(
              t,
              data.fileName || exportableInviteFileName,
              data.exportPath,
            ),
          );
          return;
        }

        if (!isAndroidClient) {
          triggerBrowserInviteFileDownload(
            exportableInviteProfile.rawJson,
            exportableInviteFileName,
          );
          setInviteFileNotice(
            `${t("exportProfileFileStarted")}: ${exportableInviteFileName}`,
          );
          return;
        }

        if (androidShareOpened) {
          setInviteFileNotice(t("exportProfileFileSharedNoLocal"));
          return;
        }

        setError(t("unknownError"));
      } catch (requestError) {
        if (!isAndroidClient) {
          triggerBrowserInviteFileDownload(
            exportableInviteProfile.rawJson,
            exportableInviteFileName,
          );
          setInviteFileNotice(
            `${t("exportProfileFileStarted")}: ${exportableInviteFileName}`,
          );
          return;
        }

        if (androidShareOpened) {
          setInviteFileNotice(t("exportProfileFileSharedNoLocal"));
          return;
        }

        const message =
          requestError instanceof Error
            ? requestError.message
            : t("unknownError");
        setError(message);
      } finally {
        setPendingAction(null);
      }
    })();
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
      const message =
        copyError instanceof Error ? copyError.message : t("unknownError");
      setError(message);
    }
  };

  const handleResetState = () => {
    setActiveTab("server");
    setActiveAccessTab("key");
    setActiveSheet(null);
    setDraft(initialDraft);
    setEdgeDraft(initialEdgeDraft);
    setSelectedAccessMode("vless-reality");
    setDeployPortMode("auto");
    setSecret("");
    setValidation(null);
    setPlan([]);
    setDeployment(null);
    setShowDeploymentOverlay(false);
    setWhitelistIp("");
    setWhitelistLookup(null);
    setWhitelistLookupError(null);
    setMobileNetworkLens(null);
    setInviteFileNotice(null);
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
      <div className="mobile-shell halo-desktop-shell">
        <aside className="halo-brief" data-tauri-drag-region>
          <div className="halo-brief__brand">
            <span className="halo-kicker">HALO · Windows</span>
            <h2>
              <b>Один</b> ключ.
              <br />
              <i>Две поверхности.</i>
            </h2>
            <p>
              Desktop-оболочка использует тот же invite JSON, что и Android:
              импорт, экспорт и runtime-профиль идут через общий контракт.
            </p>
          </div>

          <div className="halo-brief__stats">
            <div className="halo-stat halo-stat--lime">
              <span>JSON</span>
              <strong>.odinone-access</strong>
            </div>
            <div className="halo-stat">
              <span>runtime</span>
              <strong>{primaryStatusBadge}</strong>
            </div>
            <div className="halo-stat">
              <span>mode</span>
              <strong>{selectedAccessModeCard.label}</strong>
            </div>
          </div>

          <div className="halo-brief__actions">
            <button
              className="primary"
              type="button"
              onClick={handleOpenImportProfileFile}
              disabled={isPending}
            >
              {t("importProfileFile")}
            </button>
            <button
              className="ghost"
              type="button"
              onClick={handleExportInviteFile}
              disabled={
                isPending ||
                isBusy("exportInviteFile") ||
                !exportableInviteProfile?.rawJson
              }
            >
              {t("exportProfileFile")}
            </button>
          </div>

          {inviteFileNotice ? (
            <p className="halo-note">{inviteFileNotice}</p>
          ) : (
            <p className="halo-note">
              JSON-файл можно перенести с телефона на Windows без пересборки
              профиля.
            </p>
          )}
        </aside>

        <div className="home-scroll">
          <section className="phone-card home-stack">
            <div className="home-stack__scroll">
              <div className="home-section home-section--hero">
                <button
                  className={modeTriggerClassName}
                  type="button"
                  onClick={() => setActiveSheet("mode-picker")}
                  aria-haspopup="dialog"
                  aria-label={t("sheetModePickerTitle")}
                >
                  {selectedAccessModeCard.label}
                </button>

                <div className="phone-copy">
                  <h2 className="phone-title">{primaryStatusText}</h2>
                </div>

                <button
                  className={`phone-connect ${vpnVisualActive ? "phone-connect--active" : ""} ${
                    relayOwnerConnectAnimation
                      ? "phone-connect--connecting"
                      : ""
                  }`}
                  type="button"
                  onClick={vpnActionActive ? handleDisableVPN : handleEnableVPN}
                  disabled={
                    vpnActionActive
                      ? isBusy("disableVpn")
                      : isPending ||
                        (!resolvedDraftHost &&
                          !selectedModeUsesStandalonePublicRelay) ||
                        ((selectedAccessMode === "yandex-edge" ||
                          selectedAccessMode === "yandex-edge-proxy" ||
                          selectedAccessMode === "relay-via-server" ||
                          selectedAccessMode === "relay-direct")
                          ? !hasLocalAccessProfileForSelectedMode
                          : !secret.trim() &&
                            !hasLocalAccessProfileForSelectedMode) ||
                        (requiresVKLink &&
                          (!vkLink.trim() || cooldownMinutes > 0))
                  }
                >
                  <span className="phone-connect__label">{vpnButtonLabel}</span>
                </button>

                {error ? (
                  <p className="status-banner status-error">{error}</p>
                ) : null}
                {deployment ? (
                  <p className="status-banner">
                    {t("deploymentPrefix")} {deployment.deploymentId} /{" "}
                    {deploymentStatusLabel}
                    {deploymentPortSummary ? ` / ${deploymentPortSummary}` : ""}
                  </p>
                ) : null}

                {routeLensVisible ? (
                  <div className="home-network-card">
                    <div className="home-network-card__head">
                      <span className="section-eyebrow">
                        {routeLensNetworkLabel}
                      </span>
                      <span
                        className={`home-whitelist-pill home-whitelist-pill--${routeLensWhitelistTone}`}
                      >
                        {routeLensWhitelistLabel}
                      </span>
                    </div>

                    <div
                      className={`home-network-card__grid ${
                        (yandexTunnelRuntimeActive || relayRuntimeActive) &&
                        routeLensOriginDisplay &&
                        routeLensTunnelDisplay
                          ? ""
                          : "home-network-card__grid--single"
                      }`}
                    >
                      {routeLensOriginDisplay ? (
                        <div className="home-network-hop">
                          <span>{t("routeLensOrigin")}</span>
                          <strong>{routeLensOriginDisplay}</strong>
                          <p>
                            {routeLensOrigin.flag
                              ? `${routeLensOrigin.flag} ${routeLensOrigin.country}`
                              : routeLensOrigin.country}
                          </p>
                          {routeLensOrigin.host &&
                          routeLensOrigin.host !== routeLensOriginDisplay ? (
                            <code>{routeLensOrigin.host}</code>
                          ) : null}
                        </div>
                      ) : null}

                      {(yandexTunnelRuntimeActive || relayRuntimeActive) &&
                      routeLensTunnelDisplay ? (
                        <div className="home-network-hop">
                          <span>{t("routeLensTunnel")}</span>
                          <strong>{routeLensTunnelDisplay}</strong>
                          <p>
                            {routeLensTunnel.flag
                              ? `${routeLensTunnel.flag} ${routeLensTunnel.country}`
                              : routeLensTunnel.country}
                          </p>
                          {routeLensTunnel.host &&
                          routeLensTunnel.host !== routeLensTunnelDisplay ? (
                            <code>{routeLensTunnel.host}</code>
                          ) : null}
                        </div>
                      ) : null}
                    </div>

                    {routeLensNote ? (
                      <p className="home-network-card__note">{routeLensNote}</p>
                    ) : null}
                  </div>
                ) : null}

                <div className="home-hero-actions">
                  <button
                    className="ghost home-hero-actions__button"
                    type="button"
                    onClick={() => setActiveSheet("speedtest")}
                  >
                    {t("speedTestOpen")}
                  </button>
                </div>
              </div>

              <div className="home-divider" />

              <div className="home-section home-section--invite">
                <div className="invite-home__head">
                  <span className="section-eyebrow">{t("sharing")}</span>
                  <strong>{t("importProfile")}</strong>
                </div>

                <div className="invite-home__actions">
                  {pendingVkCaptchaUrl ? (
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleOpenPendingVkCaptcha}
                      disabled={isPending}
                    >
                      {t("openVkCaptcha")}
                    </button>
                  ) : null}
                  <button
                    className="ghost"
                    type="button"
                    onClick={handleOpenImportProfileFile}
                    disabled={isPending}
                  >
                    {t("importProfileFile")}
                  </button>
                </div>

                {pendingVkCaptchaUrl ? (
                  <p className="status-banner">{t("vkCaptchaReady")}</p>
                ) : null}

              </div>
            </div>
          </section>
        </div>

        <nav
          className={[
            "mobile-dock",
            isAndroidClient ? "mobile-dock--with-apps" : "",
          ]
            .filter(Boolean)
            .join(" ")}
          aria-label="Primary actions"
        >
          <button
            className={
              activeSheet === "server"
                ? "mobile-dock__button is-active"
                : "mobile-dock__button"
            }
            type="button"
            onClick={() =>
              setActiveSheet((current) =>
                current === "server" ? null : "server",
              )
            }
          >
            {t("tabServer")}
          </button>
          {isAndroidClient ? (
            <button
              className={
                activeSheet === "apps"
                  ? "mobile-dock__button is-active"
                  : "mobile-dock__button"
              }
              type="button"
              onClick={() =>
                setActiveSheet((current) => (current === "apps" ? null : "apps"))
              }
            >
              {t("navApps")}
            </button>
          ) : null}
          <button
            className={
              activeSheet === "whitelist"
                ? "mobile-dock__button is-active"
                : "mobile-dock__button"
            }
            type="button"
            onClick={() =>
              setActiveSheet((current) =>
                current === "whitelist" ? null : "whitelist",
              )
            }
          >
            {t("navWhitelist")}
          </button>
          <button
            className={
              activeSheet === "logs"
                ? "mobile-dock__button is-active"
                : "mobile-dock__button"
            }
            type="button"
            onClick={() =>
              setActiveSheet((current) => (current === "logs" ? null : "logs"))
            }
          >
            {t("navLogs")}
          </button>
          <button
            className={
              activeSheet === "more"
                ? "mobile-dock__button is-active"
                : "mobile-dock__button"
            }
            type="button"
            onClick={() =>
              setActiveSheet((current) => (current === "more" ? null : "more"))
            }
          >
            {t("navMore")}
          </button>
        </nav>
      </div>

      <input
        ref={importProfileFileInputRef}
        hidden
        type="file"
        accept=".json,.odinone-access.json"
        onChange={handleImportProfileFile}
      />

      {activeSheet === "mode-picker" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetModePickerTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("runtimeMode")}</span>
                <h3 className="sheet-panel__title">
                  {t("sheetModePickerTitle")}
                </h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <p className="compact-note compact-note--panel">
              {t("sheetModePickerText")}
            </p>

            {renderAccessModeCards({
              className: "mode-grid--single",
              closeOnSelect: true,
            })}
          </div>
        </div>
      ) : null}

      {activeSheet === "speedtest" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("speedTestTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("speedTestTitle")}</span>
                <h3 className="sheet-panel__title">{t("speedTestSubtitle")}</h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <p className="compact-note compact-note--panel">
              {t("speedTestHint")}
            </p>

            <section className="sheet-card">
              <div className="sheet-card__head">
                <div>
                  <span className="section-eyebrow">{t("speedTestTitle")}</span>
                  <strong>{t("speedTestSubtitle")}</strong>
                </div>
                <span
                  className={`sheet-card__badge ${
                    speedTestResult?.ok ? "pill pill-ok" : ""
                  }`}
                >
                  {isBusy("runSpeedTest")
                    ? t("testing")
                    : speedTestResult?.ok
                      ? t("ready")
                      : t("tunnelStatusIdle")}
                </span>
              </div>

              <div className="home-speed-card__stats">
                <div className="home-speed-card__stat">
                  <span>{t("speedTestLatency")}</span>
                  <strong>{speedTestLatencyLabel}</strong>
                </div>
                <div className="home-speed-card__stat">
                  <span>{t("speedTestDownload")}</span>
                  <strong>{speedTestDownloadDisplayLabel}</strong>
                </div>
              </div>

              {speedTestResult?.error ? (
                <p className="status-banner status-error">{speedTestResult.error}</p>
              ) : speedTestCheckedAt ? (
                <p className="compact-note">
                  {t("speedTestCheckedAt")}: {speedTestCheckedAt}
                </p>
              ) : null}

              <div className="sheet-actions">
                <button
                  className="primary"
                  type="button"
                  onClick={handleRunSpeedTest}
                  disabled={!speedTestReady || isBusy("runSpeedTest")}
                >
                  {isBusy("runSpeedTest") ? t("testing") : t("speedTestRun")}
                </button>
              </div>
            </section>
          </div>
        </div>
      ) : null}

      {activeSheet === "server" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetServerTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("serverInput")}</span>
                <h3 className="sheet-panel__title">{t("sheetServerTitle")}</h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <div className="sheet-card-stack">
              <section className="sheet-card">
                <div className="sheet-card__head">
                  <div>
                    <span className="section-eyebrow">{t("deployStepOrigin")}</span>
                    <strong>{t("deployStepOriginTitle")}</strong>
                  </div>
                  <span className="sheet-card__badge">{t("modeStatusLive")}</span>
                </div>
                <p className="compact-note">{t("deployStepOriginText")}</p>

                <div className="form-grid">
                  <label className="input-field">
                    <span>{t("host")}</span>
                    <input
                      value={draft.host}
                      onChange={(event) =>
                        setDraft((current) => ({
                          ...current,
                          host: event.target.value,
                        }))
                      }
                      placeholder="203.0.113.42"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("sshPort")}</span>
                    <input
                      value={draft.port}
                      onChange={(event) =>
                        setDraft((current) => ({
                          ...current,
                          port: Number(event.target.value) || 22,
                        }))
                      }
                      placeholder="22"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("user")}</span>
                    <input
                      value={draft.username}
                      onChange={(event) =>
                        setDraft((current) => ({
                          ...current,
                          username: event.target.value,
                        }))
                      }
                      placeholder="root"
                    />
                  </label>

                  <label className="input-field input-span">
                    <div className="input-field__head">
                      <span>
                        {draft.authMethod === "password"
                          ? t("password")
                          : t("privateKey")}
                      </span>
                      <div className="lang-toggle" aria-label={t("authMethod")}>
                        <button
                          className={
                            draft.authMethod === "password"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() =>
                            setDraft((current) => ({
                              ...current,
                              authMethod: "password",
                            }))
                          }
                        >
                          {t("authPassword")}
                        </button>
                        <button
                          className={
                            draft.authMethod === "private-key"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() =>
                            setDraft((current) => ({
                              ...current,
                              authMethod: "private-key",
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
                      placeholder={
                        draft.authMethod === "password"
                          ? "server password"
                          : "-----BEGIN OPENSSH PRIVATE KEY-----"
                      }
                    />
                  </label>

                  <label className="input-field input-span">
                    <div className="input-field__head">
                      <span>{t("portSetup")}</span>
                      <div className="lang-toggle" aria-label={t("portSetup")}>
                        <button
                          className={
                            deployPortMode === "auto"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() => {
                            setDeployPortMode("auto");
                            setDraft((current) => ({
                              ...current,
                              vkTurnProxyPort: undefined,
                              realityPort: undefined,
                              yandexEdgeOriginPort: undefined,
                            }));
                          }}
                        >
                          {t("portSetupAuto")}
                        </button>
                        <button
                          className={
                            deployPortMode === "manual"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() => setDeployPortMode("manual")}
                        >
                          {t("portSetupManual")}
                        </button>
                      </div>
                    </div>
                    <p className="compact-note">
                      {deployPortMode === "manual"
                        ? t("portSetupManualHint")
                        : t("portSetupAutoHint")}
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
                              vkTurnProxyPort: normalizePortHint(
                                Number.parseInt(event.target.value, 10),
                              ),
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
                              realityPort: normalizePortHint(
                                Number.parseInt(event.target.value, 10),
                              ),
                            }))
                          }
                          placeholder="52443"
                          inputMode="numeric"
                        />
                      </label>

                      <label className="input-field">
                        <span>{t("yandexEdgeOriginPort")}</span>
                        <input
                          value={draft.yandexEdgeOriginPort ?? ""}
                          onChange={(event) =>
                            setDraft((current) => ({
                              ...current,
                              yandexEdgeOriginPort: normalizePortHint(
                                Number.parseInt(event.target.value, 10),
                              ),
                            }))
                          }
                          placeholder="52444"
                          inputMode="numeric"
                        />
                      </label>
                    </>
                  ) : null}

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

                  {requiresVKLink ? (
                    <label className="input-field input-span">
                      <span>{t("vkTurnStreamCount")}</span>
                      <input
                        value={draft.vkTurnStreamCount ?? ""}
                        onChange={(event) =>
                          setDraft((current) => ({
                            ...current,
                            vkTurnStreamCount: normalizeVkTurnStreamCount(
                              Number.parseInt(event.target.value, 10),
                            ),
                          }))
                        }
                        placeholder="10"
                        inputMode="numeric"
                      />
                      <p className="compact-note">
                        {t("vkTurnStreamCountHint")}
                      </p>
                    </label>
                  ) : null}
                </div>

                {manualPortConfigError ? (
                  <p className="status-banner status-error">
                    {manualPortConfigError}
                  </p>
                ) : null}

                <div className="sheet-actions">
                  <button
                    className="ghost"
                    type="button"
                    onClick={() => handleValidate("origin")}
                    disabled={isPending || !draft.host || !secret.trim()}
                  >
                    {t("validateOrigin")}
                  </button>
                  <button
                    className="primary"
                    type="button"
                    onClick={() => handleDeploy("origin")}
                    disabled={
                      isPending ||
                      !draft.host ||
                      !secret.trim() ||
                      Boolean(manualPortConfigError)
                    }
                  >
                    {t("startDeploy")}
                  </button>
                </div>

                {originValidation ? (
                  <div className="check-list" style={{ marginTop: 18 }}>
                    {originValidation.error ? (
                      <p className="status-banner status-error">
                        {translateCheckDetail(originValidation.error)}
                      </p>
                    ) : (
                      <p
                        className={
                          originValidation.ok
                            ? "status-banner status-success"
                            : "status-banner"
                        }
                      >
                        {originValidation.ok ? t("checkOk") : t("checkFail")}
                      </p>
                    )}

                    {originValidation.warnings.map((warning, index) => (
                      <p className="status-banner" key={`${warning}-${index}`}>
                        {translateCheckDetail(warning)}
                      </p>
                    ))}

                    {originValidation.checks.length > 0 ? (
                      originValidation.checks.map((check) => (
                        <div className="check-row" key={check.key}>
                          <div>
                            <strong>
                              {translateCheckLabel(check.key, check.label)}
                            </strong>
                            <p>{translateCheckDetail(check.detail)}</p>
                          </div>
                          <span
                            className={
                              check.ok ? "pill pill-ok" : "pill pill-off"
                            }
                          >
                            {check.ok ? t("checkOk") : t("checkFail")}
                          </span>
                        </div>
                      ))
                    ) : !originValidation.error ? (
                      <p className="compact-note">{t("validationEmpty")}</p>
                    ) : null}
                  </div>
                ) : null}
              </section>

              <section className="sheet-card">
                <div className="sheet-card__head">
                  <div>
                    <span className="section-eyebrow">{t("deployStepEdge")}</span>
                    <strong>{t("deployStepEdgeTitle")}</strong>
                  </div>
                  <span className="sheet-card__badge">
                    {protocolEntryById.has("vless-reality-yandex-edge-proxy")
                      ? t("modeStatusOptional")
                      : t("modeStatusAttach")}
                  </span>
                </div>
                <p className="compact-note">{t("deployStepEdgeText")}</p>

                {importedYandexEdgeStale ? (
                  <p className="status-banner">
                    {t("edgeDiagInviteStaleDetail")}
                  </p>
                ) : null}

                <div className="form-grid">
                  <label className="input-field">
                    <span>{t("edgeHost")}</span>
                    <input
                      value={edgeDraft.host}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          host: event.target.value,
                        }))
                      }
                      placeholder="203.0.113.10"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("sshPort")}</span>
                    <input
                      value={edgeDraft.port}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          port: Number(event.target.value) || 22,
                        }))
                      }
                      placeholder="22"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("user")}</span>
                    <input
                      value={edgeDraft.username}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          username: event.target.value,
                        }))
                      }
                      placeholder="root"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("edgePublicPort")}</span>
                    <input
                      value={edgeDraft.publicPort}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          publicPort: Number(event.target.value) || 443,
                        }))
                      }
                      placeholder="443"
                      inputMode="numeric"
                    />
                  </label>

                  <label className="input-field">
                    <span>{t("edgeRoutingMode")}</span>
                    <select
                      value={edgeDraft.routingMode}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          routingMode: event.target.value as EdgeRoutingMode,
                        }))
                      }
                    >
                      <option value="sni-router">
                        {t("edgeRoutingSniRouter")}
                      </option>
                      <option value="xray-proxy">
                        {t("edgeRoutingXrayProxy")}
                      </option>
                    </select>
                    <small>{t("edgeRoutingModeHelp")}</small>
                  </label>

                  <label className="input-field input-span">
                    <div className="input-field__head">
                      <span>
                        {edgeDraft.authMethod === "password"
                          ? t("password")
                          : t("privateKey")}
                      </span>
                      <div className="lang-toggle" aria-label={t("authMethod")}>
                        <button
                          className={
                            edgeDraft.authMethod === "password"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() =>
                            setEdgeDraft((current) => ({
                              ...current,
                              authMethod: "password",
                            }))
                          }
                        >
                          {t("authPassword")}
                        </button>
                        <button
                          className={
                            edgeDraft.authMethod === "private-key"
                              ? "lang-button is-active"
                              : "lang-button"
                          }
                          type="button"
                          onClick={() =>
                            setEdgeDraft((current) => ({
                              ...current,
                              authMethod: "private-key",
                            }))
                          }
                        >
                          {t("authPrivateKey")}
                        </button>
                      </div>
                    </div>
                    <textarea
                      value={edgeDraft.secret}
                      onChange={(event) =>
                        setEdgeDraft((current) => ({
                          ...current,
                          secret: event.target.value,
                        }))
                      }
                      placeholder={
                        edgeDraft.authMethod === "password"
                          ? "edge server password"
                          : "-----BEGIN OPENSSH PRIVATE KEY-----"
                      }
                    />
                  </label>
                </div>

                <div className="sheet-actions">
                  <button
                    className="ghost"
                    type="button"
                    onClick={() => handleValidate("edge-attach")}
                    disabled={
                      isPending ||
                      !draft.host ||
                      !secret.trim() ||
                      !edgeDraft.host ||
                      !edgeDraft.secret.trim()
                    }
                  >
                    {t("validateEdge")}
                  </button>
                  <button
                    className="primary"
                    type="button"
                    onClick={() => handleDeploy("edge-attach")}
                    disabled={
                      isPending ||
                      !draft.host ||
                      !secret.trim() ||
                      !edgeDraft.host ||
                      !edgeDraft.secret.trim()
                    }
                  >
                    {t("attachEdge")}
                  </button>
                </div>

                {edgeAttachValidation ? (
                  <div className="check-list" style={{ marginTop: 18 }}>
                    {edgeAttachValidation.error ? (
                      <p className="status-banner status-error">
                        {translateCheckDetail(edgeAttachValidation.error)}
                      </p>
                    ) : (
                      <p
                        className={
                          edgeAttachValidation.ok
                            ? "status-banner status-success"
                            : "status-banner"
                        }
                      >
                        {edgeAttachValidation.ok ? t("checkOk") : t("checkFail")}
                      </p>
                    )}

                    {edgeAttachValidation.warnings.map((warning, index) => (
                      <p className="status-banner" key={`${warning}-${index}`}>
                        {translateCheckDetail(warning)}
                      </p>
                    ))}

                    {edgeAttachValidation.checks.length > 0 ? (
                      edgeAttachValidation.checks.map((check) => (
                        <div className="check-row" key={check.key}>
                          <div>
                            <strong>
                              {translateCheckLabel(check.key, check.label)}
                            </strong>
                            <p>{translateCheckDetail(check.detail)}</p>
                          </div>
                          <span
                            className={
                              check.ok ? "pill pill-ok" : "pill pill-off"
                            }
                          >
                            {check.ok ? t("checkOk") : t("checkFail")}
                          </span>
                        </div>
                      ))
                    ) : !edgeAttachValidation.error ? (
                      <p className="compact-note">{t("validationEmpty")}</p>
                    ) : null}
                  </div>
                ) : null}
              </section>
            </div>

            {successNotice ? (
              <p className="status-banner status-success">{successNotice}</p>
            ) : null}

            <div className="sheet-actions">
              <button
                className="ghost"
                onClick={handleResetState}
                disabled={isPending}
              >
                {t("reset")}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "apps" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetAppsTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel sheet-panel--apps">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("navApps")}</span>
                <h3 className="sheet-panel__title">{t("sheetAppsTitle")}</h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <div className="sheet-panel__scroll">
              <div className="sheet-stack">
                <section className="sheet-card">
                  <div className="sheet-card__head">
                    <div>
                      <span className="section-eyebrow">
                        {t("splitTunnelTitle")}
                      </span>
                      <strong>{splitTunnelStatusLabel}</strong>
                    </div>
                    <span className="sheet-card__badge">
                      {splitTunnelExcludePackages.length > 0
                        ? t("stateEnabled")
                        : t("stateDisabled")}
                    </span>
                  </div>
                  <p className="compact-note">{t("sheetAppsText")}</p>

                  <div className="sheet-actions">
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleClearSplitTunnelSelection}
                      disabled={
                        splitTunnelSaving ||
                        splitTunnelExcludePackages.length === 0
                      }
                    >
                      {t("splitTunnelClear")}
                    </button>
                  </div>
                </section>

                {splitTunnelReconnectRequired ? (
                  <p className="status-banner">
                    {t("splitTunnelReconnectNotice")}
                  </p>
                ) : null}

                {splitTunnelError ? (
                  <p className="status-banner status-error">
                    {splitTunnelError}
                  </p>
                ) : null}

                <label className="input-field input-span">
                  <span>{t("splitTunnelSearch")}</span>
                  <input
                    value={splitTunnelSearch}
                    onChange={(event) => setSplitTunnelSearch(event.target.value)}
                    placeholder={t("splitTunnelSearchPlaceholder")}
                  />
                </label>

                {splitTunnelAppsLoading ? (
                  <p className="compact-note compact-note--panel">
                    {t("splitTunnelLoadingApps")}
                  </p>
                ) : null}

                {!splitTunnelAppsLoading &&
                splitTunnelAppsLoaded &&
                installedApps.length === 0 ? (
                  <p className="compact-note compact-note--panel">
                    {t("splitTunnelEmpty")}
                  </p>
                ) : null}

                {!splitTunnelAppsLoading &&
                splitTunnelAppsLoaded &&
                installedApps.length > 0 &&
                splitTunnelVisibleApps.length === 0 ? (
                  <p className="compact-note compact-note--panel">
                    {t("splitTunnelNoResults")}
                  </p>
                ) : null}

                {splitTunnelVisibleApps.length > 0 ? (
                  <div className="split-app-list">
                    {splitTunnelVisibleApps.map((app) => {
                      const normalizedPackage = app.packageName
                        .trim()
                        .toLowerCase();
                      const selected =
                        splitTunnelSelectedSet.has(normalizedPackage);
                      return (
                        <button
                          key={app.packageName}
                          className={[
                            "split-app-card",
                            selected ? "is-active" : "",
                          ]
                            .filter(Boolean)
                            .join(" ")}
                          type="button"
                          onClick={() =>
                            handleToggleSplitTunnelPackage(app.packageName)
                          }
                          disabled={splitTunnelSaving}
                          aria-pressed={selected}
                        >
                          <div className="split-app-card__copy">
                            <strong>{app.appName}</strong>
                            <span>{app.packageName}</span>
                          </div>
                          <div className="split-app-card__meta">
                            {app.systemApp ? (
                              <span className="split-app-card__badge">
                                {t("splitTunnelSystemApp")}
                              </span>
                            ) : null}
                            <span className="split-app-card__toggle">
                              {selected ? t("stateEnabled") : t("stateDisabled")}
                            </span>
                          </div>
                        </button>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "whitelist" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetWhitelistTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("whitelistEyebrow")}</span>
                <h3 className="sheet-panel__title">
                  {t("sheetWhitelistTitle")}
                </h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <div className="sheet-stack">
              <section className="sheet-card">
                <div className="sheet-card__head">
                  <div>
                    <span className="section-eyebrow">
                      {t("whitelistInputLabel")}
                    </span>
                    <strong>{t("whitelistCardTitle")}</strong>
                  </div>
                  <span className="sheet-card__badge">
                    {whitelistLookup?.cached
                      ? t("whitelistSourceCached")
                      : t("whitelistSourceLive")}
                  </span>
                </div>

                {t("sheetWhitelistText") ? (
                  <p className="compact-note">{t("sheetWhitelistText")}</p>
                ) : null}

                <label className="input-field input-span">
                  <span>{t("whitelistIpv4")}</span>
                  <input
                    value={whitelistIp}
                    onChange={(event) => {
                      setWhitelistIp(event.target.value);
                      setWhitelistLookup(null);
                      setWhitelistLookupError(null);
                    }}
                    placeholder="IPv4"
                    inputMode="decimal"
                  />
                </label>

                <div className="sheet-actions">
                  <button
                    className="primary"
                    type="button"
                    onClick={handleCheckWhitelistIp}
                    disabled={isPending || !whitelistIp.trim()}
                  >
                    {isBusy("checkWhitelist")
                      ? t("whitelistChecking")
                      : t("whitelistCheck")}
                  </button>
                </div>
              </section>

              {whitelistLookupError ? (
                <p className="status-banner status-error">
                  {whitelistLookupError}
                </p>
              ) : null}

              {whitelistLookup && !whitelistLookup.valid ? (
                <p className="status-banner status-error">
                  {t("whitelistInvalid")}
                </p>
              ) : null}

              {whitelistLookup?.valid ? (
                <>
                  <p
                    className={
                      whitelistLookup.matchedIp || whitelistLookup.matchedCidr
                        ? "status-banner status-success"
                        : "status-banner"
                    }
                  >
                    {whitelistLookupSummary}
                  </p>

                  <div className="phone-facts">
                    <div className="phone-fact">
                      <span>{t("whitelistExactIp")}</span>
                      <strong>
                        {whitelistLookup.matchedIp
                          ? t("whitelistMatchYes")
                          : t("whitelistMatchNo")}
                      </strong>
                    </div>
                    <div className="phone-fact">
                      <span>{t("whitelistCidr")}</span>
                      <strong>
                        {whitelistLookup.matchedCidr
                          ? t("whitelistMatchYes")
                          : t("whitelistMatchNo")}
                      </strong>
                    </div>
                  </div>

                  {whitelistLookup.matchedCidrs.length > 0 ? (
                    <div className="command-card command-card--compact">
                      <strong>{t("whitelistMatchedCidrs")}</strong>
                      <div className="whitelist-pill-row">
                        {whitelistLookup.matchedCidrs.map((cidr) => (
                          <span className="whitelist-pill" key={cidr}>
                            {cidr}
                          </span>
                        ))}
                      </div>
                    </div>
                  ) : (
                    <p className="compact-note compact-note--panel">
                      {t("whitelistNoCidrs")}
                    </p>
                  )}

                </>
              ) : null}
            </div>
          </div>
        </div>
      ) : null}

      {activeSheet === "logs" ? (
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetLogsTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
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
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <div className="sheet-stack">
              <div className="sheet-actions">
                <button
                  className="ghost"
                  type="button"
                  onClick={handleRefreshTunnelStatus}
                  disabled={isPending}
                >
                  {t("refreshStatus")}
                </button>
                <button
                  className="ghost"
                  type="button"
                  onClick={handleRunTest}
                  disabled={isPending || localTunnel?.status !== "running"}
                >
                  {isBusy("runTest") ? t("testing") : t("runTest")}
                </button>
              </div>

              <section className="sheet-card">
                <div className="sheet-card__head">
                  <div>
                    <span className="section-eyebrow">{t("navLogs")}</span>
                    <strong>{t("nextVpnSessionLogTitle")}</strong>
                  </div>
                  <span className="sheet-card__badge">
                    {recordNextVpnSessionLog
                      ? t("stateEnabled")
                      : t("stateDisabled")}
                  </span>
                </div>
                <p className="compact-note">{t("nextVpnSessionLogText")}</p>

                {recordNextVpnSessionLog ? (
                  <p className="status-banner">
                    {t("nextVpnSessionLogArmed")}
                  </p>
                ) : null}

                {nextVpnSessionLogError ? (
                  <p className="status-banner status-error">
                    {nextVpnSessionLogError}
                  </p>
                ) : null}

                <div className="sheet-actions">
                  <button
                    className="ghost"
                    type="button"
                    onClick={handleToggleNextVpnSessionLog}
                    disabled={isBusy("toggleNextVpnLog")}
                  >
                    {recordNextVpnSessionLog
                      ? t("nextVpnSessionLogDisarm")
                      : t("nextVpnSessionLogArm")}
                  </button>
                </div>
              </section>

              <section className="sheet-card">
                <div className="sheet-card__head">
                  <div>
                    <span className="section-eyebrow">{t("navLogs")}</span>
                    <strong>{t("whitelistDebugProbeTitle")}</strong>
                  </div>
                  <span className="sheet-card__badge">
                    {whitelistDebugProbeAvailable
                      ? t("stateReady")
                      : t("stateDisabled")}
                  </span>
                </div>
                <p className="compact-note">
                  {t("whitelistDebugProbeText")}
                </p>

                {whitelistDebugProbeNotice ? (
                  <p className="status-banner">{whitelistDebugProbeNotice}</p>
                ) : null}

                {!whitelistDebugProbeAvailable ? (
                  <p className="status-banner status-error">
                    {t("whitelistDebugProbeUnavailable")}
                  </p>
                ) : null}

                <div className="sheet-actions">
                  <button
                    className="ghost"
                    type="button"
                    onClick={handleRunWhitelistDebugProbe}
                    disabled={
                      isBusy("runWhitelistDebugProbe") ||
                      !whitelistDebugProbeAvailable
                    }
                  >
                    {isBusy("runWhitelistDebugProbe")
                      ? t("whitelistDebugProbeRunning")
                      : t("whitelistDebugProbeStart")}
                  </button>
                </div>
              </section>

              {ownerRuntimeLabPanelVisible ? (
                <div className="command-card">
                  <strong>{t("ownerLabTitle")}</strong>
                  <p className="compact-note compact-note--panel">
                    {t("ownerLabText")}
                  </p>

                  <div
                    className="owner-lab-mode-stack"
                    aria-label={t("ownerLabMode")}
                  >
                    <button
                      className={
                        ownerRuntimeLab.mode === "off"
                          ? "lang-button owner-lab-mode-button is-active"
                          : "lang-button owner-lab-mode-button"
                      }
                      type="button"
                      aria-pressed={ownerRuntimeLab.mode === "off"}
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...current,
                          mode: "off",
                        }))
                      }
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
                      aria-pressed={
                        ownerRuntimeLab.mode === "reality-whitelist-scaffold"
                      }
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...current,
                          mode: "reality-whitelist-scaffold",
                        }))
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
                      aria-pressed={
                        ownerRuntimeLab.mode === "reality-vps-scaffold"
                      }
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...current,
                          mode: "reality-vps-scaffold",
                          vpsUseOwnerRealityEgress: false,
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
                          vpsUseOwnerRealityEgress: false,
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
                      aria-pressed={
                        ownerRuntimeLab.mode === "reality-vps-relay-lab"
                      }
                      onClick={() =>
                        setOwnerRuntimeLab((current) => ({
                          ...withIgareckRelayDefaults(current),
                          mode: "reality-vps-relay-lab",
                          vpsUseOwnerRealityEgress: true,
                          vpsUseRelayAutoselect: true,
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
                            setOwnerRuntimeLab((current) => ({
                              ...current,
                              hintServerName: event.target.value,
                            }))
                          }
                          placeholder="max.ru"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintCidrBucket")}</span>
                        <input
                          value={ownerRuntimeLab.hintCidrBucket}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({
                              ...current,
                              hintCidrBucket: event.target.value,
                            }))
                          }
                          placeholder="cidr-max"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintSource")}</span>
                        <input
                          value={ownerRuntimeLab.hintSource}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({
                              ...current,
                              hintSource: event.target.value,
                            }))
                          }
                          placeholder="operator-curated"
                        />
                      </label>

                      <label className="input-field input-span">
                        <span>{t("ownerLabHintTag")}</span>
                        <input
                          value={ownerRuntimeLab.hintTag}
                          onChange={(event) =>
                            setOwnerRuntimeLab((current) => ({
                              ...current,
                              hintTag: event.target.value,
                            }))
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
                              className={
                                !ownerRuntimeLab.vpsUseRelayAutoselect
                                  ? "lang-button is-active"
                                  : "lang-button"
                              }
                              type="button"
                              aria-pressed={
                                !ownerRuntimeLab.vpsUseRelayAutoselect
                              }
                              onClick={() =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsUseRelayAutoselect: false,
                                }))
                              }
                            >
                              {t("ownerLabVpsManualRelay")}
                            </button>
                            <button
                              className={
                                ownerRuntimeLab.vpsUseRelayAutoselect
                                  ? "lang-button is-active"
                                  : "lang-button"
                              }
                              type="button"
                              aria-pressed={
                                ownerRuntimeLab.vpsUseRelayAutoselect
                              }
                              onClick={() =>
                                setOwnerRuntimeLab((current) =>
                                  withIgareckRelayDefaults(current),
                                )
                              }
                            >
                              {t("ownerLabVpsIgareckRelay")}
                            </button>
                          </div>
                        </label>
                      ) : (
                        <p className="compact-note compact-note--panel">
                          {t("ownerLabVpsRelayLockedText")}
                        </p>
                      )}

                      {ownerRuntimeLabVpsRelayInputsVisible ? (
                        <>
                          <p className="compact-note compact-note--panel">
                            {t("ownerLabVpsRelayText")}
                          </p>

                          {ownerRuntimeLabVpsRelayOwnerMode ? (
                            <p className="compact-note compact-note--panel">
                              {t("ownerLabVpsRelayOwnerText")}
                            </p>
                          ) : null}

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsRelaySubscriptionUrl")}</span>
                            <input
                              value={ownerRuntimeLab.vpsRelaySubscriptionUrl}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsRelaySubscriptionUrl: event.target.value,
                                }))
                              }
                              placeholder={
                                defaultOwnerRuntimeLabRelaySubscriptionUrl
                              }
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsRelaySourceLabel")}</span>
                            <input
                              value={ownerRuntimeLab.vpsRelaySourceLabel}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsRelaySourceLabel: event.target.value,
                                }))
                              }
                              placeholder={
                                defaultOwnerRuntimeLabRelaySourceLabel
                              }
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
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsServerName: event.target.value,
                                }))
                              }
                              placeholder="pimg.mycdn.me"
                            />
                          </label>

                          <label className="input-field">
                            <span>{t("ownerLabVpsPort")}</span>
                            <input
                              value={ownerRuntimeLab.vpsPort}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsPort: event.target.value,
                                }))
                              }
                              placeholder="10443"
                              inputMode="numeric"
                            />
                          </label>

                          <label className="input-field">
                            <span>{t("ownerLabVpsTransport")}</span>
                            <div className="lang-toggle">
                              <button
                                className={
                                  ownerRuntimeLab.vpsTransport === "tcp"
                                    ? "lang-button is-active"
                                    : "lang-button"
                                }
                                type="button"
                                aria-pressed={
                                  ownerRuntimeLab.vpsTransport === "tcp"
                                }
                                onClick={() =>
                                  setOwnerRuntimeLab((current) => ({
                                    ...current,
                                    vpsTransport: "tcp",
                                  }))
                                }
                              >
                                TCP
                              </button>
                              <button
                                className={
                                  ownerRuntimeLab.vpsTransport === "grpc"
                                    ? "lang-button is-active"
                                    : "lang-button"
                                }
                                type="button"
                                aria-pressed={
                                  ownerRuntimeLab.vpsTransport === "grpc"
                                }
                                onClick={() =>
                                  setOwnerRuntimeLab((current) => ({
                                    ...current,
                                    vpsTransport: "grpc",
                                  }))
                                }
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
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsFlow: event.target.value,
                                }))
                              }
                              placeholder="xtls-rprx-vision"
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsFingerprint")}</span>
                            <input
                              value={ownerRuntimeLab.vpsFingerprint}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsFingerprint: event.target.value,
                                }))
                              }
                              placeholder={
                                ownerRuntimeLab.vpsTransport === "grpc"
                                  ? "firefox"
                                  : "chrome"
                              }
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsGrpcServiceName")}</span>
                            <input
                              value={ownerRuntimeLab.vpsGrpcServiceName}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsGrpcServiceName: event.target.value,
                                }))
                              }
                              placeholder="grpc serviceName"
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsGrpcAuthority")}</span>
                            <input
                              value={ownerRuntimeLab.vpsGrpcAuthority}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsGrpcAuthority: event.target.value,
                                }))
                              }
                              placeholder="grpc authority"
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsSource")}</span>
                            <input
                              value={ownerRuntimeLab.vpsSource}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsSource: event.target.value,
                                }))
                              }
                              placeholder="operator-curated:vps-lab"
                            />
                          </label>

                          <label className="input-field input-span">
                            <span>{t("ownerLabVpsTag")}</span>
                            <input
                              value={ownerRuntimeLab.vpsTag}
                              onChange={(event) =>
                                setOwnerRuntimeLab((current) => ({
                                  ...current,
                                  vpsTag: event.target.value,
                                }))
                              }
                              placeholder="reality-lab-pimg-mycdn-me-tcp"
                            />
                          </label>
                        </>
                      ) : null}
                    </>
                  ) : null}

                  {ownerRuntimeLabDisabledReason ? (
                    <p className="compact-note compact-note--panel">
                      {ownerRuntimeLabDisabledReason}
                    </p>
                  ) : null}

                  <div className="sheet-actions">
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleStartOwnerRuntimeLab}
                      disabled={
                        isPending || Boolean(ownerRuntimeLabDisabledReason)
                      }
                    >
                      {isBusy("startOwnerRuntimeLab")
                        ? t("startingTunnel")
                        : t("ownerLabStart")}
                    </button>
                    <button
                      className="ghost"
                      type="button"
                      onClick={handleStopTunnel}
                      disabled={
                        isPending ||
                        !localTunnel ||
                        localTunnel.status === "idle" ||
                        localTunnel.status === "stopped"
                      }
                    >
                      {isBusy("stopTunnel")
                        ? t("stoppingTunnel")
                        : t("stopTunnel")}
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
                <pre className="command-card__output">
                  {runtimeRelayAutoselectSummaryDisplay}
                </pre>
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
                <pre className="command-card__output command-card__output--long">
                  {runtimeLogDisplay}
                </pre>
              </div>

              <div className="command-card command-card--compact">
                <strong>{t("lastTest")}</strong>
                <p className="compact-note">
                  {localTunnel?.lastTest?.url ?? "https://example.com"}
                  {localTunnel?.lastTest?.checkedAt
                    ? ` / ${localTunnel.lastTest.checkedAt}`
                    : ""}
                </p>
                <pre className="command-card__output">
                  {runtimeLastTestDisplay}
                </pre>
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
        <div
          className="sheet-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("sheetMoreTitle")}
        >
          <button
            className="sheet-overlay__backdrop"
            onClick={() => setActiveSheet(null)}
            aria-label={t("close")}
          />
          <div className="sheet-panel">
            <div className="sheet-panel__head">
              <div>
                <span className="section-eyebrow">{t("guestAccess")}</span>
                <h3 className="sheet-panel__title">{t("sheetMoreTitle")}</h3>
              </div>
              <button
                className="ghost ghost--compact"
                type="button"
                onClick={() => setActiveSheet(null)}
              >
                {t("close")}
              </button>
            </div>

            <div className="sheet-stack">
              <p className="compact-note compact-note--panel">
                {t("guestAccessIntro")}
              </p>

              <div className="sheet-actions">
                <button
                  className="ghost"
                  type="button"
                  onClick={handleGenerateGuestProfile}
                  disabled={isPending || !canGenerateGuestProfile}
                >
                  {t("generateShareCode")}
                </button>
                <button
                  className="ghost"
                  type="button"
                  onClick={handleExportInviteFile}
                  disabled={
                    isPending ||
                    isBusy("exportInviteFile") ||
                    !exportableInviteProfile?.rawJson
                  }
                >
                  {t("exportProfileFile")}
                </button>
                <button
                  className="ghost"
                  type="button"
                  onClick={handleOpenImportProfileFile}
                  disabled={isPending}
                >
                  {t("importProfileFile")}
                </button>
              </div>

              {!canGenerateGuestProfile && guestProfileHint ? (
                <p className="compact-note compact-note--panel">
                  {guestProfileHint}
                </p>
              ) : null}

              {inviteFileNotice ? (
                <p className="status-banner status-success">{inviteFileNotice}</p>
              ) : null}

              <div className="command-card command-card--compact">
                <strong>{t("importProfileFile")}</strong>
                <p className="compact-note">{t("importProfileIntro")}</p>
              </div>
            </div>
          </div>
        </div>
      ) : null}

      {showDeploymentOverlay && plan.length > 0 ? (
        <div
          className="deployment-overlay"
          role="dialog"
          aria-modal="true"
          aria-label={t("deploymentDetails")}
        >
          <div
            className="deployment-overlay__backdrop"
            onClick={() => setShowDeploymentOverlay(false)}
          />
          <div className="deployment-overlay__panel">
            <div className="deployment-overlay__head">
              <div>
                <span className="section-eyebrow">{t("provisioning")}</span>
                <h2 className="section-title">{t("deploymentDetails")}</h2>
              </div>
              <button
                className="ghost"
                onClick={() => setShowDeploymentOverlay(false)}
                type="button"
              >
                {t("close")}
              </button>
            </div>

            <StageList
              stages={plan.map(translateStage)}
              statusLabels={stageStatusLabels}
            />

            {deployment?.healthChecks?.length ? (
              <div className="check-list" style={{ marginTop: 18 }}>
                {deployment.healthChecks.map((check) => (
                  <div className="check-row" key={check.key}>
                    <div>
                      <strong>
                        {translateCheckLabel(check.key, check.label)}
                      </strong>
                      <p>{translateCheckDetail(check.detail)}</p>
                    </div>
                    <span
                      className={check.ok ? "pill pill-ok" : "pill pill-off"}
                    >
                      {check.ok ? t("checkOk") : t("checkFail")}
                    </span>
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        </div>
      ) : null}

    </>
  );
}
