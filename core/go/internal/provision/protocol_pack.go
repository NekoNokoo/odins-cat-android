package provision

import "encoding/json"

type ProtocolStatus string

const (
	ProtocolStatusActive ProtocolStatus = "active"
	ProtocolStatusStaged ProtocolStatus = "staged"
)

type ProtocolPackEntry struct {
	ID      string         `json:"id"`
	Label   string         `json:"label"`
	Status  ProtocolStatus `json:"status"`
	Engine  string         `json:"engine"`
	Scheme  string         `json:"scheme"`
	Network string         `json:"network"`
	Port    int            `json:"port"`
	Notes   string         `json:"notes,omitempty"`
}

type protocolPackManifest struct {
	Host            string              `json:"host"`
	Transport       string              `json:"transport"`
	ActiveProtocol  string              `json:"activeProtocol"`
	GeneratedAt     string              `json:"generatedAt"`
	RecommendedPath string              `json:"recommendedPath"`
	Entries         []ProtocolPackEntry `json:"entries"`
}

func buildProtocolPack(transport Transport, endpointPort, realityPort int) []ProtocolPackEntry {
	if endpointPort <= 0 {
		endpointPort = whitelistWireGuardPortStart
	}
	if realityPort <= 0 {
		realityPort = realityFallbackPort
	}

	if transport == TransportVKTurnProxyXray {
		return []ProtocolPackEntry{
			{
				ID:      "vk-turn-wireguard",
				Label:   "VK TURN relay + xray",
				Status:  ProtocolStatusActive,
				Engine:  "xray",
				Scheme:  "wireguard",
				Network: "udp",
				Port:    endpointPort,
				Notes:   "Current VK-focused path that relays WireGuard-compatible traffic through vk-turn-proxy.",
			},
			{
				ID:      "vless-reality",
				Label:   "VLESS + REALITY",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "vless+reality",
				Network: "tcp",
				Port:    realityPort,
				Notes:   "Direct TCP fallback stays staged until the server is switched to the xray direct transport.",
			},
			{
				ID:      "naive",
				Label:   "Naive",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "naive",
				Network: "tcp",
				Port:    naiveFallbackPort,
				Notes:   "Planned browser-like HTTPS fallback for restrictive networks once server certificates are provisioned.",
			},
			{
				ID:      "hysteria2",
				Label:   "Hysteria2",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "hysteria2",
				Network: "udp",
				Port:    hysteria2FallbackPort,
				Notes:   "Planned high-performance UDP fallback for networks where direct WireGuard is unstable.",
			},
		}
	}

	return []ProtocolPackEntry{
		{
			ID:      "vless-reality",
			Label:   "VLESS + REALITY",
			Status:  ProtocolStatusActive,
			Engine:  "sing-box",
			Scheme:  "vless+reality",
			Network: "tcp",
			Port:    realityPort,
			Notes:   "Default direct path for localhost SOCKS and system proxy mode on restrictive networks.",
		},
		{
			ID:      "direct-wireguard",
			Label:   "Direct WireGuard-over-xray",
			Status:  ProtocolStatusStaged,
			Engine:  "xray",
			Scheme:  "wireguard",
			Network: "udp",
			Port:    endpointPort,
			Notes:   "Legacy direct UDP path kept as a fallback while VLESS + REALITY is the default.",
		},
		{
			ID:      "naive",
			Label:   "Naive",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "naive",
			Network: "tcp",
			Port:    naiveFallbackPort,
			Notes:   "Planned browser-like HTTPS fallback for restrictive networks once server certificates are provisioned.",
		},
		{
			ID:      "hysteria2",
			Label:   "Hysteria2",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "hysteria2",
			Network: "udp",
			Port:    hysteria2FallbackPort,
			Notes:   "Planned high-performance UDP fallback for networks where direct WireGuard is unstable.",
		},
	}
}

func activeProtocolID(transport Transport) string {
	if transport == TransportVKTurnProxyXray {
		return "vk-turn-wireguard"
	}
	return "vless-reality"
}

func realityPortFromStagedFallbacks(stagedFallbacks map[string]any) int {
	raw, ok := stagedFallbacks["vlessReality"]
	if !ok {
		return 0
	}
	entry, ok := raw.(map[string]any)
	if !ok {
		return 0
	}
	switch value := entry["port"].(type) {
	case float64:
		return int(value)
	case int:
		return value
	default:
		return 0
	}
}

func renderProtocolPackManifest(host string, transport Transport, endpointPort, realityPort int) (string, error) {
	manifest := protocolPackManifest{
		Host:            host,
		Transport:       string(transport),
		ActiveProtocol:  activeProtocolID(transport),
		GeneratedAt:     nowRFC3339(),
		RecommendedPath: activeProtocolID(transport),
		Entries:         buildProtocolPack(transport, endpointPort, realityPort),
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
