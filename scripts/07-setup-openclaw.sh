#!/usr/bin/env bash
# 07-setup-openclaw.sh - Create Mattermost bot credentials and deploy OpenClaw
#
# Secrets are stored in AWS Secrets Manager and synced into Kubernetes by ESO.
# Nothing sensitive is committed to git.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "07 - OpenClaw / KubeClaw Setup"
require_tool kubectl
require_tool curl
require_tool python3
require_tool aws
require_tool flux

AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_PREFIX="${SECRET_PREFIX:-mattermost-openclaw-setup}"
MM_ADMIN_EMAIL="${MM_ADMIN_EMAIL:-${LETSENCRYPT_EMAIL}}"
MM_BOT_CHANNELS="${MM_BOT_CHANNELS:-town-square}"
MM_BOT_DM_POLICY="${MM_BOT_DM_POLICY:-pairing}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-not-configured}"

missing=()
for var in MM_ADMIN_USERNAME MM_ADMIN_PASSWORD OPENCLAW_GATEWAY_TOKEN \
           GEMINI_API_KEY LITELLM_MASTER_KEY; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  log_error "Missing required variables in .env: ${missing[*]}"
  exit 1
fi
if [[ "${LITELLM_MASTER_KEY}" != sk-* ]]; then
  log_error "LITELLM_MASTER_KEY must start with sk-"
  exit 1
fi

put_secret() {
  local name="$1"
  local value="$2"
  local desc="$3"

  if aws secretsmanager describe-secret --secret-id "$name" \
    --region "$AWS_REGION" &>/dev/null; then
    aws secretsmanager put-secret-value \
      --secret-id "$name" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output text --query 'VersionId' > /dev/null
    log_ok "Updated: $name"
  else
    aws secretsmanager create-secret \
      --name "$name" \
      --description "$desc" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output text --query 'ARN' > /dev/null
    log_ok "Created: $name"
  fi
}

json_get() {
  local key="$1"
  python3 -c "import sys,json; print(json.load(sys.stdin).get('$key',''))" 2>/dev/null || true
}

log_step "Waiting for Mattermost to become Ready"
for i in $(seq 1 60); do
  READY=$(kubectl get pods -n mattermost -l app=mattermost \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$READY" == "True" ]] && { log_ok "Mattermost pod Ready"; break; }
  log_info "Waiting for Mattermost... attempt $i/60"
  sleep 10
done
[[ "${READY:-}" != "True" ]] && { log_error "Mattermost pod not Ready after 10 min"; exit 1; }

MM_PF_PID=""
cleanup() {
  [[ -n "${MM_PF_PID:-}" ]] && kill "$MM_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

log_step "Opening Mattermost API port-forward"
kubectl port-forward -n mattermost svc/mattermost 8065:8065 >/tmp/mm-openclaw-port-forward.log 2>&1 &
MM_PF_PID=$!
sleep 6
MM_API="http://localhost:8065"

log_step "Ensuring Mattermost admin exists"
LOGIN_RESP=$(curl -s -i -X POST "$MM_API/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"login_id\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" 2>/dev/null || true)
MM_TOKEN=$(echo "$LOGIN_RESP" | awk 'BEGIN{IGNORECASE=1} /^token:/ {print $2}' | tr -d '\r\n')

if [[ -z "$MM_TOKEN" ]]; then
  log_info "Admin login failed; trying first-user creation"
  FIRST_USER_RESP=$(curl -s -X POST "$MM_API/api/v4/users" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${MM_ADMIN_EMAIL}\",\"username\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" \
    2>/dev/null || true)
  FIRST_USER_ID=$(echo "$FIRST_USER_RESP" | json_get id)
  [[ -n "$FIRST_USER_ID" ]] && log_ok "Admin user created"

  LOGIN_RESP=$(curl -s -i -X POST "$MM_API/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" 2>/dev/null || true)
  MM_TOKEN=$(echo "$LOGIN_RESP" | awk 'BEGIN{IGNORECASE=1} /^token:/ {print $2}' | tr -d '\r\n')
fi

[[ -z "$MM_TOKEN" ]] && {
  log_error "Failed to authenticate with Mattermost API"
  echo "  Check MM_ADMIN_USERNAME/MM_ADMIN_PASSWORD in .env"
  exit 1
}
log_ok "Mattermost API authenticated"

ME_RESP=$(curl -s "$MM_API/api/v4/users/me" -H "Authorization: Bearer $MM_TOKEN")
ADMIN_USER_ID=$(echo "$ME_RESP" | json_get id)

log_step "Ensuring default team exists"
TEAMS_RESP=$(curl -s "$MM_API/api/v4/teams" -H "Authorization: Bearer $MM_TOKEN")
TEAM_ID=$(echo "$TEAMS_RESP" | python3 -c '
import sys,json
try:
    teams=json.load(sys.stdin)
    print(teams[0]["id"] if teams else "")
except Exception:
    print("")
' 2>/dev/null || true)

if [[ -z "$TEAM_ID" ]]; then
  CREATE_TEAM_RESP=$(curl -s -X POST "$MM_API/api/v4/teams" \
    -H "Authorization: Bearer $MM_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"main","display_name":"Main","type":"O"}' 2>/dev/null || true)
  TEAM_ID=$(echo "$CREATE_TEAM_RESP" | json_get id)
  [[ -n "$TEAM_ID" ]] && log_ok "Default team created"
fi

if [[ -n "$TEAM_ID" && -n "$ADMIN_USER_ID" ]]; then
  curl -s -X POST "$MM_API/api/v4/teams/${TEAM_ID}/members" \
    -H "Authorization: Bearer $MM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_ID}\",\"user_id\":\"${ADMIN_USER_ID}\"}" >/dev/null 2>&1 || true
fi

log_step "Ensuring openclaw-bot exists"
BOT_RESP=$(curl -s -X POST "$MM_API/api/v4/bots" \
  -H "Authorization: Bearer $MM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"openclaw-bot","display_name":"OpenClaw","description":"OpenClaw AI agent for Mattermost"}' \
  2>/dev/null || true)
BOT_USER_ID=$(echo "$BOT_RESP" | json_get user_id)

if [[ -z "$BOT_USER_ID" ]]; then
  BOTS=$(curl -s "$MM_API/api/v4/bots?include_deleted=false" \
    -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null || true)
  BOT_USER_ID=$(echo "$BOTS" | python3 -c '
import sys,json
try:
    for bot in json.load(sys.stdin):
        if bot.get("username") == "openclaw-bot":
            print(bot.get("user_id",""))
            break
except Exception:
    pass
' 2>/dev/null || true)
fi

[[ -z "$BOT_USER_ID" ]] && { log_error "Could not create or find openclaw-bot"; exit 1; }
log_ok "openclaw-bot user id: $BOT_USER_ID"

log_step "Creating Mattermost bot token"
TOKEN_RESP=$(curl -s -X POST "$MM_API/api/v4/users/${BOT_USER_ID}/tokens" \
  -H "Authorization: Bearer $MM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"description":"OpenClaw KubeClaw integration token"}' 2>/dev/null || true)
MATTERMOST_BOT_TOKEN=$(echo "$TOKEN_RESP" | json_get token)

[[ -z "$MATTERMOST_BOT_TOKEN" ]] && {
  log_error "Failed to create bot token. Confirm user access tokens are enabled."
  echo "  Response: $(echo "$TOKEN_RESP" | head -c 200)"
  exit 1
}
log_ok "Bot token created"

if [[ -n "$TEAM_ID" ]]; then
  log_step "Adding bot to configured channels"
  curl -s -X POST "$MM_API/api/v4/teams/${TEAM_ID}/members" \
    -H "Authorization: Bearer $MM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_ID}\",\"user_id\":\"${BOT_USER_ID}\"}" >/dev/null 2>&1 || true

  IFS=',' read -r -a CHANNEL_NAMES <<< "$MM_BOT_CHANNELS"
  for channel in "${CHANNEL_NAMES[@]}"; do
    CHAN_NAME="$(echo "$channel" | tr -d '[:space:]')"
    [[ -z "$CHAN_NAME" ]] && continue
    CHAN_RESP=$(curl -s "$MM_API/api/v4/teams/${TEAM_ID}/channels/name/${CHAN_NAME}" \
      -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null || true)
    CHAN_ID=$(echo "$CHAN_RESP" | json_get id)
    if [[ -z "$CHAN_ID" ]]; then
      log_warn "Channel '$CHAN_NAME' not found; skipping"
      continue
    fi
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$MM_API/api/v4/channels/${CHAN_ID}/members" \
      -H "Authorization: Bearer $MM_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"${BOT_USER_ID}\"}" 2>/dev/null || true)
    [[ "$HTTP" == "200" || "$HTTP" == "201" || "$HTTP" == "400" ]] && \
      log_ok "Bot present in #${CHAN_NAME}" || \
      log_warn "Could not add bot to #${CHAN_NAME} (HTTP $HTTP)"
  done
fi

cleanup
trap - EXIT

log_step "Writing OpenClaw secrets to AWS Secrets Manager"
put_secret "${SECRET_PREFIX}/openclaw-gateway-token" "$OPENCLAW_GATEWAY_TOKEN" "OpenClaw gateway bearer token"
put_secret "${SECRET_PREFIX}/anthropic-api-key" "$ANTHROPIC_API_KEY" "Anthropic API key for OpenClaw LiteLLM"
put_secret "${SECRET_PREFIX}/gemini-api-key" "$GEMINI_API_KEY" "Gemini API key for OpenClaw LiteLLM"
put_secret "${SECRET_PREFIX}/litellm-master-key" "$LITELLM_MASTER_KEY" "LiteLLM master key for OpenClaw"
put_secret "${SECRET_PREFIX}/mattermost-bot-token" "$MATTERMOST_BOT_TOKEN" "Mattermost bot token for OpenClaw"

log_step "Reconciling OpenClaw GitOps layer"
flux reconcile source git flux-system --timeout=2m 2>/dev/null || true
flux reconcile kustomization openclaw --with-source --timeout=2m 2>/dev/null || true

log_step "Waiting for kubeclaw-secret"
for i in $(seq 1 30); do
  kubectl get secret kubeclaw-secret -n kubeclaw &>/dev/null && { log_ok "kubeclaw-secret exists"; break; }
  log_info "Waiting for ESO sync... attempt $i/30"
  sleep 10
done

log_step "Waiting for KubeClaw HelmRelease"
for i in $(seq 1 60); do
  HR_READY=$(kubectl get helmrelease kubeclaw -n kubeclaw \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$HR_READY" == "True" ]] && { log_ok "KubeClaw HelmRelease Ready"; break; }
  log_info "Waiting for HelmRelease... attempt $i/60"
  sleep 10
done

log_step "Waiting for KubeClaw gateway pod"
for i in $(seq 1 60); do
  GW_READY=$(kubectl get pods -n kubeclaw -l app.kubernetes.io/name=kubeclaw \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$GW_READY" == "True" ]] && { log_ok "KubeClaw gateway Ready"; break; }
  log_info "Waiting for gateway... attempt $i/60"
  sleep 10
done

if [[ "${GW_READY:-}" == "True" ]]; then
  GW_POD=$(kubectl get pods -n kubeclaw -l app.kubernetes.io/name=kubeclaw \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  log_step "Installing bundled Mattermost plugin"
  kubectl exec -n kubeclaw "$GW_POD" -- \
    openclaw plugins install ./extensions/mattermost 2>/dev/null || true
  kubectl exec -n kubeclaw "$GW_POD" -- \
    openclaw gateway restart 2>/dev/null || true
fi

log_section "OpenClaw Setup Complete"
echo ""
echo "  OpenClaw URL : https://openclaw.${DOMAIN}/#token=${OPENCLAW_GATEWAY_TOKEN}"
echo "  DM policy    : ${MM_BOT_DM_POLICY}"
echo "  Channels     : ${MM_BOT_CHANNELS}"
echo ""
echo "  DNS reminder:"
echo "    openclaw.${DOMAIN} CNAME -> ${NLB_DNS_NAME}"
echo ""
echo "  Manage bot:"
echo "    bash scripts/08-manage-bot.sh"
echo ""
