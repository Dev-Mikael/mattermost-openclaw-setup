#!/usr/bin/env bash
# 01-install-tools.sh — installs all local tools needed to run bootstrap
# Tools: kubectl, helm, flux CLI, terraform, jq, awscli
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log_section "01 — Install Local Tools"
OS="$(uname -s)"; ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH_ALT="amd64" || ARCH_ALT="arm64"

install_linux() {
  # jq + unzip are needed by the installer itself before Terraform/AWS CLI setup
  if ! command -v jq &>/dev/null || ! command -v unzip &>/dev/null; then
    log_step "Installing jq and unzip"
    sudo apt-get update -qq
    sudo apt-get install -y -qq jq unzip
    log_ok "jq $(jq --version)"
  else
    log_ok "jq $(jq --version)"
    log_ok "unzip installed"
  fi

  # kubectl
  if ! command -v kubectl &>/dev/null; then
    log_step "Installing kubectl"
    KUBE_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${KUBE_VER}/bin/linux/${ARCH_ALT}/kubectl"
    chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
    log_ok "kubectl ${KUBE_VER}"
  else log_ok "kubectl $(kubectl version --client --short 2>/dev/null | head -1)"; fi

  # Helm
  if ! command -v helm &>/dev/null; then
    log_step "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_ok "helm $(helm version --short)"
  else log_ok "helm $(helm version --short)"; fi

  # Flux CLI
  if ! command -v flux &>/dev/null; then
    log_step "Installing Flux CLI"
    curl -s https://fluxcd.io/install.sh | sudo bash
    log_ok "flux $(flux version --client)"
  else log_ok "flux $(flux version --client)"; fi

  # Terraform
  if ! command -v terraform &>/dev/null; then
    log_step "Installing Terraform"
    TF_VER=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r '.current_version')
    curl -sLo /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_${ARCH_ALT}.zip"
    unzip -q /tmp/terraform.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/terraform
    rm -f /tmp/terraform.zip
    log_ok "terraform ${TF_VER}"
  else log_ok "terraform $(terraform version -json | jq -r '.terraform_version')"; fi

  # AWS CLI v2
  if ! command -v aws &>/dev/null; then
    log_step "Installing AWS CLI v2"
    curl -sLo /tmp/awscliv2.zip \
      "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
    log_ok "aws $(aws --version)"
  else log_ok "aws $(aws --version 2>&1 | head -1)"; fi
}

install_mac() {
  if ! command -v brew &>/dev/null; then
    log_error "Homebrew not found — install from https://brew.sh"
    exit 1
  fi
  log_step "Installing tools via Homebrew"
  brew install kubectl helm fluxcd/tap/flux terraform jq awscli
}

case "$OS" in
  Linux)  install_linux ;;
  Darwin) install_mac ;;
  *)      log_error "Unsupported OS: $OS"; exit 1 ;;
esac

log_ok "All tools installed and ready"
