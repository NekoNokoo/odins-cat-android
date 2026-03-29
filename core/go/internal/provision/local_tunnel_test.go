package provision

import "testing"

func TestParseVKRelayUnitPorts(t *testing.T) {
	unit := renderSystemdUnit(
		"Odin One vk-turn-proxy",
		"/opt/whitelist/bin/vk-turn-proxy-server -listen 0.0.0.0:56080 -connect 127.0.0.1:51820",
	)

	listenPort, connectPort := parseVKRelayUnitPorts(unit)
	if listenPort != 56080 {
		t.Fatalf("expected relay listen port 56080, got %d", listenPort)
	}
	if connectPort != 51820 {
		t.Fatalf("expected relay connect port 51820, got %d", connectPort)
	}
}

func TestBuildVKRelayRuntimeProfileFromDirectProfile(t *testing.T) {
	profile := ownerProfile{
		Name:           "Owner",
		Transport:      string(TransportXray),
		ActiveProtocol: string(ProtocolVLESSReality),
		ServerHost:     "example.com",
		EndpointPort:   51820,
		StagedFallbacks: map[string]any{
			"vlessReality": map[string]any{
				"port": 52443,
			},
		},
	}
	profile.WireGuard.ServerPublicKey = "server-public"
	profile.WireGuard.ClientPrivateKey = "client-private"
	profile.WireGuard.Address = "10.66.66.2/32"

	runtimeProfile, err := buildVKRelayRuntimeProfile(profile, 56080)
	if err != nil {
		t.Fatalf("expected runtime VK profile, got error %v", err)
	}

	if runtimeProfile.Transport != string(TransportVKTurnProxyXray) {
		t.Fatalf("expected VK transport, got %q", runtimeProfile.Transport)
	}
	if runtimeProfile.EndpointPort != 56080 {
		t.Fatalf("expected runtime endpoint port 56080, got %d", runtimeProfile.EndpointPort)
	}
	if runtimeProfile.VKTurnProxyPort != 56080 {
		t.Fatalf("expected runtime relay port 56080, got %d", runtimeProfile.VKTurnProxyPort)
	}
	if runtimeProfile.ActiveProtocol != "vk-turn-wireguard" {
		t.Fatalf("expected VK active protocol, got %q", runtimeProfile.ActiveProtocol)
	}
	activeFound := false
	for _, entry := range runtimeProfile.ProtocolPack {
		if entry.Status == ProtocolStatusActive {
			activeFound = true
			if entry.ID != "vk-turn-wireguard" || entry.Port != 56080 {
				t.Fatalf("expected active VK relay entry on 56080, got %+v", entry)
			}
		}
	}
	if !activeFound {
		t.Fatalf("expected protocol pack to contain an active entry, got %+v", runtimeProfile.ProtocolPack)
	}
}

func TestBuildVKRelayRuntimeProfileRejectsMissingWireGuard(t *testing.T) {
	_, err := buildVKRelayRuntimeProfile(ownerProfile{}, 56080)
	if err == nil {
		t.Fatal("expected missing WireGuard data to be rejected")
	}
}

func TestOwnerProfileMatchesVKRequestFromDirectDualStackProfile(t *testing.T) {
	profile := ownerProfile{
		Transport:       string(TransportXray),
		EndpointPort:    51820,
		VKTurnProxyPort: 56080,
	}
	profile.WireGuard.ServerPublicKey = "server-public"
	profile.WireGuard.ClientPrivateKey = "client-private"
	profile.WireGuard.Address = "10.66.66.2/32"

	if !ownerProfileMatchesRequest(profile, TransportVKTurnProxyXray) {
		t.Fatal("expected direct dual-stack owner profile to satisfy VK runtime request")
	}
	if !ownerProfileSupportsProtocol(profile, TransportVKTurnProxyXray, ProtocolDirectWireGuard) {
		t.Fatal("expected direct dual-stack owner profile to satisfy VK transport protocol requirements")
	}
}
