package provision

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	whitelistRoot             = "/opt/whitelist"
	whitelistBinDir           = whitelistRoot + "/bin"
	whitelistConfigDir        = whitelistRoot + "/config"
	whitelistProfilesDir      = whitelistRoot + "/profiles"
	whitelistGuestProfilesDir = whitelistProfilesDir + "/guests"
	whitelistXrayConfigPath   = whitelistConfigDir + "/xray-server.json"
	whitelistInvitePath       = whitelistProfilesDir + "/owner-profile.json"
	whitelistXrayBinaryPath   = whitelistBinDir + "/xray"
	whitelistProxyBinaryPath  = whitelistBinDir + "/vk-turn-proxy-server"
	whitelistXrayServicePath  = "/etc/systemd/system/whitelist-xray.service"
	whitelistProxyServicePath = "/etc/systemd/system/whitelist-vk-turn-proxy.service"
)

type xrayWireGuardPeer struct {
	PublicKey  string
	AllowedIPs []string
}

func renderXrayConfig(serverPrivateKey string, peers []xrayWireGuardPeer, port int) string {
	return renderXrayConfigWithListen(serverPrivateKey, peers, "127.0.0.1", port)
}

func renderXrayConfigWithListen(serverPrivateKey string, peers []xrayWireGuardPeer, listenHost string, port int) string {
	peerBlocks := make([]string, 0, len(peers))
	for _, peer := range peers {
		allowedIPs := make([]string, 0, len(peer.AllowedIPs))
		for _, address := range peer.AllowedIPs {
			allowedIPs = append(allowedIPs, fmt.Sprintf("              %q", address))
		}
		peerBlocks = append(peerBlocks, fmt.Sprintf(`          {
            "publicKey": %q,
            "allowedIPs": [
%s
            ]
          }`, peer.PublicKey, strings.Join(allowedIPs, ",\n")))
	}

	return fmt.Sprintf(`{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "wg-in",
      "protocol": "wireguard",
      "listen": %q,
      "port": %d,
      "settings": {
        "secretKey": "%s",
        "mtu": 1280,
        "peers": [
%s
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    }
  ]
}
`, listenHost, port, serverPrivateKey, strings.Join(peerBlocks, ",\n"))
}

func renderAccessProfile(role, id, name, host string, transport Transport, endpointPort int, serverPublicKey, clientPrivateKey, clientPublicKey, address string) (string, error) {
	profile := map[string]any{
		"id":           id,
		"role":         role,
		"name":         name,
		"transport":    transport,
		"serverHost":   host,
		"endpointPort": endpointPort,
		"createdAt":    nowRFC3339(),
		"wireguard": map[string]any{
			"serverPublicKey":  serverPublicKey,
			"clientPrivateKey": clientPrivateKey,
			"clientPublicKey":  clientPublicKey,
			"address":          address,
			"mtu":              1280,
		},
	}
	if transport == TransportVKTurnProxyXray {
		profile["vkTurnProxyPort"] = endpointPort
	}

	raw, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func renderSystemdUnit(name, execStart string) string {
	return fmt.Sprintf(`[Unit]
Description=%s
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s
Restart=always
RestartSec=2
WorkingDirectory=%s

[Install]
WantedBy=multi-user.target
`, name, execStart, whitelistRoot)
}

func appCacheDir() (string, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	targetDir := filepath.Join(cacheDir, "odin-one")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return "", err
	}
	return targetDir, nil
}

func sanitizeHost(host string) string {
	replacer := strings.NewReplacer("/", "_", ":", "_", " ", "_")
	return replacer.Replace(strings.TrimSpace(host))
}

func localProfilesDir() (string, error) {
	root, err := appCacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, "profiles")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func localProfilePath(host string) (string, error) {
	dir, err := localProfilesDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, sanitizeHost(host)+"-owner-profile.json"), nil
}
