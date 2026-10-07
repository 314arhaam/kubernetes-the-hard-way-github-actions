#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

enter_repo
load_inventory
require_files \
  downloads/controller/kube-apiserver \
  downloads/controller/kube-controller-manager \
  downloads/controller/kube-scheduler \
  downloads/client/kubectl \
  units/kube-apiserver.service \
  units/kube-controller-manager.service \
  units/kube-scheduler.service \
  configs/kube-scheduler.yaml \
  configs/kube-apiserver-to-kubelet.yaml \
  ca.crt

log "Checking control-plane connectivity"
wait_for_tailnet_hosts "${SERVERS[@]}"
wait_for_tailscale_ssh "${SERVERS[@]}"

etcd_servers="$(etcd_endpoints)"

log "Checking previous-step files"
for host in "${SERVERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail
    for file in \
      /root/ca.crt /root/ca.key \
      /root/kube-api-server.crt /root/kube-api-server.key \
      /root/service-accounts.crt /root/service-accounts.key \
      /root/encryption-config.yaml /root/admin.kubeconfig \
      /root/kube-controller-manager.kubeconfig \
      /root/kube-scheduler.kubeconfig
    do
      test -s "$file"
    done
  '
done

log "Installing control-plane files"
for host in "${SERVERS[@]}"; do
  tar -cf - \
    downloads/controller/kube-apiserver \
    downloads/controller/kube-controller-manager \
    downloads/controller/kube-scheduler \
    downloads/client/kubectl \
    units/kube-apiserver.service \
    units/kube-controller-manager.service \
    units/kube-scheduler.service \
    configs/kube-scheduler.yaml \
    configs/kube-apiserver-to-kubelet.yaml \
    | tailscale ssh "${SSH_USER}@${host}" 'tar -xf - -C /tmp'

  tailscale ssh "${SSH_USER}@${host}" "bash -s" <<EOF
set -euo pipefail

install -m 0755 \
  /tmp/downloads/controller/kube-apiserver \
  /tmp/downloads/controller/kube-controller-manager \
  /tmp/downloads/controller/kube-scheduler \
  /tmp/downloads/client/kubectl \
  /usr/local/bin/

mkdir -p /etc/kubernetes/config /var/lib/kubernetes
mv \
  /root/ca.crt /root/ca.key \
  /root/kube-api-server.key /root/kube-api-server.crt \
  /root/service-accounts.key /root/service-accounts.crt \
  /root/encryption-config.yaml \
  /var/lib/kubernetes/

chmod 600 \
  /var/lib/kubernetes/ca.key \
  /var/lib/kubernetes/kube-api-server.key \
  /var/lib/kubernetes/service-accounts.key \
  /var/lib/kubernetes/encryption-config.yaml
chmod 644 \
  /var/lib/kubernetes/ca.crt \
  /var/lib/kubernetes/kube-api-server.crt \
  /var/lib/kubernetes/service-accounts.crt

mv /root/kube-controller-manager.kubeconfig /var/lib/kubernetes/
mv /root/kube-scheduler.kubeconfig /var/lib/kubernetes/
chmod 600 /var/lib/kubernetes/*.kubeconfig

install -m 0644 /tmp/units/kube-apiserver.service /etc/systemd/system/
install -m 0644 /tmp/units/kube-controller-manager.service /etc/systemd/system/
install -m 0644 /tmp/units/kube-scheduler.service /etc/systemd/system/
install -m 0644 /tmp/configs/kube-scheduler.yaml /etc/kubernetes/config/
install -m 0600 /tmp/configs/kube-apiserver-to-kubelet.yaml /root/

sed -i \
  "s|--etcd-servers=http://127.0.0.1:2379|--etcd-servers=${etcd_servers}|" \
  /etc/systemd/system/kube-apiserver.service
sed -i \
  "s|--service-account-issuer=[^ ]*|--service-account-issuer=${API_SERVER}|" \
  /etc/systemd/system/kube-apiserver.service

rm -rf /tmp/downloads /tmp/units /tmp/configs
systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl restart kube-apiserver kube-controller-manager kube-scheduler
EOF
done

services=(kube-apiserver kube-controller-manager kube-scheduler)

log "Waiting for control-plane services"
for host in "${SERVERS[@]}"; do
  for service in "${services[@]}"; do
    wait_for_remote_service "$host" "$service"
  done
done

api_ready() {
  tailscale ssh "${SSH_USER}@$1" \
    'curl --fail --silent --cacert /var/lib/kubernetes/ca.crt https://127.0.0.1:6443/version >/dev/null 2>&1'
}

for host in "${SERVERS[@]}"; do
  retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" "API on $host is not ready." \
    api_ready "$host" || die "API server failed on $host."
done

log "Applying kubelet RBAC"
tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" '
  set -euo pipefail
  kubectl cluster-info --kubeconfig /root/admin.kubeconfig
  kubectl apply -f /root/kube-apiserver-to-kubelet.yaml \
    --kubeconfig /root/admin.kubeconfig
  kubectl get clusterrole system:kube-apiserver-to-kubelet \
    --kubeconfig /root/admin.kubeconfig
'

sleep 60

log "Verifying API server from jumpbox"
for endpoint in version readyz livez; do
  curl --fail-with-body --show-error --show-error --cacert ca.crt \
    "${API_SERVER}/${endpoint}"
  echo
done

log "Final control-plane service status"
for host in "${SERVERS[@]}"; do
  echo "[$host]"
  for service in "${services[@]}"; do
    tailscale ssh "${SSH_USER}@${host}" "systemctl is-active '$service'"
  done
done

log "Kubernetes control plane bootstrap completed"
echo "Servers: ${SERVERS[*]}"
echo "API endpoint: $API_SERVER"
