#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

enter_repo
load_inventory
require_commands tailscale python3 grep

log "Checking machine connectivity"
wait_for_tailnet_hosts "${ALL_HOSTS[@]}"
wait_for_tailscale_ssh "${ALL_HOSTS[@]}"

declare -A WORKER_IPS WORKER_SUBNETS TEST_IPS
for host in "${WORKERS[@]}"; do
  WORKER_IPS["$host"]="$(machine_ip "$host")"
  WORKER_SUBNETS["$host"]="$(machine_subnet "$host")"
  [ -n "${WORKER_IPS[$host]}" ] || die "No IP found for $host."
  [ -n "${WORKER_SUBNETS[$host]}" ] || die "No Pod subnet found for $host."
  TEST_IPS["$host"]="$(python3 -c \
    'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]).network_address + 10)' \
    "${WORKER_SUBNETS[$host]}")"
done

log "Enabling worker IPv4 forwarding"
for host in "${WORKERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-kubernetes-routing.conf
    sysctl -p /etc/sysctl.d/99-kubernetes-routing.conf
    test "$(sysctl -n net.ipv4.ip_forward)" = 1
  '
done

log "Checking Tailscale interfaces"
for host in "${ALL_HOSTS[@]}"; do
  echo "[$host]"
  tailscale ssh "${SSH_USER}@${host}" \
    "ip link show tailscale0; ip addr show dev tailscale0"
done

add_route() {
  local source_host="$1"
  local target_worker="$2"

  tailscale ssh "${SSH_USER}@${source_host}" \
    "ip route replace '${WORKER_SUBNETS[$target_worker]}' via '${WORKER_IPS[$target_worker]}' dev tailscale0 onlink"
}

log "Adding Pod routes to control-plane nodes"
for server in "${SERVERS[@]}"; do
  for worker in "${WORKERS[@]}"; do
    add_route "$server" "$worker"
  done
done

log "Adding Pod routes between workers"
for source_worker in "${WORKERS[@]}"; do
  for target_worker in "${WORKERS[@]}"; do
    [ "$source_worker" = "$target_worker" ] && continue
    add_route "$source_worker" "$target_worker"
  done
done

verify_route() {
  local source_host="$1"
  local target_worker="$2"
  local expected="${WORKER_SUBNETS[$target_worker]} via ${WORKER_IPS[$target_worker]} dev tailscale0"
  local routes

  routes="$(tailscale ssh "${SSH_USER}@${source_host}" "ip route")"
  grep -Fq "$expected" <<< "$routes" \
    || die "$source_host route to ${target_worker}'s Pod subnet is missing."
}

log "Verifying Pod routes"
for server in "${SERVERS[@]}"; do
  for worker in "${WORKERS[@]}"; do
    verify_route "$server" "$worker"
  done
done

for source_worker in "${WORKERS[@]}"; do
  for target_worker in "${WORKERS[@]}"; do
    [ "$source_worker" = "$target_worker" ] && continue
    verify_route "$source_worker" "$target_worker"
  done
done

log "Checking kernel route decisions"
for server in "${SERVERS[@]}"; do
  for worker in "${WORKERS[@]}"; do
    echo "$server -> $worker (${TEST_IPS[$worker]})"
    tailscale ssh "${SSH_USER}@${server}" \
      "ip route get '${TEST_IPS[$worker]}'"
  done
done

for source_worker in "${WORKERS[@]}"; do
  for target_worker in "${WORKERS[@]}"; do
    [ "$source_worker" = "$target_worker" ] && continue
    echo "$source_worker -> $target_worker (${TEST_IPS[$target_worker]})"
    tailscale ssh "${SSH_USER}@${source_worker}" \
      "ip route get '${TEST_IPS[$target_worker]}'"
  done
done

log "Checking forwarding and local Pod routes"
for host in "${WORKERS[@]}"; do
  forwarding="$(tailscale ssh "${SSH_USER}@${host}" \
    "sysctl -n net.ipv4.ip_forward")"
  [ "$forwarding" = 1 ] || die "IPv4 forwarding is disabled on $host."
  tailscale ssh "${SSH_USER}@${host}" \
    "ip route show '${WORKER_SUBNETS[$host]}' || true"
done

log "Pod network routing completed"
for server in "${SERVERS[@]}"; do
  for worker in "${WORKERS[@]}"; do
    echo "$server: ${WORKER_SUBNETS[$worker]} -> ${WORKER_IPS[$worker]}"
  done
done
for source_worker in "${WORKERS[@]}"; do
  for target_worker in "${WORKERS[@]}"; do
    [ "$source_worker" = "$target_worker" ] && continue
    echo "$source_worker: ${WORKER_SUBNETS[$target_worker]} -> ${WORKER_IPS[$target_worker]}"
  done
done
