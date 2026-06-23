package provision

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRenderHysteria2ServerConfigUsesPinnedRuntimeShape(t *testing.T) {
	raw, err := renderHysteria2ServerConfig(8443, map[string]string{
		"owner":     "owner-secret",
		"guest-001": "guest-secret",
	}, "obfs-secret")
	if err != nil {
		t.Fatalf("render config: %v", err)
	}

	var config map[string]any
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if !strings.Contains(raw, `"type": "hysteria2"`) {
		t.Fatalf("expected hysteria2 inbound: %s", raw)
	}
	if !strings.Contains(raw, `"listen_port": 8443`) {
		t.Fatalf("expected UDP 8443 listener: %s", raw)
	}
	if !strings.Contains(raw, `"type": "salamander"`) {
		t.Fatalf("expected Salamander obfuscation: %s", raw)
	}
	if !strings.Contains(raw, `"guest-001"`) {
		t.Fatalf("expected guest-specific user: %s", raw)
	}
}

func TestHysteria2FallbackIsReadyAndExposedInProtocolPack(t *testing.T) {
	fallbacks := map[string]any{}
	upsertHysteria2Fallback(fallbacks, "203.0.113.10", "owner-secret", "obfs-secret", "pin")

	entries := buildProtocolPackWithFallbacks(TransportXray, 51820, 52443, 56080, fallbacks)
	for _, entry := range entries {
		if entry.ID == "hysteria2" {
			if entry.Status != ProtocolStatusActive || entry.Port != 8443 {
				t.Fatalf("unexpected Hysteria 2 entry: %#v", entry)
			}
			return
		}
	}
	t.Fatal("Hysteria 2 entry is missing")
}
