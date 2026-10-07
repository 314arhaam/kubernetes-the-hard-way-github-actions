#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

enter_repo
load_inventory

# Check required local files

log "Checking required local files"

required_files=(
  machines.txt

  downloads/client/kubectl

  downloads/worker/crictl
  downloads/worker/kube-proxy
  downloads/worker/kubelet
  downloads/worker/runc
  downloads/worker/containerd
  downloads/worker/containerd-shim-runc-v2
  downloads/worker/containerd-stress

  configs/10-bridge.conf
  configs/99-loopback.conf
  configs/containerd-config.toml
  configs/kubelet-config.yaml
  configs/kube-proxy-config.yaml

  units/containerd.service
  units/kubelet.service
  units/kube-proxy.service
)

require_files "${required_files[@]}"

if [ ! -d downloads/cni-plugins ]; then
  die "downloads/cni-plugins directory not found."
fi

echo "Required local files are present."

log "Waiting for Kubernetes machines"
wait_for_tailnet_hosts "${ALL_HOSTS[@]}"
wait_for_tailscale_ssh "${ALL_HOSTS[@]}"

# Verify previous-step files on worker nodes
#
# Step 04/05 should already have installed:
#
# /var/lib/kubelet/ca.crt
# /var/lib/kubelet/kubelet.crt
# /var/lib/kubelet/kubelet.key
# /var/lib/kubelet/kubeconfig
# /var/lib/kube-proxy/kubeconfig

log "Checking worker certificates and kubeconfigs"

for host in "${WORKERS[@]}"; do

  echo "Checking $host..."

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    required_files=(
      /var/lib/kubelet/ca.crt
      /var/lib/kubelet/kubelet.crt
      /var/lib/kubelet/kubelet.key
      /var/lib/kubelet/kubeconfig
      /var/lib/kube-proxy/kubeconfig
    )

    for file in "${required_files[@]}"; do
      if [ ! -f "$file" ]; then
        echo "ERROR: Missing required file: $file" >&2
        exit 1
      fi
    done
  '

done

# Generate worker-specific configuration files
#
# Upstream:
#
# SUBNET=$(grep ${HOST} machines.txt | cut -d " " -f 4)
#
# sed "s|SUBNET|$SUBNET|g" ...

log "Generating worker-specific configuration"

rm -rf .worker-configs
mkdir -p .worker-configs

for host in "${WORKERS[@]}"; do

  subnet="$(machine_subnet "$host")"

  [ -n "$subnet" ] \
    || die "No pod subnet found for $host in machines.txt"

  echo "$host pod subnet: $subnet"

  mkdir -p ".worker-configs/$host"

  sed "s|SUBNET|${subnet}|g" \
    configs/10-bridge.conf \
    > ".worker-configs/${host}/10-bridge.conf"

  sed "s|SUBNET|${subnet}|g" \
    configs/kubelet-config.yaml \
    > ".worker-configs/${host}/kubelet-config.yaml"

done

# Copy worker files
#
# Instead of scp, use tar over Tailscale SSH.

log "Copying worker files"

for host in "${WORKERS[@]}"; do

  echo "Copying files to $host..."

  staging_dir=".worker-stage-${host}"

  rm -rf "$staging_dir"

  mkdir -p \
    "$staging_dir/cni-plugins"

  cp ".worker-configs/${host}/10-bridge.conf" \
    "$staging_dir/10-bridge.conf"

  cp ".worker-configs/${host}/kubelet-config.yaml" \
    "$staging_dir/kubelet-config.yaml"

  cp configs/99-loopback.conf \
    "$staging_dir/99-loopback.conf"

  cp configs/containerd-config.toml \
    "$staging_dir/containerd-config.toml"

  cp configs/kube-proxy-config.yaml \
    "$staging_dir/kube-proxy-config.yaml"

  cp units/containerd.service \
    "$staging_dir/containerd.service"

  cp units/kubelet.service \
    "$staging_dir/kubelet.service"

  cp units/kube-proxy.service \
    "$staging_dir/kube-proxy.service"

  cp downloads/client/kubectl \
    "$staging_dir/kubectl"

  cp downloads/worker/crictl \
    "$staging_dir/crictl"

  cp downloads/worker/kube-proxy \
    "$staging_dir/kube-proxy"

  cp downloads/worker/kubelet \
    "$staging_dir/kubelet"

  cp downloads/worker/runc \
    "$staging_dir/runc"

  cp downloads/worker/containerd \
    "$staging_dir/containerd"

  cp downloads/worker/containerd-shim-runc-v2 \
    "$staging_dir/containerd-shim-runc-v2"

  cp downloads/worker/containerd-stress \
    "$staging_dir/containerd-stress"

  cp downloads/cni-plugins/* \
    "$staging_dir/cni-plugins/"

  tar -C "$staging_dir" -cf - . |
  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    rm -rf /root/kthw-worker
    mkdir -p /root/kthw-worker

    tar -xf - -C /root/kthw-worker
  '

  rm -rf "$staging_dir"

done

# Provision workers

log "Provisioning Kubernetes workers"

for host in "${WORKERS[@]}"; do

  echo
  echo "Provisioning $host..."

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    cd /root/kthw-worker

    # --------------------------------------------------------
    # Install OS dependencies
    # --------------------------------------------------------

    apt-get update

    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
      socat \
      conntrack \
      ipset \
      kmod

    # --------------------------------------------------------
    # Disable swap
    # --------------------------------------------------------

    swapoff -a

    echo "Current swap configuration:"
    swapon --show || true

    # --------------------------------------------------------
    # Create installation directories
    # --------------------------------------------------------

    mkdir -p \
      /etc/cni/net.d \
      /opt/cni/bin \
      /var/lib/kubelet \
      /var/lib/kube-proxy \
      /var/lib/kubernetes \
      /var/run/kubernetes

    # --------------------------------------------------------
    # Install worker binaries
    # --------------------------------------------------------

    install -m 0755 \
      crictl \
      kube-proxy \
      kubelet \
      runc \
      kubectl \
      /usr/local/bin/

    install -m 0755 \
      containerd \
      containerd-shim-runc-v2 \
      containerd-stress \
      /bin/

    cp cni-plugins/* \
      /opt/cni/bin/

    chmod 0755 /opt/cni/bin/*

    # --------------------------------------------------------
    # Configure CNI networking
    # --------------------------------------------------------

    mv \
      10-bridge.conf \
      99-loopback.conf \
      /etc/cni/net.d/

    # --------------------------------------------------------
    # Enable bridge netfilter
    # --------------------------------------------------------

    modprobe br-netfilter

    printf "%s\n" \
      "br-netfilter" \
      > /etc/modules-load.d/kubernetes.conf

    cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

    sysctl -p /etc/sysctl.d/kubernetes.conf

    # --------------------------------------------------------
    # Configure containerd
    # --------------------------------------------------------

    mkdir -p /etc/containerd

    mv \
      containerd-config.toml \
      /etc/containerd/config.toml

    mv \
      containerd.service \
      /etc/systemd/system/containerd.service

    # --------------------------------------------------------
    # Configure kubelet
    # --------------------------------------------------------

    mv \
      kubelet-config.yaml \
      /var/lib/kubelet/kubelet-config.yaml

    mv \
      kubelet.service \
      /etc/systemd/system/kubelet.service

    # --------------------------------------------------------
    # Configure kube-proxy
    # --------------------------------------------------------

    mv \
      kube-proxy-config.yaml \
      /var/lib/kube-proxy/kube-proxy-config.yaml

    mv \
      kube-proxy.service \
      /etc/systemd/system/kube-proxy.service

    # --------------------------------------------------------
    # Start worker services
    # --------------------------------------------------------

    systemctl daemon-reload

    systemctl enable \
      containerd \
      kubelet \
      kube-proxy

    systemctl restart \
      containerd \
      kubelet \
      kube-proxy
  '

done

# Wait for services

log "Waiting for worker services"

services=(
  containerd
  kubelet
  kube-proxy
)

for host in "${WORKERS[@]}"; do
  for service in "${services[@]}"; do
    wait_for_remote_service "$host" "$service"
  done
done

# Verify containerd

log "Checking containerd"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    crictl \
      --runtime-endpoint unix:///run/containerd/containerd.sock \
      info >/dev/null

    echo "containerd OK"
  '

done

# Verify CNI configuration

log "Checking CNI configuration"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    echo "CNI configs:"
    ls -l /etc/cni/net.d/

    echo
    echo "Bridge config:"
    cat /etc/cni/net.d/10-bridge.conf
  '

done

# Verify kubelet API endpoint configuration
#
# This should point at the primary server selected from servers.txt.

log "Checking worker API endpoint configuration"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    grep -n "server:" \
      /var/lib/kubelet/kubeconfig
  '

done

workers_registered() {
  local host registered

  for host in "${WORKERS[@]}"; do
    registered="$(tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" \
      "kubectl get node '$host' --kubeconfig /root/admin.kubeconfig -o name 2>/dev/null" || true)"
    [ "$registered" = "node/$host" ] || return 1
  done
}

workers_ready() {
  local host ready

  for host in "${WORKERS[@]}"; do
    ready="$(tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" \
      "kubectl get node '$host' --kubeconfig /root/admin.kubeconfig -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" || true)"
    [ "$ready" = True ] || return 1
  done
}

show_worker_diagnostics() {
  local host

  tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" \
    "kubectl get nodes -o wide --kubeconfig /root/admin.kubeconfig || true"
  for host in "${WORKERS[@]}"; do
    echo "Kubelet logs on $host:"
    tailscale ssh "${SSH_USER}@${host}" \
      "journalctl -u kubelet --no-pager -n 150 || true"
  done
}

log "Waiting for Kubernetes nodes to register"
retry 90 "$RETRY_DELAY" "Waiting for inventory workers to register." \
  workers_registered \
  || { show_worker_diagnostics; die "Workers did not register."; }

log "Waiting for workers to become Ready"
retry 90 "$RETRY_DELAY" "Waiting for inventory workers to become Ready." \
  workers_ready \
  || { show_worker_diagnostics; die "Workers did not become Ready."; }

# Final verification

log "Kubernetes workers"

tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" \
  "kubectl get nodes \
    -o wide \
    --kubeconfig /root/admin.kubeconfig"

# Worker service summary

log "Worker service summary"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    for service in \
      containerd \
      kubelet \
      kube-proxy
    do
      printf "%-12s " "$service"
      systemctl is-active "$service"
    done
  '

done

log "Kubernetes worker bootstrap completed"

echo
echo "Workers:"
printf '  %s\n' "${WORKERS[@]}"
echo
echo "Expected Kubernetes status:"
for host in "${WORKERS[@]}"; do
  printf '  %-18s Ready\n' "$host"
done
