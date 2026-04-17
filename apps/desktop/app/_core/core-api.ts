import type {
  DeploymentState,
  DeployStage,
  InviteFileExportResult,
  InviteFileShareResult,
  InstalledAppInfo,
  InviteProfile,
  LocalTunnelStartRequest,
  LocalTunnelState,
  MobileNetworkLensRequest,
  MobileNetworkLensResult,
  OwnerAccessProfile,
  ProvisionRequest,
  SplitTunnelSelection,
  SystemProxyState,
  ValidationResponse,
  WhitelistLookupResult
} from "@whitelist/contracts";

const apiBaseUrl = process.env.NEXT_PUBLIC_CORE_API_URL ?? "http://127.0.0.1:18088";
const androidBridgeTodo =
  "Android native runtime bridge is not implemented yet. Import, local profile access, SSH validation, deployment control-plane, and remote guest share issuance already use the native bridge.";

export type CoreHealthState = {
  service: string;
  status: string;
};

export type TunnelSpeedTestResult = {
  ok: boolean;
  status: "idle" | "running" | "passed" | "failed";
  latencyUrl?: string;
  downloadUrl?: string;
  checkedAt?: string;
  latencyMs?: number;
  downloadMbps?: number;
  downloadBytes?: number;
  downloadDurationMs?: number;
  error?: string;
};

export type CoreApiResult<T> = {
  ok: boolean;
  status: number;
  data: T;
};

type SystemProxyEnableRequest = {
  socksAddress: string;
};

type GuestProfileRequest = ProvisionRequest & {
  host: string;
  name: string;
};

type ImportProfileRequest = {
  shareCode: string;
};

type TunnelSpeedTestRequest = {
  latencyUrl?: string;
  downloadUrl?: string;
  downloadBytes?: number;
};

type TauriCoreModule = typeof import("@tauri-apps/api/core");

let tauriCorePromise: Promise<TauriCoreModule | null> | null = null;

const STATIC_WHITELIST_SOURCE = "embedded-static-whitelist";
const STATIC_WHITELIST_IP_LIST = `${STATIC_WHITELIST_SOURCE}:ipwhitelist.txt`;
const STATIC_WHITELIST_CIDR_LIST = `${STATIC_WHITELIST_SOURCE}:cidrwhitelist.txt`;
const STATIC_WHITELIST_CIDRS = [
  "51.250.0.0/17",
  "84.201.128.0/18",
  "158.160.0.0/16",
  "217.16.24.0/21",
  "95.163.248.0/22",
  "185.241.192.0/22",
  "185.39.206.0/24",
  "91.222.239.0/24",
  "109.73.201.0/24",
  "95.181.182.0/24",
  "89.253.200.0/21",
  "79.174.91.0/24",
  "79.174.92.0/24",
  "79.174.93.0/24",
  "79.174.94.0/24",
  "79.174.95.0/24",
  "185.177.73.0/24",
  "134.17.94.0/24",
  "185.141.216.0/24",
  "103.111.114.0/24",
  "78.159.247.0/24",
  "87.250.247.0/24",
  "87.250.251.0/24",
  "87.250.250.0/24",
  "87.250.254.0/24",
  "77.88.21.0/24"
] as const;
const DEFAULT_SPEEDTEST_LATENCY_URL = "https://www.gstatic.com/generate_204";
const DEFAULT_SPEEDTEST_DOWNLOAD_BYTES = 2_000_000;
const DEFAULT_SPEEDTEST_DOWNLOAD_URL = `https://speed.cloudflare.com/__down?bytes=${DEFAULT_SPEEDTEST_DOWNLOAD_BYTES}`;

function parseIpv4(ip: string) {
  const parts = ip.trim().split(".");
  if (parts.length !== 4) {
    return null;
  }
  const octets = parts.map((part) => Number.parseInt(part, 10));
  if (octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) {
    return null;
  }
  return (
    ((octets[0] ?? 0) << 24) |
    ((octets[1] ?? 0) << 16) |
    ((octets[2] ?? 0) << 8) |
    (octets[3] ?? 0)
  ) >>> 0;
}

function ipMatchesCidr(ip: number, cidr: string) {
  const [base, prefixText] = cidr.split("/");
  const baseIp = base ? parseIpv4(base) : null;
  const prefix = prefixText ? Number.parseInt(prefixText, 10) : NaN;
  if (baseIp === null || !Number.isInteger(prefix) || prefix < 0 || prefix > 32) {
    return false;
  }
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return (ip & mask) >>> 0 === (baseIp & mask) >>> 0;
}

function checkStaticWhitelistIp(ip: string): WhitelistLookupResult {
  const trimmedIp = ip.trim();
  const parsedIp = parseIpv4(trimmedIp);
  if (parsedIp === null) {
    return {
      ip: trimmedIp,
      valid: false,
      matchedIp: false,
      matchedCidr: false,
      matchedCidrs: [],
      checkedAt: new Date().toISOString(),
      cached: true,
      sourceRepo: STATIC_WHITELIST_SOURCE,
      ipListUrl: STATIC_WHITELIST_IP_LIST,
      cidrListUrl: STATIC_WHITELIST_CIDR_LIST,
      error: "enter a valid IPv4 address"
    };
  }

  const matchedCidrs = STATIC_WHITELIST_CIDRS.filter((cidr) => ipMatchesCidr(parsedIp, cidr));
  return {
    ip: trimmedIp,
    valid: true,
    matchedIp: false,
    matchedCidr: matchedCidrs.length > 0,
    matchedCidrs,
    checkedAt: new Date().toISOString(),
    listsFetchedAt: STATIC_WHITELIST_SOURCE,
    cached: true,
    sourceRepo: STATIC_WHITELIST_SOURCE,
    ipListUrl: STATIC_WHITELIST_IP_LIST,
    cidrListUrl: STATIC_WHITELIST_CIDR_LIST,
    note: "Using the bundled static whitelist dataset."
  };
}

async function runBrowserSpeedTest(
  payload: TunnelSpeedTestRequest = {}
): Promise<TunnelSpeedTestResult> {
  const latencyUrl = payload.latencyUrl?.trim() || DEFAULT_SPEEDTEST_LATENCY_URL;
  const downloadBytes =
    typeof payload.downloadBytes === "number" && payload.downloadBytes > 0
      ? Math.floor(payload.downloadBytes)
      : DEFAULT_SPEEDTEST_DOWNLOAD_BYTES;
  const downloadUrl =
    payload.downloadUrl?.trim() ||
    `https://speed.cloudflare.com/__down?bytes=${downloadBytes}`;

  const checkedAt = new Date().toISOString();

  try {
    const latencyStartedAt = performance.now();
    const latencyResponse = await fetch(latencyUrl, {
      method: "HEAD",
      cache: "no-store"
    });
    const latencyFinishedAt = performance.now();
    if (!latencyResponse.ok) {
      return {
        ok: false,
        status: "failed",
        latencyUrl,
        downloadUrl,
        checkedAt,
        error: `Latency probe returned HTTP ${latencyResponse.status}.`
      };
    }

    const downloadStartedAt = performance.now();
    const downloadResponse = await fetch(downloadUrl, {
      method: "GET",
      cache: "no-store"
    });
    if (!downloadResponse.ok) {
      return {
        ok: false,
        status: "failed",
        latencyUrl,
        downloadUrl,
        checkedAt,
        latencyMs: Math.max(1, Math.round(latencyFinishedAt - latencyStartedAt)),
        error: `Download probe returned HTTP ${downloadResponse.status}.`
      };
    }

    const buffer = await downloadResponse.arrayBuffer();
    const downloadFinishedAt = performance.now();
    const measuredBytes = buffer.byteLength;
    const durationMs = Math.max(1, Math.round(downloadFinishedAt - downloadStartedAt));
    const mbps = Number((((measuredBytes * 8) / 1_000_000 / durationMs) * 1000).toFixed(1));

    return {
      ok: true,
      status: "passed",
      latencyUrl,
      downloadUrl,
      checkedAt,
      latencyMs: Math.max(1, Math.round(latencyFinishedAt - latencyStartedAt)),
      downloadMbps: mbps,
      downloadBytes: measuredBytes,
      downloadDurationMs: durationMs
    };
  } catch (error) {
    return {
      ok: false,
      status: "failed",
      latencyUrl,
      downloadUrl,
      checkedAt,
      error: error instanceof Error ? error.message : "Browser speed test failed."
    };
  }
}

function unsupportedResult<T>(status: number, data: T): CoreApiResult<T> {
  return {
    ok: false,
    status,
    data
  };
}

async function loadTauriCore() {
  if (typeof window === "undefined") {
    return null;
  }

  tauriCorePromise ??= import("@tauri-apps/api/core").catch(() => null);
  return tauriCorePromise;
}

async function prefersAndroidNativeBridge() {
  if (typeof window === "undefined") {
    return false;
  }

  const tauriCore = await loadTauriCore();
  return Boolean(tauriCore?.isTauri() && /Android/i.test(window.navigator.userAgent));
}

async function hasTauriBridge() {
  if (typeof window === "undefined") {
    return false;
  }

  const tauriCore = await loadTauriCore();
  return Boolean(tauriCore?.isTauri());
}

async function invokeNative<T>(command: string, args?: Record<string, unknown>): Promise<CoreApiResult<T>> {
  const tauriCore = await loadTauriCore();
  if (!tauriCore?.isTauri()) {
    return unsupportedResult(500, { error: "Tauri bridge is unavailable" } as T);
  }

  try {
    const data = await tauriCore.invoke<T>(command, args);
    return {
      ok: true,
      status: 200,
      data
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return unsupportedResult(500, { error: message } as T);
  }
}

function notImplementedError(operation: string) {
  return Promise.reject(new Error(`${operation}. ${androidBridgeTodo}`));
}

function androidProxyState(error?: string): SystemProxyState {
  return {
    supported: false,
    enabled: false,
    ...(error ? { error } : {})
  };
}

async function androidVpnProxyState(forceDisabled = false): Promise<CoreApiResult<SystemProxyState>> {
  const tunnelResult = await invokeNative<LocalTunnelState>("mobile_get_local_tunnel_status");
  const tunnel = tunnelResult.data;
  const socksAddress = tunnel.socksAddress ?? "";
  const [host, portText] = socksAddress.split(":");
  const parsedPort = Number.parseInt(portText ?? "", 10);
  const enabled = !forceDisabled && tunnel.status === "running" && Boolean(socksAddress);

  return {
    ok: tunnelResult.ok,
    status: tunnelResult.status,
    data: {
      supported: true,
      enabled,
      serviceName: "Android VpnService",
      ...(enabled && host && Number.isFinite(parsedPort) ? { host, port: parsedPort } : {}),
      ...(tunnel.error ? { error: tunnel.error } : {})
    }
  };
}

function androidTunnelState(
  status: LocalTunnelState["status"],
  error?: string,
  withFailedTest = false
): LocalTunnelState {
  return {
    status,
    ...(error ? { error } : {}),
    ...(withFailedTest
      ? {
          lastTest: {
            ok: false,
            status: "failed",
            url: "https://example.com",
            error: error ?? androidBridgeTodo,
            checkedAt: new Date().toISOString()
          }
        }
      : {})
  };
}

async function requestJson<T>(path: string, init?: RequestInit): Promise<CoreApiResult<T>> {
  const response = await fetch(`${apiBaseUrl}${path}`, init);
  const data = (await response.json()) as T;
  return {
    ok: response.ok,
    status: response.status,
    data
  };
}

function postJson<T>(path: string, payload?: unknown) {
  return requestJson<T>(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    ...(payload === undefined ? {} : { body: JSON.stringify(payload) })
  });
}

export const coreApi = {
  async getHealth() {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<CoreHealthState>("mobile_core_health");
    }
    return requestJson<CoreHealthState>("/healthz");
  },

  async validateProvision(payload: ProvisionRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<ValidationResponse>("mobile_validate_provision", { payload });
    }
    return postJson<ValidationResponse>("/api/provision/validate", payload);
  },

  async getProvisionPlan(payload: ProvisionRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ steps: DeployStage[] }>("mobile_build_provision_plan", { payload });
    }
    return postJson<{ steps: DeployStage[] }>("/api/provision/plan", payload);
  },

  async startDeployment(payload: ProvisionRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<DeploymentState>("mobile_start_deployment", { payload });
    }
    return postJson<DeploymentState>("/api/provision/deploy", payload);
  },

  async getDeployment(deploymentId: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<DeploymentState>("mobile_get_deployment", { deploymentId });
    }
    return requestJson<DeploymentState>(`/api/provision/deploy/${deploymentId}`);
  },

  async getOwnerProfile(host: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<OwnerAccessProfile>("mobile_get_owner_profile", { host });
    }
    return requestJson<OwnerAccessProfile>(`/api/profile/owner?host=${encodeURIComponent(host)}`);
  },

  async getImportedProfile(host: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<InviteProfile>("mobile_get_imported_profile", { host });
    }
    return requestJson<InviteProfile>(`/api/profile/imported?host=${encodeURIComponent(host)}`);
  },

  async startLocalTunnel(payload: LocalTunnelStartRequest, useRealityStartEndpoint = false) {
    if (await prefersAndroidNativeBridge()) {
      const pause = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));
      let result = await invokeNative<LocalTunnelState>("mobile_start_local_tunnel", { payload });
      let data = result.data;

      for (let attempt = 0; attempt < 12 && data.status === "starting"; attempt += 1) {
        await pause(500);
        result = await invokeNative<LocalTunnelState>("mobile_get_local_tunnel_status");
        data = result.data;
      }

      if (data.status === "failed") {
        return unsupportedResult(502, data);
      }

      return result;
    }
    return postJson<LocalTunnelState>(
      useRealityStartEndpoint ? "/api/local-tunnel/start-reality" : "/api/local-tunnel/start",
      payload
    );
  },

  async startLocalTunnelFast(payload: LocalTunnelStartRequest, useRealityStartEndpoint = false) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<LocalTunnelState>("mobile_start_local_tunnel", { payload });
    }
    return postJson<LocalTunnelState>(
      useRealityStartEndpoint ? "/api/local-tunnel/start-reality" : "/api/local-tunnel/start",
      payload
    );
  },

  async stopLocalTunnel() {
    if (await prefersAndroidNativeBridge()) {
      const pause = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));
      let result = await invokeNative<LocalTunnelState>("mobile_stop_local_tunnel");
      let data = result.data;

      for (
        let attempt = 0;
        attempt < 16 && data.status !== "stopped" && data.status !== "idle" && data.status !== "failed";
        attempt += 1
      ) {
        await pause(250);
        result = await invokeNative<LocalTunnelState>("mobile_get_local_tunnel_status");
        data = result.data;
      }

      return result;
    }
    return postJson<LocalTunnelState>("/api/local-tunnel/stop");
  },

  async getLocalTunnelStatus() {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<LocalTunnelState>("mobile_get_local_tunnel_status");
    }
    return requestJson<LocalTunnelState>("/api/local-tunnel/status");
  },

  async runLocalTunnelTest(url: string) {
    if (await prefersAndroidNativeBridge()) {
      const result = await invokeNative<LocalTunnelState>("mobile_run_local_tunnel_test", {
        payload: { url }
      });
      if (!result.data.lastTest?.ok) {
        return unsupportedResult(502, result.data);
      }
      return result;
    }
    return postJson<LocalTunnelState>("/api/local-tunnel/test", { url });
  },

  async runLocalTunnelSpeedTest(payload: TunnelSpeedTestRequest = {}) {
    if (await prefersAndroidNativeBridge()) {
      const result = await invokeNative<TunnelSpeedTestResult>("mobile_run_local_tunnel_speed_test", {
        payload
      });
      if (!result.data.ok) {
        return unsupportedResult(502, result.data);
      }
      return result;
    }
    return {
      ok: true,
      status: 200,
      data: await runBrowserSpeedTest(payload)
    };
  },

  async getSystemProxyStatus() {
    if (await prefersAndroidNativeBridge()) {
      return androidVpnProxyState();
    }
    return requestJson<SystemProxyState>("/api/system-proxy/status");
  },

  async enableSystemProxy(payload: SystemProxyEnableRequest) {
    if (await prefersAndroidNativeBridge()) {
      const state = await androidVpnProxyState();
      if (!state.data.enabled) {
        return unsupportedResult(
          502,
          {
            ...state.data,
            error: state.data.error ?? "Android VPN runtime is not active yet."
          } satisfies SystemProxyState
        );
      }
      const [host, portText] = payload.socksAddress.split(":");
      const parsedPort = Number.parseInt(portText ?? "", 10);
      return {
        ok: true,
        status: 200,
        data: {
          ...state.data,
          ...(host && Number.isFinite(parsedPort) ? { host, port: parsedPort } : {})
        }
      };
    }
    return postJson<SystemProxyState>("/api/system-proxy/enable", payload);
  },

  async disableSystemProxy() {
    if (await prefersAndroidNativeBridge()) {
      return androidVpnProxyState();
    }
    return postJson<SystemProxyState>("/api/system-proxy/disable");
  },

  async generateGuestProfile(payload: GuestProfileRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<InviteProfile>("mobile_generate_guest_profile", { payload });
    }
    return postJson<InviteProfile>("/api/profile/guest", payload);
  },

  async importProfile(payload: ImportProfileRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<InviteProfile>("mobile_import_profile", { shareCode: payload.shareCode });
    }
    return postJson<InviteProfile>("/api/profile/import", payload);
  },

  async checkWhitelistIp(ip: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<WhitelistLookupResult>("mobile_check_whitelist_ip", { ip });
    }
    return {
      ok: true,
      status: 200,
      data: checkStaticWhitelistIp(ip)
    };
  },

  async inspectMobileNetworkLens(payload: MobileNetworkLensRequest) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<MobileNetworkLensResult>("mobile_inspect_network_lens", { payload });
    }
    return unsupportedResult(
      501,
      {
        available: false,
        checkedAt: new Date().toISOString(),
        networkType: "unknown",
        isCellular: false,
        whitelistStatus: "unknown",
        note: "Mobile whitelist detection is currently available only through the Android native bridge."
      } satisfies MobileNetworkLensResult
    );
  },

  async listInstalledApps() {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ apps: InstalledAppInfo[] }>("mobile_list_installed_apps");
    }
    return unsupportedResult(
      501,
      {
        apps: [],
        error: "Installed app listing is currently available only through the Android native bridge."
      } as { apps: InstalledAppInfo[]; error: string }
    );
  },

  async getSplitTunnelSelection() {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<SplitTunnelSelection>("mobile_get_split_tunnel_selection");
    }
    return unsupportedResult(
      501,
      {
        excludePackages: [],
        error: "Split tunnel selection is currently available only through the Android native bridge."
      } as SplitTunnelSelection & { error: string }
    );
  },

  async setSplitTunnelSelection(payload: SplitTunnelSelection) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<SplitTunnelSelection>("mobile_set_split_tunnel_selection", { payload });
    }
    return unsupportedResult(
      501,
      {
        excludePackages: payload.excludePackages,
        error: "Split tunnel selection is currently available only through the Android native bridge."
      } as SplitTunnelSelection & { error: string }
    );
  },

  async getNextVpnSessionLogState() {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ enabled: boolean }>("mobile_get_next_vpn_session_log_state");
    }
    return unsupportedResult(
      501,
      {
        enabled: false,
        error: "Next VPN session log state is currently available only through the Android native bridge."
      } as { enabled: boolean; error: string }
    );
  },

  async setNextVpnSessionLogState(enabled: boolean) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ enabled: boolean }>("mobile_set_next_vpn_session_log_state", { enabled });
    }
    return unsupportedResult(
      501,
      {
        enabled,
        error: "Next VPN session log state is currently available only through the Android native bridge."
      } as { enabled: boolean; error: string }
    );
  },

  async exportInviteFile(contents: string) {
    if (await hasTauriBridge()) {
      return invokeNative<InviteFileExportResult>("mobile_export_invite_file", { contents });
    }
    return unsupportedResult(
      501,
      {
        fileName: "",
        exportPath: "",
        rawJson: "",
        shareCode: "",
        error: "Native invite file export is unavailable."
      } as InviteFileExportResult & { error: string }
    );
  },

  async shareInviteFile(fileName: string, contents: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<InviteFileShareResult>("mobile_share_invite_file", {
        fileName,
        contents
      });
    }
    return unsupportedResult(
      501,
      {
        ok: false,
        fileName,
        error: "Native invite file sharing is currently available only through the Android bridge."
      } as InviteFileShareResult & { error: string }
    );
  },

  async exportDebugLog(fileName: string, contents: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ ok: boolean; fileName: string; exportPath: string }>(
        "mobile_export_debug_log",
        {
          fileName,
          contents
        }
      );
    }
    return unsupportedResult(
      501,
      {
        ok: false,
        fileName,
        exportPath: "",
        error: "Debug log export is currently available only through the Android native bridge."
      } as { ok: boolean; fileName: string; exportPath: string; error: string }
    );
  },

  async openExternalUrl(url: string) {
    if (await prefersAndroidNativeBridge()) {
      return invokeNative<{ ok: boolean; url?: string }>("mobile_open_external_url", {
        url
      });
    }

    if (typeof window !== "undefined") {
      window.open(url, "_blank", "noopener,noreferrer");
      return {
        ok: true,
        status: 200,
        data: {
          ok: true,
          url
        }
      };
    }

    return unsupportedResult(
      501,
      {
        ok: false,
        url,
        error: "External URL opening is unavailable in this environment."
      } as { ok: boolean; url?: string; error: string }
    );
  }
};
