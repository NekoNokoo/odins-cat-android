package provision

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"

	"golang.org/x/crypto/curve25519"
)

const (
	defaultRealityServerName = "www.cloudflare.com"
	defaultRealityDestHost   = "www.cloudflare.com"
	realityFallbackPort      = 443
	realityFallbackMinPort   = 52443
	realityFallbackMaxPort   = 52543
	naiveFallbackPort        = 8443
	hysteria2FallbackPort    = 8443
	yandexEdgeDefaultPort    = 443

	relayAutoselectDefaultURL         = "https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt"
	relayAutoselectDefaultSourceLabel = "igareck-mobile-hourly"
)

func realityServerName() string {
	if value := strings.TrimSpace(os.Getenv("ODIN_ONE_REALITY_SERVER_NAME")); value != "" {
		return value
	}
	return defaultRealityServerName
}

func realityDestination() string {
	if value := strings.TrimSpace(os.Getenv("ODIN_ONE_REALITY_DEST")); value != "" {
		return value
	}
	if host := strings.TrimSpace(os.Getenv("ODIN_ONE_REALITY_DEST_HOST")); host != "" {
		return host + ":443"
	}
	return defaultRealityDestHost + ":443"
}

type x25519KeyPair struct {
	Private string
	Public  string
}

func generateX25519KeyPair() (x25519KeyPair, error) {
	if pair, err := generateX25519KeyPairViaXray(); err == nil {
		return pair, nil
	}

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
		Private: encodeXrayX25519Key(privateKey),
		Public:  encodeXrayX25519Key(publicKey),
	}, nil
}

func generateX25519KeyPairViaXray() (x25519KeyPair, error) {
	binaryPath, err := ensureLocalXrayBinary()
	if err != nil {
		return x25519KeyPair{}, err
	}
	cmd := exec.Command(binaryPath, "x25519")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return x25519KeyPair{}, fmt.Errorf("run xray x25519: %w: %s", err, strings.TrimSpace(string(output)))
	}

	var pair x25519KeyPair
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "Private key:") {
			pair.Private = strings.TrimSpace(strings.TrimPrefix(line, "Private key:"))
		}
		if strings.HasPrefix(line, "Public key:") {
			pair.Public = strings.TrimSpace(strings.TrimPrefix(line, "Public key:"))
		}
	}
	if err := scanner.Err(); err != nil {
		return x25519KeyPair{}, fmt.Errorf("scan xray x25519 output: %w", err)
	}
	if pair.Private == "" || pair.Public == "" {
		return x25519KeyPair{}, fmt.Errorf("parse xray x25519 output: %q", strings.TrimSpace(string(output)))
	}
	return pair, nil
}

func encodeXrayX25519Key(key []byte) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	var out strings.Builder
	out.Grow((len(key)*8 + 5) / 6)
	var buffer uint
	var bits uint
	for _, b := range key {
		buffer = (buffer << 8) | uint(b)
		bits += 8
		for bits >= 6 {
			bits -= 6
			out.WriteByte(alphabet[(buffer>>bits)&0x3F])
		}
	}
	if bits > 0 {
		out.WriteByte(alphabet[(buffer<<(6-bits))&0x3F])
	}
	return out.String()
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

func generateProtocolSecret(byteCount int) (string, error) {
	raw := make([]byte, byteCount)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate protocol secret: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

func renderHysteria2ServerConfig(port int, users map[string]string, obfsPassword string) (string, error) {
	authUsers := make([]map[string]any, 0, len(users))
	names := make([]string, 0, len(users))
	for name := range users {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		authUsers = append(authUsers, map[string]any{
			"name":     name,
			"password": users[name],
		})
	}
	config := map[string]any{
		"log": map[string]any{"level": "warn"},
		"inbounds": []map[string]any{{
			"type":        "hysteria2",
			"tag":         "hy2-in",
			"listen":      "0.0.0.0",
			"listen_port": port,
			"obfs": map[string]any{
				"type":     "salamander",
				"password": obfsPassword,
			},
			"users": authUsers,
			"tls": map[string]any{
				"enabled":          true,
				"certificate_path": whitelistHysteria2CertPath,
				"key_path":         whitelistHysteria2KeyPath,
			},
		}},
		"outbounds": []map[string]any{{"type": "direct", "tag": "direct"}},
	}
	raw, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func upsertHysteria2Fallback(stagedFallbacks map[string]any, host, password, obfsPassword, certificatePin string) {
	if stagedFallbacks == nil {
		return
	}
	stagedFallbacks["hysteria2"] = map[string]any{
		"status":                     "ready",
		"connectHost":                strings.TrimSpace(host),
		"connectPort":                hysteria2FallbackPort,
		"password":                   password,
		"serverName":                 "odin-hysteria.local",
		"certificatePublicKeySha256": certificatePin,
		"obfsType":                   "salamander",
		"obfsPassword":               obfsPassword,
		"source":                     "owner-deployed:hysteria2",
		"tag":                        "hysteria2-beta",
		"description":                "Experimental direct Hysteria 2 path over QUIC/UDP with certificate pinning and Salamander obfuscation.",
	}
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
						"dest":        realityDestination(),
						"xver":        0,
						"serverNames": []string{realityServerName()},
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
				"status":  "ready",
				"engine":  "sing-box",
				"port":    hysteria2FallbackPort,
				"network": "udp",
				"notes":   "Hysteria 2 Beta is active on UDP 8443 with certificate pinning, BBR, and Salamander obfuscation.",
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
			"serverName":  realityServerName(),
			"publicKey":   realityPublicKey,
			"shortId":     realityShortID,
			"uuid":        realityUUID,
			"flow":        "xtls-rprx-vision",
			"description": realityDescription,
		},
		"realityRelayOwnerEgress": map[string]any{
			"status":          "ready",
			"ownerEgressPort": realityPort,
			"subscriptionUrl": relayAutoselectDefaultURL,
			"sourceLabel":     relayAutoselectDefaultSourceLabel,
			"description":     "Experimental relay-assisted REALITY mode. The client picks a curated external REALITY relay first, then moves egress back to your Odin One server.",
		},
		"realityRelayDirect": map[string]any{
			"status":          "ready",
			"subscriptionUrl": relayAutoselectDefaultURL,
			"sourceLabel":     relayAutoselectDefaultSourceLabel,
			"description":     "Experimental direct relay mode. The client picks a curated external REALITY relay from the hourly igareck feed and sends traffic through it without a second hop to your Odin One server.",
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

func ensureRealityRelayOwnerEgressFallback(stagedFallbacks map[string]any) {
	if stagedFallbacks == nil {
		return
	}
	if _, exists := stagedFallbacks["realityRelayOwnerEgress"]; exists {
		return
	}
	stagedFallbacks["realityRelayOwnerEgress"] = map[string]any{
		"status":          "ready",
		"ownerEgressPort": realityFallbackMinPort,
		"subscriptionUrl": relayAutoselectDefaultURL,
		"sourceLabel":     relayAutoselectDefaultSourceLabel,
		"description":     "Experimental relay-assisted REALITY mode. The client picks a curated external REALITY relay first, then moves egress back to your Odin One server.",
	}
}

func ensureRealityRelayDirectFallback(stagedFallbacks map[string]any) {
	if stagedFallbacks == nil {
		return
	}
	if _, exists := stagedFallbacks["realityRelayDirect"]; exists {
		return
	}
	stagedFallbacks["realityRelayDirect"] = map[string]any{
		"status":          "ready",
		"subscriptionUrl": relayAutoselectDefaultURL,
		"sourceLabel":     relayAutoselectDefaultSourceLabel,
		"description":     "Experimental direct relay mode. The client picks a curated external REALITY relay from the hourly igareck feed and sends traffic through it without a second hop to your Odin One server.",
	}
}

func buildYandexEdgeFallback(connectHost string, connectPort int, originHost string, originPort int, serverName, publicKey, shortID, uuid, flow string) map[string]any {
	if connectPort <= 0 {
		connectPort = yandexEdgeDefaultPort
	}
	trimmedFlow := strings.TrimSpace(flow)
	if trimmedFlow == "" {
		trimmedFlow = "xtls-rprx-vision"
	}
	return map[string]any{
		"status":      "ready",
		"connectHost": strings.TrimSpace(connectHost),
		"connectPort": connectPort,
		"routingMode": EdgeRoutingModeTCPForward,
		"originHost":  strings.TrimSpace(originHost),
		"originPort":  originPort,
		"serverName":  strings.TrimSpace(serverName),
		"publicKey":   strings.TrimSpace(publicKey),
		"shortId":     strings.TrimSpace(shortID),
		"uuid":        strings.TrimSpace(uuid),
		"flow":        trimmedFlow,
		"fingerprint": "chrome",
		"source":      "operator-curated:yandex-edge",
		"tag":         strings.ReplaceAll(strings.TrimSpace(connectHost), ".", "-"),
		"description": fmt.Sprintf("Visible Yandex edge mode. The client reaches the stable REALITY origin through %s:%d while preserving the origin path on %s:%d.", strings.TrimSpace(connectHost), connectPort, strings.TrimSpace(originHost), originPort),
	}
}

func buildYandexEdgeProxyFallback(connectHost string, connectPort int, originHost string, originPort int, serverName, publicKey, shortID, uuid, flow string) map[string]any {
	fallback := buildYandexEdgeFallback(
		connectHost,
		connectPort,
		originHost,
		originPort,
		serverName,
		publicKey,
		shortID,
		uuid,
		flow,
	)
	fallback["source"] = "owner-attached:yandex-edge-proxy"
	fallback["tag"] = strings.ReplaceAll(strings.TrimSpace(connectHost), ".", "-") + "-proxy"
	fallback["transport"] = "tcp"
	fallback["ownerRealityEgress"] = false
	fallback["description"] = fmt.Sprintf("Two-hop Yandex edge proxy mode. The client first reaches %s:%d and then continues through the stable REALITY origin %s:%d.", strings.TrimSpace(connectHost), connectPort, strings.TrimSpace(originHost), originPort)
	return fallback
}

func upsertYandexEdgeFallback(stagedFallbacks map[string]any, connectHost string, connectPort int, originHost string, originPort int, serverName, publicKey, shortID, uuid, flow string) {
	if stagedFallbacks == nil {
		return
	}
	stagedFallbacks["realityYandexEdge"] = buildYandexEdgeFallback(
		connectHost,
		connectPort,
		originHost,
		originPort,
		serverName,
		publicKey,
		shortID,
		uuid,
		flow,
	)
	stagedFallbacks["realityYandexEdgeProxy"] = buildYandexEdgeProxyFallback(
		connectHost,
		connectPort,
		originHost,
		originPort,
		serverName,
		publicKey,
		shortID,
		uuid,
		flow,
	)
}
