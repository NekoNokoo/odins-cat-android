package provision

import (
	"encoding/json"
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
	DeploymentID    string              `json:"deploymentId"`
	ServerHost      string              `json:"serverHost"`
	DeployFlow      string              `json:"deployFlow,omitempty"`
	Transport       string              `json:"transport"`
	Engine          string              `json:"engine,omitempty"`
	Protocol        string              `json:"protocol,omitempty"`
	Status          string              `json:"status"`
	Steps           []Step              `json:"steps"`
	TurnPort        int                 `json:"turnPort,omitempty"`
	WireGuardPort   int                 `json:"wireGuardPort,omitempty"`
	RealityPort     int                 `json:"realityPort,omitempty"`
	EdgeEnabled     bool                `json:"edgeEnabled,omitempty"`
	EdgeHost        string              `json:"edgeHost,omitempty"`
	EdgePort        int                 `json:"edgePort,omitempty"`
	EdgeRoutingMode string              `json:"edgeRoutingMode,omitempty"`
	HealthChecks    []Check             `json:"healthChecks,omitempty"`
	ProtocolPack    []ProtocolPackEntry `json:"protocolPack,omitempty"`
	Error           string              `json:"error,omitempty"`
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
	flow := normalizedProvisionFlow(req.Flow)
	protocolPackFallbacks := previewProtocolPackFallbacks("", 0)
	if req.Edge != nil && req.Edge.Enabled {
		protocolPackFallbacks = previewProtocolPackFallbacks(req.Edge.Server.Host, normalizedEdgePublicPort(req.Edge))
	}

	steps := make([]Step, len(plan.Steps))
	copy(steps, plan.Steps)
	if len(steps) > 0 {
		steps[0].Status = "current"
	}

	deployment := Deployment{
		DeploymentID: id,
		ServerHost:   req.Server.Host,
		DeployFlow:   string(flow),
		Transport:    string(TransportXray),
		Engine:       string(EngineSingBox),
		Protocol:     string(ProtocolVLESSReality),
		Status:       "running",
		Steps:        steps,
		ProtocolPack: buildProtocolPackWithFallbacks(
			TransportXray,
			0,
			req.Server.RealityPort,
			req.Server.VKTurnProxyPort,
			protocolPackFallbacks,
		),
	}
	if req.Edge != nil && req.Edge.Enabled {
		deployment.EdgeEnabled = true
		deployment.EdgeHost = req.Edge.Server.Host
		deployment.EdgePort = normalizedEdgePublicPort(req.Edge)
		deployment.EdgeRoutingMode = string(normalizedEdgeRoutingMode(req.Edge))
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
	flow := normalizedProvisionFlow(req.Flow)
	steps := buildPlanSteps(flow)
	warnings := buildPlanWarnings(req, flow)
	protocolPackFallbacks := previewProtocolPackFallbacks("", 0)
	if req.Edge != nil && req.Edge.Enabled {
		protocolPackFallbacks = previewProtocolPackFallbacks(req.Edge.Server.Host, normalizedEdgePublicPort(req.Edge))
	}

	if flow == ProvisionFlowOrigin && (req.Server.VKTurnProxyPort > 0 || req.Server.RealityPort > 0) {
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
		ServerHost: req.Server.Host,
		DeployFlow: string(flow),
		Transport:  string(TransportXray),
		Steps:      steps,
		Warnings:   warnings,
		ProtocolPack: buildProtocolPackWithFallbacks(
			TransportXray,
			0,
			req.Server.RealityPort,
			req.Server.VKTurnProxyPort,
			protocolPackFallbacks,
		),
	}
}

func buildPlanSteps(flow ProvisionFlow) []Step {
	if flow == ProvisionFlowEdgeAttach {
		return []Step{
			{
				ID:          "origin-ssh-check",
				Label:       "Origin validation",
				Status:      StatusQueued,
				Description: "Load the live Odin One origin profile and confirm the current REALITY port and keys.",
			},
			{
				ID:          "edge-ssh-check",
				Label:       "Edge validation",
				Status:      StatusQueued,
				Description: "Validate the Yandex edge host and confirm that privileged setup can run there.",
			},
			{
				ID:          "edge-runtime-prep",
				Label:       "Edge preparation",
				Status:      StatusQueued,
				Description: "Prepare the selected edge runtime and write the manifest for the new Yandex edge surface.",
			},
			{
				ID:          "edge-configure",
				Label:       "Edge wiring",
				Status:      StatusQueued,
				Description: "Install the edge systemd service that exposes the current REALITY origin through the Yandex edge.",
			},
			{
				ID:          "edge-service-start",
				Label:       "Edge startup",
				Status:      StatusQueued,
				Description: "Start the selected edge service and verify that it can reach the current origin REALITY port.",
			},
			{
				ID:          "profile-refresh",
				Label:       "Profile refresh",
				Status:      StatusQueued,
				Description: "Patch the owner profile and protocol pack so the extra Yandex edge mode can be exported in a single invite key.",
			},
		}
	}

	return []Step{
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
}

func buildPlanWarnings(req Request, flow ProvisionFlow) []string {
	warnings := []string{
		"Odin One uses its own ports and paths so the existing Amnezia stack can remain untouched.",
		"Odin One keeps the stable direct REALITY path separate from additive access surfaces so stable mode can stay untouched while extra modes are attached later.",
	}
	if flow == ProvisionFlowEdgeAttach {
		warnings = append(warnings,
			"The Yandex edge step is additive: it only exposes the existing REALITY origin through a second host and does not rotate the origin keys by itself.",
			"You should re-issue invite keys after the edge is attached so imported profiles receive the extra visible mode.",
		)
		return warnings
	}

	warnings = append(warnings,
		"Odin One now keeps VLESS + REALITY and the VK relay live on the same server, so the desktop client can switch paths locally without redeploying the node.",
		"Protocol pack staging is enabled: Odin One keeps the current active data path, while preparing Russia-friendly fallback protocols for later rollout without Apple Network Extension entitlements.",
	)
	return warnings
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
	if normalizedProvisionFlow(req.Flow) == ProvisionFlowEdgeAttach {
		return executeEdgeAttach(id, req)
	}

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

func executeEdgeAttach(id string, req Request) error {
	if err := validateEdgeAttachRequest(req); err != nil {
		return err
	}

	originClient, err := connectSSH(req)
	if err != nil {
		return err
	}
	defer originClient.Close()

	if _, err := runRemote(originClient, "whoami && uname -a"); err != nil {
		return err
	}
	completeStep(id, 0)

	owner, ownerText, xrayState, err := loadRemoteAccessState(originClient)
	if err != nil {
		return err
	}
	reality, err := readInviteRealityFallback(owner)
	if err != nil {
		return fmt.Errorf("origin owner profile has no usable VLESS + REALITY fallback: %w", err)
	}
	setDeploymentPorts(id, owner.VKTurnProxyPort, xrayState.WireGuardPort, reality.Port)

	edgeClient, err := connectSSH(edgeRequest(req))
	if err != nil {
		return err
	}
	defer edgeClient.Close()

	if _, err := runRemote(edgeClient, "whoami && uname -a"); err != nil {
		return err
	}
	completeStep(id, 1)

	publicPort := normalizedEdgePublicPort(req.Edge)
	routingMode := normalizedEdgeRoutingMode(req.Edge)
	layout := buildYandexEdgeRuntimeLayout(publicPort, routingMode)
	switch routingMode {
	case EdgeRoutingModeSNIRouter:
		if err := ensureRemoteHAProxyInstalled(edgeClient); err != nil {
			return err
		}
	case EdgeRoutingModeXrayProxy:
		if err := ensureRemoteEdgeXrayInstalled(edgeClient, layout.xrayPath); err != nil {
			return err
		}
	default:
		if err := ensureRemoteSocatInstalled(edgeClient); err != nil {
			return err
		}
	}
	manifestText, err := renderYandexEdgeManifest(
		req.Edge.Server.Host,
		publicPort,
		req.Server.Host,
		reality.Port,
		reality.ServerName,
		reality.PublicKey,
		reality.ShortID,
		reality.UUID,
		reality.Flow,
		routingMode,
		layout,
	)
	if err != nil {
		return err
	}
	if err := uploadFileWithSudo(edgeClient, layout.manifestPath, []byte(manifestText), "0644"); err != nil {
		return err
	}
	if routingMode == EdgeRoutingModeSNIRouter {
		haproxyConfig := renderYandexEdgeHAProxyConfig("0.0.0.0", publicPort, reality.ServerName, req.Server.Host, reality.Port)
		if err := uploadFileWithSudo(edgeClient, layout.haproxyPath, []byte(haproxyConfig), "0644"); err != nil {
			return err
		}
	} else if routingMode == EdgeRoutingModeXrayProxy {
		if _, err := runRemote(edgeClient, renderYandexEdgeXrayProxyCertificateCommand(layout, req.Edge.Server.Host)); err != nil {
			return err
		}
		xrayConfig, err := renderYandexEdgeXrayProxyConfig(
			publicPort,
			layout.xrayCert,
			layout.xrayKey,
			req.Server.Host,
			reality.Port,
			reality.ServerName,
			reality.PublicKey,
			reality.ShortID,
			reality.UUID,
			reality.Flow,
		)
		if err != nil {
			return err
		}
		if err := uploadFileWithSudo(edgeClient, layout.xrayConfig, []byte(xrayConfig), "0644"); err != nil {
			return err
		}
	}
	completeStep(id, 2)

	unitText := renderYandexEdgeTCPForwardSystemdUnit(req.Server.Host, reality.Port, publicPort)
	if routingMode == EdgeRoutingModeSNIRouter {
		unitText = renderYandexEdgeSNIRouterSystemdUnit(layout.haproxyPath)
	} else if routingMode == EdgeRoutingModeXrayProxy {
		unitText = renderYandexEdgeXrayProxySystemdUnit(layout.xrayPath, layout.xrayConfig)
	}
	if err := uploadFileWithSudo(edgeClient, layout.servicePath, []byte(unitText), "0644"); err != nil {
		return err
	}
	completeStep(id, 3)

	if routingMode == EdgeRoutingModeSNIRouter {
		if _, err := runRemote(edgeClient, remoteRootShell(fmt.Sprintf("haproxy -c -f %s", quoteShell(layout.haproxyPath)))); err != nil {
			return err
		}
	} else if routingMode == EdgeRoutingModeXrayProxy {
		if _, err := runRemote(edgeClient, remoteRootShell(fmt.Sprintf("%s version >/dev/null", quoteShell(layout.xrayPath)))); err != nil {
			return err
		}
	}
	if _, err := runRemote(
		edgeClient,
		remoteRootShell(
			fmt.Sprintf(
				"systemctl daemon-reload && systemctl enable %s && systemctl restart %s && sleep 2",
				quoteShell(layout.serviceName),
				quoteShell(layout.serviceName),
			),
		),
	); err != nil {
		return err
	}
	healthCommand := remoteRootShell(fmt.Sprintf(
		"systemctl is-active %s && ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$' && timeout 8 bash -lc 'cat </dev/null >/dev/tcp/%s/%d'",
		quoteShell(layout.serviceName),
		publicPort,
		req.Server.Host,
		reality.Port,
	))
	if _, err := runRemote(edgeClient, healthCommand); err != nil {
		return err
	}
	healthChecks, healthOK := runEdgeAttachHealthChecks(edgeClient, layout, routingMode, publicPort, req.Server.Host, reality.Port)
	setDeploymentHealthChecks(id, healthChecks)
	if !healthOK {
		return fmt.Errorf("edge attach health checks failed")
	}
	completeStep(id, 4)

	patchedOwnerProfile, protocolPack, err := patchOwnerProfileWithYandexEdge(
		ownerText,
		req.Edge.Server.Host,
		publicPort,
		req.Server.Host,
		reality,
		routingMode,
		nil,
	)
	if err != nil {
		return err
	}
	if err := uploadFile(originClient, whitelistInvitePath, []byte(patchedOwnerProfile), "0600"); err != nil {
		return err
	}
	if err := saveLocalOwnerProfile(req.Server.Host, []byte(patchedOwnerProfile)); err != nil {
		return err
	}
	fallbackManifest, err := renderStagedFallbackManifest(req.Server.Host, reality.Port)
	if err != nil {
		return err
	}
	if err := uploadFile(originClient, whitelistFallbacksPath, []byte(fallbackManifest), "0644"); err != nil {
		return err
	}
	protocolPackManifest, err := renderProtocolPackManifestWithFallbacks(
		req.Server.Host,
		Transport(owner.Transport),
		xrayState.WireGuardPort,
		reality.Port,
		owner.VKTurnProxyPort,
		protocolPackFallbacks(protocolPack),
	)
	if err != nil {
		return err
	}
	if err := uploadFile(originClient, whitelistProtocolPackPath, []byte(protocolPackManifest), "0644"); err != nil {
		return err
	}
	setDeploymentProtocolPack(id, protocolPack)
	store.mu.Lock()
	deployment := store.items[id]
	deployment.EdgeEnabled = true
	deployment.EdgeHost = req.Edge.Server.Host
	deployment.EdgePort = publicPort
	deployment.EdgeRoutingMode = string(routingMode)
	store.items[id] = deployment
	store.mu.Unlock()
	completeStep(id, 5)

	return nil
}

func patchOwnerProfileWithYandexEdge(rawJSON string, edgeHost string, publicPort int, originHost string, reality realityFallback, routingMode EdgeRoutingMode, edgeClientReality *realityFallback) (string, []ProtocolPackEntry, error) {
	var profile ownerProfile
	if err := json.Unmarshal([]byte(rawJSON), &profile); err != nil {
		return "", nil, fmt.Errorf("parse owner profile: %w", err)
	}
	if profile.StagedFallbacks == nil {
		profile.StagedFallbacks = map[string]any{}
	}
	ensureRealityRelayDirectFallback(profile.StagedFallbacks)
	ensureRealityRelayOwnerEgressFallback(profile.StagedFallbacks)
	upsertYandexEdgeFallback(
		profile.StagedFallbacks,
		edgeHost,
		publicPort,
		originHost,
		reality.Port,
		reality.ServerName,
		reality.PublicKey,
		reality.ShortID,
		reality.UUID,
		reality.Flow,
	)
	if fallback, ok := profile.StagedFallbacks["realityYandexEdge"].(map[string]any); ok {
		fallback["routingMode"] = routingMode
		fallback["source"] = buildYandexEdgeFallbackSource(publicPort, routingMode)
		fallback["tag"] = buildYandexEdgeFallbackTag(edgeHost, publicPort, routingMode)
	}
	if fallback, ok := profile.StagedFallbacks["realityYandexEdgeProxy"].(map[string]any); ok {
		fallback["routingMode"] = routingMode
		fallback["source"] = buildYandexEdgeFallbackSource(publicPort, routingMode) + ":proxy"
		fallback["tag"] = buildYandexEdgeFallbackTag(edgeHost, publicPort, routingMode) + "-proxy"
		fallback["ownerRealityEgress"] = false
		if routingMode == EdgeRoutingModeXrayProxy {
			fallback["transport"] = inviteCdnYandexTransport
			fallback["description"] = fmt.Sprintf("Edge-terminated Yandex edge bridge mode. The client first connects to the dedicated edge xhttp inbound on %s:%d, then the Yandex VM forwards traffic to the stable REALITY origin %s:%d.", strings.TrimSpace(edgeHost), publicPort, strings.TrimSpace(originHost), reality.Port)
		} else if edgeClientReality != nil {
			fallback["connectPort"] = edgeClientReality.Port
			fallback["serverName"] = edgeClientReality.ServerName
			fallback["publicKey"] = edgeClientReality.PublicKey
			fallback["shortId"] = edgeClientReality.ShortID
			fallback["uuid"] = edgeClientReality.UUID
			fallback["flow"] = edgeClientReality.Flow
			fallback["description"] = fmt.Sprintf("Edge-terminated Yandex edge proxy mode. The client first connects to the dedicated edge REALITY inbound on %s:%d, then the Yandex VM forwards traffic to the stable REALITY origin %s:%d.", strings.TrimSpace(edgeHost), publicPort, strings.TrimSpace(originHost), reality.Port)
		}
	}
	profile.AndroidRuntime = effectiveOwnerAndroidRuntime(
		profile.ServerHost,
		profile.StagedFallbacks,
		profile.AndroidRuntime,
	)
	protocolPack := buildProtocolPackWithFallbacks(
		Transport(profile.Transport),
		effectiveOwnerEndpointPort(profile),
		reality.Port,
		profile.VKTurnProxyPort,
		profile.StagedFallbacks,
	)
	profile.ProtocolPack = protocolPack
	normalized, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return "", nil, fmt.Errorf("marshal owner profile: %w", err)
	}
	return string(normalized), protocolPack, nil
}

func protocolPackFallbacks(protocolPack []ProtocolPackEntry) map[string]any {
	fallbacks := map[string]any{}
	for _, entry := range protocolPack {
		switch entry.ID {
		case "vless-reality-yandex-edge":
			fallbacks["realityYandexEdge"] = map[string]any{"connectPort": entry.Port}
		case "vless-reality-yandex-edge-proxy":
			fallbacks["realityYandexEdgeProxy"] = map[string]any{"connectPort": entry.Port}
		case "vless-reality-relay-owner":
			fallbacks["realityRelayOwnerEgress"] = map[string]any{}
		case "vless-reality-relay-direct":
			fallbacks["realityRelayDirect"] = map[string]any{}
		}
	}
	return fallbacks
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

func runEdgeAttachHealthChecks(client *ssh.Client, layout yandexEdgeRuntimeLayout, routingMode EdgeRoutingMode, publicPort int, originHost string, originPort int) ([]Check, bool) {
	type remoteCheck struct {
		key           string
		label         string
		cmd           string
		successDetail string
	}

	checks := []remoteCheck{
		{
			key:           "edge-service-active",
			label:         "Edge service active",
			cmd:           remoteRootShell(fmt.Sprintf("systemctl is-active %s", quoteShell(layout.serviceName))),
			successDetail: fmt.Sprintf("%s is active.", layout.serviceName),
		},
		{
			key:           "edge-public-listener",
			label:         "Edge public listener",
			cmd:           remoteRootShell(fmt.Sprintf("ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$'", publicPort)),
			successDetail: fmt.Sprintf("%d/tcp is listening on the edge host.", publicPort),
		},
		{
			key:           "edge-origin-reachability",
			label:         "Edge to origin reachability",
			cmd:           remoteRootShell(fmt.Sprintf("timeout 8 bash -lc 'cat </dev/null >/dev/tcp/%s/%d'", originHost, originPort)),
			successDetail: fmt.Sprintf("Edge can reach the REALITY origin on %s:%d.", originHost, originPort),
		},
		{
			key:           "edge-manifest",
			label:         "Edge manifest",
			cmd:           remoteRootShell(fmt.Sprintf("test -s %s", quoteShell(layout.manifestPath))),
			successDetail: fmt.Sprintf("Edge manifest is present at %s.", layout.manifestPath),
		},
	}

	switch routingMode {
	case EdgeRoutingModeSNIRouter:
		checks = append(checks, remoteCheck{
			key:           "edge-haproxy-config",
			label:         "Edge HAProxy config",
			cmd:           remoteRootShell(fmt.Sprintf("haproxy -c -f %s", quoteShell(layout.haproxyPath))),
			successDetail: fmt.Sprintf("HAProxy config passes syntax validation at %s.", layout.haproxyPath),
		})
	case EdgeRoutingModeXrayProxy:
		checks = append(checks, remoteCheck{
			key:           "edge-xray-config",
			label:         "Edge xray config",
			cmd:           remoteRootShell(fmt.Sprintf("%s run -test -config %s", quoteShell(layout.xrayPath), quoteShell(layout.xrayConfig))),
			successDetail: fmt.Sprintf("Xray config passes syntax validation at %s.", layout.xrayConfig),
		})
		checks = append(checks, remoteCheck{
			key:           "edge-xray-cert",
			label:         "Edge xray certificate",
			cmd:           remoteRootShell(fmt.Sprintf("test -s %s && test -s %s", quoteShell(layout.xrayCert), quoteShell(layout.xrayKey))),
			successDetail: fmt.Sprintf("Xray bridge certificate and key are present at %s and %s.", layout.xrayCert, layout.xrayKey),
		})
	default:
		checks = append(checks, remoteCheck{
			key:           "edge-socat-runtime",
			label:         "Edge socat runtime",
			cmd:           remoteRootShell("command -v socat >/dev/null"),
			successDetail: "socat is installed for tcp-forward mode.",
		})
	}

	results := make([]Check, 0, len(checks))
	allOK := true
	for _, item := range checks {
		output, err := runRemote(client, item.cmd)
		ok := err == nil
		detail := strings.TrimSpace(output)
		if ok && detail == "" {
			detail = item.successDetail
		}
		if err != nil {
			detail = err.Error()
		}
		results = append(results, Check{
			Key:    item.key,
			Label:  item.label,
			OK:     ok,
			Detail: detail,
		})
		allOK = allOK && ok
	}
	return results, allOK
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

	cmd := exec.Command(resolveGoBinary(), "install", "github.com/cacggghp/vk-turn-proxy/server@v1.6.0")
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
