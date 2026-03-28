#!/bin/zsh
set -euo pipefail

HOST="${ODIN_ONE_HOST:-95.81.120.226}"
SSH_PORT="${ODIN_ONE_SSH_PORT:-22}"
UDP_PORT="${ODIN_ONE_UDP_PORT:-51820}"
TCP_TIMEOUT="${ODIN_ONE_TCP_TIMEOUT:-5}"
UDP_TIMEOUT="${ODIN_ONE_UDP_TIMEOUT:-5}"

ROUTE_BIN="/sbin/route"
SCUTIL_BIN="/usr/sbin/scutil"
NETSTAT_BIN="/usr/sbin/netstat"
IFCONFIG_BIN="/sbin/ifconfig"
NC_BIN="/usr/bin/nc"
DATE_BIN="/bin/date"
AWK_BIN="/usr/bin/awk"
SED_BIN="/usr/bin/sed"
GREP_BIN="/usr/bin/grep"

section() {
  echo
  echo "=== $1 ==="
}

note() {
  echo "$1"
}

route_output="$("$ROUTE_BIN" -n get "$HOST" 2>&1 || true)"
nwi_output="$("$SCUTIL_BIN" --nwi 2>&1 || true)"
netstat_output="$("$NETSTAT_BIN" -rn -f inet 2>&1 || true)"

section "Direct Path Diagnostics"
note "Started: $("$DATE_BIN" '+%Y-%m-%d %H:%M:%S %Z')"
note "Host: ${HOST}"
note "SSH port: ${SSH_PORT}"
note "UDP port: ${UDP_PORT}"

section "Route"
printf '%s\n' "$route_output"

interface_name="$(printf '%s\n' "$route_output" | "$AWK_BIN" '/interface:/ {print $2; exit}')"
gateway_name="$(printf '%s\n' "$route_output" | "$AWK_BIN" '/gateway:/ {print $2; exit}')"

section "Network Reachability"
printf '%s\n' "$nwi_output"

section "Route Summary"
if [[ -n "$interface_name" ]]; then
  note "Resolved interface: ${interface_name}"
else
  note "Resolved interface: unknown"
fi
if [[ -n "$gateway_name" ]]; then
  note "Resolved gateway: ${gateway_name}"
fi
if [[ "$interface_name" == utun* ]]; then
  note "Assessment: traffic to ${HOST} is currently routed through a VPN utun interface."
elif [[ -n "$interface_name" ]]; then
  note "Assessment: traffic to ${HOST} is currently routed through ${interface_name}."
fi

section "Default Route Table Snapshot"
printf '%s\n' "$netstat_output" | "$SED_BIN" -n '1,25p'

if [[ -n "$interface_name" ]]; then
  section "Interface Snapshot (${interface_name})"
  "$IFCONFIG_BIN" "$interface_name" 2>&1 || true
fi

section "TCP Reachability"
tcp_output="$("$NC_BIN" -G "$TCP_TIMEOUT" -vz "$HOST" "$SSH_PORT" 2>&1 || true)"
printf '%s\n' "$tcp_output"
if printf '%s\n' "$tcp_output" | "$GREP_BIN" -qi "succeeded"; then
  note "Assessment: TCP ${SSH_PORT} is reachable."
else
  note "Assessment: TCP ${SSH_PORT} did not confirm reachability."
fi

section "UDP Hint"
udp_output="$("$NC_BIN" -w "$UDP_TIMEOUT" -vz -u "$HOST" "$UDP_PORT" 2>&1 || true)"
printf '%s\n' "$udp_output"
if printf '%s\n' "$udp_output" | "$GREP_BIN" -qi "succeeded"; then
  note "Assessment: UDP ${UDP_PORT} returned a positive hint."
else
  note "Assessment: UDP ${UDP_PORT} gave no positive confirmation."
  note "Note: UDP silence is inconclusive by itself and can still happen on a working path."
fi

section "What To Compare"
note "1. Run this script with VPN off and note interface/gateway plus UDP hint."
note "2. Run it again with VPN on and compare whether the route switches to utun."
note "3. If VPN off stays on en0 but direct tunnel still times out, the weak point is likely UDP path behavior between your local network and ${HOST}:${UDP_PORT}."
