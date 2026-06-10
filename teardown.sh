#!/usr/bin/env bash
# teardown.sh — Destroys all cloud infrastructure cleanly
#
# Order matters:
#   1. Delete Flux resources first (stops Flux trying to reconcile as nodes disappear)
#   2. Terraform destroy (removes EC2, VPC, NLB, S3, IAM, Secrets Manager entries)
#
# NOTE: Secrets Manager entries have a recovery window. For staging (recovery_window=0)
# they are deleted immediately. For production (recovery_window=7) they enter a
# 7-day pending deletion period — you cannot recreate a secret with the same name
# during this window. Plan accordingly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
if [[ ! -f ".env" ]]; then
  echo "Missing .env; cannot determine environment."
  exit 1
fi
source ".env"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_section() { echo -e "\n${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

echo ""
echo -e "${BOLD}${RED}  ⚠  TEARDOWN: This will destroy all infrastructure for ${ENVIRONMENT:-production}${NC}"
echo ""
read -rp "  Type the environment name to confirm (${ENVIRONMENT:-production}): " CONFIRM

if [[ "$CONFIRM" != "${ENVIRONMENT:-production}" ]]; then
  echo "  Teardown cancelled."
  exit 0
fi

ENVIRONMENT="${ENVIRONMENT:-production}"
TF_DIR="$SCRIPT_DIR/terraform/environments/${ENVIRONMENT}"

# Step 1: Remove Flux from cluster (best-effort — cluster may already be gone)
log_section "Step 1 — Remove Flux GitOps resources"
if kubectl cluster-info &>/dev/null 2>&1; then
  log_warn "Suspending all Flux Kustomizations before destroying infra"
  flux suspend kustomization --all 2>/dev/null || true
  kubectl delete kustomization --all -n flux-system 2>/dev/null || true
  log_ok "Flux resources removed"
else
  log_warn "Cluster not reachable — skipping Flux cleanup"
fi

# Step 2: Terraform destroy
log_section "Step 2 — Terraform Destroy (${ENVIRONMENT})"
if [[ ! -d "$TF_DIR" ]]; then
  echo "  Terraform directory not found: $TF_DIR"
  exit 1
fi

terraform -chdir="$TF_DIR" destroy -auto-approve 2>&1
log_ok "All infrastructure destroyed"

# Step 3: Clean up local kubeconfig
log_section "Step 3 — Local cleanup"
if [[ -f "$HOME/.kube/config" ]]; then
  log_warn "Leaving ~/.kube/config in place."
  echo "  The destroyed cluster context may be stale, but other cluster contexts may live there too."
  echo "  Remove or edit it manually only when you are sure it is safe."
else
  log_ok "No local kubeconfig found"
fi

log_section "Teardown Complete"
echo ""
echo "  All EC2 instances, VPC, NLB, and IAM resources destroyed."
echo ""
echo "  Note: The S3 state bucket (terraform/state-backend/) is NOT destroyed."
echo "  It persists so you can re-provision with the same state file."
echo ""
echo "  Note: If environment=${ENVIRONMENT} production, the Secrets Manager entries"
echo "  have a 7-day deletion window. They cannot be recreated with the same name"
echo "  during this period."
echo ""
