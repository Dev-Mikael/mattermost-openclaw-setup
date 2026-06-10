#!/usr/bin/env bash
# 05-create-secrets.sh — Writes secret values to AWS Secrets Manager
#
# Uses AWS Secrets Manager instead of encrypting secrets and committing them
# to git, values live only in AWS Secrets Manager. ESO (External Secrets
# Operator) syncs them into Kubernetes Secrets inside the cluster at runtime.
#
# Why this is better than Sealed Secrets:
#   - Secrets are NOT in git (even encrypted)
#   - Rotation: change the value in Secrets Manager, ESO syncs automatically
#   - Audit trail: CloudTrail logs every GetSecretValue call
#   - Survives cluster rebuilds — secrets persist in AWS
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "05 — Create Secrets in AWS Secrets Manager"
require_tool aws

AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_PREFIX="${SECRET_PREFIX:-mattermost-openclaw-setup}"

# Helper: create or update a secret value
put_secret() {
  local name="$1"
  local value="$2"
  local desc="$3"

  if aws secretsmanager describe-secret --secret-id "$name" \
    --region "$AWS_REGION" &>/dev/null; then
    # Secret exists — update value
    aws secretsmanager put-secret-value \
      --secret-id "$name" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output text --query 'VersionId' > /dev/null
    log_ok "Updated: $name"
  else
    # Secret does not exist — create it
    aws secretsmanager create-secret \
      --name "$name" \
      --description "$desc" \
      --secret-string "$value" \
      --region "$AWS_REGION" \
      --output text --query 'ARN' > /dev/null
    log_ok "Created: $name"
  fi
}

log_step "Writing database password to Secrets Manager"
[[ -z "${DB_PASSWORD:-}" ]] && {
  log_error "DB_PASSWORD is not set in .env"
  exit 1
}
put_secret \
  "${SECRET_PREFIX}/db-password" \
  "${DB_PASSWORD}" \
  "PostgreSQL password for Mattermost mmuser account"

log_step "Verifying secrets are readable"
TEST=$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_PREFIX}/db-password" \
  --region "$AWS_REGION" \
  --query 'SecretString' --output text 2>/dev/null || echo "")

[[ -z "$TEST" ]] && {
  log_error "Could not read back ${SECRET_PREFIX}/db-password. Check IAM permissions."
  exit 1
}
log_ok "Secret verified — ESO will sync this into the cluster automatically"

log_section "05 Complete"
echo "  Secrets Manager entries:"
echo "    ${SECRET_PREFIX}/db-password"
echo ""
echo "  ESO will create these Kubernetes Secrets from the above:"
echo "    cnpg-app-user-secret       (CNPG cluster bootstrap)"
echo "    mattermost-db-credentials  (Mattermost operator connection string)"
echo ""
echo "  Watch ESO sync: kubectl get externalsecrets -n mattermost -w"
