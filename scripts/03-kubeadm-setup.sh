#!/usr/bin/env bash
# 03-kubeadm-setup.sh — Multi-node kubeadm setup
#
# Phases:
#   1. Install prerequisites on ALL nodes (containerd, kubelet, kubeadm, kubectl)
#   2. Run kubeadm init on the control plane
#   3. Install Flannel CNI and local-path-provisioner fallback storage
#   4. Run kubeadm join on each worker node
#   5. Fetch kubeconfig to local ~/.kube/config
#
# All phases run remotely via SSH — you never need to log into the server manually.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

SSM_FALLBACK_ENABLED="${SSM_FALLBACK_ENABLED:-true}"
if [[ "$SSM_FALLBACK_ENABLED" == "true" ]]; then
  require_tool aws
  require_tool jq
fi

K8S_VERSION="1.30"
FLANNEL_VERSION="v0.25.5"
LOCAL_PATH_VERSION="v0.0.28"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY_PATH}"
if [[ "$SSH_KEY" != /* ]]; then
  if [[ -f "$ROOT_DIR/$SSH_KEY" ]]; then
    SSH_KEY="$ROOT_DIR/$SSH_KEY"
  elif [[ -f "$ROOT_DIR/terraform/environments/${ENVIRONMENT:-production}/${SSH_KEY#./}" ]]; then
    SSH_KEY="$ROOT_DIR/terraform/environments/${ENVIRONMENT:-production}/${SSH_KEY#./}"
  fi
fi
if [[ ! -f "$SSH_KEY" ]]; then
  log_error "SSH key not found: $SSH_KEY"
  log_error "Run scripts/02-terraform-provision.sh so SSH_KEY_PATH is refreshed in .env."
  exit 1
fi
chmod 600 "$SSH_KEY"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=30"

log_section "03 — kubeadm Multi-Node Cluster Setup"
log_info "Control plane : ${SSH_USER}@${CP_PUBLIC_IP} (private: ${CP_PRIVATE_IP})"

WORKER_PUBLIC_IPS="${WORKER_PUBLIC_IPS:-${WORKER1_PUBLIC_IP:-},${WORKER2_PUBLIC_IP:-}}"
WORKER_PRIVATE_IPS="${WORKER_PRIVATE_IPS:-${WORKER1_PRIVATE_IP:-},${WORKER2_PRIVATE_IP:-}}"
WORKER_INSTANCE_IDS="${WORKER_INSTANCE_IDS:-}"
IFS=',' read -r -a WORKER_PUBLIC_LIST <<< "$WORKER_PUBLIC_IPS"
IFS=',' read -r -a WORKER_INSTANCE_LIST <<< "$WORKER_INSTANCE_IDS"

if [[ ${#WORKER_PUBLIC_LIST[@]} -lt 1 || -z "${WORKER_PUBLIC_LIST[0]}" ]]; then
  log_error "No worker IPs found. Run scripts/02-terraform-provision.sh first."
  exit 1
fi

for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  log_info "Worker $((idx + 1))      : ${SSH_USER}@${WORKER_PUBLIC_LIST[$idx]}"
done

wait_for_ssh_soft() {
  local host="$1"
  local key="$2"
  local user="${3:-ubuntu}"
  local max_attempts="${4:-30}"
  local opts="-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30"

  log_info "Waiting for SSH on ${host} (up to $((max_attempts * 10))s)..."
  for i in $(seq 1 "$max_attempts"); do
    if ssh $opts "${user}@${host}" "echo ok" &>/dev/null; then
      log_ok "SSH ready on ${host}"
      return 0
    fi
    log_info "  attempt ${i}/${max_attempts} — retrying in 10s..."
    sleep 10
  done

  log_warn "SSH not available on ${host} after $((max_attempts * 10))s"
  return 1
}

wait_for_ssm() {
  local instance_id="$1"
  local max_attempts="${2:-30}"
  local status=""

  [[ -z "$instance_id" || "$SSM_FALLBACK_ENABLED" != "true" ]] && return 1

  log_info "Waiting for SSM on ${instance_id} (up to $((max_attempts * 10))s)..."
  for i in $(seq 1 "$max_attempts"); do
    status="$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"
    if [[ "$status" == "Online" ]]; then
      log_ok "SSM ready on ${instance_id}"
      return 0
    fi
    log_info "  attempt ${i}/${max_attempts} — SSM status: ${status:-unknown}; retrying in 10s..."
    sleep 10
  done

  log_warn "SSM not available on ${instance_id} after $((max_attempts * 10))s"
  return 1
}

ssm_send_script() {
  local instance_id="$1"
  local script_path="$2"
  local comment="$3"
  local params command_id status stdout stderr

  if ! wait_for_ssm "$instance_id"; then
    return 1
  fi
  params="$(jq -n --rawfile script "$script_path" '{commands: ["cat > /tmp/mm-ssm-script.sh <<'"'"'MM_SSM_SCRIPT'"'"'\n\($script)\nMM_SSM_SCRIPT", "chmod +x /tmp/mm-ssm-script.sh", "sudo bash /tmp/mm-ssm-script.sh"]}')"
  command_id="$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$instance_id" \
    --comment "$comment" \
    --parameters "$params" \
    --query 'Command.CommandId' \
    --output text)"

  log_info "SSM command ${command_id} sent to ${instance_id}"
  aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" || true

  stdout="$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || true)"
  stderr="$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'StandardErrorContent' \
    --output text 2>/dev/null || true)"
  status="$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'Status' \
    --output text 2>/dev/null || true)"

  [[ -n "$stdout" && "$stdout" != "None" ]] && printf '%s\n' "$stdout"
  [[ -n "$stderr" && "$stderr" != "None" ]] && printf '%s\n' "$stderr" >&2

  if [[ "$status" != "Success" ]]; then
    log_error "SSM command ${command_id} failed on ${instance_id} with status: ${status:-unknown}"
    return 1
  fi
}

run_worker_prereqs() {
  local worker_ip="$1"
  local worker_num="$2"
  local instance_id="${3:-}"

  log_step "Phase 1 worker ${worker_num} — Installing prerequisites"
  if wait_for_ssh_soft "$worker_ip" "$SSH_KEY" "$SSH_USER"; then
    scp $SSH_OPTS /tmp/mm-node-prereqs.sh "${SSH_USER}@${worker_ip}:/tmp/prereqs.sh"
    ssh $SSH_OPTS -tt "${SSH_USER}@${worker_ip}" "sudo bash /tmp/prereqs.sh"
    return 0
  fi

  if [[ "$SSM_FALLBACK_ENABLED" == "true" && -n "$instance_id" ]]; then
    log_warn "Falling back to SSM for worker ${worker_num} (${instance_id})"
    ssm_send_script "$instance_id" /tmp/mm-node-prereqs.sh "mattermost-kubeadm-prereqs-worker-${worker_num}"
    return 0
  fi

  log_error "Worker ${worker_num} is not reachable by SSH and no SSM instance ID is available."
  exit 1
}

# ── Phase 1: Prerequisites on all nodes ──────────────────────────────────────
# This script is copied to each node and run as root.
# It installs containerd (CRI) + kubeadm + kubelet + kubectl.
cat > /tmp/mm-node-prereqs.sh << NODESCRIPT
#!/usr/bin/env bash
set -euo pipefail
K8S_VERSION="${K8S_VERSION}"

echo "==> Disabling swap (required by kubelet)"
swapoff -a
sed -i '/\\sswap\\s/d' /etc/fstab

echo "==> Loading kernel modules for Kubernetes networking"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "==> Installing containerd (container runtime)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq containerd.io
# Enable SystemdCgroup — required for kubelet to work correctly
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

echo "==> Installing kubeadm, kubelet, kubectl (v${K8S_VERSION})"
apt-get install -y -qq apt-transport-https
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v\${K8S_VERSION}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v\${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
echo "==> Node prerequisites complete"
NODESCRIPT

log_step "Phase 1a — Installing prerequisites on control plane"
wait_for_ssh "$CP_PUBLIC_IP" "$SSH_KEY" "$SSH_USER"
scp $SSH_OPTS /tmp/mm-node-prereqs.sh "${SSH_USER}@${CP_PUBLIC_IP}:/tmp/prereqs.sh"
ssh $SSH_OPTS -tt "${SSH_USER}@${CP_PUBLIC_IP}" "sudo bash /tmp/prereqs.sh"

for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  worker_ip="${WORKER_PUBLIC_LIST[$idx]}"
  [[ -z "$worker_ip" ]] && continue
  run_worker_prereqs "$worker_ip" "$((idx + 1))" "${WORKER_INSTANCE_LIST[$idx]:-}"
done

log_ok "Prerequisites installed on all nodes"

# ── Phase 2: kubeadm init on control plane ────────────────────────────────────
log_step "Phase 2 — kubeadm init on control plane (takes ~2 min)"

cat > /tmp/mm-cp-init.sh << CPSCRIPT
#!/usr/bin/env bash
set -euo pipefail
K8S_VERSION="${K8S_VERSION}"
FLANNEL_VERSION="${FLANNEL_VERSION}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION}"
CP_PRIVATE_IP="${CP_PRIVATE_IP}"
CP_PUBLIC_IP="${CP_PUBLIC_IP}"

echo "==> Running kubeadm init"
kubeadm init \\
  --apiserver-advertise-address="\${CP_PRIVATE_IP}" \\
  --apiserver-cert-extra-sans="\${CP_PUBLIC_IP},\${CP_PRIVATE_IP}" \\
  --pod-network-cidr="10.244.0.0/16" \\
  --kubernetes-version="v\${K8S_VERSION}.0" \\
  | tee /tmp/kubeadm-init.log

echo "==> Configuring kubectl for root"
mkdir -p \$HOME/.kube
cp /etc/kubernetes/admin.conf \$HOME/.kube/config
chown "\$(id -u):\$(id -g)" \$HOME/.kube/config

echo "==> Configuring kubectl for ${SSH_USER:-ubuntu}"
SUDO_USER_HOME=\$(getent passwd "\${SUDO_USER:-ubuntu}" | cut -d: -f6)
mkdir -p "\${SUDO_USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "\${SUDO_USER_HOME}/.kube/config"
chown -R "\${SUDO_USER:-ubuntu}:\${SUDO_USER:-ubuntu}" "\${SUDO_USER_HOME}/.kube"

# Patch kubeconfig server to use public IP so local kubectl works
sed -i "s|server: https://\${CP_PRIVATE_IP}:6443|server: https://\${CP_PUBLIC_IP}:6443|" \\
  "\${SUDO_USER_HOME}/.kube/config"

echo "==> Keeping control-plane taint"
echo "Workloads stay on worker nodes so pods can use the worker IAM instance profile."

echo "==> Installing Flannel CNI v\${FLANNEL_VERSION}"
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/\${FLANNEL_VERSION}/kube-flannel.yml"

echo "==> Installing local-path-provisioner v\${LOCAL_PATH_VERSION} (fallback default StorageClass)"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/\${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path \\
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "==> Waiting for control plane to be Ready"
kubectl wait node --all --for=condition=Ready --timeout=180s

echo "==> Generating worker join command"
kubeadm token create --print-join-command > /tmp/kubeadm-join.sh
chmod 644 /tmp/kubeadm-join.sh
echo "==> Control plane init complete"
CPSCRIPT

scp $SSH_OPTS /tmp/mm-cp-init.sh "${SSH_USER}@${CP_PUBLIC_IP}:/tmp/cp-init.sh"
ssh $SSH_OPTS -tt "${SSH_USER}@${CP_PUBLIC_IP}" "sudo bash /tmp/cp-init.sh"
log_ok "Control plane initialised"

# ── Phase 3: Fetch kubeconfig and join command ────────────────────────────────
log_step "Phase 3 — Fetching kubeconfig"
mkdir -p "$HOME/.kube"
scp $SSH_OPTS "${SSH_USER}@${CP_PUBLIC_IP}:~/.kube/config" "$HOME/.kube/config"
log_ok "kubeconfig saved to ~/.kube/config"

log_step "Phase 3b — Fetching join command from control plane"
if ! scp $SSH_OPTS "${SSH_USER}@${CP_PUBLIC_IP}:/tmp/kubeadm-join.sh" /tmp/kubeadm-join.sh; then
  log_warn "Direct scp failed; fetching join command with sudo"
  ssh $SSH_OPTS "${SSH_USER}@${CP_PUBLIC_IP}" "sudo cat /tmp/kubeadm-join.sh" > /tmp/kubeadm-join.sh
  chmod 600 /tmp/kubeadm-join.sh
fi
log_ok "Join command fetched"

# ── Phase 4: Join workers ─────────────────────────────────────────────────────
join_worker() {
  local worker_ip="$1"
  local worker_num="$2"
  local instance_id="${3:-}"
  log_step "Phase 4${worker_num} — Joining worker ${worker_num} (${worker_ip})"

  if wait_for_ssh_soft "$worker_ip" "$SSH_KEY" "$SSH_USER"; then
    scp $SSH_OPTS /tmp/kubeadm-join.sh "${SSH_USER}@${worker_ip}:/tmp/kubeadm-join.sh"
    ssh $SSH_OPTS -tt "${SSH_USER}@${worker_ip}" "sudo bash /tmp/kubeadm-join.sh"
  elif [[ "$SSM_FALLBACK_ENABLED" == "true" && -n "$instance_id" ]]; then
    log_warn "Falling back to SSM for worker ${worker_num} (${instance_id})"
    ssm_send_script "$instance_id" /tmp/kubeadm-join.sh "mattermost-kubeadm-join-worker-${worker_num}"
  else
    log_error "Worker ${worker_num} is not reachable by SSH and no SSM instance ID is available."
    exit 1
  fi

  log_ok "Worker ${worker_num} joined"
}

for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  worker_ip="${WORKER_PUBLIC_LIST[$idx]}"
  [[ -z "$worker_ip" ]] && continue
  join_worker "$worker_ip" "$((idx + 1))" "${WORKER_INSTANCE_LIST[$idx]:-}"
done

# ── Phase 5: Verify all nodes Ready ──────────────────────────────────────────
log_step "Phase 5 — Waiting for all nodes to be Ready"
kubectl wait node --all --for=condition=Ready --timeout=300s

log_section "03 Complete — Cluster is Ready"
kubectl get nodes -o wide
echo ""
echo "  3-node cluster ready:"
echo "    Control plane : ${CP_PUBLIC_IP}"
for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  [[ -z "${WORKER_PUBLIC_LIST[$idx]}" ]] && continue
  echo "    Worker $((idx + 1))      : ${WORKER_PUBLIC_LIST[$idx]}"
done
