#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

require_root
require_commands redis-cli ssh scp tailscale awk sed grep getent sort python3
enter_repo

redis_ready() {
  [ "$(redis-cli -h "$REDIS_HOST" ping 2>/dev/null || true)" = PONG ]
}

log "Reading machine inventory from Redis"
retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" "Redis is not ready." redis_ready \
  || die "Unable to connect to Redis at $REDIS_HOST."

mapfile -t redis_servers < <(
  redis-cli --raw -h "$REDIS_HOST" HKEYS "$MASTERS_HASH" \
    | sed '/^[[:space:]]*$/d' | sort -V
)
mapfile -t redis_workers < <(
  redis-cli --raw -h "$REDIS_HOST" HKEYS "$WORKERS_HASH" \
    | sed '/^[[:space:]]*$/d' | sort -V
)

[ "${#redis_servers[@]}" -gt 0 ] || die "Redis hash '$MASTERS_HASH' is empty."
[ "${#redis_workers[@]}" -gt 0 ] || die "Redis hash '$WORKERS_HASH' is empty."
[ "${#redis_workers[@]}" -le 256 ] || die "At most 256 workers are supported."

for host in "${redis_servers[@]}" "${redis_workers[@]}"; do
  [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname in Redis inventory: $host"
done

for host in "${redis_servers[@]}"; do
  printf '%s\n' "${redis_workers[@]}" | grep -qx "$host" \
    && die "$host appears in both Redis hashes."
done

printf '%s\n' "${redis_servers[@]}" > servers.txt
printf '%s\n' "${redis_workers[@]}" > workers.txt

: > machines.txt

for host in "${redis_servers[@]}"; do
  ip="$(redis-cli --raw -h "$REDIS_HOST" HGET "$MASTERS_HASH" "$host")"
  [ -n "$ip" ] || die "No IP stored for server $host."
  python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$ip" \
    || die "Invalid IP stored for server $host: $ip"
  printf '%s %s.kubernetes.local %s\n' "$ip" "$host" "$host" \
    >> machines.txt
done

for index in "${!redis_workers[@]}"; do
  host="${redis_workers[$index]}"
  ip="$(redis-cli --raw -h "$REDIS_HOST" HGET "$WORKERS_HASH" "$host")"
  [ -n "$ip" ] || die "No IP stored for worker $host."
  python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$ip" \
    || die "Invalid IP stored for worker $host: $ip"
  printf '%s %s.kubernetes.local %s 10.200.%s.0/24\n' \
    "$ip" "$host" "$host" "$index" >> machines.txt
done

load_inventory

echo "Servers: ${SERVERS[*]}"
echo "Workers: ${WORKERS[*]}"
cat machines.txt

log "Waiting for Kubernetes machines"
wait_for_tailnet_hosts "${ALL_HOSTS[@]}"
wait_for_native_ssh "${ALL_HOSTS[@]}"

log "Configuring machine hostnames"
while read -r ip fqdn host subnet; do
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -s" <<EOF
set -euo pipefail
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i 's/^127\.0\.1\.1.*/127.0.1.1\t${fqdn} ${host}/' /etc/hosts
else
  echo -e '127.0.1.1\t${fqdn} ${host}' >> /etc/hosts
fi
hostnamectl set-hostname '${host}'
systemctl restart systemd-hostnamed
EOF
done < machines.txt

log "Verifying hostnames"
for host in "${ALL_HOSTS[@]}"; do
  echo "[$host]"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
    "hostname && hostname --fqdn"
done

log "Generating Kubernetes hosts file"
{
  echo
  echo "# Kubernetes The Hard Way"
  while read -r ip fqdn host subnet; do
    echo "$ip $fqdn $host"
  done < machines.txt
} > hosts

sed -i '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' /etc/hosts
{
  cat hosts
  echo "# End Kubernetes The Hard Way"
} >> /etc/hosts

log "Checking jumpbox hostname resolution"
for host in "${ALL_HOSTS[@]}"; do
  getent hosts "$host"
done

log "Distributing hosts file"
for host in "${ALL_HOSTS[@]}"; do
  scp "${SCP_OPTS[@]}" hosts "${SSH_USER}@${host}:/tmp/kubernetes-hosts"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "sudo bash -s" <<'EOF'
set -euo pipefail
sed -i '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' /etc/hosts
{
  echo
  echo "# Kubernetes The Hard Way"
  sed '/^$/d; /^# Kubernetes The Hard Way$/d' /tmp/kubernetes-hosts
  echo "# End Kubernetes The Hard Way"
} >> /etc/hosts
rm -f /tmp/kubernetes-hosts
EOF
done

log "Verifying cross-node hostname resolution"
for source_host in "${ALL_HOSTS[@]}"; do
  echo "[$source_host]"
  for target_host in "${ALL_HOSTS[@]}"; do
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${source_host}" \
      "getent hosts '$target_host'"
  done
done

log "Validating Redis inventory against Tailscale"
while read -r expected_ip fqdn host subnet; do
  current_ip="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
    "tailscale ip -4 | head -n1")"
  [ "$current_ip" = "$expected_ip" ] \
    || die "IP mismatch for $host: Redis=$expected_ip Tailscale=$current_ip"
  echo "$host -> $current_ip OK"
done < machines.txt

log "Compute resources are ready"
printf '%-18s %-16s %-36s %-20s\n' HOST TAILSCALE_IP FQDN POD_SUBNET
while read -r ip fqdn host subnet; do
  printf '%-18s %-16s %-36s %-20s\n' \
    "$host" "$ip" "$fqdn" "${subnet:-N/A}"
done < machines.txt
