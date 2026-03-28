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

func buildProtocolPack(transport Transport, endpointPort int) []ProtocolPackEntry {
	if endpointPort <= 0 {
		endpointPort = whitelistWireGuardPortStart
	}
	activeID := "direct-wireguard"
	activeLabel := "Direct WireGuard-over-xray"
	activeNotes := "Current production path for isolated localhost SOCKS and system proxy mode."
	if transport == TransportVKTurnProxyXray {
		activeID = "vk-turn-wireguard"
		activeLabel = "VK TURN relay + xray"
		activeNotes = "Current VK-focused path that relays WireGuard-compatible traffic through vk-turn-proxy."
	}

	return []ProtocolPackEntry{
		{
			ID:      activeID,
			Label:   activeLabel,
			Status:  ProtocolStatusActive,
			Engine:  "xray",
			Scheme:  "wireguard",
			Network: "udp",
			Port:    endpointPort,
			Notes:   activeNotes,
		},
		{
			ID:      "vless-reality",
			Label:   "VLESS + REALITY",
			Status:  ProtocolStatusStaged,
			Engine:  "xray/sing-box",
			Scheme:  "vless+reality",
			Network: "tcp",
			Port:    443,
			Notes:   "Planned Russia-friendly TCP/443 fallback for future direct mode without Apple Network Extension.",
		},
		{
			ID:      "naive",
			Label:   "Naive",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "naive",
			Network: "tcp",
			Port:    8443,
			Notes:   "Planned browser-like HTTPS fallback for restrictive networks once server certificates are provisioned.",
		},
		{
			ID:      "hysteria2",
			Label:   "Hysteria2",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "hysteria2",
			Network: "udp",
			Port:    9443,
			Notes:   "Planned high-performance UDP fallback for networks where direct WireGuard is unstable.",
		},
	}
}

func activeProtocolID(transport Transport) string {
	if transport == TransportVKTurnProxyXray {
		return "vk-turn-wireguard"
	}
	return "direct-wireguard"
}

func renderProtocolPackManifest(host string, transport Transport, endpointPort int) (string, error) {
	manifest := protocolPackManifest{
		Host:            host,
		Transport:       string(transport),
		ActiveProtocol:  activeProtocolID(transport),
		GeneratedAt:     nowRFC3339(),
		RecommendedPath: activeProtocolID(transport),
		Entries:         buildProtocolPack(transport, endpointPort),
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
