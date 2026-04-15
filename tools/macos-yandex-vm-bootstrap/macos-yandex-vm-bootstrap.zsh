#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
CAT_BIN="/bin/cat"
PRINTF_BIN="/usr/bin/printf"
SED_BIN="/usr/bin/sed"
CP_BIN="/bin/cp"
CHMOD_BIN="/bin/chmod"
SSH_BIN="${SSH_BIN:-$(command -v ssh || true)}"
SSH_KEYGEN_BIN="${SSH_KEYGEN_BIN:-$(command -v ssh-keygen || true)}"
SSH_KEYSCAN_BIN="${SSH_KEYSCAN_BIN:-$(command -v ssh-keyscan || true)}"
PBCOPY_BIN="${PBCOPY_BIN:-$(command -v pbcopy || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

DEFAULT_KEY_PATH="${HOME}/.ssh/odin_one_yandex_vm"
OUTPUT_DIR=""
KEY_PATH="$DEFAULT_KEY_PATH"
KEY_COMMENT="odin-one-yandex-vm"
COPY_PUBLIC_KEY="0"
VM_HOST=""
VM_USER=""
VM_PORT="22"
CHECK_VM_SSH="0"

usage() {
  cat <<'EOF'
Usage:
  tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh <command> [options]

Commands:
  ensure-local-key     Create or reuse a local SSH keypair for Yandex VM onboarding.
  build-vm-handoff     Build a ready-to-use SSH handoff bundle for a created VM.
  full                 Run ensure-local-key and then build-vm-handoff in one go.

Common options:
  --output-dir <dir>   Output directory. Default: /tmp/odin-one-macos-yandex-vm-bootstrap/<stamp>
  --key-path <path>    SSH private key path. Default: ~/.ssh/odin_one_yandex_vm
  --copy-public-key    Copy the public key to macOS clipboard.

VM handoff options:
  --vm-host <host>     VM external IPv4 or hostname.
  --vm-user <user>     SSH username for the VM.
  --vm-port <port>     SSH port. Default: 22
  --check-vm-ssh       Probe SSH connectivity and save host key scan output.

Examples:
  tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh ensure-local-key --copy-public-key

  tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh build-vm-handoff \
    --vm-host 62.84.123.148 \
    --vm-user flatron109 \
    --key-path ~/.ssh/odin_one_yandex_vm \
    --check-vm-ssh

  tools/macos-yandex-vm-bootstrap/macos-yandex-vm-bootstrap.zsh full \
    --vm-host 62.84.123.148 \
    --vm-user flatron109 \
    --copy-public-key \
    --check-vm-ssh
EOF
}

require_bin() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" || ! -x "$path" ]]; then
    echo "${label} not found" >&2
    exit 1
  fi
}

ensure_output_dir() {
  if [[ -z "$OUTPUT_DIR" ]]; then
    local stamp
    stamp="$("$DATE_BIN" -u '+%Y%m%d-%H%M%S')"
    OUTPUT_DIR="/tmp/odin-one-macos-yandex-vm-bootstrap/${stamp}"
  fi
  "$MKDIR_BIN" -p "$OUTPUT_DIR"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --key-path)
        KEY_PATH="$2"
        shift 2
        ;;
      --copy-public-key)
        COPY_PUBLIC_KEY="1"
        shift
        ;;
      --vm-host)
        VM_HOST="$2"
        shift 2
        ;;
      --vm-user)
        VM_USER="$2"
        shift 2
        ;;
      --vm-port)
        VM_PORT="$2"
        shift 2
        ;;
      --check-vm-ssh)
        CHECK_VM_SSH="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

key_dir() {
  dirname "$KEY_PATH"
}

ensure_local_key() {
  require_bin "$SSH_KEYGEN_BIN" "ssh-keygen"
  ensure_output_dir
  "$MKDIR_BIN" -p "$(key_dir)"

  if [[ ! -f "$KEY_PATH" ]]; then
    "$SSH_KEYGEN_BIN" -t ed25519 -a 64 -N "" -C "$KEY_COMMENT" -f "$KEY_PATH" >/dev/null
  fi

  if [[ ! -f "${KEY_PATH}.pub" ]]; then
    echo "public key missing next to ${KEY_PATH}" >&2
    exit 1
  fi

  local fingerprint
  fingerprint="$("$SSH_KEYGEN_BIN" -lf "$KEY_PATH" | awk '{print $2}')"

  "$CP_BIN" "$KEY_PATH" "${OUTPUT_DIR}/odin-one-yandex-vm.key"
  "$CP_BIN" "${KEY_PATH}.pub" "${OUTPUT_DIR}/odin-one-yandex-vm.pub"
  "$CP_BIN" "${KEY_PATH}.pub" "${OUTPUT_DIR}/yandex-cloud-public-key.txt"

  local public_key
  public_key="$("$CAT_BIN" "${KEY_PATH}.pub")"

  cat > "${OUTPUT_DIR}/yandex-cloud-metadata-line.txt" <<EOF
${VM_USER:-odin}:${public_key}
EOF

  cat > "${OUTPUT_DIR}/yandex-cloud-user-data.yaml" <<EOF
#cloud-config
datasource:
  Ec2:
    strict_id: false
ssh_pwauth: no
users:
  - name: ${VM_USER:-odin}
    groups: sudo
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    ssh_authorized_keys:
      - ${public_key}
EOF

  if [[ "$COPY_PUBLIC_KEY" == "1" && -n "$PBCOPY_BIN" ]]; then
    "$CAT_BIN" "${KEY_PATH}.pub" | "$PBCOPY_BIN"
  fi

  cat > "${OUTPUT_DIR}/local-key-summary.txt" <<EOF
SSH key ready for Yandex VM onboarding.

Private key:
${KEY_PATH}

Public key:
${KEY_PATH}.pub

Fingerprint:
${fingerprint}

Yandex Cloud public key file:
${OUTPUT_DIR}/yandex-cloud-public-key.txt

Yandex Cloud metadata line:
${OUTPUT_DIR}/yandex-cloud-metadata-line.txt

Cloud-init user-data template:
${OUTPUT_DIR}/yandex-cloud-user-data.yaml
EOF

  echo "Prepared local SSH key bundle in ${OUTPUT_DIR}"
}

build_vm_handoff() {
  require_bin "$SSH_BIN" "ssh"
  require_bin "$SSH_KEYGEN_BIN" "ssh-keygen"
  require_bin "$PYTHON_BIN" "python3"
  ensure_output_dir

  if [[ -z "$VM_HOST" || -z "$VM_USER" ]]; then
    echo "--vm-host and --vm-user are required for build-vm-handoff" >&2
    exit 1
  fi
  if [[ ! -f "$KEY_PATH" || ! -f "${KEY_PATH}.pub" ]]; then
    echo "SSH keypair not found at ${KEY_PATH}; run ensure-local-key first" >&2
    exit 1
  fi

  local host_scan_file ssh_check_file
  host_scan_file="${OUTPUT_DIR}/vm-hostkey-scan.txt"
  ssh_check_file="${OUTPUT_DIR}/vm-ssh-check.txt"

  if [[ "$CHECK_VM_SSH" == "1" ]]; then
    require_bin "$SSH_KEYSCAN_BIN" "ssh-keyscan"
    "$SSH_KEYSCAN_BIN" -p "$VM_PORT" -T 5 "$VM_HOST" >"$host_scan_file" 2>/dev/null || true
    if "$SSH_BIN" -i "$KEY_PATH" -p "$VM_PORT" -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=8 "${VM_USER}@${VM_HOST}" "whoami && uname -a" >"$ssh_check_file" 2>&1; then
      :
    else
      echo "SSH connectivity check failed; inspect ${ssh_check_file}" >&2
    fi
  fi

  python3 - "$KEY_PATH" "${KEY_PATH}.pub" "$VM_HOST" "$VM_USER" "$VM_PORT" "${OUTPUT_DIR}" <<'PY'
import json
import pathlib
import sys

key_path = pathlib.Path(sys.argv[1]).expanduser()
pub_path = pathlib.Path(sys.argv[2]).expanduser()
vm_host = sys.argv[3]
vm_user = sys.argv[4]
vm_port = int(sys.argv[5])
out_dir = pathlib.Path(sys.argv[6])

private_key = key_path.read_text()
public_key = pub_path.read_text().strip()

handoff = {
    "kind": "odin-one-macos-vm-ssh-handoff",
    "createdAtUtc": __import__("datetime").datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "vm": {
        "host": vm_host,
        "port": vm_port,
        "username": vm_user,
        "authMethod": "private-key",
    },
    "localKey": {
        "privateKeyPath": str(key_path),
        "publicKeyPath": str(pub_path),
        "publicKey": public_key,
    },
    "secret": private_key,
    "provisionRequestTemplate": {
        "server": {
            "host": vm_host,
            "port": vm_port,
            "username": vm_user,
            "authMethod": "private-key",
            "transport": "xray",
            "engine": "xray",
            "protocol": "vless-reality",
        },
        "secret": private_key,
        "flow": "origin",
    },
}

(out_dir / "vm-ssh-handoff.json").write_text(json.dumps(handoff, ensure_ascii=False, indent=2) + "\n")
PY

  cat > "${OUTPUT_DIR}/ssh-into-vm.sh" <<EOF
#!/bin/zsh
exec ssh -i "${KEY_PATH}" -p "${VM_PORT}" -o StrictHostKeyChecking=accept-new "${VM_USER}@${VM_HOST}"
EOF
  "$CHMOD_BIN" +x "${OUTPUT_DIR}/ssh-into-vm.sh"

  cat > "${OUTPUT_DIR}/app-deploy-notes.txt" <<EOF
Use these values in the Android app / deploy flow when SSH access is requested:

Host: ${VM_HOST}
Port: ${VM_PORT}
Username: ${VM_USER}
Auth method: private-key
Private key path on this Mac: ${KEY_PATH}

Ready-made handoff JSON:
${OUTPUT_DIR}/vm-ssh-handoff.json
EOF

  echo "Prepared VM SSH handoff bundle in ${OUTPUT_DIR}"
}

main() {
  [[ $# -ge 1 ]] || { usage >&2; exit 1; }
  local command="$1"
  shift
  parse_args "$@"

  case "$command" in
    ensure-local-key)
      ensure_local_key
      ;;
    build-vm-handoff)
      build_vm_handoff
      ;;
    full)
      ensure_local_key
      build_vm_handoff
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
