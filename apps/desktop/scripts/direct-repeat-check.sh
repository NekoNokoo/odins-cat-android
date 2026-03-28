#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
GO_BIN="/Users/vladislav/.local/opt/go/bin/go"
APP_MVPD_BIN="/Applications/Odin One.app/Contents/Resources/bin/mvpd"
WORKSPACE_MVPD_BIN="${ODIN_ONE_LOCAL_MVPD_BIN:-/tmp/odin-one-mvpd-workspace}"
CURL_BIN="/usr/bin/curl"
JQ_BIN="/usr/bin/jq"
PYTHON_BIN="/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"
MVPD_PORT="${ODIN_ONE_TEST_CORE_PORT:-}"
API_BASE=""
HOST="${ODIN_ONE_HOST:-95.81.120.226}"
USER_NAME="${ODIN_ONE_USER:-root}"
SSH_PORT="${ODIN_ONE_SSH_PORT:-22}"
ENGINE="${1:-xray}"
PROTOCOL_MODE="${2:-${ODIN_ONE_PROTOCOL_MODE:-direct-wireguard}}"
ATTEMPTS="${ODIN_ONE_REPEAT_ATTEMPTS:-5}"
TEST_URL="${ODIN_ONE_TEST_URL:-https://example.com}"
MVPD_LOG="${ODIN_ONE_REPEAT_LOG:-/tmp/odin-one-repeat-check.log}"
MVPD_CMD=()

if [[ "$ENGINE" != "xray" && "$ENGINE" != "sing-box" ]]; then
  echo "Usage: $0 [xray|sing-box] [direct-wireguard|vless-reality]" >&2
  exit 1
fi

if [[ "$PROTOCOL_MODE" != "direct-wireguard" && "$PROTOCOL_MODE" != "vless-reality" ]]; then
  echo "Usage: $0 [xray|sing-box] [direct-wireguard|vless-reality]" >&2
  exit 1
fi

if [[ ! -x "$CURL_BIN" || ! -x "$JQ_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "Required binaries are missing" >&2
  exit 1
fi

if [[ -z "${ODIN_ONE_SSH_SECRET:-}" ]]; then
  read -s "?SSH password for ${USER_NAME}@${HOST}: " ODIN_ONE_SSH_SECRET
  echo
fi

MVPD_PID=""

cleanup() {
  "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
  if [[ -n "$MVPD_PID" ]]; then
    kill "$MVPD_PID" >/dev/null 2>&1 || true
    wait "$MVPD_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

step() {
  echo "[$(/bin/date '+%H:%M:%S')] $1"
}

ensure_mvpd_command() {
  if [[ "$PROTOCOL_MODE" == "vless-reality" && "${ODIN_ONE_FORCE_WORKSPACE_MVPD:-0}" != "0" ]]; then
    :
  elif [[ "$PROTOCOL_MODE" != "vless-reality" && "${ODIN_ONE_FORCE_WORKSPACE_MVPD:-0}" != "1" && -x "$APP_MVPD_BIN" ]]; then
    step "Using app-bundled mvpd"
    MVPD_CMD=("$APP_MVPD_BIN")
    return 0
  fi

  if [[ -x "$GO_BIN" ]]; then
    if [[ "$PROTOCOL_MODE" == "vless-reality" ]]; then
      step "Using workspace mvpd because protocol=${PROTOCOL_MODE} requires fresh repo code"
    fi
    step "Building workspace mvpd binary"
    (
      cd "$ROOT_DIR/core/go"
      "$GO_BIN" build -buildvcs=false -o "$WORKSPACE_MVPD_BIN" ./cmd/mvpd
    ) >/tmp/odin-one-mvpd-build.log 2>&1 || {
      echo "Failed to build workspace mvpd binary" >&2
      sed -n '1,160p' /tmp/odin-one-mvpd-build.log >&2 || true
      exit 1
    }
    step "Using workspace mvpd binary"
    MVPD_CMD=("$WORKSPACE_MVPD_BIN")
    return 0
  fi

  echo "Neither workspace Go toolchain nor app mvpd is available" >&2
  exit 1
}

normalize_json() {
  printf '%s\n' "$1" | awk 'BEGIN{found=0} { if (found || $0 ~ /^[[:space:]]*[{[]/) { found=1; print } }'
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

start_mvpd() {
  step "Preparing isolated localhost core"
  ensure_mvpd_command
  choose_port
  API_BASE="http://127.0.0.1:${MVPD_PORT}"
  step "Starting mvpd on ${API_BASE}"
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

poll_deploy_done() {
  local deployment_id="$1"
  local resp=""
  for _ in {1..90}; do
    resp="$(get_json "/api/provision/deploy/${deployment_id}")"
    local deploy_state
    deploy_state="$(printf '%s' "$resp" | "$JQ_BIN" -r '.status // empty')"
    echo "  deploy status: ${deploy_state}" >&2
    if [[ "$deploy_state" == "done" || "$deploy_state" == "failed" ]]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 2
  done
  printf '%s' "$resp"
}

poll_tunnel_state() {
  local resp=""
  for _ in {1..60}; do
    resp="$(get_json "/api/local-tunnel/status")"
    local tunnel_state
    tunnel_state="$(printf '%s' "$resp" | "$JQ_BIN" -r '.status // empty')"
    if [[ "$tunnel_state" == "running" || "$tunnel_state" == "failed" ]]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 1
  done
  printf '%s' "$resp"
}

payload_for() {
  "$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    --arg engine "$ENGINE" \
    --arg protocol "$PROTOCOL_MODE" \
    '{
      server: {
        host: $host,
        port: $port,
        username: $user,
        authMethod: "password",
        transport: "xray",
        engine: $engine,
        protocol: $protocol
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
    --arg engine "$ENGINE" \
    --arg protocol "$PROTOCOL_MODE" \
    '{
      server: {
        host: $host,
        port: $port,
        username: $user,
        authMethod: "password",
        transport: "xray",
        engine: $engine,
        protocol: $protocol
      },
      secret: $secret,
      vkLink: ""
    }'
}

test_payload() {
  "$JQ_BIN" -n --arg url "$TEST_URL" '{url: $url}'
}

section() {
  echo
  echo "=== $1 ==="
}

step "Disable system VPN before trusting these results."
start_mvpd

section "Repeat Direct Check"
echo "Engine: ${ENGINE}"
echo "Protocol: ${PROTOCOL_MODE}"
echo "Attempts: ${ATTEMPTS}"
echo "Target URL: ${TEST_URL}"
echo "API base: ${API_BASE}"

section "Deploy"
step "Deploying server state for protocol=${PROTOCOL_MODE}"
deploy_start="$(normalize_json "$(post_json "/api/provision/deploy" "$(payload_for)")")"
deployment_id="$(printf '%s' "$deploy_start" | "$JQ_BIN" -r '.deploymentId')"
deploy_done="$(normalize_json "$(poll_deploy_done "$deployment_id")")"
printf '%s\n' "$deploy_done" | "$JQ_BIN" '{deploymentId, status, healthChecks}'

pass_count=0
fail_count=0

section "Attempts"
for attempt in $(seq 1 "$ATTEMPTS"); do
  echo
  echo "--- Attempt ${attempt}/${ATTEMPTS} ---"
  step "Starting attempt ${attempt}/${ATTEMPTS}"
  "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true

  start_resp="$(normalize_json "$(post_json "/api/local-tunnel/start" "$(start_payload)")")"
  echo "start: $(printf '%s' "$start_resp" | "$JQ_BIN" -r '.status')"

  tunnel_resp="$(normalize_json "$(poll_tunnel_state)")"
  echo "tunnel: $(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.status')"
  echo "protocol: $(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.protocol // "none"')"

  test_resp="$(normalize_json "$(post_json "/api/local-tunnel/test" "$(test_payload)")")"
  test_status="$(printf '%s' "$test_resp" | "$JQ_BIN" -r '.lastTest.status // "none"')"
  test_error="$(printf '%s' "$test_resp" | "$JQ_BIN" -r '.lastTest.error // .error // ""')"
  echo "explicit test: ${test_status}"
  if [[ -n "$test_error" ]]; then
    echo "error: ${test_error}"
  fi

  if [[ "$test_status" == "passed" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi

  "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
  sleep 1
done

section "Summary"
echo "passed: ${pass_count}"
echo "failed: ${fail_count}"
if [[ "$pass_count" -gt 0 && "$fail_count" -gt 0 ]]; then
  echo "assessment: flapping direct path"
elif [[ "$pass_count" -eq 0 ]]; then
  echo "assessment: consistently failing direct path"
else
  echo "assessment: consistently healthy direct path"
fi
