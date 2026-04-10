package provision

import (
	"encoding/json"
	"strings"
)

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

func buildProtocolPack(transport Transport, wireGuardPort, realityPort, vkRelayPort int) []ProtocolPackEntry {
	return buildProtocolPackWithFallbacks(transport, wireGuardPort, realityPort, vkRelayPort, nil)
}

func previewProtocolPackFallbacks(edgeHost string, edgePort int) map[string]any {
	fallbacks := map[string]any{
		"realityRelayOwnerEgress": map[string]any{},
		"realityRelayDirect":      map[string]any{},
	}
	if strings.TrimSpace(edgeHost) != "" {
		fallbacks["realityYandexEdge"] = map[string]any{
			"connectPort": edgePort,
		}
		fallbacks["realityYandexEdgeProxy"] = map[string]any{
			"connectPort": edgePort,
		}
	}
	return fallbacks
}

func buildProtocolPackWithFallbacks(transport Transport, wireGuardPort, realityPort, vkRelayPort int, stagedFallbacks map[string]any) []ProtocolPackEntry {
	if wireGuardPort <= 0 {
		wireGuardPort = whitelistWireGuardPortStart
	}
	if realityPort <= 0 {
		realityPort = realityFallbackPort
	}
	if vkRelayPort <= 0 {
		vkRelayPort = whitelistTurnPortStart
	}

	entries := []ProtocolPackEntry{
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
			ID:      "vk-turn-wireguard",
			Label:   "VK TURN relay + xray",
			Status:  ProtocolStatusStaged,
			Engine:  "xray",
			Scheme:  "wireguard",
			Network: "udp",
			Port:    vkRelayPort,
			Notes:   "VK relay stays deployed on the same server so the client can switch to it without another server rollout.",
		},
	}

	if stagedFallbacks != nil {
		if _, ok := stagedFallbacks["realityYandexEdge"]; ok {
			entries = append(entries, ProtocolPackEntry{
				ID:      "vless-reality-yandex-edge",
				Label:   "Yandex edge",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "vless+reality-edge",
				Network: "tcp",
				Port:    protocolPackPortFromFallback(stagedFallbacks["realityYandexEdge"], "connectPort", yandexEdgeDefaultPort),
				Notes:   "Optional whitelist-facing entry surface that forwards to the live REALITY origin through a dedicated Yandex edge.",
			})
		}
		if _, ok := stagedFallbacks["realityYandexEdgeProxy"]; ok {
			entries = append(entries, ProtocolPackEntry{
				ID:      "vless-reality-yandex-edge-proxy",
				Label:   "Yandex edge proxy",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "vless+reality-edge-proxy",
				Network: "tcp",
				Port:    protocolPackPortFromFallback(stagedFallbacks["realityYandexEdgeProxy"], "connectPort", yandexEdgeDefaultPort),
				Notes:   "Two-hop Yandex edge proxy path for restrictive networks. The client enters through the Yandex edge and keeps egress on the stable REALITY origin.",
			})
		}
		if _, ok := stagedFallbacks["realityRelayOwnerEgress"]; ok {
			entries = append(entries, ProtocolPackEntry{
				ID:      "vless-reality-relay-owner",
				Label:   "white tunel",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "vless+reality-relay",
				Network: "tcp",
				Port:    realityFallbackPort,
				Notes:   "Relay-assisted REALITY path. The client first reaches a curated relay and then exits through your server.",
			})
		}
		if _, ok := stagedFallbacks["realityRelayDirect"]; ok {
			entries = append(entries, ProtocolPackEntry{
				ID:      "vless-reality-relay-direct",
				Label:   "white relay",
				Status:  ProtocolStatusStaged,
				Engine:  "sing-box",
				Scheme:  "vless+reality-relay",
				Network: "tcp",
				Port:    realityFallbackPort,
				Notes:   "Direct relay path. The client uses a curated external REALITY relay without a second hop through your server.",
			})
		}
	}

	entries = append(entries,
		ProtocolPackEntry{
			ID:      "direct-wireguard",
			Label:   "Direct WireGuard-over-xray",
			Status:  ProtocolStatusStaged,
			Engine:  "xray",
			Scheme:  "wireguard",
			Network: "udp",
			Port:    wireGuardPort,
			Notes:   "Legacy direct UDP path kept as a fallback while VLESS + REALITY is the default.",
		},
		ProtocolPackEntry{
			ID:      "naive",
			Label:   "Naive",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "naive",
			Network: "tcp",
			Port:    naiveFallbackPort,
			Notes:   "Planned browser-like HTTPS fallback for restrictive networks once server certificates are provisioned.",
		},
		ProtocolPackEntry{
			ID:      "hysteria2",
			Label:   "Hysteria2",
			Status:  ProtocolStatusStaged,
			Engine:  "sing-box",
			Scheme:  "hysteria2",
			Network: "udp",
			Port:    hysteria2FallbackPort,
			Notes:   "Planned high-performance UDP fallback for networks where direct WireGuard is unstable.",
		},
	)

	if transport == TransportVKTurnProxyXray {
		entries[0].Status = ProtocolStatusStaged
		entries[1].Status = ProtocolStatusActive
	}

	return entries
}

func protocolPackPortFromFallback(raw any, key string, fallback int) int {
	entry, ok := raw.(map[string]any)
	if !ok {
		return fallback
	}
	switch value := entry[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	default:
		return fallback
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

func renderProtocolPackManifest(host string, transport Transport, wireGuardPort, realityPort, vkRelayPort int) (string, error) {
	return renderProtocolPackManifestWithFallbacks(host, transport, wireGuardPort, realityPort, vkRelayPort, nil)
}

func renderProtocolPackManifestWithFallbacks(host string, transport Transport, wireGuardPort, realityPort, vkRelayPort int, stagedFallbacks map[string]any) (string, error) {
	manifest := protocolPackManifest{
		Host:            host,
		Transport:       string(transport),
		ActiveProtocol:  activeProtocolID(transport),
		GeneratedAt:     nowRFC3339(),
		RecommendedPath: activeProtocolID(transport),
		Entries:         buildProtocolPackWithFallbacks(transport, wireGuardPort, realityPort, vkRelayPort, stagedFallbacks),
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
