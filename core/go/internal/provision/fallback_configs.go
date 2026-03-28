package provision

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"golang.org/x/crypto/curve25519"
)

const (
	realityServerName      = "www.cloudflare.com"
	realityDestination     = "www.cloudflare.com:443"
	realityFallbackPort    = 443
	realityFallbackMinPort = 52443
	realityFallbackMaxPort = 52543
	naiveFallbackPort      = 8443
	hysteria2FallbackPort  = 9443
)

type x25519KeyPair struct {
	Private string
	Public  string
}

func generateX25519KeyPair() (x25519KeyPair, error) {
	privateKey := make([]byte, 32)
	if _, err := rand.Read(privateKey); err != nil {
		return x25519KeyPair{}, err
	}
	privateKey[0] &= 248
	privateKey[31] = (privateKey[31] & 127) | 64
	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		return x25519KeyPair{}, fmt.Errorf("derive x25519 public key: %w", err)
	}
	return x25519KeyPair{
		Private: base64.RawURLEncoding.EncodeToString(privateKey),
		Public:  base64.RawURLEncoding.EncodeToString(publicKey),
	}, nil
}

func generateProtocolUUID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate uuid bytes: %w", err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	hexText := hex.EncodeToString(raw)
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexText[0:8], hexText[8:12], hexText[12:16], hexText[16:20], hexText[20:32]), nil
}

func generateRealityShortID() (string, error) {
	raw := make([]byte, 8)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate short id: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

func renderRealityServerConfig(port int, uuid, privateKey, shortID string) (string, error) {
	config := map[string]any{
		"log": map[string]any{
			"loglevel": "warning",
		},
		"inbounds": []map[string]any{
			{
				"tag":      "reality-in",
				"listen":   "0.0.0.0",
				"port":     port,
				"protocol": "vless",
				"settings": map[string]any{
					"clients": []map[string]any{
						{
							"id":   uuid,
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
						"dest":        realityDestination,
						"xver":        0,
						"serverNames": []string{realityServerName},
						"privateKey":  privateKey,
						"shortIds":    []string{shortID},
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
				"protocol": "freedom",
				"settings": map[string]any{
					"domainStrategy": "UseIPv4",
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

func renderStagedFallbackManifest(host string, realityPort int) (string, error) {
	manifest := map[string]any{
		"host":        host,
		"generatedAt": nowRFC3339(),
		"entries": []map[string]any{
			{
				"id":      "vless-reality",
				"status":  "ready",
				"engine":  "xray",
				"port":    realityPort,
				"network": "tcp",
				"notes":   "Controlled direct fallback path exposed alongside the current WireGuard transport for macOS localhost testing.",
			},
			{
				"id":      "naive",
				"status":  "staged",
				"engine":  "sing-box",
				"port":    naiveFallbackPort,
				"network": "tcp",
				"notes":   "Reserved for future HTTPS camouflage fallback once certificates and auth material are provisioned.",
			},
			{
				"id":      "hysteria2",
				"status":  "staged",
				"engine":  "sing-box",
				"port":    hysteria2FallbackPort,
				"network": "udp",
				"notes":   "Reserved for future UDP fallback once client and server configs are promoted from staged mode.",
			},
		},
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func buildStagedFallbacks(realityPort int, realityPublicKey, realityShortID, realityUUID string, promoted bool) map[string]any {
	realityStatus := "staged"
	realityDescription := "Server-side config is generated during deploy but not promoted to the active runtime path yet."
	if promoted {
		realityStatus = "ready"
		realityDescription = "Server-side REALITY inbound is live alongside the current WireGuard path and ready for controlled client-side testing."
	}
	return map[string]any{
		"vlessReality": map[string]any{
			"status":      realityStatus,
			"port":        realityPort,
			"serverName":  realityServerName,
			"publicKey":   realityPublicKey,
			"shortId":     realityShortID,
			"uuid":        realityUUID,
			"flow":        "xtls-rprx-vision",
			"description": realityDescription,
		},
		"naive": map[string]any{
			"status":      "staged",
			"port":        naiveFallbackPort,
			"description": "Reserved for future HTTPS camouflage fallback once certificates and credentials are provisioned.",
		},
		"hysteria2": map[string]any{
			"status":      "staged",
			"port":        hysteria2FallbackPort,
			"description": "Reserved for future UDP fallback once client and server configs are promoted from staged mode.",
		},
	}
}
