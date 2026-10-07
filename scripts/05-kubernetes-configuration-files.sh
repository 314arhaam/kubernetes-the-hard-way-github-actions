#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

require_commands kubectl tailscale grep
enter_repo
load_inventory

required_files=(
  ca.crt
  kube-proxy.crt kube-proxy.key
  kube-controller-manager.crt kube-controller-manager.key
  kube-scheduler.crt kube-scheduler.key
  admin.crt admin.key
)
for host in "${WORKERS[@]}"; do
  required_files+=("${host}.crt" "${host}.key")
done
require_files "${required_files[@]}"

log "Checking machine connectivity"
wait_for_tailnet_hosts "${ALL_HOSTS[@]}"
wait_for_tailscale_ssh "${ALL_HOSTS[@]}"

generate_kubeconfig() {
  local file="$1"
  local user="$2"
  local cert="$3"
  local key="$4"
  local server="$5"

  kubectl config set-cluster "$CLUSTER_NAME" \
    --certificate-authority=ca.crt --embed-certs=true \
    --server="$server" --kubeconfig="$file"
  kubectl config set-credentials "$user" \
    --client-certificate="$cert" --client-key="$key" \
    --embed-certs=true --kubeconfig="$file"
  kubectl config set-context default --cluster="$CLUSTER_NAME" \
    --user="$user" --kubeconfig="$file"
  kubectl config use-context default --kubeconfig="$file"
}

log "Generating kubeconfig files"
rm -f ./*.kubeconfig

worker_configs=()
for host in "${WORKERS[@]}"; do
  config="${host}.kubeconfig"
  worker_configs+=("$config")
  generate_kubeconfig "$config" "system:node:${host}" \
    "${host}.crt" "${host}.key" "$API_SERVER"
done

generate_kubeconfig kube-proxy.kubeconfig system:kube-proxy \
  kube-proxy.crt kube-proxy.key "$API_SERVER"
generate_kubeconfig kube-controller-manager.kubeconfig \
  system:kube-controller-manager kube-controller-manager.crt \
  kube-controller-manager.key "$API_SERVER"
generate_kubeconfig kube-scheduler.kubeconfig system:kube-scheduler \
  kube-scheduler.crt kube-scheduler.key "$API_SERVER"
generate_kubeconfig admin.kubeconfig admin admin.crt admin.key \
  https://127.0.0.1:6443

all_configs=(
  "${worker_configs[@]}"
  kube-proxy.kubeconfig
  kube-controller-manager.kubeconfig
  kube-scheduler.kubeconfig
  admin.kubeconfig
)

log "Validating kubeconfig files"
for config in "${all_configs[@]}"; do
  kubectl config view --kubeconfig="$config" --minify >/dev/null
done

log "Distributing worker kubeconfigs"
for host in "${WORKERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" \
    "mkdir -p /var/lib/kube-proxy /var/lib/kubelet"
  cat kube-proxy.kubeconfig | tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kube-proxy/kubeconfig"
  cat "${host}.kubeconfig" | tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kubelet/kubeconfig"
  tailscale ssh "${SSH_USER}@${host}" \
    "chmod 600 /var/lib/kube-proxy/kubeconfig /var/lib/kubelet/kubeconfig"
done

control_configs=(
  admin.kubeconfig
  kube-controller-manager.kubeconfig
  kube-scheduler.kubeconfig
)

log "Distributing control-plane kubeconfigs"
for host in "${SERVERS[@]}"; do
  for file in "${control_configs[@]}"; do
    cat "$file" | tailscale ssh "${SSH_USER}@${host}" \
      "cat > /root/${file}"
  done
  tailscale ssh "${SSH_USER}@${host}" \
    "chmod 600 /root/admin.kubeconfig /root/kube-controller-manager.kubeconfig /root/kube-scheduler.kubeconfig"
done

log "Verifying remote kubeconfigs"
for host in "${WORKERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" \
    "test -s /var/lib/kubelet/kubeconfig; test -s /var/lib/kube-proxy/kubeconfig; grep -q 'server: ${API_SERVER}' /var/lib/kubelet/kubeconfig; grep -q 'server: ${API_SERVER}' /var/lib/kube-proxy/kubeconfig"
done

for host in "${SERVERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" \
    "test -s /root/admin.kubeconfig; test -s /root/kube-controller-manager.kubeconfig; test -s /root/kube-scheduler.kubeconfig"
done

for config in "${worker_configs[@]}" kube-proxy.kubeconfig \
  kube-controller-manager.kubeconfig kube-scheduler.kubeconfig; do
  grep -q "server: ${API_SERVER}" "$config" \
    || die "$config does not reference $API_SERVER"
done
grep -q 'server: https://127.0.0.1:6443' admin.kubeconfig \
  || die "admin.kubeconfig does not reference localhost."

log "Kubernetes configuration-file step completed"
printf 'Workers: %s\n' "${WORKERS[*]}"
printf 'Servers: %s\n' "${SERVERS[*]}"
