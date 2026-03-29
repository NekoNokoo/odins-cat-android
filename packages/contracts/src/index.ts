export type AuthMethod = "password" | "private-key";
export type TransportMode = "vk-turn-proxy+xray" | "xray";
export type TunnelEngine = "xray" | "sing-box";
export type TunnelProtocol = "direct-wireguard" | "vless-reality";
export type StageStatus = "queued" | "current" | "done" | "failed";
export type ProtocolPackStatus = "active" | "staged";

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
  vkTurnProxyPort?: number;
  realityPort?: number;
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
  vkTurnProxyPort: number;
  endpointPort?: number;
  endpoint: string;
  fingerprint: string;
  vlessReality?: InviteRealityProfile;
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
}

export interface ProvisionResponse {
  deploymentId: string;
  status: "accepted";
}

export interface DeploymentState {
  deploymentId: string;
  serverHost: string;
  transport: string;
  engine?: TunnelEngine;
  protocol?: TunnelProtocol;
  status: "queued" | "running" | "done" | "failed";
  steps: DeployStage[];
  turnPort?: number;
  wireGuardPort?: number;
  realityPort?: number;
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
}

export interface ValidationResponse {
  ok: boolean;
  host: string;
  user: string;
  authMethod: AuthMethod;
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

export interface LocalTunnelStartRequest {
  server: ServerDraft;
  secret: string;
  vkLink: string;
}

export interface LocalTunnelState {
  status: "idle" | "starting" | "running" | "stopped" | "failed";
  socksAddress?: string;
  bridgeAddress?: string;
  vkLink?: string;
  serverHost?: string;
  transport?: string;
  engine?: TunnelEngine;
  protocol?: TunnelProtocol;
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
