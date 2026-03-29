package provision

import (
	"strings"
	"testing"
)

func TestGenerateGuestInviteRejectsLocalOwnerClone(t *testing.T) {
	resp := GenerateGuestInvite("example.com", "Friend Laptop")
	if resp.Error == "" {
		t.Fatal("expected local guest invite generation to be rejected")
	}
}

func TestValidateInviteAcceptsRealityInvite(t *testing.T) {
	invite := inviteProfile{
		Name:         "Friend Laptop",
		Protocol:     string(ProtocolVLESSReality),
		Transport:    string(TransportXray),
		ServerHost:   "example.com",
		EndpointPort: 443,
		Endpoint:     "example.com:443",
	}
	invite.VLESSReality.Port = 443
	invite.VLESSReality.ServerName = "www.cloudflare.com"
	invite.VLESSReality.PublicKey = "test-public-key"
	invite.VLESSReality.ShortID = "abcd1234"
	invite.VLESSReality.UUID = "11111111-1111-4111-8111-111111111111"
	invite.VLESSReality.Flow = "xtls-rprx-vision"

	if err := validateInvite(invite); err != nil {
		t.Fatalf("expected VLESS + REALITY invite to validate, got %v", err)
	}
}

func TestBuildInviteResponseMarksDualModeCapabilities(t *testing.T) {
	invite := inviteProfile{
		Name:            "Friend Laptop",
		Protocol:        string(ProtocolVLESSReality),
		Transport:       string(TransportXray),
		ServerHost:      "example.com",
		VKTurnProxyPort: 56080,
		WireGuardPort:   51820,
		EndpointPort:    52443,
		Endpoint:        "example.com:52443",
	}
	invite.WireGuard.ServerPublicKey = "server-public"
	invite.WireGuard.ClientPrivateKey = "client-private"
	invite.WireGuard.ClientPublicKey = "client-public"
	invite.WireGuard.Address = "10.66.66.3/32"
	invite.WireGuard.MTU = 1280
	invite.VLESSReality.Port = 52443
	invite.VLESSReality.ServerName = "www.cloudflare.com"
	invite.VLESSReality.PublicKey = "test-public-key"
	invite.VLESSReality.ShortID = "abcd1234"
	invite.VLESSReality.UUID = "11111111-1111-4111-8111-111111111111"
	invite.VLESSReality.Flow = "xtls-rprx-vision"

	resp := buildInviteResponse(invite, "")
	if !resp.SupportsReality {
		t.Fatal("expected response to report VLESS + REALITY support")
	}
	if !resp.SupportsVKRelay {
		t.Fatal("expected response to report VK relay support")
	}
	if resp.WireGuardPort != 51820 {
		t.Fatalf("expected wireguard port 51820, got %d", resp.WireGuardPort)
	}
}

func TestInviteMatchesTransportAllowsDualModeVKRequest(t *testing.T) {
	invite := inviteProfile{
		Transport:       string(TransportXray),
		VKTurnProxyPort: 56080,
		WireGuardPort:   51820,
	}
	invite.WireGuard.ServerPublicKey = "server-public"
	invite.WireGuard.ClientPrivateKey = "client-private"
	invite.WireGuard.ClientPublicKey = "client-public"

	if !inviteMatchesTransport(invite, string(TransportVKTurnProxyXray)) {
		t.Fatal("expected dual-mode xray invite to satisfy VK transport lookup")
	}
}

func TestRenderXrayConfigWithListenIncludesAllRealityClients(t *testing.T) {
	config := renderXrayConfigWithListen(
		"test-secret",
		[]xrayWireGuardPeer{
			{
				PublicKey:  "wg-owner",
				AllowedIPs: []string{"10.66.66.2/32"},
			},
		},
		"0.0.0.0",
		51820,
		&xrayRealityInbound{
			Port:       443,
			Clients:    []xrayRealityClient{{UUID: "owner-uuid", Flow: "xtls-rprx-vision"}, {UUID: "guest-uuid", Flow: "xtls-rprx-vision"}},
			PrivateKey: "reality-private",
			ShortID:    "abcd1234",
			ServerName: "www.cloudflare.com",
			Dest:       "www.cloudflare.com:443",
		},
	)

	if !strings.Contains(config, `"id": "owner-uuid"`) {
		t.Fatal("expected owner reality client to be rendered")
	}
	if !strings.Contains(config, `"id": "guest-uuid"`) {
		t.Fatal("expected guest reality client to be rendered")
	}
}
