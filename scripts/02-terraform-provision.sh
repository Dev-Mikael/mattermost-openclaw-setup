#!/usr/bin/env bash
# 02-terraform-provision.sh — runs terraform apply and writes outputs to .env
# After this script runs, .env contains all IPs, key paths, bucket names, and
# NLB DNS needed by the subsequent kubeadm and Flux scripts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

ENVIRONMENT="${ENVIRONMENT:-production}"
TF_DIR="$ROOT_DIR/terraform/environments/${ENVIRONMENT}"

log_section "02 — Terraform: Provision Infrastructure (${ENVIRONMENT})"
require_tool terraform
require_tool jq
require_tool aws

# Verify AWS credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
  log_error "AWS credentials not configured. Run: aws configure"
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_ok "AWS authenticated — account: ${ACCOUNT_ID}"

if [[ ! -d "$TF_DIR" ]]; then
  log_error "Terraform environment directory not found: $TF_DIR"
  exit 1
fi

# ── Validate backend.tf has been configured ───────────────────────────────────
if grep -q "REPLACE-WITH-YOUR-STATE-BUCKET-NAME" "$TF_DIR/backend.tf"; then
  log_error "You must edit terraform/environments/${ENVIRONMENT}/backend.tf"
  echo ""
  echo "  1. First run the state backend setup (once per AWS account):"
  echo "     cd terraform/state-backend && terraform init && terraform apply"
  echo "  2. Copy the output bucket name into backend.tf"
  echo "  3. Re-run bootstrap.sh"
  exit 1
fi

if grep -q "REPLACE-WITH-UNIQUE-SUFFIX" "$TF_DIR/terraform.tfvars"; then
  log_error "Set bucket_suffix in terraform/environments/${ENVIRONMENT}/terraform.tfvars"
  echo "  Use your AWS account ID: ${ACCOUNT_ID}"
  exit 1
fi

log_step "terraform init"
terraform -chdir="$TF_DIR" init -upgrade 2>&1 | tail -5

log_step "terraform plan"
terraform -chdir="$TF_DIR" plan -out=/tmp/tfplan 2>&1

log_step "terraform apply"
terraform -chdir="$TF_DIR" apply /tmp/tfplan 2>&1
rm -f /tmp/tfplan

log_step "Reading Terraform outputs → .env"
OUTPUTS=$(terraform -chdir="$TF_DIR" output -json)
SSH_KEY_OUTPUT="$(echo "$OUTPUTS" | jq -r '.ssh_key_path.value')"
if [[ "$SSH_KEY_OUTPUT" != /* ]]; then
  SSH_KEY_OUTPUT="$TF_DIR/${SSH_KEY_OUTPUT#./}"
fi

update_env "CP_PUBLIC_IP"      "$(echo "$OUTPUTS" | jq -r '.control_plane_public_ip.value')"  "$ROOT_DIR/.env"
update_env "CP_PRIVATE_IP"     "$(echo "$OUTPUTS" | jq -r '.control_plane_private_ip.value')" "$ROOT_DIR/.env"
update_env "WORKER1_PUBLIC_IP" "$(echo "$OUTPUTS" | jq -r '.worker_public_ips.value[0]')"     "$ROOT_DIR/.env"
update_env "WORKER2_PUBLIC_IP" "$(echo "$OUTPUTS" | jq -r '.worker_public_ips.value[1]')"     "$ROOT_DIR/.env"
update_env "WORKER1_PRIVATE_IP" "$(echo "$OUTPUTS" | jq -r '.worker_private_ips.value[0]')"  "$ROOT_DIR/.env"
update_env "WORKER2_PRIVATE_IP" "$(echo "$OUTPUTS" | jq -r '.worker_private_ips.value[1]')"  "$ROOT_DIR/.env"
update_env "WORKER_PUBLIC_IPS"  "$(echo "$OUTPUTS" | jq -r '.worker_public_ips.value | join(",")')"  "$ROOT_DIR/.env"
update_env "WORKER_PRIVATE_IPS" "$(echo "$OUTPUTS" | jq -r '.worker_private_ips.value | join(",")')" "$ROOT_DIR/.env"
update_env "SSH_KEY_PATH"      "$SSH_KEY_OUTPUT"                                               "$ROOT_DIR/.env"
update_env "NLB_DNS_NAME"      "$(echo "$OUTPUTS" | jq -r '.nlb_dns_name.value')"             "$ROOT_DIR/.env"
update_env "S3_BUCKET_NAME"    "$(echo "$OUTPUTS" | jq -r '.s3_bucket_name.value')"           "$ROOT_DIR/.env"

# Re-source so subsequent scripts in bootstrap.sh pick up the new values
set -a; source "$ROOT_DIR/.env"; set +a

log_ok "Terraform outputs written to .env"

log_section "02 Complete"
echo "  Control plane : ${CP_PUBLIC_IP}"
echo "  Workers       : ${WORKER1_PUBLIC_IP}, ${WORKER2_PUBLIC_IP}"
echo "  NLB DNS       : ${NLB_DNS_NAME}"
echo "  SSH key       : ${SSH_KEY_PATH}"
echo ""
echo "  ACTION REQUIRED: Point your domain CNAME to the NLB:"
echo "    ${DOMAIN}  CNAME  →  ${NLB_DNS_NAME}"
echo ""
echo "  On Cloudflare: Add CNAME record, enable Proxy (orange cloud) for DDoS protection."
echo "  Or use a plain CNAME if you want direct NLB connection."
