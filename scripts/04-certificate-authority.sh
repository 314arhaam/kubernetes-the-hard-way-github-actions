#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

require_commands openssl tailscale awk sed grep
enter_repo
load_inventory
require_files ca.conf

log "Checking machine connectivity"
wait_for_tailnet_hosts "${ALL_HOSTS[@]}"
wait_for_tailscale_ssh "${ALL_HOSTS[@]}"

log "Generating certificate authority"
rm -f ./*.crt ./*.key ./*.csr ./ca.srl

openssl genrsa -out ca.key 4096
openssl req -x509 -new -sha512 -noenc -key ca.key -days 3653 \
  -config ca.conf -out ca.crt
openssl x509 -in ca.crt -noout -subject -issuer -dates

component_certs=(
  admin
  kube-proxy
  kube-scheduler
  kube-controller-manager
  service-accounts
)

log "Generating component certificates"
for cert in "${component_certs[@]}"; do
  openssl genrsa -out "${cert}.key" 4096
  openssl req -new -key "${cert}.key" -sha256 -config ca.conf \
    -section "$cert" -out "${cert}.csr"
  openssl x509 -req -days 3653 -in "${cert}.csr" \
    -copy_extensions copyall -sha256 -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out "${cert}.crt"
done

log "Generating worker certificates"
for host in "${WORKERS[@]}"; do
  ip="$(machine_ip "$host")"
  [ -n "$ip" ] || die "No IP found for worker $host."

  openssl genrsa -out "${host}.key" 4096
  openssl req -new -sha256 -key "${host}.key" \
    -subj "/C=US/ST=Washington/L=Seattle/O=system:nodes/CN=system:node:${host}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=clientAuth,serverAuth" \
    -addext "subjectAltName=DNS:${host},DNS:${host}.kubernetes.local,IP:${ip},IP:127.0.0.1" \
    -out "${host}.csr"
  openssl x509 -req -days 3653 -in "${host}.csr" \
    -copy_extensions copyall -sha256 -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out "${host}.crt"
done

log "Generating API server certificate"
api_sans="IP:127.0.0.1,IP:10.32.0.1,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster,DNS:kubernetes.svc.cluster.local,DNS:api-server.kubernetes.local"
for host in "${SERVERS[@]}"; do
  ip="$(machine_ip "$host")"
  [ -n "$ip" ] || die "No IP found for server $host."
  api_sans+=",DNS:${host},DNS:${host}.kubernetes.local,IP:${ip}"
done

openssl genrsa -out kube-api-server.key 4096
openssl req -new -sha256 -key kube-api-server.key \
  -subj "/C=US/ST=Washington/L=Seattle/CN=kubernetes" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=clientAuth,serverAuth" \
  -addext "subjectAltName=${api_sans}" \
  -out kube-api-server.csr
openssl x509 -req -days 3653 -in kube-api-server.csr \
  -copy_extensions copyall -sha256 -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out kube-api-server.crt

all_certs=(
  "${component_certs[@]}"
  "${WORKERS[@]}"
  kube-api-server
)

log "Validating certificates"
for cert in "${all_certs[@]}"; do
  openssl verify -CAfile ca.crt "${cert}.crt"
done

log "Installing worker certificates"
for host in "${WORKERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" "mkdir -p /var/lib/kubelet"
  cat ca.crt | tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kubelet/ca.crt"
  cat "${host}.crt" | tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kubelet/kubelet.crt"
  cat "${host}.key" | tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kubelet/kubelet.key"
  tailscale ssh "${SSH_USER}@${host}" \
    "chmod 644 /var/lib/kubelet/ca.crt /var/lib/kubelet/kubelet.crt; chmod 600 /var/lib/kubelet/kubelet.key"
done

server_files=(
  ca.key
  ca.crt
  kube-api-server.key
  kube-api-server.crt
  service-accounts.key
  service-accounts.crt
)

log "Installing control-plane certificates"
for host in "${SERVERS[@]}"; do
  for file in "${server_files[@]}"; do
    cat "$file" | tailscale ssh "${SSH_USER}@${host}" \
      "umask 077; cat > /root/${file}"
  done

  tailscale ssh "${SSH_USER}@${host}" \
    "chmod 600 /root/ca.key /root/kube-api-server.key /root/service-accounts.key; chmod 644 /root/ca.crt /root/kube-api-server.crt /root/service-accounts.crt"
done

log "Verifying installed certificates"
for host in "${WORKERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" \
    "test -s /var/lib/kubelet/ca.crt; test -s /var/lib/kubelet/kubelet.crt; test -s /var/lib/kubelet/kubelet.key; openssl x509 -in /var/lib/kubelet/kubelet.crt -noout -subject"
done

for host in "${SERVERS[@]}"; do
  tailscale ssh "${SSH_USER}@${host}" \
    "test -s /root/ca.key; test -s /root/kube-api-server.crt; test -s /root/kube-api-server.key; test -s /root/service-accounts.crt; test -s /root/service-accounts.key; openssl x509 -in /root/kube-api-server.crt -noout -subject -issuer"
done

log "Certificate authority step completed"
echo "Worker certificates installed on: ${WORKERS[*]}"
echo "Control-plane certificates installed on: ${SERVERS[*]}"
