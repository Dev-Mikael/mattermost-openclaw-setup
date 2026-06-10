#!/usr/bin/env bash
# bootstrap.sh — Single command to deploy Mattermost end-to-end
#
# What this does, in order:
#   01. Install local tools (kubectl, helm, flux, terraform, jq, awscli)
#   02. Terraform: provision VPC, EC2 nodes, NLB, S3, IAM, Secrets Manager
#   03. kubeadm: install Kubernetes on all nodes (multi-node, SSH automated)
#   04. FluxCD: bootstrap GitOps — Flux watches the repo and reconciles everything
#   05. Secrets: push DB password to AWS Secrets Manager (ESO syncs into cluster)
#   06. Verify: check all components, DNS, TLS, and NLB reachability
#   07. OpenClaw: create Mattermost bot token and deploy KubeClaw
#
# Prerequisites:
#   1. cp .env.example .env && nano .env   (fill in all values)
#   2. Run: aws configure                  (set up AWS credentials once)
#   3. Set up state backend (once per AWS account):
#      cd terraform/state-backend && terraform init && terraform apply
#      Then update terraform/environments/*/backend.tf with the bucket name.
#   4. bash bootstrap.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() {
  echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  Mattermost + OpenClaw GitOps Bootstrap                 │"
echo "  │  Terraform + kubeadm + FluxCD + CNPG + ESO + S3         │"
echo "  └─────────────────────────────────────────────────────────┘"
echo -e "${NC}"

# ── Validate .env ─────────────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
  log_error ".env not found. Run: cp .env.example .env && nano .env"
  exit 1
fi
source ".env"
log_ok ".env loaded (DOMAIN=${DOMAIN}, ENVIRONMENT=${ENVIRONMENT:-production})"

chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

# ── Step 1: Tools ─────────────────────────────────────────────────────────────
log_section "Step 1/7 - Install Local Tools"
bash scripts/01-install-tools.sh

# ── Step 2: Terraform ─────────────────────────────────────────────────────────
log_section "Step 2/7 - Terraform: Provision Infrastructure"
bash scripts/02-terraform-provision.sh
source ".env"   # reload: picks up CP_PUBLIC_IP, WORKER*_PUBLIC_IP, SSH_KEY_PATH, NLB_DNS_NAME, S3_BUCKET_NAME

# ── Step 3: kubeadm ───────────────────────────────────────────────────────────
log_section "Step 3/7 - kubeadm: Build Kubernetes Cluster"
if kubectl cluster-info &>/dev/null 2>&1; then
  log_ok "Cluster already reachable - skipping kubeadm setup"
else
  bash scripts/03-kubeadm-setup.sh
fi

# ── Step 4: FluxCD ────────────────────────────────────────────────────────────
log_section "Step 4/7 - FluxCD: Bootstrap GitOps"
bash scripts/04-bootstrap-flux.sh

# ── Step 5: Secrets ───────────────────────────────────────────────────────────
log_section "Step 5/7 - Secrets: Push to AWS Secrets Manager"
bash scripts/05-create-secrets.sh

# ── Step 6: Verify ────────────────────────────────────────────────────────────
log_section "Step 6/7 - Verify Mattermost Deployment"
bash scripts/06-verify.sh

# ── Step 7: OpenClaw ──────────────────────────────────────────────────────────
log_section "Step 7/7 - OpenClaw: Mattermost Bot + KubeClaw"
bash scripts/07-setup-openclaw.sh

# ── Done ──────────────────────────────────────────────────────────────────────
source ".env"
log_section "Bootstrap Complete!"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo "    1. Point DNS CNAME: ${DOMAIN} -> ${NLB_DNS_NAME:-<see NLB output>}"
echo "    2. Wait ~3 min for Flux to reconcile all components"
echo "    3. Wait ~5 min for cert-manager to issue TLS certificate"
echo "    4. Open Mattermost: https://${DOMAIN}"
echo "    5. Open OpenClaw:   https://openclaw.${DOMAIN}"
echo ""
echo -e "${BOLD}  Watch deployment:${NC}"
echo "    flux get kustomizations -A --watch"
echo "    kubectl get pods -n mattermost --watch"
echo "    kubectl get pods -n kubeclaw --watch"
echo ""
echo -e "${BOLD}  When done, tear down with:${NC}"
echo "    bash teardown.sh"
echo ""
echo -e "${GREEN}${BOLD}  Mattermost + OpenClaw are deploying via GitOps!${NC}"
echo ""
