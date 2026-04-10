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

func TestDecodeInviteSyncsYandexEdgeProxyFallbackToGuestReality(t *testing.T) {
	raw := `{
  "id": "guest-009",
  "role": "guest",
  "name": "Odin's Cat Owner Node",
  "protocol": "vless-reality",
  "transport": "xray",
  "serverHost": "95.81.120.226",
  "endpointPort": 55555,
  "endpoint": "95.81.120.226:55555",
  "fingerprint": "482471d931882079",
  "status": "active",
  "vlessReality": {
    "port": 55555,
    "serverName": "www.cloudflare.com",
    "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
    "shortId": "ba81780391343b01",
    "uuid": "b707d399-3f96-4df9-8daa-8b7b2ea23650",
    "flow": "xtls-rprx-vision"
  },
  "stagedFallbacks": {
    "vlessReality": {
      "port": 55555,
      "serverName": "www.cloudflare.com",
      "publicKey": "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo",
      "shortId": "ba81780391343b01",
      "uuid": "7e56811d-4815-474a-a2a2-9cb869aeae5b",
      "flow": "xtls-rprx-vision"
    },
    "realityRelayOwnerEgress": {
      "ownerEgressPort": 52443
    },
    "realityYandexEdgeProxy": {
      "connectHost": "62.84.123.148",
      "connectPort": 10443,
      "originHost": "95.81.120.226",
      "originPort": 55555,
      "serverName": "www.cloudflare.com",
      "publicKey": "stale-public",
      "shortId": "stale-short",
      "uuid": "stale-uuid",
      "flow": "xtls-rprx-vision",
      "routingMode": "xray-proxy",
      "ownerRealityEgress": true
    }
  }
}`

	invite, _, err := decodeInvite(raw)
	if err != nil {
		t.Fatalf("decode invite: %v", err)
	}

	proxyRaw, ok := invite.StagedFallbacks["realityYandexEdgeProxy"]
	if !ok {
		t.Fatal("expected invite to preserve yandex edge proxy fallback")
	}
	proxy, ok := proxyRaw.(map[string]any)
	if !ok {
		t.Fatalf("expected proxy fallback object, got %#v", proxyRaw)
	}
	if proxy["uuid"] != "b707d399-3f96-4df9-8daa-8b7b2ea23650" {
		t.Fatalf("expected proxy uuid to sync to guest reality uuid, got %#v", proxy["uuid"])
	}
	if proxy["publicKey"] != "EhIONikEgvX3cReHEHzo1fGwZVXI27XOIt6In4YGgDo" {
		t.Fatalf("expected proxy public key to sync to guest reality key, got %#v", proxy["publicKey"])
	}
	if proxy["originHost"] != "95.81.120.226" {
		t.Fatalf("expected proxy origin host to stay populated, got %#v", proxy["originHost"])
	}
	if proxy["ownerRealityEgress"] != false {
		t.Fatalf("expected proxy fallback to disable owner reality egress, got %#v", proxy["ownerRealityEgress"])
	}

	ownerRelayRaw, ok := invite.StagedFallbacks["realityRelayOwnerEgress"]
	if !ok {
		t.Fatal("expected owner relay fallback to remain present")
	}
	ownerRelay, ok := ownerRelayRaw.(map[string]any)
	if !ok {
		t.Fatalf("expected owner relay fallback object, got %#v", ownerRelayRaw)
	}
	if ownerRelay["ownerEgressPort"] != float64(55555) && ownerRelay["ownerEgressPort"] != 55555 {
		t.Fatalf("expected owner relay egress port to sync to active reality port, got %#v", ownerRelay["ownerEgressPort"])
	}
}
