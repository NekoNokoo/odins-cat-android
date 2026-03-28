#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
GO_BIN="/Users/vladislav/.local/opt/go/bin/go"
FALLBACK_MVPD_BIN="$ROOT_DIR/apps/desktop/src-tauri/bin/mvpd"
WORKSPACE_MVPD_BIN="${ODIN_ONE_LOCAL_MVPD_BIN:-/tmp/odin-one-vk-mvpd-reality}"
CURL_BIN="/usr/bin/curl"
JQ_BIN="/usr/bin/jq"
PYTHON_BIN="/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"

HOST="${ODIN_ONE_HOST:-95.81.120.226}"
USER_NAME="${ODIN_ONE_USER:-root}"
SSH_PORT="${ODIN_ONE_SSH_PORT:-22}"
TEST_URL="${ODIN_ONE_TEST_URL:-https://example.com}"
IP_CHECK_URL="${ODIN_ONE_IP_CHECK_URL:-https://api.ipify.org?format=json}"
MVPD_LOG="${ODIN_ONE_REALITY_LOG:-/tmp/odin-one-reality-console-check.log}"
MVPD_PORT="${ODIN_ONE_TEST_CORE_PORT:-}"

API_BASE=""
MVPD_PID=""
MVPD_CMD=()

step() {
  echo "[$(/bin/date '+%H:%M:%S')] $1"
}

require_bin() {
  local path="$1"
  local label="$2"
  if [[ ! -x "$path" ]]; then
    echo "${label} not found at ${path}" >&2
    exit 1
  fi
}

require_bin "$CURL_BIN" "curl"
require_bin "$JQ_BIN" "jq"
require_bin "$PYTHON_BIN" "python3"

if [[ -z "${ODIN_ONE_SSH_SECRET:-}" ]]; then
  read -s "?SSH password for ${USER_NAME}@${HOST}: " ODIN_ONE_SSH_SECRET
  echo
fi

if [[ -z "${ODIN_ONE_SSH_SECRET}" ]]; then
  echo "SSH secret is required" >&2
  exit 1
fi

cleanup() {
  if [[ -n "$API_BASE" ]]; then
    "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MVPD_PID" ]]; then
    kill "$MVPD_PID" >/dev/null 2>&1 || true
    wait "$MVPD_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

choose_port() {
  if [[ -n "$MVPD_PORT" ]]; then
    return 0
  fi
  MVPD_PORT="$("$PYTHON_BIN" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
}

ensure_mvpd_command() {
  if [[ -x "$GO_BIN" ]]; then
    step "Building workspace mvpd for fresh REALITY runtime"
    (
      cd "$ROOT_DIR/core/go"
      "$GO_BIN" build -buildvcs=false -o "$WORKSPACE_MVPD_BIN" ./cmd/mvpd
    ) >/tmp/odin-one-reality-mvpd-build.log 2>&1 || {
      echo "Failed to build workspace mvpd binary" >&2
      sed -n '1,160p' /tmp/odin-one-reality-mvpd-build.log >&2 || true
      exit 1
    }
    MVPD_CMD=("$WORKSPACE_MVPD_BIN")
    return 0
  fi

  if [[ -x "$FALLBACK_MVPD_BIN" ]]; then
    step "Using repo-bundled mvpd fallback"
    MVPD_CMD=("$FALLBACK_MVPD_BIN")
    return 0
  fi

  echo "No usable mvpd binary found" >&2
  exit 1
}

start_mvpd() {
  choose_port
  ensure_mvpd_command
  API_BASE="http://127.0.0.1:${MVPD_PORT}"
  step "Starting isolated mvpd on ${API_BASE}"
  (
    cd "$ROOT_DIR/core/go"
    MVPD_ADDR="127.0.0.1:${MVPD_PORT}" "${MVPD_CMD[@]}"
  ) >"$MVPD_LOG" 2>&1 &
  MVPD_PID=$!

  for _ in {1..240}; do
    if "$CURL_BIN" -sf "${API_BASE}/healthz" >/dev/null 2>&1; then
      step "mvpd is healthy"
      return 0
    fi
    if ! kill -0 "$MVPD_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done

  echo "Failed to start mvpd on ${API_BASE}" >&2
  if [[ -f "$MVPD_LOG" ]]; then
    echo "--- mvpd log ---" >&2
    sed -n '1,160p' "$MVPD_LOG" >&2 || true
  fi
  exit 1
}

post_json() {
  local path="$1"
  local payload="$2"
  "$CURL_BIN" -sS -X POST "${API_BASE}${path}" -H 'Content-Type: application/json' -d "$payload"
}

get_json() {
  local path="$1"
  "$CURL_BIN" -sS "${API_BASE}${path}"
}

normalize_json() {
  printf '%s\n' "$1" | awk 'BEGIN{found=0} { if (found || $0 ~ /^[[:space:]]*[{[]/) { found=1; print } }'
}

payload_base() {
  "$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    '{
      server: {
        host: $host,
        port: $port,
        username: $user,
        authMethod: "password",
        transport: "xray",
        engine: "xray",
        protocol: "vless-reality"
      },
      secret: $secret
    }'
}

start_payload() {
  "$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    '{
      server: {
        host: $host,
        port: $port,
        username: $user,
        authMethod: "password",
        transport: "xray",
        engine: "xray",
        protocol: "vless-reality"
      },
      secret: $secret,
      vkLink: ""
    }'
}

test_payload() {
  "$JQ_BIN" -n --arg url "$TEST_URL" '{url: $url}'
}

poll_deploy_done() {
  local deployment_id="$1"
  local resp=""
  for _ in {1..90}; do
    resp="$(get_json "/api/provision/deploy/${deployment_id}")"
    local state
    state="$(printf '%s' "$resp" | "$JQ_BIN" -r '.status // empty')"
    echo "  deploy status: ${state}" >&2
    if [[ "$state" == "done" || "$state" == "failed" ]]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 2
  done
  printf '%s' "$resp"
}

poll_tunnel() {
  local resp=""
  for _ in {1..60}; do
    resp="$(get_json "/api/local-tunnel/status")"
    local state
    state="$(printf '%s' "$resp" | "$JQ_BIN" -r '.status // empty')"
    echo "  tunnel status: ${state}" >&2
    if [[ "$state" == "running" || "$state" == "failed" ]]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 1
  done
  printf '%s' "$resp"
}

section() {
  echo
  echo "=== $1 ==="
}

direct_ip() {
  "$CURL_BIN" -sS --max-time 15 "$IP_CHECK_URL" || true
}

tunneled_ip() {
  local socks="$1"
  "$CURL_BIN" -sS --socks5-hostname "$socks" --max-time 20 "$IP_CHECK_URL" || true
}

step "Disable your system VPN before trusting these results."
start_mvpd
step "Using isolated localhost API: ${API_BASE}"

section "Validate"
validate_resp="$(normalize_json "$(post_json "/api/provision/validate" "$(payload_base)")")"
printf '%s\n' "$validate_resp" | "$JQ_BIN" '{ok, checks, warnings, error}'
if [[ "$(printf '%s' "$validate_resp" | "$JQ_BIN" -r '.ok')" != "true" ]]; then
  echo "Validation failed" >&2
  exit 1
fi

section "Deploy"
deploy_start="$(normalize_json "$(post_json "/api/provision/deploy" "$(payload_base)")")"
deployment_id="$(printf '%s' "$deploy_start" | "$JQ_BIN" -r '.deploymentId')"
deploy_done="$(normalize_json "$(poll_deploy_done "$deployment_id")")"
printf '%s\n' "$deploy_done" | "$JQ_BIN" '{deploymentId, status, protocol, healthChecks, error}'
if [[ "$(printf '%s' "$deploy_done" | "$JQ_BIN" -r '.status')" != "done" ]]; then
  echo "Deploy failed" >&2
  exit 1
fi

section "Start Tunnel"
"$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
start_resp="$(normalize_json "$(post_json "/api/local-tunnel/start" "$(start_payload)")")"
printf '%s\n' "$start_resp" | "$JQ_BIN" '{status, engine, protocol, error}'
tunnel_resp="$(normalize_json "$(poll_tunnel)")"
printf '%s\n' "$tunnel_resp" | "$JQ_BIN" '{status, engine, protocol, socksAddress, lastTest, error}'

socks_address="$(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.socksAddress // empty')"
if [[ -z "$socks_address" ]]; then
  echo "Tunnel did not provide a SOCKS address" >&2
  exit 1
fi

section "HTTPS Test"
test_resp="$(normalize_json "$(post_json "/api/local-tunnel/test" "$(test_payload)")")"
printf '%s\n' "$test_resp" | "$JQ_BIN" '{status, engine, protocol, socksAddress, lastTest, error}'

section "IP Check"
echo "Direct IP:"
direct_ip
echo
echo "Tunnel IP via ${socks_address}:"
tunneled_ip "$socks_address"
echo
echo
echo "Manual curl through tunnel:"
echo "curl --socks5-hostname ${socks_address} -I ${TEST_URL}"
echo "curl --socks5-hostname ${socks_address} '${IP_CHECK_URL}'"
