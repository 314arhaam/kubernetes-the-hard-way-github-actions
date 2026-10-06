#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

enter_repo
load_inventory
require_files downloads/controller/etcd downloads/client/etcdctl

log "Checking control-plane connectivity"
wait_for_tailnet_hosts "${SERVERS[@]}"
wait_for_tailscale_ssh "${SERVERS[@]}"

initial_cluster="$(etcd_initial_cluster)"
endpoints="$(etcd_endpoints)"

log "Installing etcd cluster"
for host in "${SERVERS[@]}"; do
  ip="$(machine_ip "$host")"
  [ -n "$ip" ] || die "No IP found for server $host."

  tar -cf - downloads/controller/etcd downloads/client/etcdctl \
    | tailscale ssh "${SSH_USER}@${host}" 'tar -xf - -C /tmp'

  tailscale ssh "${SSH_USER}@${host}" "bash -s" <<EOF
set -euo pipefail

install -m 0755 /tmp/downloads/controller/etcd /usr/local/bin/etcd
install -m 0755 /tmp/downloads/client/etcdctl /usr/local/bin/etcdctl
rm -rf /tmp/downloads

mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd
cp /root/ca.crt /root/kube-api-server.crt /root/kube-api-server.key /etc/etcd/
chmod 644 /etc/etcd/ca.crt /etc/etcd/kube-api-server.crt
chmod 600 /etc/etcd/kube-api-server.key

cat > /etc/systemd/system/etcd.service <<'UNIT'
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${host} \\
  --initial-advertise-peer-urls http://${ip}:2380 \\
  --listen-peer-urls http://${ip}:2380 \\
  --listen-client-urls http://127.0.0.1:2379,http://${ip}:2379 \\
  --advertise-client-urls http://${ip}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${initial_cluster} \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable etcd
systemctl restart --no-block etcd
EOF
done

log "Waiting for etcd services"
for host in "${SERVERS[@]}"; do
  wait_for_remote_service "$host" etcd
done

etcd_cluster_healthy() {
  tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" \
    "ETCDCTL_API=3 etcdctl --endpoints='${endpoints}' endpoint health >/dev/null 2>&1"
}

log "Checking etcd cluster health"
retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" "etcd is not healthy yet." \
  etcd_cluster_healthy || die "etcd cluster did not become healthy."

tailscale ssh "${SSH_USER}@${PRIMARY_SERVER}" "
  ETCDCTL_API=3 etcdctl --endpoints='${endpoints}' member list
  ETCDCTL_API=3 etcdctl --endpoints='${endpoints}' endpoint status --write-out=table
"

for host in "${SERVERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" '
    ss -lntp | grep -E ":(2379|2380)" >/dev/null
    systemctl is-active etcd
  '
done

log "etcd bootstrap completed"
echo "Members: ${SERVERS[*]}"
echo "Endpoints: $endpoints"
