package provision

import (
	"encoding/json"
	"testing"
)

func TestBuildProtocolPackForDirectIncludesVKRelayFallback(t *testing.T) {
	entries := buildProtocolPack(TransportXray, 51820, 52443, 56080)

	var realityEntry *ProtocolPackEntry
	var vkEntry *ProtocolPackEntry
	for index := range entries {
		switch entries[index].ID {
		case "vless-reality":
			realityEntry = &entries[index]
		case "vk-turn-wireguard":
			vkEntry = &entries[index]
		}
	}

	if realityEntry == nil || realityEntry.Status != ProtocolStatusActive || realityEntry.Port != 52443 {
		t.Fatalf("expected active VLESS + REALITY entry on 52443, got %+v", entries)
	}
	if vkEntry == nil || vkEntry.Status != ProtocolStatusStaged || vkEntry.Port != 56080 {
		t.Fatalf("expected staged VK relay entry on 56080, got %+v", entries)
	}
}

func TestRenderAccessProfileIncludesVKRelayPortForDirectDeploy(t *testing.T) {
	raw, err := renderAccessProfile(
		"owner",
		"owner",
		"Odin One Owner Node",
		"example.com",
		TransportXray,
		51820,
		51820,
		56080,
		"server-public",
		"client-private",
		"client-public",
		"10.66.66.2/32",
		map[string]any{
			"vlessReality": map[string]any{
				"port": 52443,
			},
		},
	)
	if err != nil {
		t.Fatalf("render access profile: %v", err)
	}

	var profile ownerProfile
	if err := json.Unmarshal([]byte(raw), &profile); err != nil {
		t.Fatalf("unmarshal access profile: %v", err)
	}
	if profile.Transport != string(TransportXray) {
		t.Fatalf("expected direct owner profile transport, got %q", profile.Transport)
	}
	if profile.VKTurnProxyPort != 56080 {
		t.Fatalf("expected VK relay port 56080, got %d", profile.VKTurnProxyPort)
	}
	if profile.AndroidRuntime != nil {
		t.Fatalf("expected no owner androidRuntime before yandex edge is attached, got %#v", profile.AndroidRuntime)
	}
}

func TestRenderAccessProfileIncludesYandexCamoRuntimeWhenEdgeFallbackPresent(t *testing.T) {
	raw, err := renderAccessProfile(
		"owner",
		"owner",
		"Odin One Owner Node",
		"95.81.120.226",
		TransportXray,
		51820,
		51820,
		56080,
		"server-public",
		"client-private",
		"client-public",
		"10.66.66.2/32",
		map[string]any{
			"vlessReality": map[string]any{
				"port": 55555,
			},
			"realityYandexEdgeProxy": map[string]any{
				"connectHost": "62.84.123.148",
				"connectPort": 12443,
			},
		},
	)
	if err != nil {
		t.Fatalf("render access profile: %v", err)
	}

	var profile ownerProfile
	if err := json.Unmarshal([]byte(raw), &profile); err != nil {
		t.Fatalf("unmarshal access profile: %v", err)
	}
	cdn, ok := profile.AndroidRuntime["cdnAntiWhitelist"].(map[string]any)
	if !ok {
		t.Fatalf("expected owner profile androidRuntime.cdnAntiWhitelist, got %#v", profile.AndroidRuntime)
	}
	if cdn["tlsServerName"] != "ya.ru" {
		t.Fatalf("expected owner profile ya.ru camouflage runtime, got %#v", cdn["tlsServerName"])
	}
}
