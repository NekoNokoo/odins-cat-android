export type AuthMethod = "password" | "private-key";
export type TransportMode = "vk-turn-proxy+xray" | "xray";
export type TunnelEngine = "xray" | "sing-box";
export type TunnelProtocol = "direct-wireguard" | "vless-reality";
export type StageStatus = "queued" | "current" | "done" | "failed";
export type ProtocolPackStatus = "active" | "staged";
export type ProvisionFlow = "origin" | "edge-attach";
export type EdgeProvider = "yandex-edge";
export type EdgeRoutingMode =
  | "tcp-forward"
  | "sni-router"
  | "xray-proxy";

export interface ProtocolPackEntry {
  id: string;
  label: string;
  status: ProtocolPackStatus;
  engine: string;
  scheme: string;
  network: string;
  port: number;
  notes?: string;
}

export interface ServerDraft {
  host: string;
  port: number;
  username: string;
  authMethod: AuthMethod;
  transport: TransportMode;
  engine?: TunnelEngine;
  protocol?: TunnelProtocol;
  vkTurnStreamCount?: number;
  vkTurnProxyPort?: number;
  realityPort?: number;
}

export interface EdgeServerDraft {
  host: string;
  port: number;
  username: string;
  authMethod: AuthMethod;
}

export interface EdgeAttachDraft {
  enabled: boolean;
  provider: EdgeProvider;
  server: EdgeServerDraft;
  secret: string;
  publicPort?: number;
  routingMode?: EdgeRoutingMode;
}

export interface DeployStage {
  id: string;
  label: string;
  status: StageStatus;
  description: string;
}

export interface InviteRealityProfile {
  port: number;
  serverName: string;
  publicKey: string;
  shortId: string;
  uuid: string;
  flow?: string;
}

export interface InviteProfile {
  id?: string;
  role: "owner" | "guest";
  name: string;
  protocol: "wireguard" | "vless-reality";
  transport: string;
  serverHost: string;
  vkTurnStreamCount?: number;
  vkTurnProxyPort: number;
  wireGuardPort?: number;
  endpointPort?: number;
  endpoint: string;
  fingerprint: string;
  vlessReality?: InviteRealityProfile;
  supportsReality?: boolean;
  supportsVKRelay?: boolean;
  supportsRealityRelay?: boolean;
  protocolPack?: ProtocolPackEntry[];
  stagedFallbacks?: Record<string, unknown>;
  shareCode: string;
  rawJson: string;
  localPath?: string;
  importedAt?: string;
  createdAt?: string;
  revokedAt?: string;
  status?: "active" | "revoked";
  error?: string;
}

export interface GuestProfileGenerateRequest {
  server: ServerDraft;
  secret: string;
  host: string;
  name: string;
}

export interface GuestProfileListRequest {
  server: ServerDraft;
  secret: string;
  host: string;
}

export interface GuestProfileRevokeRequest {
  server: ServerDraft;
  secret: string;
  host: string;
  guestId: string;
}

export interface GuestProfileImportRequest {
  shareCode: string;
}

export interface OwnerAccessProfile {
  exists: boolean;
  name?: string;
  transport?: string;
  activeProtocol?: string;
  serverHost?: string;
  vkTurnStreamCount?: number;
  vkTurnProxyPort?: number;
  endpointPort?: number;
  localPath?: string;
  rawJson?: string;
  protocolPack?: ProtocolPackEntry[];
  stagedFallbacks?: Record<string, unknown>;
  wireguard?: {
    serverPublicKey: string;
    clientPrivateKey: string;
    clientPublicKey: string;
    address: string;
    mtu: number;
  };
  error?: string;
}

export interface ProvisionRequest {
  server: ServerDraft;
  secret: string;
  flow?: ProvisionFlow;
  edge?: EdgeAttachDraft;
}

export interface ProvisionResponse {
  deploymentId: string;
  status: "accepted";
}

export interface DeploymentState {
  deploymentId: string;
  serverHost: string;
  deployFlow?: ProvisionFlow;
  transport: string;
  engine?: TunnelEngine;
  protocol?: TunnelProtocol;
  status: "queued" | "running" | "done" | "failed";
  steps: DeployStage[];
  turnPort?: number;
  wireGuardPort?: number;
  realityPort?: number;
  edgeEnabled?: boolean;
  edgeHost?: string;
  edgePort?: number;
  edgeRoutingMode?: EdgeRoutingMode;
  healthChecks?: Array<{
    key: string;
    label: string;
    ok: boolean;
    detail: string;
  }>;
  protocolPack?: ProtocolPackEntry[];
  error?: string;
}

export interface ValidationRequest {
  server: ServerDraft;
  secret: string;
  flow?: ProvisionFlow;
  edge?: EdgeAttachDraft;
}

export interface ValidationResponse {
  ok: boolean;
  host: string;
  deployFlow?: ProvisionFlow;
  user: string;
  authMethod: AuthMethod;
  edgeEnabled?: boolean;
  edgeHost?: string;
  edgePort?: number;
  edgeRoutingMode?: EdgeRoutingMode;
  checks: Array<{
    key: string;
    label: string;
    ok: boolean;
    detail: string;
  }>;
  warnings: string[];
  protocolPack?: ProtocolPackEntry[];
  error?: string;
}

export interface WhitelistLookupResult {
  ip: string;
  valid: boolean;
  matchedIp: boolean;
  matchedCidr: boolean;
  matchedCidrs: string[];
  checkedAt: string;
  listsFetchedAt?: string;
  cached: boolean;
  sourceRepo: string;
  ipListUrl: string;
  cidrListUrl: string;
  note?: string;
  error?: string;
}

export interface InviteFileExportResult {
  fileName: string;
  exportPath: string;
  rawJson: string;
  shareCode: string;
}

export interface InviteFileShareResult {
  ok: boolean;
  fileName: string;
  cachePath?: string;
  contentUri?: string;
}

export type MobileNetworkType =
  | "cellular"
  | "wifi"
  | "ethernet"
  | "other"
  | "unknown";

export type WhitelistRuntimeStatus = "active" | "inactive" | "unknown";

export interface MobileNetworkProbeResult {
  url: string;
  ok: boolean;
  httpStatus?: number;
  error?: string;
  checkedAt?: string;
}

export interface MobileNetworkEndpoint {
  host: string;
  ip?: string;
  countryCode?: string;
  country?: string;
  error?: string;
}

export interface MobileNetworkLensRequest {
  originHost: string;
  tunnelHost?: string;
  cellularOnly?: boolean;
}

export interface MobileNetworkLensResult {
  available: boolean;
  checkedAt: string;
  networkType: MobileNetworkType;
  interfaceName?: string;
  isCellular: boolean;
  whitelistStatus: WhitelistRuntimeStatus;
  note?: string;
  yandexProbe?: MobileNetworkProbeResult;
  googleProbe?: MobileNetworkProbeResult;
  origin?: MobileNetworkEndpoint;
  tunnel?: MobileNetworkEndpoint;
  error?: string;
}

export interface InstalledAppInfo {
  packageName: string;
  appName: string;
  systemApp?: boolean;
}

export interface SplitTunnelSelection {
  excludePackages: string[];
  updatedAt?: string;
}

export interface LocalTunnelStartRequest {
  server: ServerDraft;
  secret: string;
  vkLink: string;
  excludePackages?: string[];
  ownerRuntimeLab?: OwnerRuntimeLabRequest;
}

export type OwnerRuntimeLabMode =
  | "reality-whitelist-scaffold"
  | "reality-whitelist-lab"
  | "reality-vps-scaffold"
  | "reality-vps-lab"
  | "reality-vps-relay-lab"
  | "reality-yandex-edge"
  | "reality-yandex-edge-proxy";

export type OwnerRuntimeLabTransport = "tcp" | "grpc";

export interface OwnerRuntimeLabRelayAutoselectRequest {
  enabled: boolean;
  subscriptionUrl?: string;
  sourceLabel?: string;
}

export interface OwnerRuntimeLabRequest {
  mode: OwnerRuntimeLabMode;
  hintServerName: string;
  hintCidrBucket?: string;
  hintSource?: string;
  hintTag?: string;
  vpsServerName?: string;
  vpsPort?: number;
  vpsConnectHost?: string;
  vpsConnectPort?: number;
  vpsTransport?: OwnerRuntimeLabTransport;
  vpsFlow?: string;
  vpsFingerprint?: string;
  vpsGrpcServiceName?: string;
  vpsGrpcAuthority?: string;
  vpsSource?: string;
  vpsTag?: string;
  vpsOwnerRealityEgress?: boolean;
  vpsRelayAutoselect?: OwnerRuntimeLabRelayAutoselectRequest;
}

export interface LocalTunnelState {
  status: "idle" | "starting" | "running" | "stopped" | "failed";
  socksAddress?: string;
  bridgeAddress?: string;
  pendingCaptchaUrl?: string;
  vkLink?: string;
  serverHost?: string;
  transport?: string;
  engine?: TunnelEngine;
  protocol?: TunnelProtocol;
  runtimeFamily?: string;
  activationState?: string;
  frontHost?: string;
  frontConnectHost?: string;
  frontConnectPort?: number;
  frontPath?: string;
  frontProvider?: string;
  frontTag?: string;
  relayAutoselectEnabled?: boolean;
  relayAutoselectStatus?: string;
  relayAutoselectBestHost?: string;
  relayAutoselectBestPort?: number;
  relayAutoselectBestSni?: string;
  relayAutoselectBestTag?: string;
  relayAutoselectBestLatencyMs?: number;
  relayAutoselectSourceLabel?: string;
  relayAutoselectCandidateCount?: number;
  relayAutoselectLastRefreshAt?: string;
  relayAutoselectRefreshIntervalHours?: number;
  relayAutoselectLastError?: string;
  selectedSniHint?: string;
  selectedCidrHint?: string;
  whitelistHintSource?: string;
  whitelistHintTag?: string;
  startSource?: string;
  profileHash?: string;
  excludePackages?: string[];
  configMode?: string;
  activeFeatures?: string[];
  alwaysOnEnabled?: boolean;
  lockdownEnabled?: boolean;
  resumeEligible?: boolean;
  lastNetworkEvent?: string;
  lastStartupDurationMs?: number;
  lastStartupStage?: string;
  lastFailureStage?: string;
  lastFailureCode?: string;
  networkChangeCount?: number;
  reloadCount?: number;
  restoreCount?: number;
  lastRecoveryAction?: string;
  error?: string;
  cooldownUntil?: string;
  cooldownRemainingSeconds?: number;
  logTail?: string[];
  lastTest?: LocalTunnelTestResult;
}

export interface SystemProxyState {
  supported: boolean;
  enabled: boolean;
  serviceName?: string;
  host?: string;
  port?: number;
  error?: string;
}

export interface LocalTunnelTestResult {
  ok: boolean;
  status: "idle" | "running" | "passed" | "failed";
  url: string;
  output?: string;
  error?: string;
  checkedAt?: string;
}
