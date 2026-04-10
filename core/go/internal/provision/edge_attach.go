package provision

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

	"golang.org/x/crypto/ssh"
)

const (
	legacyWhitelistEdgeRoot        = "/opt/whitelist-edge"
	legacyWhitelistEdgeServiceName = "whitelist-yandex-edge.service"
)

type yandexEdgeRuntimeLayout struct {
	rootDir      string
	configDir    string
	manifestPath string
	haproxyPath  string
	xrayPath     string
	xrayConfig   string
	serviceName  string
	servicePath  string
}

func buildYandexEdgeRuntimeLayout(publicPort int, routingMode EdgeRoutingMode) yandexEdgeRuntimeLayout {
	if publicPort <= 0 {
		publicPort = yandexEdgeDefaultPort
	}
	if routingMode == "" {
		routingMode = EdgeRoutingModeTCPForward
	}
	if publicPort == yandexEdgeDefaultPort && routingMode == EdgeRoutingModeTCPForward {
		return yandexEdgeRuntimeLayout{
			rootDir:      legacyWhitelistEdgeRoot,
			configDir:    legacyWhitelistEdgeRoot + "/config",
			manifestPath: legacyWhitelistEdgeRoot + "/config/edge-forward.json",
			haproxyPath:  legacyWhitelistEdgeRoot + "/config/haproxy.cfg",
			xrayPath:     legacyWhitelistEdgeRoot + "/bin/xray",
			xrayConfig:   legacyWhitelistEdgeRoot + "/config/xray-edge-proxy.json",
			serviceName:  legacyWhitelistEdgeServiceName,
			servicePath:  "/etc/systemd/system/" + legacyWhitelistEdgeServiceName,
		}
	}
	rootDir := fmt.Sprintf("/opt/whitelist-edge-%s-%d", routingMode, publicPort)
	serviceName := fmt.Sprintf("whitelist-yandex-edge-%s-%d.service", routingMode, publicPort)
	return yandexEdgeRuntimeLayout{
		rootDir:      rootDir,
		configDir:    rootDir + "/config",
		manifestPath: rootDir + "/config/edge-forward.json",
		haproxyPath:  rootDir + "/config/haproxy.cfg",
		xrayPath:     rootDir + "/bin/xray",
		xrayConfig:   rootDir + "/config/xray-edge-proxy.json",
		serviceName:  serviceName,
		servicePath:  "/etc/systemd/system/" + serviceName,
	}
}

func buildYandexEdgeFallbackSource(publicPort int, routingMode EdgeRoutingMode) string {
	if publicPort == yandexEdgeDefaultPort && routingMode == EdgeRoutingModeTCPForward {
		return "owner-attached:yandex-edge"
	}
	return fmt.Sprintf("owner-attached:yandex-edge:%s:%d", routingMode, publicPort)
}

func buildYandexEdgeFallbackTag(edgeHost string, publicPort int, routingMode EdgeRoutingMode) string {
	tag := fmt.Sprintf("yandex-edge-%s", strings.ReplaceAll(strings.TrimSpace(edgeHost), ".", "-"))
	if publicPort != yandexEdgeDefaultPort {
		tag = fmt.Sprintf("%s-%d", tag, publicPort)
	}
	if routingMode != EdgeRoutingModeTCPForward {
		tag = fmt.Sprintf("%s-%s", tag, routingMode)
	}
	return tag
}

func normalizedEdgePublicPort(edge *EdgeAttach) int {
	if edge == nil || edge.PublicPort <= 0 {
		return yandexEdgeDefaultPort
	}
	return edge.PublicPort
}

func normalizedEdgeRoutingMode(edge *EdgeAttach) EdgeRoutingMode {
	if edge == nil {
		return EdgeRoutingModeTCPForward
	}
	trimmed := strings.TrimSpace(string(edge.RoutingMode))
	if trimmed == "" {
		return EdgeRoutingModeTCPForward
	}
	return EdgeRoutingMode(trimmed)
}

func validateEdgeAttachRequest(req Request) error {
	if req.Edge == nil || !req.Edge.Enabled {
		return fmt.Errorf("edge attach requires an enabled edge configuration")
	}
	if req.Edge.Provider != "" && req.Edge.Provider != EdgeProviderYandex {
		return fmt.Errorf("unsupported edge provider %q", req.Edge.Provider)
	}
	if strings.TrimSpace(req.Server.Host) == "" || strings.TrimSpace(req.Server.Username) == "" || strings.TrimSpace(req.Secret) == "" {
		return fmt.Errorf("origin host, username, and secret are required")
	}
	if strings.TrimSpace(req.Edge.Server.Host) == "" || strings.TrimSpace(req.Edge.Server.Username) == "" || strings.TrimSpace(req.Edge.Secret) == "" {
		return fmt.Errorf("edge host, username, and secret are required")
	}
	if normalizedPort(req.Edge.Server.Port) <= 0 {
		return fmt.Errorf("edge ssh port must be positive")
	}
	if normalizedEdgePublicPort(req.Edge) <= 0 {
		return fmt.Errorf("edge public port must be positive")
	}
	switch normalizedEdgeRoutingMode(req.Edge) {
	case EdgeRoutingModeTCPForward, EdgeRoutingModeSNIRouter, EdgeRoutingModeXrayProxy:
	default:
		return fmt.Errorf("unsupported edge routing mode %q", req.Edge.RoutingMode)
	}
	return nil
}

func edgeRequest(req Request) Request {
	if req.Edge == nil {
		return Request{}
	}
	return Request{
		Server: Server{
			Host:       req.Edge.Server.Host,
			Port:       normalizedPort(req.Edge.Server.Port),
			Username:   req.Edge.Server.Username,
			AuthMethod: req.Edge.Server.AuthMethod,
		},
		Secret: req.Edge.Secret,
	}
}

func remoteRootShell(cmd string) string {
	quoted := quoteShell(cmd)
	return fmt.Sprintf("if [ \"$(id -u)\" = \"0\" ]; then sh -lc %s; else sudo sh -lc %s; fi", quoted, quoted)
}

func uploadFileWithSudo(client *ssh.Client, remotePath string, data []byte, mode string) error {
	encoded := base64.StdEncoding.EncodeToString(data)
	cmd := remoteRootShell(fmt.Sprintf(
		"mkdir -p %s && printf %%s %s | base64 -d > %s && chmod %s %s",
		quoteShell(dirOf(remotePath)),
		quoteShell(encoded),
		quoteShell(remotePath),
		mode,
		quoteShell(remotePath),
	))
	_, err := runRemote(client, cmd)
	return err
}

func ensureRemoteSocatInstalled(client *ssh.Client) error {
	cmd := remoteRootShell("if command -v socat >/dev/null 2>&1; then exit 0; fi; if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y socat; else echo 'socat is required and apt-get was not found' >&2; exit 1; fi")
	_, err := runRemote(client, cmd)
	return err
}

func ensureRemoteHAProxyInstalled(client *ssh.Client) error {
	cmd := remoteRootShell("if command -v haproxy >/dev/null 2>&1; then exit 0; fi; if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy; else echo 'haproxy is required and apt-get was not found' >&2; exit 1; fi")
	_, err := runRemote(client, cmd)
	return err
}

func ensureRemoteEdgeXrayInstalled(client *ssh.Client, targetPath string) error {
	cmd := remoteRootShell(fmt.Sprintf(
		"mkdir -p %s && if [ -x %s ]; then exit 0; fi; %s",
		quoteShell(dirOf(targetPath)),
		quoteShell(targetPath),
		renderRemoteXrayInstallCommand(xrayReleaseURL, targetPath),
	))
	_, err := runRemote(client, cmd)
	return err
}

func renderYandexEdgeTCPForwardSystemdUnit(originHost string, originPort, publicPort int) string {
	return fmt.Sprintf(`[Unit]
Description=Odin One Yandex edge passthrough
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:%d,fork,reuseaddr TCP:%s:%d
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
`, publicPort, originHost, originPort)
}

func renderYandexEdgeHAProxyConfig(bindHost string, publicPort int, serverName, originHost string, originPort int) string {
	return fmt.Sprintf(`global
  log /dev/log local0

defaults
  log global
  mode tcp
  timeout connect 10s
  timeout client 60s
  timeout server 60s

frontend reality_edge_in
  bind %s:%d
  mode tcp
  tcp-request inspect-delay 5s
  tcp-request content accept if { req.ssl_hello_type 1 }
  acl sni_route req.ssl_sni -i %s
  use_backend be_route if sni_route
  default_backend reality_drop

backend be_route
  mode tcp
  server route %s:%d check

backend reality_drop
  mode tcp
  server drop 127.0.0.1:9
`, bindHost, publicPort, serverName, originHost, originPort)
}

func renderYandexEdgeSNIRouterSystemdUnit(configPath string) string {
	return fmt.Sprintf(`[Unit]
Description=Odin One Yandex edge SNI router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -W -db -f %s
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
`, configPath)
}

func renderYandexEdgeXrayProxyConfig(
	publicPort int,
	edgeUUID, edgePrivateKey, edgeShortID string,
	edgeServerName string,
	originHost string,
	originPort int,
	originServerName, originPublicKey, originShortID, originUUID, originFlow string,
) (string, error) {
	flow := strings.TrimSpace(originFlow)
	if flow == "" {
		flow = "xtls-rprx-vision"
	}
	config := map[string]any{
		"log": map[string]any{
			"loglevel": "warning",
		},
		"inbounds": []map[string]any{
			{
				"tag":      "edge-reality-in",
				"listen":   "0.0.0.0",
				"port":     publicPort,
				"protocol": "vless",
				"settings": map[string]any{
					"clients": []map[string]any{
						{
							"id":   edgeUUID,
							"flow": "xtls-rprx-vision",
						},
					},
					"decryption": "none",
				},
				"streamSettings": map[string]any{
					"network":  "tcp",
					"security": "reality",
					"realitySettings": map[string]any{
						"show":        false,
						"dest":        realityDestination(),
						"xver":        0,
						"serverNames": []string{edgeServerName},
						"privateKey":  edgePrivateKey,
						"shortIds":    []string{edgeShortID},
					},
				},
				"sniffing": map[string]any{
					"enabled":      true,
					"destOverride": []string{"http", "tls", "quic"},
				},
			},
		},
		"outbounds": []map[string]any{
			{
				"tag":      "origin-reality-out",
				"protocol": "vless",
				"settings": map[string]any{
					"vnext": []map[string]any{
						{
							"address": originHost,
							"port":    originPort,
							"users": []map[string]any{
								{
									"id":         originUUID,
									"encryption": "none",
									"flow":       flow,
								},
							},
						},
					},
				},
				"streamSettings": map[string]any{
					"network":  "tcp",
					"security": "reality",
					"realitySettings": map[string]any{
						"serverName":  originServerName,
						"publicKey":   originPublicKey,
						"shortId":     originShortID,
						"fingerprint": "chrome",
					},
				},
			},
			{
				"tag":      "direct",
				"protocol": "freedom",
				"settings": map[string]any{
					"domainStrategy": "UseIPv4",
				},
			},
		},
		"routing": map[string]any{
			"rules": []map[string]any{
				{
					"type":        "field",
					"inboundTag":  []string{"edge-reality-in"},
					"outboundTag": "origin-reality-out",
				},
			},
		},
	}
	raw, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func renderYandexEdgeXrayProxySystemdUnit(binaryPath, configPath string) string {
	return fmt.Sprintf(`[Unit]
Description=Odin One Yandex edge xray proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s run -config %s
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
`, binaryPath, configPath)
}

func renderYandexEdgeManifest(edgeHost string, publicPort int, originHost string, originPort int, serverName, publicKey, shortID, uuid, flow string, routingMode EdgeRoutingMode, layout yandexEdgeRuntimeLayout) (string, error) {
	raw, err := json.MarshalIndent(map[string]any{
		"provider":    EdgeProviderYandex,
		"routingMode": routingMode,
		"edgeHost":    edgeHost,
		"publicPort":  publicPort,
		"serviceName": layout.serviceName,
		"servicePath": layout.servicePath,
		"installRoot": layout.rootDir,
		"configDir":   layout.configDir,
		"configPath":  layout.manifestPath,
		"xrayPath":    layout.xrayPath,
		"xrayConfig":  layout.xrayConfig,
		"originHost":  originHost,
		"originPort":  originPort,
		"serverName":  serverName,
		"publicKey":   publicKey,
		"shortId":     shortID,
		"uuid":        uuid,
		"flow":        flow,
		"routes": []map[string]any{
			{
				"serverName": serverName,
				"originHost": originHost,
				"originPort": originPort,
			},
		},
		"generatedAt": nowRFC3339(),
	}, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
