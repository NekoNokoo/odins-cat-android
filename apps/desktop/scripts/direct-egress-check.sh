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
ENGINE_MODE="${1:-both}"
PROTOCOL_MODE="${2:-${ODIN_ONE_PROTOCOL_MODE:-direct-wireguard}}"
TEST_URL="${ODIN_ONE_TEST_URL:-https://example.com}"
MVPD_LOG="${ODIN_ONE_TEST_LOG:-/tmp/odin-one-egress-check.log}"
MVPD_CMD=()

if [[ ! -x "$CURL_BIN" ]]; then
  echo "curl binary not found at $CURL_BIN" >&2
  exit 1
fi

if [[ ! -x "$JQ_BIN" ]]; then
  echo "jq binary not found at $JQ_BIN" >&2
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "python binary not found at $PYTHON_BIN" >&2
  exit 1
fi

if [[ "$ENGINE_MODE" != "both" && "$ENGINE_MODE" != "xray" && "$ENGINE_MODE" != "sing-box" ]]; then
  echo "Usage: $0 [both|xray|sing-box] [direct-wireguard|vless-reality]" >&2
  exit 1
fi

if [[ "$PROTOCOL_MODE" != "direct-wireguard" && "$PROTOCOL_MODE" != "vless-reality" ]]; then
  echo "Usage: $0 [both|xray|sing-box] [direct-wireguard|vless-reality]" >&2
  exit 1
fi

if [[ -z "${ODIN_ONE_SSH_SECRET:-}" ]]; then
  read -s "?SSH password for ${USER_NAME}@${HOST}: " ODIN_ONE_SSH_SECRET
  echo
fi

if [[ -z "${ODIN_ONE_SSH_SECRET}" ]]; then
  echo "SSH secret is required" >&2
  exit 1
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

poll_deploy() {
  local deployment_id="$1"
  local resp=""
  echo "Polling deploy ${deployment_id}..." >&2
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
  return 1
}

poll_tunnel() {
  local resp=""
  echo "Polling local tunnel..." >&2
  for _ in {1..60}; do
    resp="$(get_json "/api/local-tunnel/status")"
    local tunnel_state
    tunnel_state="$(printf '%s' "$resp" | "$JQ_BIN" -r '.status // empty')"
    echo "  tunnel status: ${tunnel_state}" >&2
    if [[ "$tunnel_state" == "running" || "$tunnel_state" == "failed" ]]; then
      printf '%s' "$resp"
      return 0
    fi
    sleep 1
  done
  printf '%s' "$resp"
  return 1
}

validate_remote() {
  local engine="$1"
  local payload
  payload="$("$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    --arg engine "$engine" \
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
    }')"

  post_json "/api/provision/validate" "$payload"
}

deploy_remote() {
  local engine="$1"
  local payload
  payload="$("$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    --arg engine "$engine" \
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
    }')"

  post_json "/api/provision/deploy" "$payload"
}

start_tunnel() {
  local engine="$1"
  local payload
  payload="$("$JQ_BIN" -n \
    --arg host "$HOST" \
    --arg user "$USER_NAME" \
    --argjson port "$SSH_PORT" \
    --arg secret "$ODIN_ONE_SSH_SECRET" \
    --arg engine "$engine" \
    --arg protocol "$PROTOCOL_MODE" \
    --arg url "$TEST_URL" \
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
    }')"

  post_json "/api/local-tunnel/start" "$payload"
}

run_explicit_test() {
  local payload
  payload="$("$JQ_BIN" -n --arg url "$TEST_URL" '{url: $url}')"
  post_json "/api/local-tunnel/test" "$payload"
}

print_summary() {
  local engine="$1"
  local validate_resp="$2"
  local deploy_resp="$3"
  local tunnel_resp="$4"
  local test_resp="$5"

  echo
  echo "=== ${engine} ==="
  echo "protocol: ${PROTOCOL_MODE}"
  echo "validate.ok: $(printf '%s' "$validate_resp" | "$JQ_BIN" -r '.ok')"
  echo "deploy.status: $(printf '%s' "$deploy_resp" | "$JQ_BIN" -r '.status')"
  echo "remote egress: $(printf '%s' "$deploy_resp" | "$JQ_BIN" -r '[.healthChecks[]? | select(.ok == false)] | if length == 0 then "passed" else "failed" end')"
  echo "tunnel.status: $(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.status')"
  echo "tunnel.protocol: $(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.protocol // "none"')"
  echo "local auto-test: $(printf '%s' "$tunnel_resp" | "$JQ_BIN" -r '.lastTest.status // "none"')"
  echo "explicit test: $(printf '%s' "$test_resp" | "$JQ_BIN" -r '.lastTest.status // "none"')"
  echo "local error: $(printf '%s' "$test_resp" | "$JQ_BIN" -r '.lastTest.error // .error // ""')"
  echo
  printf '%s' "$deploy_resp" | "$JQ_BIN" '{deploymentId, status, healthChecks}'
  echo
  printf '%s' "$test_resp" | "$JQ_BIN" '{status, engine, socksAddress, lastTest}'
  echo
}

run_engine() {
  local engine="$1"

  step "Running isolated direct check for engine=${engine}, protocol=${PROTOCOL_MODE}, host=${HOST}"
  local validate_resp
  step "Step 1/4: validate"
  validate_resp="$(normalize_json "$(validate_remote "$engine")")"

  if [[ "$(printf '%s' "$validate_resp" | "$JQ_BIN" -r '.ok')" != "true" ]]; then
    echo "Validation failed for ${engine}" >&2
    printf '%s\n' "$validate_resp" | "$JQ_BIN" .
    return 1
  fi

  local deploy_start
  step "Step 2/4: deploy"
  deploy_start="$(normalize_json "$(deploy_remote "$engine")")"
  local deployment_id
  deployment_id="$(printf '%s' "$deploy_start" | "$JQ_BIN" -r '.deploymentId')"
  local deploy_resp
  deploy_resp="$(normalize_json "$(poll_deploy "$deployment_id")")"

  if [[ "$(printf '%s' "$deploy_resp" | "$JQ_BIN" -r '.status')" != "done" ]]; then
    echo "Deploy failed for ${engine}" >&2
    printf '%s\n' "$deploy_resp" | "$JQ_BIN" .
    return 1
  fi

  step "Step 3/4: start local tunnel"
  "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
  start_tunnel "$engine" >/dev/null
  local tunnel_resp
  tunnel_resp="$(normalize_json "$(poll_tunnel)")"
  local test_resp
  step "Step 4/4: explicit HTTPS test"
  test_resp="$(normalize_json "$(run_explicit_test)")"

  print_summary "$engine" "$validate_resp" "$deploy_resp" "$tunnel_resp" "$test_resp"
  "$CURL_BIN" -s -X POST "${API_BASE}/api/local-tunnel/stop" >/dev/null 2>&1 || true
}

step "Disable your system VPN before trusting these results."
start_mvpd
step "Using isolated localhost API: ${API_BASE}"

case "$ENGINE_MODE" in
  xray)
    run_engine "xray"
    ;;
  sing-box)
    run_engine "sing-box"
    ;;
  both)
    run_engine "xray"
    run_engine "sing-box"
    ;;
esac
