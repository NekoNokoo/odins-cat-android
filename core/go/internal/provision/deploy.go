package provision

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
		Transport:    string(req.Server.Transport),
		Engine:       string(normalizedEngine(req.Server.Engine)),
		Protocol:     string(normalizedProtocol(req.Server.Transport, req.Server.Protocol)),
		Status:       "running",
		Steps:        steps,
		ProtocolPack: buildProtocolPack(req.Server.Transport, 0),
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
	}

	if req.Server.Transport == TransportVKTurnProxyXray {
		warnings = append(warnings, "This deployment auto-selects free UDP ports for both the public vk-turn-proxy listener and the local xray WireGuard inbound, so it can coexist with an existing VPN stack.")
	} else if req.Server.Transport == TransportXray {
		warnings = append(warnings, "Direct xray mode publishes a WireGuard-compatible UDP port on the server and does not depend on VK for connectivity.")
	}
	warnings = append(warnings, "Protocol pack staging is enabled: Odin One keeps the current active data path, while preparing Russia-friendly fallback protocols for later rollout without Apple Network Extension entitlements.")

	return Response{
		ServerHost:   req.Server.Host,
		Transport:    string(req.Server.Transport),
		Steps:        steps,
		Warnings:     warnings,
		ProtocolPack: buildProtocolPack(req.Server.Transport, 0),
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

	turnPort := 0
	if req.Server.Transport == TransportVKTurnProxyXray {
		turnPort, err = findRemoteFreeUDPPort(client, whitelistTurnPortStart, whitelistTurnPortEnd)
		if err != nil {
			return err
		}
	}
	wireGuardPort, err := findRemoteFreeUDPPort(client, whitelistWireGuardPortStart, whitelistWireGuardPortEnd)
	if err != nil {
		return err
	}
	if turnPort != 0 && wireGuardPort == turnPort {
		wireGuardPort, err = findRemoteFreeUDPPort(client, wireGuardPort+1, whitelistWireGuardPortEnd+20)
		if err != nil {
			return err
		}
	}
	setDeploymentPorts(id, turnPort, wireGuardPort)
	setDeploymentProtocolPack(id, buildProtocolPack(req.Server.Transport, endpointPortForProtocolPack(req.Server.Transport, turnPort, wireGuardPort)))

	realityPort := realityFallbackPort
	if req.Server.Transport == TransportXray {
		realityPort, err = findRemotePreferredTCPPort(client, realityFallbackPort, realityFallbackMinPort, realityFallbackMaxPort)
		if err != nil {
			return err
		}
	}

	if req.Server.Transport == TransportVKTurnProxyXray {
		vkBinary, err := ensureVKTurnProxyBinary()
		if err != nil {
			return err
		}
		if err := uploadFile(client, whitelistProxyBinaryPath, vkBinary, "0755"); err != nil {
			return err
		}
	}
	if _, err := runRemote(client, fmt.Sprintf(
		"tmp=$(mktemp -d) && cd \"$tmp\" && curl -fsSLo xray.zip %s && unzip -oq xray.zip xray && install -m 0755 xray %s && rm -rf \"$tmp\"",
		quoteShell(xrayReleaseURL),
		quoteShell(whitelistXrayBinaryPath),
	)); err != nil {
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

	listenHost := "127.0.0.1"
	endpointPort := turnPort
	if req.Server.Transport == TransportXray {
		listenHost = "0.0.0.0"
		endpointPort = wireGuardPort
	}

	xrayConfig := renderXrayConfigWithListen(serverKeys.Private, []xrayWireGuardPeer{
		{
			PublicKey:  clientKeys.Public,
			AllowedIPs: []string{"10.66.66.2/32"},
		},
	}, listenHost, wireGuardPort, nil)
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
	var realityInbound *xrayRealityInbound
	if req.Server.Transport == TransportXray {
		realityInbound = &xrayRealityInbound{
			Port:       realityPort,
			UUID:       realityUUID,
			PrivateKey: realityKeys.Private,
			ShortID:    realityShortID,
		}
	}
	xrayConfig = renderXrayConfigWithListen(serverKeys.Private, []xrayWireGuardPeer{
		{
			PublicKey:  clientKeys.Public,
			AllowedIPs: []string{"10.66.66.2/32"},
		},
	}, listenHost, wireGuardPort, realityInbound)
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

	stagedFallbacks := buildStagedFallbacks(realityPort, realityKeys.Public, realityShortID, realityUUID, req.Server.Transport == TransportXray)
	inviteProfile, err := renderAccessProfile("owner", "owner", "Odin One Owner Node", req.Server.Host, req.Server.Transport, endpointPort, serverKeys.Public, clientKeys.Private, clientKeys.Public, "10.66.66.2/32", stagedFallbacks)
	if err != nil {
		return err
	}
	if err := uploadFile(client, whitelistInvitePath, []byte(inviteProfile), "0600"); err != nil {
		return err
	}
	if err := saveLocalOwnerProfile(req.Server.Host, []byte(inviteProfile)); err != nil {
		return err
	}
	protocolPackManifest, err := renderProtocolPackManifest(req.Server.Host, req.Server.Transport, endpointPort)
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

	if req.Server.Transport == TransportVKTurnProxyXray {
		proxyUnit := renderSystemdUnit(
			"Odin One vk-turn-proxy",
			fmt.Sprintf("%s -listen 0.0.0.0:%d -connect 127.0.0.1:%d", whitelistProxyBinaryPath, turnPort, wireGuardPort),
		)
		if err := uploadFile(client, whitelistProxyServicePath, []byte(proxyUnit), "0644"); err != nil {
			return err
		}
	}
	completeStep(id, 3)

	switch req.Server.Transport {
	case TransportVKTurnProxyXray:
		if _, err := runRemote(client, "systemctl daemon-reload && systemctl enable whitelist-xray.service whitelist-vk-turn-proxy.service && systemctl restart whitelist-xray.service whitelist-vk-turn-proxy.service && sleep 2"); err != nil {
			return err
		}
		if _, err := runRemote(client, fmt.Sprintf("systemctl is-active whitelist-xray.service && systemctl is-active whitelist-vk-turn-proxy.service && ss -lun | grep ':%d'", turnPort)); err != nil {
			return err
		}
	case TransportXray:
		if _, err := runRemote(client, "systemctl daemon-reload && systemctl disable --now whitelist-vk-turn-proxy.service >/dev/null 2>&1 || true && systemctl enable whitelist-xray.service && systemctl restart whitelist-xray.service && sleep 2"); err != nil {
			return err
		}
		if _, err := runRemote(client, fmt.Sprintf("systemctl is-active whitelist-xray.service && ss -lun | grep ':%d' && ss -ltn | grep ':%d'", wireGuardPort, realityPort)); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported transport %q", req.Server.Transport)
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

func setDeploymentPorts(id string, turnPort, wireGuardPort int) {
	store.mu.Lock()
	defer store.mu.Unlock()

	deployment, ok := store.items[id]
	if !ok {
		return
	}
	deployment.TurnPort = turnPort
	deployment.WireGuardPort = wireGuardPort
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

func endpointPortForProtocolPack(transport Transport, turnPort, wireGuardPort int) int {
	if transport == TransportVKTurnProxyXray {
		return turnPort
	}
	return wireGuardPort
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
