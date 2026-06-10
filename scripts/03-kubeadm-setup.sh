#!/usr/bin/env bash
# 03-kubeadm-setup.sh — Multi-node kubeadm setup
#
# Phases:
#   1. Install prerequisites on ALL nodes (containerd, kubelet, kubeadm, kubectl)
#   2. Run kubeadm init on the control plane
#   3. Install Flannel CNI and local-path-provisioner
#   4. Run kubeadm join on each worker node
#   5. Fetch kubeconfig to local ~/.kube/config
#
# All phases run remotely via SSH — you never need to log into the server manually.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

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
IFS=',' read -r -a WORKER_PUBLIC_LIST <<< "$WORKER_PUBLIC_IPS"

if [[ ${#WORKER_PUBLIC_LIST[@]} -lt 1 || -z "${WORKER_PUBLIC_LIST[0]}" ]]; then
  log_error "No worker IPs found. Run scripts/02-terraform-provision.sh first."
  exit 1
fi

for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  log_info "Worker $((idx + 1))      : ${SSH_USER}@${WORKER_PUBLIC_LIST[$idx]}"
done

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
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
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
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v\${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
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
  log_step "Phase 1 worker $((idx + 1)) — Installing prerequisites"
  wait_for_ssh "$worker_ip" "$SSH_KEY" "$SSH_USER"
  scp $SSH_OPTS /tmp/mm-node-prereqs.sh "${SSH_USER}@${worker_ip}:/tmp/prereqs.sh"
  ssh $SSH_OPTS -tt "${SSH_USER}@${worker_ip}" "sudo bash /tmp/prereqs.sh"
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

echo "==> Installing local-path-provisioner v\${LOCAL_PATH_VERSION} (default StorageClass)"
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
  log_step "Phase 4${worker_num} — Joining worker ${worker_num} (${worker_ip})"
  scp $SSH_OPTS /tmp/kubeadm-join.sh "${SSH_USER}@${worker_ip}:/tmp/kubeadm-join.sh"
  ssh $SSH_OPTS -tt "${SSH_USER}@${worker_ip}" "sudo bash /tmp/kubeadm-join.sh"
  log_ok "Worker ${worker_num} joined"
}

for idx in "${!WORKER_PUBLIC_LIST[@]}"; do
  worker_ip="${WORKER_PUBLIC_LIST[$idx]}"
  [[ -z "$worker_ip" ]] && continue
  join_worker "$worker_ip" "$((idx + 1))"
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
