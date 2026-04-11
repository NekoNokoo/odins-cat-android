package provision

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const ownerProfileRemotePath = whitelistInvitePath
const preferredLocalSOCKSPort = 58371
const singBoxReleaseVersion = "1.12.22"

type ownerProfile struct {
	Name            string              `json:"name"`
	Transport       string              `json:"transport"`
	ActiveProtocol  string              `json:"activeProtocol,omitempty"`
	ServerHost      string              `json:"serverHost"`
	VKTurnStreamCount int               `json:"vkTurnStreamCount,omitempty"`
	VKTurnProxyPort int                 `json:"vkTurnProxyPort"`
	EndpointPort    int                 `json:"endpointPort,omitempty"`
	ProtocolPack    []ProtocolPackEntry `json:"protocolPack,omitempty"`
	AndroidRuntime  map[string]any      `json:"androidRuntime,omitempty"`
	StagedFallbacks map[string]any      `json:"stagedFallbacks,omitempty"`
	WireGuard       struct {
		ServerPublicKey  string `json:"serverPublicKey"`
		ClientPrivateKey string `json:"clientPrivateKey"`
		ClientPublicKey  string `json:"clientPublicKey"`
		Address          string `json:"address"`
		MTU              int    `json:"mtu"`
	} `json:"wireguard"`
}

type OwnerProfileResponse struct {
	Exists          bool                `json:"exists"`
	Name            string              `json:"name,omitempty"`
	Transport       string              `json:"transport,omitempty"`
	ActiveProtocol  string              `json:"activeProtocol,omitempty"`
	ServerHost      string              `json:"serverHost,omitempty"`
	VKTurnStreamCount int               `json:"vkTurnStreamCount,omitempty"`
	VKTurnProxyPort int                 `json:"vkTurnProxyPort,omitempty"`
	EndpointPort    int                 `json:"endpointPort,omitempty"`
	LocalPath       string              `json:"localPath,omitempty"`
	RawJSON         string              `json:"rawJson,omitempty"`
	ProtocolPack    []ProtocolPackEntry `json:"protocolPack,omitempty"`
	AndroidRuntime  map[string]any      `json:"androidRuntime,omitempty"`
	StagedFallbacks map[string]any      `json:"stagedFallbacks,omitempty"`
	WireGuard       struct {
		ServerPublicKey  string `json:"serverPublicKey"`
		ClientPrivateKey string `json:"clientPrivateKey"`
		ClientPublicKey  string `json:"clientPublicKey"`
		Address          string `json:"address"`
		MTU              int    `json:"mtu"`
	} `json:"wireguard,omitempty"`
	Error string `json:"error,omitempty"`
}

type LocalTunnelState struct {
	Status        string                 `json:"status"`
	SOCKSAddress  string                 `json:"socksAddress,omitempty"`
	BridgeAddress string                 `json:"bridgeAddress,omitempty"`
	VKLink        string                 `json:"vkLink,omitempty"`
	ServerHost    string                 `json:"serverHost,omitempty"`
	Transport     string                 `json:"transport,omitempty"`
	Engine        string                 `json:"engine,omitempty"`
	Protocol      string                 `json:"protocol,omitempty"`
	Error         string                 `json:"error,omitempty"`
	CooldownUntil string                 `json:"cooldownUntil,omitempty"`
	CooldownSecs  int                    `json:"cooldownRemainingSeconds,omitempty"`
	LogTail       []string               `json:"logTail,omitempty"`
	LastTest      *LocalTunnelTestResult `json:"lastTest,omitempty"`
}

type LocalTunnelTestResult struct {
	OK        bool   `json:"ok"`
	Status    string `json:"status"`
	URL       string `json:"url"`
	Output    string `json:"output,omitempty"`
	Error     string `json:"error,omitempty"`
	CheckedAt string `json:"checkedAt,omitempty"`
}

type localTunnelManager struct {
	mu     sync.Mutex
	state  LocalTunnelState
	cancel context.CancelFunc
	cmds   []*exec.Cmd
	files  []*os.File
	logs   []string
}

var tunnelManager = &localTunnelManager{
	state: LocalTunnelState{Status: "idle"},
}

const vkRateLimitCooldown = 15 * time.Minute

func StartLocalTunnel(req Request, vkLink string) LocalTunnelState {
	tunnelManager.mu.Lock()
	defer tunnelManager.mu.Unlock()

	if req.Server.Transport == TransportVKTurnProxyXray && tunnelManager.cooldownActiveLocked() {
		tunnelManager.state.Status = "failed"
		tunnelManager.state.VKLink = vkLink
		tunnelManager.state.ServerHost = req.Server.Host
		tunnelManager.state.Error = tunnelManager.cooldownMessageLocked()
		state := tunnelManager.snapshotLocked()
		return state
	}

	tunnelManager.stopLocked()
	tunnelManager.cleanupOrphanedClientsLocked()
	tunnelManager.state = LocalTunnelState{
		Status:     "starting",
		VKLink:     vkLink,
		ServerHost: req.Server.Host,
		Transport:  string(req.Server.Transport),
		Engine:     string(resolvedEngine(req.Server.Engine, req.Server.Transport, req.Server.Protocol)),
		Protocol:   string(normalizedProtocol(req.Server.Transport, req.Server.Protocol)),
	}
	tunnelManager.logs = nil

	ctx, cancel := context.WithCancel(context.Background())
	tunnelManager.cancel = cancel

	go tunnelManager.run(ctx, req, vkLink)

	return tunnelManager.state
}

func StopLocalTunnel() LocalTunnelState {
	tunnelManager.mu.Lock()
	tunnelManager.stopLocked()
	tunnelManager.cleanupOrphanedClientsLocked()
	tunnelManager.setStateLocked("stopped", "")
	state := tunnelManager.state
	tunnelManager.mu.Unlock()
	_ = DisableSystemProxy()
	return state
}

func GetLocalTunnelState() LocalTunnelState {
	tunnelManager.mu.Lock()
	defer tunnelManager.mu.Unlock()
	if tunnelManager.cooldownActiveLocked() && tunnelManager.state.Error == "" {
		tunnelManager.state.Error = tunnelManager.cooldownMessageLocked()
	}
	if tunnelManager.state.Status == "running" && tunnelManager.state.SOCKSAddress != "" && !isSOCKSReady(tunnelManager.state.SOCKSAddress) {
		tunnelManager.setStateLocked("failed", "local SOCKS tunnel is not accepting connections")
		tunnelManager.logs = append(tunnelManager.logs, tunnelManager.state.Error)
		tunnelManager.trimLogsLocked()
	}
	return tunnelManager.snapshotLocked()
}

func TestLocalTunnel(url string) LocalTunnelState {
	tunnelManager.mu.Lock()
	if url == "" {
		url = "https://example.com"
	}
	if tunnelManager.state.Status != "running" || tunnelManager.state.SOCKSAddress == "" {
		state := tunnelManager.state
		state.LastTest = &LocalTunnelTestResult{
			OK:        false,
			Status:    "failed",
			URL:       url,
			Error:     "local tunnel is not running",
			CheckedAt: time.Now().UTC().Format(time.RFC3339),
		}
		tunnelManager.state = state
		state.LogTail = append([]string(nil), tunnelManager.logs...)
		tunnelManager.mu.Unlock()
		return state
	}

	socksAddress := tunnelManager.state.SOCKSAddress
	tunnelManager.state.LastTest = &LocalTunnelTestResult{
		OK:        false,
		Status:    "running",
		URL:       url,
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
	}
	state := tunnelManager.state
	state.LogTail = append([]string(nil), tunnelManager.logs...)
	tunnelManager.mu.Unlock()

	tunnelManager.mu.Lock()
	defer tunnelManager.mu.Unlock()

	result := runSOCKSProbe(socksAddress, url, 8, 20)
	tunnelManager.state.LastTest = result
	if result.OK {
		tunnelManager.logs = append(tunnelManager.logs, "Tunnel test passed for "+url)
	} else {
		tunnelManager.logs = append(tunnelManager.logs, "Tunnel test failed for "+url+": "+result.Error)
	}
	tunnelManager.trimLogsLocked()

	state = tunnelManager.state
	state.LogTail = append([]string(nil), tunnelManager.logs...)
	return state
}

func GetLocalOwnerProfile(host string) OwnerProfileResponse {
	if strings.TrimSpace(host) == "" {
		return OwnerProfileResponse{
			Exists: false,
			Error:  "host is required",
		}
	}

	targetPath, err := localProfilePath(host)
	if err != nil {
		return OwnerProfileResponse{
			Exists: false,
			Error:  err.Error(),
		}
	}

	data, err := os.ReadFile(targetPath)
	if err != nil {
		if os.IsNotExist(err) {
			return OwnerProfileResponse{
				Exists:    false,
				LocalPath: targetPath,
			}
		}
		return OwnerProfileResponse{
			Exists:    false,
			LocalPath: targetPath,
			Error:     err.Error(),
		}
	}

	var profile ownerProfile
	if err := json.Unmarshal(data, &profile); err != nil {
		return OwnerProfileResponse{
			Exists:    false,
			LocalPath: targetPath,
			Error:     fmt.Sprintf("parse local owner profile: %v", err),
		}
	}
	if profile.StagedFallbacks == nil {
		profile.StagedFallbacks = map[string]any{}
	}
	profile.AndroidRuntime = effectiveOwnerAndroidRuntime(
		profile.ServerHost,
		profile.StagedFallbacks,
		profile.AndroidRuntime,
	)
	profile.VKTurnStreamCount = effectiveVKTurnStreamCount(profile.VKTurnStreamCount)
	ensureRealityRelayDirectFallback(profile.StagedFallbacks)
	ensureRealityRelayOwnerEgressFallback(profile.StagedFallbacks)
	normalizedRaw, _ := json.MarshalIndent(profile, "", "  ")

	resp := OwnerProfileResponse{
		Exists:          true,
		Name:            profile.Name,
		Transport:       profile.Transport,
		ActiveProtocol:  profile.ActiveProtocol,
		ServerHost:      profile.ServerHost,
		VKTurnStreamCount: effectiveVKTurnStreamCount(profile.VKTurnStreamCount),
		VKTurnProxyPort: profile.VKTurnProxyPort,
		EndpointPort:    effectiveOwnerEndpointPort(profile),
		LocalPath:       targetPath,
		RawJSON:         string(normalizedRaw),
		ProtocolPack: buildProtocolPackWithFallbacks(
			Transport(profile.Transport),
			effectiveOwnerEndpointPort(profile),
			realityPortFromStagedFallbacks(profile.StagedFallbacks),
			profile.VKTurnProxyPort,
			profile.StagedFallbacks,
		),
		AndroidRuntime: profile.AndroidRuntime,
		StagedFallbacks: profile.StagedFallbacks,
	}
	resp.WireGuard.ServerPublicKey = profile.WireGuard.ServerPublicKey
	resp.WireGuard.ClientPrivateKey = profile.WireGuard.ClientPrivateKey
	resp.WireGuard.ClientPublicKey = profile.WireGuard.ClientPublicKey
	resp.WireGuard.Address = profile.WireGuard.Address
	resp.WireGuard.MTU = profile.WireGuard.MTU
	return resp
}

func (m *localTunnelManager) run(ctx context.Context, req Request, vkLink string) {
	profile, err := loadOwnerProfile(req)
	if err != nil {
		m.fail(err)
		return
	}

	socksPort, usingFallbackSOCKSPort, err := reserveLocalSOCKSPort()
	if err != nil {
		m.fail(err)
		return
	}

	endpointPort := effectiveOwnerEndpointPort(profile)
	if endpointPort == 0 {
		m.fail(fmt.Errorf("owner profile endpointPort is required"))
		return
	}

	bridgePort := 0
	if profile.Transport == string(TransportVKTurnProxyXray) {
		bridgePort, err = freePort("udp")
		if err != nil {
			m.fail(err)
			return
		}
	}

	engine := resolvedEngine(req.Server.Engine, req.Server.Transport, req.Server.Protocol)
	protocol := normalizedProtocol(req.Server.Transport, req.Server.Protocol)
	if profile.Transport == string(TransportVKTurnProxyXray) {
		engine = EngineXray
		protocol = ProtocolDirectWireGuard
	}

	clientBinary, clientConfigPath, clientCmd, clientLog, clientLogPath, err := buildLocalTunnelClient(
		ctx,
		engine,
		protocol,
		profile,
		socksPort,
		bridgePort,
		endpointPort,
	)
	if err != nil {
		m.fail(err)
		return
	}
	_ = clientBinary
	_ = clientConfigPath

	var vkCmd *exec.Cmd
	var vkLog *os.File
	var vkLogPath string
	if profile.Transport == string(TransportVKTurnProxyXray) {
		vkBinary, err := ensureLocalVKClientBinary()
		if err != nil {
			m.fail(err)
			return
		}
		vkCmd = exec.CommandContext(
			ctx,
			vkBinary,
			"-peer", fmt.Sprintf("%s:%d", profile.ServerHost, endpointPort),
			"-vk-link", vkLink,
			"-n", strconv.Itoa(effectiveVKTurnStreamCount(profile.VKTurnStreamCount)),
			"-listen", fmt.Sprintf("127.0.0.1:%d", bridgePort),
		)
		vkLog, _ = createLogFile("vk-turn-proxy-client")
		if vkLog != nil {
			vkLogPath = vkLog.Name()
			vkCmd.Stdout = vkLog
			vkCmd.Stderr = vkLog
		}
		if err := vkCmd.Start(); err != nil {
			m.fail(fmt.Errorf("start vk-turn-proxy client: %w", err))
			return
		}
	}
	if err := clientCmd.Start(); err != nil {
		if vkCmd != nil && vkCmd.Process != nil {
			_ = vkCmd.Process.Kill()
		}
		m.fail(fmt.Errorf("start %s client: %w", engine, err))
		return
	}

	vkExit := make(chan error, 1)
	clientExit := make(chan error, 1)
	if vkCmd != nil {
		go func() {
			vkExit <- vkCmd.Wait()
		}()
	}
	go func() {
		clientExit <- clientCmd.Wait()
	}()

	socksAddress := fmt.Sprintf("127.0.0.1:%d", socksPort)
	if err := waitForSOCKSReady(ctx, socksAddress, 5*time.Second, clientExit, clientLogPath, m); err != nil {
		if ctx.Err() == nil {
			m.fail(err)
		}
		return
	}
	select {
	case err := <-vkExit:
		if vkCmd != nil && ctx.Err() == nil {
			m.fail(m.describeProcessExit("vk-turn-proxy client", err, vkLogPath))
		}
		return
	default:
	}
	if vkCmd != nil {
		if err := waitForVKRelayWarmup(ctx, 4*time.Second, vkExit, vkLogPath, m); err != nil {
			if ctx.Err() == nil {
				m.fail(err)
			}
			return
		}
	}

	m.mu.Lock()
	if vkCmd != nil {
		m.cmds = []*exec.Cmd{vkCmd, clientCmd}
	} else {
		m.cmds = []*exec.Cmd{clientCmd}
	}
	m.files = compactFiles(vkLog, clientLog)
	m.state = LocalTunnelState{
		Status:        "running",
		SOCKSAddress:  socksAddress,
		BridgeAddress: "",
		VKLink:        vkLink,
		ServerHost:    profile.ServerHost,
		Transport:     profile.Transport,
		Engine:        string(engine),
		Protocol:      string(protocol),
		LastTest: &LocalTunnelTestResult{
			OK:     false,
			Status: "idle",
			URL:    defaultProbeHTTPSURL,
		},
	}
	if usingFallbackSOCKSPort {
		m.logs = append(m.logs, fmt.Sprintf("Preferred local SOCKS port %d was busy, using %s", preferredLocalSOCKSPort, socksAddress))
	}
	m.logs = append(m.logs, "Local tunnel started")
	m.mu.Unlock()

	if vkCmd != nil {
		go func() {
			err := <-vkExit
			if ctx.Err() == nil {
				m.fail(m.describeProcessExit("vk-turn-proxy client", err, vkLogPath))
			}
		}()
	}

	go func() {
		err := <-clientExit
		if ctx.Err() == nil {
			m.fail(m.describeProcessExit(string(engine)+" client", err, clientLogPath))
		}
	}()
}

func buildLocalTunnelClient(
	ctx context.Context,
	engine CoreEngine,
	protocol TunnelProtocol,
	profile ownerProfile,
	socksPort, bridgePort, endpointPort int,
) (string, string, *exec.Cmd, *os.File, string, error) {
	if protocol == ProtocolVLESSReality {
		binaryPath, err := ensureLocalSingBoxBinary()
		if err != nil {
			return "", "", nil, nil, "", err
		}
		configPath, err := writeLocalRealitySingBoxConfig(profile, socksPort)
		if err != nil {
			return "", "", nil, nil, "", err
		}
		cmd := exec.CommandContext(ctx, binaryPath, "run", "-c", configPath)
		logFile, _ := createLogFile("sing-box-reality-client")
		logPath := ""
		if logFile != nil {
			logPath = logFile.Name()
			cmd.Stdout = logFile
			cmd.Stderr = logFile
		}
		return binaryPath, configPath, cmd, logFile, logPath, nil
	}
	switch engine {
	case EngineSingBox:
		binaryPath, err := ensureLocalSingBoxBinary()
		if err != nil {
			return "", "", nil, nil, "", err
		}
		configPath, err := writeLocalSingBoxConfig(profile, socksPort, bridgePort, endpointPort)
		if err != nil {
			return "", "", nil, nil, "", err
		}
		cmd := exec.CommandContext(ctx, binaryPath, "run", "-c", configPath)
		cmd.Env = append(os.Environ(), "ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true")
		logFile, _ := createLogFile("sing-box-client")
		logPath := ""
		if logFile != nil {
			logPath = logFile.Name()
			cmd.Stdout = logFile
			cmd.Stderr = logFile
		}
		return binaryPath, configPath, cmd, logFile, logPath, nil
	default:
		binaryPath, err := ensureLocalXrayBinary()
		if err != nil {
			return "", "", nil, nil, "", err
		}
		configPath, err := writeLocalXrayConfig(profile, socksPort, bridgePort, endpointPort)
		if err != nil {
			return "", "", nil, nil, "", err
		}
		cmd := exec.CommandContext(ctx, binaryPath, "run", "-config", configPath)
		logFile, _ := createLogFile("xray-client")
		logPath := ""
		if logFile != nil {
			logPath = logFile.Name()
			cmd.Stdout = logFile
			cmd.Stderr = logFile
		}
		return binaryPath, configPath, cmd, logFile, logPath, nil
	}
}

func loadOwnerProfile(req Request) (ownerProfile, error) {
	var profile ownerProfile
	expectedProtocol := normalizedProtocol(req.Server.Transport, req.Server.Protocol)
	cachedOwnerFound := false

	localPath, err := localProfilePath(req.Server.Host)
	if err == nil {
		if data, readErr := os.ReadFile(localPath); readErr == nil {
			if unmarshalErr := json.Unmarshal(data, &profile); unmarshalErr == nil {
				if ownerProfileMatchesRequest(profile, req.Server.Transport) {
					cachedOwnerFound = true
					if ownerProfileSupportsProtocol(profile, req.Server.Transport, expectedProtocol) &&
						!(req.Secret != "" && req.Server.Transport == TransportVKTurnProxyXray) {
						return runtimeOwnerProfileForRequest(profile, req.Server.Transport)
					}
				}
			}
		}
	}

	if req.Secret == "" {
		importedProfile, importedErr := loadImportedProfile(req.Server.Host, req.Server.Transport)
		if importedErr == nil && ownerProfileSupportsProtocol(importedProfile, req.Server.Transport, expectedProtocol) {
			return runtimeOwnerProfileForRequest(importedProfile, req.Server.Transport)
		}
		if cachedOwnerFound {
			return runtimeOwnerProfileForRequest(profile, req.Server.Transport)
		}
		return profile, fmt.Errorf("no usable imported access key found for %s on %s", expectedProtocol, req.Server.Host)
	}

	client, err := connectSSH(req)
	if err != nil {
		return profile, err
	}
	defer client.Close()

	profileText, err := runRemote(client, "cat "+quoteShell(ownerProfileRemotePath))
	if err != nil {
		return profile, err
	}

	if err := json.Unmarshal([]byte(profileText), &profile); err != nil {
		return profile, fmt.Errorf("parse owner profile: %w", err)
	}
	if err := saveLocalOwnerProfile(req.Server.Host, []byte(profileText)); err != nil {
		return profile, err
	}
	if req.Server.Transport == TransportVKTurnProxyXray {
		return ensureVKRuntimeOwnerProfile(client, profile)
	}
	if !ownerProfileSupportsProtocol(profile, req.Server.Transport, expectedProtocol) {
		return profile, fmt.Errorf("no usable owner profile found for %s on %s", expectedProtocol, req.Server.Host)
	}
	return profile, nil
}

func ensureVKRuntimeOwnerProfile(client *ssh.Client, profile ownerProfile) (ownerProfile, error) {
	var (
		connectPort        int
		preferredRelayPort int
	)

	switch profile.Transport {
	case string(TransportVKTurnProxyXray):
		preferredRelayPort = effectiveOwnerEndpointPort(profile)
	default:
		connectPort = effectiveOwnerEndpointPort(profile)
		preferredRelayPort = profile.VKTurnProxyPort
	}

	relayPort, err := ensureRemoteVKRelayService(client, connectPort, preferredRelayPort)
	if err != nil {
		return ownerProfile{}, err
	}
	return buildVKRelayRuntimeProfile(profile, relayPort)
}

func buildVKRelayRuntimeProfile(profile ownerProfile, relayPort int) (ownerProfile, error) {
	if relayPort <= 0 {
		return ownerProfile{}, fmt.Errorf("vk relay port is required")
	}
	if strings.TrimSpace(profile.WireGuard.ServerPublicKey) == "" ||
		strings.TrimSpace(profile.WireGuard.ClientPrivateKey) == "" ||
		strings.TrimSpace(profile.WireGuard.Address) == "" {
		return ownerProfile{}, fmt.Errorf("owner profile is missing WireGuard data required for vk-turn-proxy")
	}

	wireGuardPort := effectiveOwnerEndpointPort(profile)
	profile.Transport = string(TransportVKTurnProxyXray)
	profile.VKTurnProxyPort = relayPort
	profile.EndpointPort = relayPort
	profile.ActiveProtocol = activeProtocolID(TransportVKTurnProxyXray)
	profile.ProtocolPack = buildProtocolPackWithFallbacks(
		TransportVKTurnProxyXray,
		wireGuardPort,
		realityPortFromStagedFallbacks(profile.StagedFallbacks),
		relayPort,
		profile.StagedFallbacks,
	)
	return profile, nil
}

func runtimeOwnerProfileForRequest(profile ownerProfile, transport Transport) (ownerProfile, error) {
	if transport != TransportVKTurnProxyXray {
		return profile, nil
	}
	switch profile.Transport {
	case string(TransportVKTurnProxyXray):
		if profile.VKTurnProxyPort <= 0 {
			return ownerProfile{}, fmt.Errorf("owner profile is missing vk-turn-proxy relay port")
		}
		return profile, nil
	case string(TransportXray):
		return buildVKRelayRuntimeProfile(profile, profile.VKTurnProxyPort)
	default:
		return ownerProfile{}, fmt.Errorf("owner profile transport %q does not support vk-turn-proxy runtime", profile.Transport)
	}
}

func ownerProfileMatchesRequest(profile ownerProfile, transport Transport) bool {
	switch transport {
	case TransportXray:
		return profile.Transport == string(TransportXray) && effectiveOwnerEndpointPort(profile) > 0
	case TransportVKTurnProxyXray:
		if profile.Transport != string(TransportVKTurnProxyXray) && profile.Transport != string(TransportXray) {
			return false
		}
		return profile.VKTurnProxyPort > 0
	default:
		return false
	}
}

func ownerProfileSupportsProtocol(profile ownerProfile, transport Transport, protocol TunnelProtocol) bool {
	if !ownerProfileMatchesRequest(profile, transport) {
		return false
	}

	switch normalizedProtocol(transport, protocol) {
	case ProtocolVLESSReality:
		_, err := readRealityFallback(profile)
		return err == nil
	default:
		return strings.TrimSpace(profile.WireGuard.ServerPublicKey) != "" &&
			strings.TrimSpace(profile.WireGuard.ClientPrivateKey) != "" &&
			strings.TrimSpace(profile.WireGuard.Address) != ""
	}
}

func ensureRemoteVKRelayService(client *ssh.Client, connectPort, preferredRelayPort int) (int, error) {
	if client == nil {
		return 0, fmt.Errorf("ssh client is required to prepare vk-turn-proxy relay")
	}

	unitText, unitErr := runRemote(client, "cat "+quoteShell(whitelistProxyServicePath))
	existingRelayPort, existingConnectPort := parseVKRelayUnitPorts(unitText)

	relayPort := preferredRelayPort
	if relayPort <= 0 {
		relayPort = existingRelayPort
	}
	if relayPort <= 0 {
		var err error
		relayPort, err = findRemoteFreeUDPPort(client, whitelistTurnPortStart, whitelistTurnPortEnd)
		if err != nil {
			return 0, fmt.Errorf("select vk-turn-proxy relay port: %w", err)
		}
	}

	if connectPort <= 0 {
		connectPort = existingConnectPort
	}
	if connectPort <= 0 {
		return 0, fmt.Errorf("vk-turn-proxy relay connect port is unknown on the server")
	}

	needsUnitRewrite := unitErr != nil || existingRelayPort != relayPort || existingConnectPort != connectPort
	if needsUnitRewrite {
		if _, err := runRemote(client, "test -x "+quoteShell(whitelistProxyBinaryPath)); err != nil {
			vkBinary, binaryErr := ensureVKTurnProxyBinary()
			if binaryErr != nil {
				return 0, fmt.Errorf("build vk-turn-proxy relay binary: %w", binaryErr)
			}
			if uploadErr := uploadFile(client, whitelistProxyBinaryPath, vkBinary, "0755"); uploadErr != nil {
				return 0, fmt.Errorf("upload vk-turn-proxy relay binary: %w", uploadErr)
			}
		}

		proxyUnit := renderSystemdUnit(
			"Odin One vk-turn-proxy",
			fmt.Sprintf("%s -listen 0.0.0.0:%d -connect 127.0.0.1:%d", whitelistProxyBinaryPath, relayPort, connectPort),
		)
		if err := uploadFile(client, whitelistProxyServicePath, []byte(proxyUnit), "0644"); err != nil {
			return 0, fmt.Errorf("upload vk-turn-proxy relay unit: %w", err)
		}
	}

	command := fmt.Sprintf(
		"systemctl daemon-reload && systemctl restart whitelist-vk-turn-proxy.service && systemctl is-active whitelist-vk-turn-proxy.service >/dev/null && sleep 1 && ss -H -lun | grep -Fq ':%d'",
		relayPort,
	)
	if _, err := runRemote(client, command); err != nil {
		return 0, fmt.Errorf("start vk-turn-proxy relay on %d/udp: %w", relayPort, err)
	}

	return relayPort, nil
}

var (
	vkRelayListenPattern  = regexp.MustCompile(`-listen\s+\S+:(\d+)`)
	vkRelayConnectPattern = regexp.MustCompile(`-connect\s+\S+:(\d+)`)
)

func parseVKRelayUnitPorts(unitText string) (listenPort, connectPort int) {
	listenPort = parseVKRelayPortMatch(vkRelayListenPattern, unitText)
	connectPort = parseVKRelayPortMatch(vkRelayConnectPattern, unitText)
	return listenPort, connectPort
}

func parseVKRelayPortMatch(pattern *regexp.Regexp, text string) int {
	matches := pattern.FindStringSubmatch(text)
	if len(matches) != 2 {
		return 0
	}
	port, err := strconv.Atoi(matches[1])
	if err != nil {
		return 0
	}
	return port
}

func loadImportedProfile(host string, transport Transport) (ownerProfile, error) {
	var profile ownerProfile

	invite, _, err := findLocalImportedInvite(host, string(transport))
	if err != nil {
		return profile, err
	}

	profile = ownerProfile{
		Name:            invite.Name,
		Transport:       invite.Transport,
		ServerHost:      invite.ServerHost,
		VKTurnStreamCount: effectiveVKTurnStreamCount(invite.VKTurnStreamCount),
		VKTurnProxyPort: invite.VKTurnProxyPort,
		EndpointPort:    effectiveInviteEndpointPort(invite),
	}

	if inviteSupportsVKRelay(invite) {
		profile.EndpointPort = effectiveInviteWireGuardPort(invite)
		profile.WireGuard.ServerPublicKey = invite.WireGuard.ServerPublicKey
		profile.WireGuard.ClientPrivateKey = invite.WireGuard.ClientPrivateKey
		profile.WireGuard.ClientPublicKey = invite.WireGuard.ClientPublicKey
		profile.WireGuard.Address = invite.WireGuard.Address
		profile.WireGuard.MTU = invite.WireGuard.MTU
		profile.ActiveProtocol = string(ProtocolDirectWireGuard)
	}

	if reality, err := readInviteRealityFallback(invite); err == nil {
		profile.ActiveProtocol = string(ProtocolVLESSReality)
		profile.StagedFallbacks = map[string]any{
			"vlessReality": map[string]any{
				"port":        reality.Port,
				"serverName":  reality.ServerName,
				"publicKey":   reality.PublicKey,
				"shortId":     reality.ShortID,
				"uuid":        reality.UUID,
				"flow":        reality.Flow,
				"description": "Imported VLESS + REALITY guest access profile.",
				"status":      "ready",
			},
		}
	}
	profile.ProtocolPack = buildProtocolPackWithFallbacks(
		Transport(profile.Transport),
		effectiveInviteWireGuardPort(invite),
		realityPortFromStagedFallbacks(profile.StagedFallbacks),
		invite.VKTurnProxyPort,
		profile.StagedFallbacks,
	)

	return profile, nil
}

func EnsureRealityOwnerProfile(req Request) error {
	req.Server.Transport = TransportXray
	req.Server.Engine = EngineSingBox
	req.Server.Protocol = ProtocolVLESSReality

	profile, err := loadOwnerProfile(req)
	if err == nil {
		if _, realityErr := readRealityFallback(profile); realityErr == nil {
			return nil
		}
	}

	if err := executeDeployment("", req); err != nil {
		return err
	}

	profile, err = loadOwnerProfile(req)
	if err != nil {
		return err
	}
	if _, err := readRealityFallback(profile); err != nil {
		return err
	}
	return nil
}

func (m *localTunnelManager) fail(err error) {
	m.mu.Lock()
	m.stopLocked()
	m.setStateLocked("failed", err.Error())
	if isVKRateLimitError(err) {
		until := time.Now().UTC().Add(vkRateLimitCooldown)
		m.state.CooldownUntil = until.Format(time.RFC3339)
		m.state.CooldownSecs = int(time.Until(until).Seconds())
		m.state.Error = m.cooldownMessageLocked()
	}
	m.logs = append(m.logs, err.Error())
	m.trimLogsLocked()
	m.mu.Unlock()
	_ = DisableSystemProxy()
}

func (m *localTunnelManager) stopLocked() {
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	for _, cmd := range m.cmds {
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	m.cmds = nil
	for _, file := range m.files {
		if file != nil {
			_ = file.Close()
		}
	}
	m.files = nil
}

func (m *localTunnelManager) cleanupOrphanedClientsLocked() {
	cacheDir, err := appCacheDir()
	if err != nil {
		return
	}
	patterns := []string{
		filepath.Join(cacheDir, "bin", "xray-darwin-arm64") + " run -config " + filepath.Join(cacheDir, "config", "xray-client-"),
		filepath.Join(cacheDir, "bin", "xray-darwin-arm64") + " run -config " + filepath.Join(cacheDir, "config", "xray-reality-client-"),
		filepath.Join(cacheDir, "bin", "sing-box-darwin-arm64") + " run -c " + filepath.Join(cacheDir, "config", "sing-box-client-"),
		filepath.Join(cacheDir, "bin", "sing-box-darwin-arm64") + " run -c " + filepath.Join(cacheDir, "config", "sing-box-reality-client-"),
	}
	for _, pattern := range patterns {
		_ = killMatchingProcesses(pattern, false)
	}
	time.Sleep(150 * time.Millisecond)
	for _, pattern := range patterns {
		_ = killMatchingProcesses(pattern, true)
	}
}

func (m *localTunnelManager) runDirectHealthProbe(ctx context.Context, socksAddress string) {
	time.Sleep(1500 * time.Millisecond)

	m.mu.Lock()
	if m.state.Status != "running" || m.state.SOCKSAddress != socksAddress {
		m.mu.Unlock()
		return
	}
	m.state.LastTest = &LocalTunnelTestResult{
		OK:        false,
		Status:    "running",
		URL:       defaultProbeHTTPSURL,
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
	}
	m.mu.Unlock()

	result := runSOCKSProbe(socksAddress, defaultProbeHTTPSURL, 8, 20)

	m.mu.Lock()
	defer m.mu.Unlock()
	if ctx.Err() != nil || m.state.Status != "running" || m.state.SOCKSAddress != socksAddress {
		return
	}
	m.state.LastTest = result
	if result.OK {
		m.logs = append(m.logs, "Direct egress probe passed for "+result.URL)
	} else {
		m.logs = append(m.logs, "Direct egress probe failed for "+result.URL+": "+result.Error)
	}
	m.trimLogsLocked()
}

func (m *localTunnelManager) setStateLocked(status, errText string) {
	m.state.Status = status
	m.state.SOCKSAddress = ""
	m.state.BridgeAddress = ""
	m.state.Error = errText
	m.state.LastTest = nil
}

func (m *localTunnelManager) trimLogsLocked() {
	if len(m.logs) > 20 {
		m.logs = append([]string(nil), m.logs[len(m.logs)-20:]...)
	}
}

func freePort(network string) (int, error) {
	switch network {
	case "udp":
		addr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		conn, err := net.ListenUDP("udp", addr)
		if err != nil {
			return 0, err
		}
		defer conn.Close()
		return conn.LocalAddr().(*net.UDPAddr).Port, nil
	default:
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		defer l.Close()
		return l.Addr().(*net.TCPAddr).Port, nil
	}
}

func reserveLocalSOCKSPort() (int, bool, error) {
	port, err := reserveFixedPort("tcp", preferredLocalSOCKSPort)
	if err == nil {
		return port, false, nil
	}
	fallbackPort, fallbackErr := freePort("tcp")
	if fallbackErr != nil {
		return 0, false, fmt.Errorf("preferred local SOCKS port %d is busy and no fallback port is available", preferredLocalSOCKSPort)
	}
	return fallbackPort, true, nil
}

func reserveFixedPort(network string, port int) (int, error) {
	switch network {
	case "udp":
		addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return 0, err
		}
		conn, err := net.ListenUDP("udp", addr)
		if err != nil {
			return 0, fmt.Errorf("local UDP port %d is busy", port)
		}
		defer conn.Close()
		return port, nil
	default:
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return 0, fmt.Errorf("local SOCKS port %d is busy", port)
		}
		defer l.Close()
		return port, nil
	}
}

func waitForSOCKSReady(
	ctx context.Context,
	socksAddress string,
	timeout time.Duration,
	clientExit <-chan error,
	clientLogPath string,
	manager *localTunnelManager,
) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-clientExit:
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return manager.describeProcessExit("local tunnel client", err, clientLogPath)
		default:
		}

		if isSOCKSReady(socksAddress) {
			return nil
		}
		time.Sleep(150 * time.Millisecond)
	}
	return fmt.Errorf("local SOCKS listener did not become ready on %s", socksAddress)
}

func waitForVKRelayWarmup(
	ctx context.Context,
	timeout time.Duration,
	vkExit <-chan error,
	vkLogPath string,
	manager *localTunnelManager,
) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-vkExit:
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return manager.describeProcessExit("vk-turn-proxy client", err, vkLogPath)
		default:
		}

		for _, line := range readRecentLogLines(vkLogPath, 16) {
			if strings.Contains(line, "Established DTLS connection!") || strings.Contains(line, "relayed-address=") {
				time.Sleep(600 * time.Millisecond)
				return nil
			}
		}
		time.Sleep(150 * time.Millisecond)
	}
	return nil
}

func isSOCKSReady(socksAddress string) bool {
	conn, err := net.DialTimeout("tcp", socksAddress, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func killMatchingProcesses(pattern string, force bool) error {
	args := []string{"-f"}
	if force {
		args = append(args, "-9")
	}
	args = append(args, pattern)
	cmd := exec.Command("pkill", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		text := strings.TrimSpace(string(output))
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 && text == "" {
			return nil
		}
		return fmt.Errorf("pkill %q: %w: %s", pattern, err, text)
	}
	return nil
}

func ensureLocalVKClientBinary() (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	targetDir := filepath.Join(cacheDir, "bin")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return "", err
	}
	targetPath := filepath.Join(targetDir, "vk-turn-proxy-client-darwin-arm64-v1.6.0")
	if info, err := os.Stat(targetPath); err == nil && time.Since(info.ModTime()) < 12*time.Hour {
		return targetPath, nil
	}

	goPathDir := filepath.Join(targetDir, "gopath-client")
	if err := os.MkdirAll(goPathDir, 0o755); err != nil {
		return "", err
	}
	cmd := exec.Command(
		resolveGoBinary(),
		"install",
		"-ldflags=-checklinkname=0",
		"github.com/cacggghp/vk-turn-proxy/client@v1.6.0",
	)
	cmd.Env = append(os.Environ(), "GOPATH="+goPathDir, "GOOS=darwin", "GOARCH=arm64", "CGO_ENABLED=0")
	if output, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("go install vk-turn-proxy client: %w: %s", err, strings.TrimSpace(string(output)))
	}
	installedPath := filepath.Join(goPathDir, "bin", "client")
	data, err := os.ReadFile(installedPath)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(targetPath, data, 0o755); err != nil {
		return "", err
	}
	return targetPath, nil
}

func resolveGoBinary() string {
	preferred := "/Users/vladislav/.local/opt/go/bin/go"
	if _, err := os.Stat(preferred); err == nil {
		return preferred
	}
	return "go"
}

func ensureLocalXrayBinary() (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	targetDir := filepath.Join(cacheDir, "bin")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return "", err
	}
	targetPath := filepath.Join(targetDir, "xray-darwin-arm64")
	if _, err := os.Stat(targetPath); err == nil {
		return targetPath, nil
	}

	tmpDir, err := os.MkdirTemp("", "odin-one-xray-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmpDir)

	zipPath := filepath.Join(tmpDir, "xray.zip")
	curlCmd := exec.Command("curl", "-fsSLo", zipPath, "https://github.com/XTLS/Xray-core/releases/download/v25.8.3/Xray-macos-arm64-v8a.zip")
	if output, err := curlCmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("download xray: %w: %s", err, strings.TrimSpace(string(output)))
	}
	unzipCmd := exec.Command("unzip", "-oq", zipPath, "xray", "-d", tmpDir)
	if output, err := unzipCmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("unzip xray: %w: %s", err, strings.TrimSpace(string(output)))
	}
	data, err := os.ReadFile(filepath.Join(tmpDir, "xray"))
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(targetPath, data, 0o755); err != nil {
		return "", err
	}
	return targetPath, nil
}

func ensureLocalSingBoxBinary() (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	targetDir := filepath.Join(cacheDir, "bin")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return "", err
	}
	targetPath := filepath.Join(targetDir, "sing-box-darwin-arm64")
	if _, err := os.Stat(targetPath); err == nil {
		return targetPath, nil
	}

	tmpDir, err := os.MkdirTemp("", "odin-one-sing-box-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmpDir)

	archivePath := filepath.Join(tmpDir, "sing-box.tar.gz")
	archiveURL := fmt.Sprintf(
		"https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-darwin-arm64.tar.gz",
		singBoxReleaseVersion,
		singBoxReleaseVersion,
	)
	curlCmd := exec.Command("curl", "-fsSLo", archivePath, archiveURL)
	if output, err := curlCmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("download sing-box: %w: %s", err, strings.TrimSpace(string(output)))
	}
	tarCmd := exec.Command("tar", "-xzf", archivePath, "-C", tmpDir)
	if output, err := tarCmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("extract sing-box: %w: %s", err, strings.TrimSpace(string(output)))
	}
	binaryPath := filepath.Join(tmpDir, "sing-box-"+singBoxReleaseVersion+"-darwin-arm64", "sing-box")
	data, err := os.ReadFile(binaryPath)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(targetPath, data, 0o755); err != nil {
		return "", err
	}
	return targetPath, nil
}

func writeLocalXrayConfig(profile ownerProfile, socksPort, bridgePort, endpointPort int) (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	configDir := filepath.Join(cacheDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return "", err
	}
	configPath := filepath.Join(configDir, fmt.Sprintf("xray-client-%d.json", socksPort))
	endpoint := fmt.Sprintf("%s:%d", profile.ServerHost, endpointPort)
	if profile.Transport == string(TransportVKTurnProxyXray) {
		endpoint = fmt.Sprintf("127.0.0.1:%d", bridgePort)
	}
	config := fmt.Sprintf(`{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": %d,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": %q,
        "address": [%q],
        "peers": [
          {
            "endpoint": %q,
            "publicKey": %q
          }
        ],
        "mtu": %d,
        "reserved": [0, 0, 0]
      }
    }
  ]
}
`, socksPort, profile.WireGuard.ClientPrivateKey, profile.WireGuard.Address, endpoint, profile.WireGuard.ServerPublicKey, profile.WireGuard.MTU)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		return "", err
	}
	return configPath, nil
}

func writeLocalSingBoxConfig(profile ownerProfile, socksPort, bridgePort, endpointPort int) (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	configDir := filepath.Join(cacheDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return "", err
	}
	configPath := filepath.Join(configDir, fmt.Sprintf("sing-box-client-%d.json", socksPort))
	endpoint := profile.ServerHost
	if profile.Transport == string(TransportVKTurnProxyXray) {
		endpoint = "127.0.0.1"
	}
	config := fmt.Sprintf(`{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": %d
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "wg-out",
      "server": %q,
      "server_port": %d,
      "local_address": [%q],
      "private_key": %q,
      "peer_public_key": %q,
      "mtu": %d
    }
  ],
  "route": {
    "final": "wg-out",
    "auto_detect_interface": true
  }
}
`, socksPort, endpoint, endpointPort, profile.WireGuard.Address, profile.WireGuard.ClientPrivateKey, profile.WireGuard.ServerPublicKey, profile.WireGuard.MTU)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		return "", err
	}
	return configPath, nil
}

func writeLocalRealityXrayConfig(profile ownerProfile, socksPort int) (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	configDir := filepath.Join(cacheDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return "", err
	}
	reality, err := readRealityFallback(profile)
	if err != nil {
		return "", err
	}
	configPath := filepath.Join(configDir, fmt.Sprintf("xray-reality-client-%d.json", socksPort))
	config := fmt.Sprintf(`{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": %d,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": %q,
            "port": %d,
            "users": [
              {
                "id": %q,
                "encryption": "none",
                "flow": %q
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": %q,
          "fingerprint": "chrome",
          "publicKey": %q,
          "shortId": %q,
          "spiderX": "/"
        }
      }
    }
  ]
}
`, socksPort, profile.ServerHost, reality.Port, reality.UUID, reality.Flow, reality.ServerName, reality.PublicKey, reality.ShortID)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		return "", err
	}
	return configPath, nil
}

func writeLocalRealitySingBoxConfig(profile ownerProfile, socksPort int) (string, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return "", err
	}
	configDir := filepath.Join(cacheDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return "", err
	}
	reality, err := readRealityFallback(profile)
	if err != nil {
		return "", err
	}
	configPath := filepath.Join(configDir, fmt.Sprintf("sing-box-reality-client-%d.json", socksPort))
	config := fmt.Sprintf(`{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": %d
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": %q,
      "server_port": %d,
      "uuid": %q,
      "flow": %q,
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": %q,
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": %q,
          "short_id": %q
        }
      }
    }
  ],
  "route": {
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
`, socksPort, profile.ServerHost, reality.Port, reality.UUID, reality.Flow, reality.ServerName, reality.PublicKey, reality.ShortID)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		return "", err
	}
	return configPath, nil
}

type realityFallback struct {
	Port       int
	ServerName string
	PublicKey  string
	ShortID    string
	UUID       string
	Flow       string
}

func readRealityFallback(profile ownerProfile) (realityFallback, error) {
	raw, ok := profile.StagedFallbacks["vlessReality"]
	if !ok {
		return realityFallback{}, fmt.Errorf("staged VLESS + REALITY config is not available in the owner profile")
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return realityFallback{}, fmt.Errorf("marshal staged reality config: %w", err)
	}
	var parsed struct {
		Port       int    `json:"port"`
		ServerName string `json:"serverName"`
		PublicKey  string `json:"publicKey"`
		ShortID    string `json:"shortId"`
		UUID       string `json:"uuid"`
		Flow       string `json:"flow"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		return realityFallback{}, fmt.Errorf("parse staged reality config: %w", err)
	}
	if parsed.Port <= 0 || parsed.ServerName == "" || parsed.PublicKey == "" || parsed.ShortID == "" || parsed.UUID == "" {
		return realityFallback{}, fmt.Errorf("staged VLESS + REALITY config is incomplete")
	}
	if parsed.Flow == "" {
		parsed.Flow = "xtls-rprx-vision"
	}
	return realityFallback{
		Port:       parsed.Port,
		ServerName: parsed.ServerName,
		PublicKey:  parsed.PublicKey,
		ShortID:    parsed.ShortID,
		UUID:       parsed.UUID,
		Flow:       parsed.Flow,
	}, nil
}

func effectiveOwnerEndpointPort(profile ownerProfile) int {
	if profile.EndpointPort > 0 {
		return profile.EndpointPort
	}
	return profile.VKTurnProxyPort
}

func createLogFile(prefix string) (*os.File, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return nil, err
	}
	logDir := filepath.Join(cacheDir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, err
	}
	return os.OpenFile(filepath.Join(logDir, prefix+".log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}

func (m *localTunnelManager) describeProcessExit(name string, err error, logPath string) error {
	if logPath != "" {
		logTail := readRecentLogLines(logPath, 30)
		if diagnostic := diagnoseVKLog(logTail); diagnostic != "" {
			m.mu.Lock()
			m.logs = append(m.logs, diagnostic)
			m.trimLogsLocked()
			m.mu.Unlock()
			return fmt.Errorf("%s: %s", name, diagnostic)
		}
	}
	return fmt.Errorf("%s exited: %w", name, err)
}

func (m *localTunnelManager) cooldownActiveLocked() bool {
	if m.state.CooldownUntil == "" {
		return false
	}
	until, err := time.Parse(time.RFC3339, m.state.CooldownUntil)
	if err != nil {
		m.state.CooldownUntil = ""
		m.state.CooldownSecs = 0
		return false
	}
	remaining := int(time.Until(until).Seconds())
	if remaining <= 0 {
		m.state.CooldownUntil = ""
		m.state.CooldownSecs = 0
		return false
	}
	m.state.CooldownSecs = remaining
	return true
}

func (m *localTunnelManager) cooldownMessageLocked() string {
	if !m.cooldownActiveLocked() {
		return ""
	}
	minutes := (m.state.CooldownSecs + 59) / 60
	return fmt.Sprintf("VK rate limit is active. Wait about %d min, use a fresh VK call link, then retry once.", minutes)
}

func (m *localTunnelManager) snapshotLocked() LocalTunnelState {
	if m.cooldownActiveLocked() && m.state.Error != "" && isVKRateLimitMessage(m.state.Error) {
		m.state.Error = m.cooldownMessageLocked()
	}
	state := m.state
	state.LogTail = append([]string(nil), m.logs...)
	return state
}

func isVKRateLimitError(err error) bool {
	return err != nil && isVKRateLimitMessage(err.Error())
}

func isVKRateLimitMessage(message string) bool {
	normalized := strings.ToLower(message)
	return strings.Contains(normalized, "vk rate limit")
}

func diagnoseVKLog(lines []string) string {
	joined := strings.ToLower(strings.Join(lines, "\n"))
	switch {
	case strings.Contains(joined, "rate limit reached"), strings.Contains(joined, "error_code:29"):
		return "VK rate limit reached. Wait 10-15 minutes, use a fresh VK call link, and retry with a single SOCKS request first."
	case strings.Contains(joined, "get turn creds error"):
		return "VK TURN credential request failed. Retry later with a fresh VK call link."
	default:
		return ""
	}
}

func readRecentLogLines(path string, limit int) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			filtered = append(filtered, line)
		}
	}
	if len(filtered) > limit {
		filtered = filtered[len(filtered)-limit:]
	}
	return filtered
}

func compactFiles(files ...*os.File) []*os.File {
	result := files[:0]
	for _, file := range files {
		if file != nil {
			result = append(result, file)
		}
	}
	return slices.Clone(result)
}
