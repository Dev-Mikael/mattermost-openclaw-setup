#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for all bootstrap scripts

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
log_section() { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

require_tool() {
  if ! command -v "$1" &>/dev/null; then
    log_error "Required tool '$1' not found. Run scripts/01-install-tools.sh first."
    exit 1
  fi
}

# Update or add a key=value in .env
update_env() {
  local key="$1"
  local value="$2"
  local envfile="${3:-.env}"
  if grep -q "^${key}=" "$envfile" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$envfile"
    rm -f "${envfile}.bak"
  else
    echo "${key}=${value}" >> "$envfile"
  fi
}

# Load and validate .env file
load_env() {
  local envfile="${1:-.env}"
  if [[ ! -f "$envfile" ]]; then
    log_error "Missing $envfile — copy .env.example to .env and fill in values."
    exit 1
  fi
  set -a; source "$envfile"; set +a

  local missing=()
  for var in GITHUB_USER GITHUB_TOKEN GITHUB_REPO GITHUB_BRANCH \
             CLUSTER_NAME ENVIRONMENT DOMAIN LETSENCRYPT_EMAIL \
             DB_PASSWORD; do
    [[ -z "${!var:-}" ]] && missing+=("$var")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required variables in $envfile: ${missing[*]}"
    exit 1
  fi
}

# Wait for SSH to become available on a remote host
wait_for_ssh() {
  local host="$1"
  local key="$2"
  local user="${3:-ubuntu}"
  local max_attempts="${4:-30}"
  local SSH_OPTS="-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30"
  log_info "Waiting for SSH on ${host} (up to $((max_attempts * 10))s)..."
  for i in $(seq 1 "$max_attempts"); do
    if ssh $SSH_OPTS "${user}@${host}" "echo ok" &>/dev/null; then
      log_ok "SSH ready on ${host}"
      return 0
    fi
    log_info "  attempt ${i}/${max_attempts} — retrying in 10s..."
    sleep 10
  done
  log_error "SSH not available on ${host} after $((max_attempts * 10))s"
  exit 1
}

# Run a script on a remote host via SSH, streaming output locally
remote_exec() {
  local host="$1"
  local key="$2"
  local user="$3"
  local script_path="$4"   # local path to the script
  local remote_path="${5:-/tmp/$(basename $script_path)}"
  local SSH_OPTS="-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 -o BatchMode=yes"

  scp $SSH_OPTS "$script_path" "${user}@${host}:${remote_path}" 2>/dev/null
  ssh $SSH_OPTS -tt "${user}@${host}" "sudo bash ${remote_path}" || {
    log_error "Remote execution failed on ${host}. Check the output above."
    exit 1
  }
}
