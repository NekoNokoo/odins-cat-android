package provision

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

	"golang.org/x/crypto/ssh"
)

const (
	whitelistEdgeRoot         = "/opt/whitelist-edge"
	whitelistEdgeConfigDir    = whitelistEdgeRoot + "/config"
	whitelistEdgeManifestPath = whitelistEdgeConfigDir + "/edge-forward.json"
	whitelistEdgeServicePath  = "/etc/systemd/system/whitelist-yandex-edge.service"
)

func normalizedEdgePublicPort(edge *EdgeAttach) int {
	if edge == nil || edge.PublicPort <= 0 {
		return yandexEdgeDefaultPort
	}
	return edge.PublicPort
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

func renderYandexEdgeSystemdUnit(originHost string, originPort, publicPort int) string {
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

func renderYandexEdgeManifest(edgeHost string, publicPort int, originHost string, originPort int, serverName, publicKey, shortID, uuid, flow string) (string, error) {
	raw, err := json.MarshalIndent(map[string]any{
		"provider":   EdgeProviderYandex,
		"edgeHost":   edgeHost,
		"publicPort": publicPort,
		"originHost": originHost,
		"originPort": originPort,
		"serverName": serverName,
		"publicKey":  publicKey,
		"shortId":    shortID,
		"uuid":       uuid,
		"flow":       flow,
		"generatedAt": nowRFC3339(),
	}, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
