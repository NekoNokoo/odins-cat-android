package provision

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	whitelistTurnPortStart      = 56080
	whitelistTurnPortEnd        = 56180
	whitelistWireGuardPortStart = 51820
	whitelistWireGuardPortEnd   = 51920
	xrayReleaseURL              = "https://github.com/XTLS/Xray-core/releases/download/v25.8.3/Xray-linux-64.zip"
	singBoxLinuxReleaseURL      = "https://github.com/SagerNet/sing-box/releases/download/v1.12.22/sing-box-1.12.22-linux-amd64.tar.gz"
)

type Deployment struct {
	DeploymentID  string              `json:"deploymentId"`
	ServerHost    string              `json:"serverHost"`
	Transport     string              `json:"transport"`
	Engine        string              `json:"engine,omitempty"`
	Protocol      string              `json:"protocol,omitempty"`
	Status        string              `json:"status"`
	Steps         []Step              `json:"steps"`
	TurnPort      int                 `json:"turnPort,omitempty"`
	WireGuardPort int                 `json:"wireGuardPort,omitempty"`
	RealityPort   int                 `json:"realityPort,omitempty"`
	HealthChecks  []Check             `json:"healthChecks,omitempty"`
	ProtocolPack  []ProtocolPackEntry `json:"protocolPack,omitempty"`
	Error         string              `json:"error,omitempty"`
}

type deploymentStore struct {
	mu    sync.RWMutex
	items map[string]Deployment
}

var store = &deploymentStore{
	items: map[string]Deployment{},
}

func StartDeployment(req Request) Deployment {
	id := fmt.Sprintf("dep_%d", time.Now().UnixNano())
	plan := BuildPlan(req)

	steps := make([]Step, len(plan.Steps))
	copy(steps, plan.Steps)
	if len(steps) > 0 {
		steps[0].Status = "current"
	}

	deployment := Deployment{
		DeploymentID: id,
		ServerHost:   req.Server.Host,
		Transport:    string(TransportXray),
		Engine:       string(EngineSingBox),
		Protocol:     string(ProtocolVLESSReality),
		Status:       "running",
		Steps:        steps,
		ProtocolPack: buildProtocolPack(TransportXray, 0, req.Server.RealityPort, req.Server.VKTurnProxyPort),
	}

	store.mu.Lock()
	store.items[id] = deployment
	store.mu.Unlock()

	go runDeployment(id, req)

	return deployment
}

func GetDeployment(id string) (Deployment, bool) {
	store.mu.RLock()
	defer store.mu.RUnlock()

	deployment, ok := store.items[id]
	return deployment, ok
}

func BuildPlan(req Request) Response {
	steps := []Step{
		{
			ID:          "ssh-check",
			Label:       "SSH validation",
			Status:      StatusQueued,
			Description: "Validate credentials, remote OS, and the current server state.",
		},
		{
			ID:          "runtime-prep",
			Label:       "Runtime preparation",
			Status:      StatusQueued,
			Description: "Create isolated Odin One directories and verify network prerequisites.",
		},
		{
			ID:          "install-binaries",
			Label:       "Install binaries",
			Status:      StatusQueued,
			Description: "Install xray and upload the transport binaries required for this mode.",
		},
		{
			ID:          "configure-services",
			Label:       "Configure services",
			Status:      StatusQueued,
			Description: "Generate keys, write xray and Odin One configs, and install the required systemd units.",
		},
		{
			ID:          "service-start",
			Label:       "Service startup",
			Status:      StatusQueued,
			Description: "Start the selected Odin One services and verify their health.",
		},
		{
			ID:          "egress-check",
			Label:       "Egress health",
			Status:      StatusQueued,
			Description: "Verify that the server can resolve DNS and complete outbound HTTP and HTTPS probes.",
		},
	}

	warnings := []string{
		"Odin One uses its own ports and paths so the existing Amnezia stack can remain untouched.",
		"Odin One now keeps VLESS + REALITY and the VK relay live on the same server, so the desktop client can switch paths locally without redeploying the node.",
	}

	if req.Server.VKTurnProxyPort > 0 || req.Server.RealityPort > 0 {
		warnings = append(warnings, fmt.Sprintf(
			"Manual public ports are requested: VK relay %s and REALITY %s. Deploy will fail if either port is already busy on the server.",
			describeManualPort(req.Server.VKTurnProxyPort, "auto/udp"),
			describeManualPort(req.Server.RealityPort, "auto/tcp"),
		))
	} else {
		warnings = append(warnings, "Public VK relay and REALITY ports are auto-selected from currently free server ports unless you pin them manually.")
	}
	warnings = append(warnings, "Protocol pack staging is enabled: Odin One keeps the current active data path, while preparing Russia-friendly fallback protocols for later rollout without Apple Network Extension entitlements.")

	return Response{
		ServerHost:   req.Server.Host,
		Transport:    string(TransportXray),
		Steps:        steps,
		Warnings:     warnings,
		ProtocolPack: buildProtocolPack(TransportXray, 0, req.Server.RealityPort, req.Server.VKTurnProxyPort),
	}
}

func runDeployment(id string, req Request) {
	if err := executeDeployment(id, req); err != nil {
		failDeployment(id, err)
		return
	}

	store.mu.Lock()
	deployment := store.items[id]
	deployment.Status = "done"
	store.items[id] = deployment
	store.mu.Unlock()
}

func executeDeployment(id string, req Request) error {
	client, err := connectSSH(req)
	if err != nil {
		return err
	}
	defer client.Close()

	if _, err := runRemote(client, "whoami && uname -a"); err != nil {
		return err
	}
	completeStep(id, 0)

	if _, err := runRemote(client, fmt.Sprintf("mkdir -p %s %s %s %s", whitelistBinDir, whitelistConfigDir, whitelistProfilesDir, whitelistGuestProfilesDir)); err != nil {
		return err
	}
	completeStep(id, 1)

	if err := validateDeploymentPortHints(req.Server); err != nil {
		return err
	}

	turnPort, err := resolveRemoteRelayPort(client, req.Server.VKTurnProxyPort)
	if err != nil {
		return err
	}
	wireGuardPort, err := resolveRemoteUDPPort(client, 0, whitelistWireGuardPortStart, whitelistWireGuardPortEnd, []int{turnPort}, "xray wireguard")
	if err != nil {
		return err
	}
	realityPort, err := resolveDeploymentRealityPort(client, req.Server.RealityPort)
	if err != nil {
		return err
	}
	setDeploymentPorts(id, turnPort, wireGuardPort, realityPort)
	setDeploymentProtocolPack(id, buildProtocolPack(TransportXray, wireGuardPort, realityPort, turnPort))

	vkBinary, err := ensureVKTurnProxyBinary()
	if err != nil {
		return err
	}
	if err := uploadFile(client, whitelistProxyBinaryPath, vkBinary, "0755"); err != nil {
		return err
	}
	if _, err := runRemote(client, renderRemoteXrayInstallCommand(xrayReleaseURL, whitelistXrayBinaryPath)); err != nil {
		return err
	}
	if _, err := runRemote(client, fmt.Sprintf(
		"tmp=$(mktemp -d) && cd \"$tmp\" && curl -fsSLo sing-box.tar.gz %s && tar -xzf sing-box.tar.gz && install -m 0755 sing-box-*/sing-box %s && rm -rf \"$tmp\"",
		quoteShell(singBoxLinuxReleaseURL),
		quoteShell(whitelistSingBoxBinaryPath),
	)); err != nil {
		return err
	}
	completeStep(id, 2)

	serverKeys, err := generateWireGuardKeyPair()
	if err != nil {
		return err
	}
	clientKeys, err := generateWireGuardKeyPair()
	if err != nil {
		return err
	}

	endpointPort := wireGuardPort
	realityKeys, err := generateX25519KeyPair()
	if err != nil {
		return err
	}
	realityUUID, err := generateProtocolUUID()
	if err != nil {
		return err
	}
	realityShortID, err := generateRealityShortID()
	if err != nil {
		return err
	}
	realityConfig, err := renderRealityServerConfig(realityPort, realityUUID, realityKeys.Private, realityShortID)
	if err != nil {
		return err
	}
	realityInbound := &xrayRealityInbound{
		Port: realityPort,
		Clients: []xrayRealityClient{
			{
				UUID: realityUUID,
				Flow: "xtls-rprx-vision",
			},
		},
		PrivateKey: realityKeys.Private,
		ShortID:    realityShortID,
		ServerName: realityServerName(),
		Dest:       realityDestination(),
	}
	xrayConfig := renderXrayConfigWithListen(serverKeys.Private, []xrayWireGuardPeer{
		{
			PublicKey:  clientKeys.Public,
			AllowedIPs: []string{"10.66.66.2/32"},
		},
	}, "0.0.0.0", wireGuardPort, realityInbound)
	if err := uploadFile(client, whitelistXrayConfigPath, []byte(xrayConfig), "0644"); err != nil {
		return err
	}
	if err := uploadFile(client, whitelistRealityConfigPath, []byte(realityConfig), "0644"); err != nil {
		return err
	}
	fallbackManifest, err := renderStagedFallbackManifest(req.Server.Host, realityPort)
	if err != nil {
		return err
	}
	if err := uploadFile(client, whitelistFallbacksPath, []byte(fallbackManifest), "0644"); err != nil {
		return err
	}

	stagedFallbacks := buildStagedFallbacks(realityPort, realityKeys.Public, realityShortID, realityUUID, true)
	inviteProfile, err := renderAccessProfile(
		"owner",
		"owner",
		"Odin One Owner Node",
		req.Server.Host,
		TransportXray,
		endpointPort,
		wireGuardPort,
		turnPort,
		serverKeys.Public,
		clientKeys.Private,
		clientKeys.Public,
		"10.66.66.2/32",
		stagedFallbacks,
	)
	if err != nil {
		return err
	}
	if err := uploadFile(client, whitelistInvitePath, []byte(inviteProfile), "0600"); err != nil {
		return err
	}
	if err := saveLocalOwnerProfile(req.Server.Host, []byte(inviteProfile)); err != nil {
		return err
	}
	protocolPackManifest, err := renderProtocolPackManifest(req.Server.Host, TransportXray, wireGuardPort, realityPort, turnPort)
	if err != nil {
		return err
	}
	if err := uploadFile(client, whitelistProtocolPackPath, []byte(protocolPackManifest), "0644"); err != nil {
		return err
	}

	xrayUnit := renderSystemdUnit(
		"Odin One Xray",
		fmt.Sprintf("%s run -config %s", whitelistXrayBinaryPath, whitelistXrayConfigPath),
	)
	if err := uploadFile(client, whitelistXrayServicePath, []byte(xrayUnit), "0644"); err != nil {
		return err
	}

	proxyUnit := renderSystemdUnit(
		"Odin One vk-turn-proxy",
		fmt.Sprintf("%s -listen 0.0.0.0:%d -connect 127.0.0.1:%d", whitelistProxyBinaryPath, turnPort, wireGuardPort),
	)
	if err := uploadFile(client, whitelistProxyServicePath, []byte(proxyUnit), "0644"); err != nil {
		return err
	}
	completeStep(id, 3)

	if _, err := runRemote(client, "systemctl daemon-reload && systemctl enable whitelist-xray.service whitelist-vk-turn-proxy.service && systemctl restart whitelist-xray.service whitelist-vk-turn-proxy.service && sleep 2"); err != nil {
		return err
	}
	if _, err := runRemote(client, fmt.Sprintf("systemctl is-active whitelist-xray.service && systemctl is-active whitelist-vk-turn-proxy.service && ss -H -lun | grep -Fq ':%d' && ss -H -lun | grep -Fq ':%d' && ss -H -ltn | grep -Fq ':%d'", wireGuardPort, turnPort, realityPort)); err != nil {
		return err
	}
	completeStep(id, 4)

	healthChecks, healthOK := runRemoteEgressChecks(client)
	setDeploymentHealthChecks(id, healthChecks)
	if !healthOK {
		return fmt.Errorf("remote egress health checks failed")
	}
	completeStep(id, 5)

	return nil
}

func saveLocalOwnerProfile(host string, data []byte) error {
	targetPath, err := localProfilePath(host)
	if err != nil {
		return fmt.Errorf("local profile path: %w", err)
	}
	if err := os.WriteFile(targetPath, data, 0o600); err != nil {
		return fmt.Errorf("save local owner profile: %w", err)
	}
	return nil
}

func renderRemoteXrayInstallCommand(downloadURL, targetPath string) string {
	return fmt.Sprintf(`tmp=$(mktemp -d) && cd "$tmp" && \
curl -fsSLo xray.zip %s && \
if command -v unzip >/dev/null 2>&1; then \
  unzip -oq xray.zip xray; \
else \
  python3 - <<'PY'
import zipfile
with zipfile.ZipFile('xray.zip') as zf:
    with zf.open('xray') as src, open('xray', 'wb') as dst:
        dst.write(src.read())
PY
fi && \
install -m 0755 xray %s && \
rm -rf "$tmp"`,
		quoteShell(downloadURL),
		quoteShell(targetPath),
	)
}

func ensureVKTurnProxyBinary() ([]byte, error) {
	cacheDir, err := appCacheDir()
	if err != nil {
		return nil, fmt.Errorf("app cache dir: %w", err)
	}

	targetDir := filepath.Join(cacheDir, "bin")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return nil, fmt.Errorf("make cache dir: %w", err)
	}

	targetPath := filepath.Join(targetDir, "vk-turn-proxy-server-linux-amd64")
	goPathDir := filepath.Join(targetDir, "gopath")
	if err := os.MkdirAll(goPathDir, 0o755); err != nil {
		return nil, fmt.Errorf("make gopath dir: %w", err)
	}

	cmd := exec.Command(resolveGoBinary(), "install", "github.com/cacggghp/vk-turn-proxy/server@latest")
	cmd.Env = append(
		os.Environ(),
		"GOPATH="+goPathDir,
		"GOOS=linux",
		"GOARCH=amd64",
		"CGO_ENABLED=0",
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go install vk-turn-proxy: %w: %s", err, strings.TrimSpace(string(output)))
	}

	installedPath := filepath.Join(goPathDir, "bin", "linux_amd64", "server")
	data, err := os.ReadFile(installedPath)
	if err != nil {
		return nil, fmt.Errorf("read built binary: %w", err)
	}
	if err := os.WriteFile(targetPath, data, 0o755); err != nil {
		return nil, fmt.Errorf("cache built binary: %w", err)
	}
	return data, nil
}

func completeStep(id string, index int) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}

	if index < len(deployment.Steps) {
		deployment.Steps[index].Status = "done"
	}
	if index+1 < len(deployment.Steps) {
		deployment.Steps[index+1].Status = "current"
	}
	store.items[id] = deployment
}

func setDeploymentPorts(id string, turnPort, wireGuardPort, realityPort int) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}
	deployment.TurnPort = turnPort
	deployment.WireGuardPort = wireGuardPort
	deployment.RealityPort = realityPort
	store.items[id] = deployment
}

func setDeploymentHealthChecks(id string, healthChecks []Check) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}
	deployment.HealthChecks = healthChecks
	store.items[id] = deployment
}

func setDeploymentProtocolPack(id string, protocolPack []ProtocolPackEntry) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}
	deployment.ProtocolPack = protocolPack
	store.items[id] = deployment
}

func findRemoteFreeUDPPort(client *ssh.Client, start, end int) (int, error) {
	for port := start; port <= end; port++ {
		cmd := fmt.Sprintf("if ss -H -lun | awk '{print $5}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", port)
		if _, err := runRemote(client, cmd); err == nil {
			return port, nil
		}
	}
	return 0, fmt.Errorf("no free UDP port found in range %d-%d", start, end)
}

func findRemotePreferredTCPPort(client *ssh.Client, preferred, start, end int) (int, error) {
	if preferred > 0 {
		if _, err := runRemote(client, fmt.Sprintf("if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", preferred)); err == nil {
			return preferred, nil
		}
	}
	for port := start; port <= end; port++ {
		cmd := fmt.Sprintf("if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", port)
		if _, err := runRemote(client, cmd); err == nil {
			return port, nil
		}
	}
	return 0, fmt.Errorf("no free TCP port found in range %d-%d", start, end)
}

func describeManualPort(port int, fallback string) string {
	if port <= 0 {
		return fallback
	}
	return strconv.Itoa(port)
}

func validateDeploymentPortHints(server Server) error {
	if err := validateRequestedPort(server.VKTurnProxyPort, "vk-turn-proxy relay"); err != nil {
		return err
	}
	if err := validateRequestedPort(server.RealityPort, "VLESS + REALITY"); err != nil {
		return err
	}
	if server.VKTurnProxyPort > 0 && server.RealityPort > 0 && server.VKTurnProxyPort == server.RealityPort {
		return fmt.Errorf("vk-turn-proxy relay UDP port and VLESS + REALITY TCP port must be different")
	}
	return nil
}

func validateRequestedPort(port int, name string) error {
	if port == 0 {
		return nil
	}
	if port < 1 || port > 65535 {
		return fmt.Errorf("%s port must be between 1 and 65535", name)
	}
	return nil
}

func resolveRemoteUDPPort(client *ssh.Client, requested, start, end int, excluded []int, label string) (int, error) {
	if requested > 0 {
		if portExcluded(requested, excluded) {
			return 0, fmt.Errorf("%s UDP port %d conflicts with another Odin One service", label, requested)
		}
		free, err := remoteUDPPortIsFree(client, requested)
		if err != nil {
			return 0, err
		}
		if !free {
			return 0, fmt.Errorf("%s UDP port %d is already in use on the server", label, requested)
		}
		return requested, nil
	}

	for port := start; port <= end; port++ {
		if portExcluded(port, excluded) {
			continue
		}
		free, err := remoteUDPPortIsFree(client, port)
		if err != nil {
			return 0, err
		}
		if free {
			return port, nil
		}
	}
	return 0, fmt.Errorf("no free UDP port found in range %d-%d", start, end)
}

func resolveRemoteRelayPort(client *ssh.Client, requested int) (int, error) {
	if requested > 0 {
		free, err := remoteUDPPortIsFree(client, requested)
		if err != nil {
			return 0, err
		}
		if free || remoteExistingRelayUsesPort(client, requested) {
			return requested, nil
		}
		return 0, fmt.Errorf("vk-turn-proxy relay UDP port %d is already in use on the server", requested)
	}
	return resolveRemoteUDPPort(client, 0, whitelistTurnPortStart, whitelistTurnPortEnd, nil, "vk-turn-proxy relay")
}

func resolveDeploymentRealityPort(client *ssh.Client, requested int) (int, error) {
	if requested > 0 {
		free, err := remoteTCPPortIsFree(client, requested)
		if err != nil {
			return 0, err
		}
		if !free && !remoteExistingRealityUsesPort(client, requested) {
			return 0, fmt.Errorf("VLESS + REALITY TCP port %d is already in use on the server", requested)
		}
		return requested, nil
	}

	if forcedPort := strings.TrimSpace(os.Getenv("ODIN_ONE_REALITY_PORT_HINT")); forcedPort != "" {
		realityPort, err := strconv.Atoi(forcedPort)
		if err != nil {
			return 0, fmt.Errorf("parse ODIN_ONE_REALITY_PORT_HINT: %w", err)
		}
		free, err := remoteTCPPortIsFree(client, realityPort)
		if err != nil {
			return 0, err
		}
		if free {
			return realityPort, nil
		}
	}

	return findRemotePreferredTCPPort(client, realityFallbackPort, realityFallbackMinPort, realityFallbackMaxPort)
}

func remoteUDPPortIsFree(client *ssh.Client, port int) (bool, error) {
	_, err := runRemote(client, fmt.Sprintf("if ss -H -lun | awk '{print $5}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", port))
	if err == nil {
		return true, nil
	}
	return false, nil
}

func remoteTCPPortIsFree(client *ssh.Client, port int) (bool, error) {
	_, err := runRemote(client, fmt.Sprintf("if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", port))
	if err == nil {
		return true, nil
	}
	return false, nil
}

func remoteExistingRelayUsesPort(client *ssh.Client, port int) bool {
	unitText, err := runRemote(client, "cat "+quoteShell(whitelistProxyServicePath))
	if err != nil {
		return false
	}
	relayPort, _ := parseVKRelayUnitPorts(unitText)
	return relayPort == port
}

func remoteExistingRealityUsesPort(client *ssh.Client, port int) bool {
	_, _, xrayState, err := loadRemoteAccessState(client)
	if err != nil {
		return false
	}
	return xrayState.Reality.Port == port
}

func portExcluded(port int, excluded []int) bool {
	for _, item := range excluded {
		if item == port {
			return true
		}
	}
	return false
}

func failDeployment(id string, err error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}

	deployment.Status = "failed"
	deployment.Error = err.Error()
	for index := range deployment.Steps {
		if deployment.Steps[index].Status == "current" {
			deployment.Steps[index].Status = "failed"
			break
		}
	}
	store.items[id] = deployment
}
