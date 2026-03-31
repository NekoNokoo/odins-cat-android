#!/bin/zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/desktop/scripts/android-reality-profile-preset.sh list
  apps/desktop/scripts/android-reality-profile-preset.sh <preset>

Presets:
  baseline
  boot-restore
  dot-google
  doh-cloudflare
  network-reload
  leak-balanced
  leak-tight
  per-app-captive-bypass
EOF
}

emit_json() {
  cat
}

preset="${1:-}"

case "$preset" in
  ""|"-h"|"--help")
    usage
    ;;
  "list")
    cat <<'EOF'
baseline
boot-restore
dot-google
doh-cloudflare
network-reload
leak-balanced
leak-tight
per-app-captive-bypass
EOF
    ;;
  "baseline")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable"
    }
  }
}
EOF
    ;;
  "boot-restore")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "autoRestoreOnBoot": true
    }
  }
}
EOF
    ;;
  "dot-google")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "dot",
      "dnsServer": "8.8.8.8",
      "dnsServerName": "dns.google",
      "dnsStrategy": "prefer_ipv4"
    }
  }
}
EOF
    ;;
  "doh-cloudflare")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "doh",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsDohPath": "/dns-query",
      "dnsStrategy": "prefer_ipv4"
    }
  }
}
EOF
    ;;
  "network-reload")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": false,
      "allowPrivateNetworkBypass": true,
      "networkReloadOnChange": true,
      "networkReloadDebounceMs": 1500,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "leak-balanced")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": true,
      "allowPrivateNetworkBypass": false,
      "privateBypassCidrs": [
        "10.0.0.0/8",
        "192.168.0.0/16",
        "169.254.0.0/16"
      ],
      "networkReloadOnChange": false,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "leak-tight")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "stable",
      "dnsMode": "udp",
      "dnsServer": "1.1.1.1",
      "dnsServerName": "cloudflare-dns.com",
      "dnsStrategy": "prefer_ipv4",
      "strictRoute": true,
      "allowPrivateNetworkBypass": false,
      "networkReloadOnChange": false,
      "includePackages": [],
      "excludePackages": [],
      "tlsFragment": false,
      "recordFragment": false
    }
  }
}
EOF
    ;;
  "per-app-captive-bypass")
    emit_json <<'EOF'
{
  "androidRuntime": {
    "reality": {
      "mode": "experimental",
      "excludePackages": [
        "com.android.captiveportallogin"
      ]
    }
  }
}
EOF
    ;;
  *)
    echo "Unknown preset: $preset" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
