#!/usr/bin/env bash
# 06-verify.sh — Full deployment verification with actionable diagnostics
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "06 — Deployment Verification"

log_step "Flux Kustomizations"
flux get kustomizations -A

log_step "Flux HelmReleases"
flux get helmreleases -A

log_step "Cluster nodes"
kubectl get nodes -o wide

log_step "Pods — all namespaces"
kubectl get pods -A -o wide | grep -v Running | grep -v Completed || \
  log_ok "All pods are Running or Completed"

log_step "Mattermost CR status"
kubectl get mattermost -n mattermost 2>/dev/null || echo "  (not yet created)"

log_step "CNPG Cluster status"
kubectl get cluster -n mattermost 2>/dev/null || echo "  (not yet created)"

log_step "ExternalSecrets sync status"
kubectl get externalsecrets -n mattermost 2>/dev/null || echo "  (not yet created)"

log_step "TLS Certificates"
kubectl get certificates -A 2>/dev/null || echo "  (not yet issued)"

# ── Connectivity check ────────────────────────────────────────────────────────
log_step "Checking nginx reachability via NLB"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${NLB_DNS_NAME}/" --max-time 10 2>/dev/null || echo "timeout")
if [[ "$HTTP_CODE" == "timeout" ]]; then
  log_warn "NLB not yet reachable on port 80 — nginx may still be starting"
  echo "  Check: kubectl get pods -n ingress-nginx"
elif [[ "$HTTP_CODE" =~ ^[234] ]]; then
  log_ok "NLB reachable — HTTP ${HTTP_CODE}"
else
  log_info "NLB HTTP response: ${HTTP_CODE}"
fi

# ── DNS check ─────────────────────────────────────────────────────────────────
log_step "DNS resolution for ${DOMAIN}"
RESOLVED=$(dig +short "${DOMAIN}" CNAME 2>/dev/null | head -1 || true)
if [[ -z "$RESOLVED" ]]; then
  log_warn "${DOMAIN} does not resolve yet"
  echo "  ACTION: Add CNAME record at your DNS provider:"
  echo "    ${DOMAIN}  CNAME  →  ${NLB_DNS_NAME}"
else
  log_ok "${DOMAIN} → ${RESOLVED}"
fi

# ── TLS cert ──────────────────────────────────────────────────────────────────
CERT_READY=$(kubectl get certificate mattermost-tls -n mattermost \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "$CERT_READY" == "True" ]]; then
  log_ok "TLS certificate ready"
elif [[ -z "$CERT_READY" ]]; then
  log_info "TLS certificate pending — requires DNS to resolve and port 80 open"
  echo "  Debug: kubectl describe certificaterequest -n mattermost"
else
  log_warn "TLS certificate not ready (${CERT_READY})"
fi

log_section "Access Summary"
echo ""
echo "  URL       : https://${DOMAIN}"
echo "  NLB DNS   : ${NLB_DNS_NAME}"
echo "  S3 Bucket : ${S3_BUCKET_NAME}"
echo ""
echo "  CNPG primary  : mattermost-db-rw.mattermost.svc:5432"
echo "  CNPG replica  : mattermost-db-ro.mattermost.svc:5432"
echo ""
echo "  Watch commands:"
echo "    flux get kustomizations -A --watch"
echo "    kubectl get pods -n mattermost --watch"
echo "    kubectl logs -n mattermost -l app.kubernetes.io/name=mattermost -f"
echo ""
