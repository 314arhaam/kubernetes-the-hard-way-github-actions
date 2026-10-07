#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

require_commands tailscale envsubst base64 head grep
enter_repo
load_inventory
require_files configs/encryption-config.yaml

log "Checking control-plane connectivity"
wait_for_tailnet_hosts "${SERVERS[@]}"
wait_for_tailscale_ssh "${SERVERS[@]}"

log "Generating Kubernetes data-encryption key"
export ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
[ -n "$ENCRYPTION_KEY" ] || die "Failed to generate ENCRYPTION_KEY."

envsubst < configs/encryption-config.yaml > encryption-config.yaml
[ -s encryption-config.yaml ] || die "encryption-config.yaml was not generated."

grep -q '\${ENCRYPTION_KEY}' encryption-config.yaml \
  && die "ENCRYPTION_KEY was not substituted."
grep -q EncryptionConfiguration encryption-config.yaml \
  || die "EncryptionConfiguration not found."
grep -q aescbc encryption-config.yaml || die "aescbc provider not found."

log "Installing encryption configuration"
for host in "${SERVERS[@]}"; do
  cat encryption-config.yaml | tailscale ssh "${SSH_USER}@${host}" \
    "umask 077; cat > /root/encryption-config.yaml"
  tailscale ssh "${SSH_USER}@${host}" '
    test -s /root/encryption-config.yaml
    grep -q EncryptionConfiguration /root/encryption-config.yaml
    grep -q aescbc /root/encryption-config.yaml
    chmod 600 /root/encryption-config.yaml
  '
done

log "Data-encryption configuration completed"
echo "Installed on: ${SERVERS[*]}"
echo "The encryption key was intentionally not printed."
