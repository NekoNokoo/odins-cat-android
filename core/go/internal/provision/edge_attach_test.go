package provision

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRenderYandexEdgeManifestIncludesRoutingMode(t *testing.T) {
	layout := buildYandexEdgeRuntimeLayout(10443, EdgeRoutingModeSNIRouter)
	text, err := renderYandexEdgeManifest(
		"62.84.123.148",
		10443,
		"95.81.120.226",
		55555,
		"www.cloudflare.com",
		"public",
		"short",
		"uuid",
		"xtls-rprx-vision",
		EdgeRoutingModeSNIRouter,
		layout,
	)
	if err != nil {
		t.Fatalf("render manifest: %v", err)
	}
	if !strings.Contains(text, `"routingMode": "sni-router"`) {
		t.Fatalf("manifest should carry routing mode, got %s", text)
	}
	if !strings.Contains(text, `"routes"`) {
		t.Fatalf("manifest should carry routes, got %s", text)
	}
	if !strings.Contains(text, `"serviceName": "whitelist-yandex-edge-sni-router-10443.service"`) {
		t.Fatalf("manifest should carry scoped service metadata, got %s", text)
	}
}

func TestRenderYandexEdgeHAProxyConfigUsesSNIACL(t *testing.T) {
	text := renderYandexEdgeHAProxyConfig(
		"0.0.0.0",
		443,
		"www.cloudflare.com",
		"95.81.120.226",
		55555,
	)
	if !strings.Contains(text, "req.ssl_sni -i www.cloudflare.com") {
		t.Fatalf("haproxy config should route by SNI, got %s", text)
	}
	if !strings.Contains(text, "server route 95.81.120.226:55555 check") {
		t.Fatalf("haproxy config should point to origin, got %s", text)
	}
}

func TestBuildYandexEdgeRuntimeLayoutKeepsLegacy443Path(t *testing.T) {
	layout := buildYandexEdgeRuntimeLayout(443, EdgeRoutingModeTCPForward)
	if layout.rootDir != "/opt/whitelist-edge" {
		t.Fatalf("legacy root dir should stay stable, got %s", layout.rootDir)
	}
	if layout.serviceName != "whitelist-yandex-edge.service" {
		t.Fatalf("legacy service name should stay stable, got %s", layout.serviceName)
	}
}

func TestBuildYandexEdgeRuntimeLayoutScopesNonDefaultPort(t *testing.T) {
	layout := buildYandexEdgeRuntimeLayout(10443, EdgeRoutingModeSNIRouter)
	if layout.rootDir != "/opt/whitelist-edge-sni-router-10443" {
		t.Fatalf("non-default root dir should be scoped, got %s", layout.rootDir)
	}
	if layout.serviceName != "whitelist-yandex-edge-sni-router-10443.service" {
		t.Fatalf("non-default service name should be scoped, got %s", layout.serviceName)
	}
}

func TestPatchOwnerProfileWithYandexEdgeProxyUsesDedicatedEdgeReality(t *testing.T) {
	rawProfile := `{
  "name": "Owner",
  "transport": "xray",
  "serverHost": "95.81.120.226",
  "vkTurnProxyPort": 56080,
  "endpointPort": 51820,
  "stagedFallbacks": {
    "vlessReality": {
      "port": 55555,
      "serverName": "www.cloudflare.com",
      "publicKey": "origin-public",
      "shortId": "origin-short",
      "uuid": "origin-uuid",
      "flow": "xtls-rprx-vision"
    }
  }
}`

	patched, protocolPack, err := patchOwnerProfileWithYandexEdge(
		rawProfile,
		"62.84.123.148",
		10443,
		"95.81.120.226",
		realityFallback{
			Port:       55555,
			ServerName: "www.cloudflare.com",
			PublicKey:  "origin-public",
			ShortID:    "origin-short",
			UUID:       "origin-uuid",
			Flow:       "xtls-rprx-vision",
		},
		EdgeRoutingModeXrayProxy,
		&realityFallback{
			Port:       10443,
			ServerName: "www.cloudflare.com",
			PublicKey:  "edge-public",
			ShortID:    "edge-short",
			UUID:       "edge-uuid",
			Flow:       "xtls-rprx-vision",
		},
	)
	if err != nil {
		t.Fatalf("patch owner profile: %v", err)
	}

	var profile ownerProfile
	if err := json.Unmarshal([]byte(patched), &profile); err != nil {
		t.Fatalf("unmarshal patched owner profile: %v", err)
	}

	proxyRaw, ok := profile.StagedFallbacks["realityYandexEdgeProxy"]
	if !ok {
		t.Fatalf("patched owner profile should include yandex edge proxy fallback: %s", patched)
	}
	proxy, ok := proxyRaw.(map[string]any)
	if !ok {
		t.Fatalf("yandex edge proxy fallback should be an object, got %#v", proxyRaw)
	}
	if proxy["connectPort"] != float64(10443) && proxy["connectPort"] != 10443 {
		t.Fatalf("proxy fallback should use edge port 10443, got %#v", proxy["connectPort"])
	}
	if proxy["publicKey"] != "edge-public" {
		t.Fatalf("proxy fallback should use edge public key, got %#v", proxy["publicKey"])
	}
	if proxy["uuid"] != "edge-uuid" {
		t.Fatalf("proxy fallback should use edge uuid, got %#v", proxy["uuid"])
	}
	if proxy["routingMode"] != string(EdgeRoutingModeXrayProxy) {
		t.Fatalf("proxy fallback should keep xray-proxy routing mode, got %#v", proxy["routingMode"])
	}
	if proxy["ownerRealityEgress"] != false {
		t.Fatalf("proxy fallback should disable owner reality egress, got %#v", proxy["ownerRealityEgress"])
	}
	cdnRaw, ok := profile.AndroidRuntime["cdnAntiWhitelist"]
	if !ok {
		t.Fatalf("patched owner profile should include yandex camo runtime: %s", patched)
	}
	cdn, ok := cdnRaw.(map[string]any)
	if !ok {
		t.Fatalf("patched owner profile cdn runtime should be an object, got %#v", cdnRaw)
	}
	if cdn["tlsServerName"] != "ya.ru" {
		t.Fatalf("patched owner profile should use ya.ru camouflage runtime, got %#v", cdn["tlsServerName"])
	}
	if cdn["connectHost"] != "62.84.123.148" {
		t.Fatalf("patched owner profile should target yandex edge host, got %#v", cdn["connectHost"])
	}
	if cdn["connectPort"] != float64(443) && cdn["connectPort"] != 443 {
		t.Fatalf("patched owner profile should expose xhttp connect port 443, got %#v", cdn["connectPort"])
	}

	foundProtocolPack := false
	for _, entry := range protocolPack {
		if entry.ID == "vless-reality-yandex-edge-proxy" && entry.Port == 10443 {
			foundProtocolPack = true
			break
		}
	}
	if !foundProtocolPack {
		t.Fatalf("protocol pack should include yandex edge proxy entry, got %+v", protocolPack)
	}
}
