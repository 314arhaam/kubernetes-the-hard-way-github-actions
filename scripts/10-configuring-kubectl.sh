#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/utils.sh"

enter_repo
load_inventory
require_files ca.crt admin.crt admin.key
require_commands kubectl curl tailscale getent

log "Checking API server connectivity"
wait_for_tailnet_hosts "$PRIMARY_SERVER"
getent hosts "$API_HOST" || die "$API_HOST does not resolve."

api_ready() {
  curl --fail --silent --show-error --cacert ca.crt \
    "${API_SERVER}/version" --output /tmp/kubernetes-version.json
}

retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" "API server is not ready." \
  api_ready || die "Unable to reach $API_SERVER."
cat /tmp/kubernetes-version.json
echo

log "Configuring local kubectl"
mkdir -p "$HOME/.kube"
[ ! -f "$HOME/.kube/config" ] \
  || cp "$HOME/.kube/config" "$HOME/.kube/config.backup"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt --embed-certs=true --server="$API_SERVER"
kubectl config set-credentials admin \
  --client-certificate=admin.crt --client-key=admin.key --embed-certs=true
kubectl config set-context "$CLUSTER_NAME" \
  --cluster="$CLUSTER_NAME" --user=admin
kubectl config use-context "$CLUSTER_NAME"
chmod 600 "$HOME/.kube/config"

log "Verifying cluster access"
kubectl config current-context
kubectl version
kubectl get nodes -o wide

log "Checking worker registration and readiness"
for host in "${WORKERS[@]}"; do
  registered="$(kubectl get node "$host" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
  [ "$registered" = "$host" ] || die "$host is not registered."

  ready="$(kubectl get node "$host" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  if [ "$ready" != True ]; then
    kubectl describe node "$host" || true
    die "$host is not Ready."
  fi
  echo "$host is Ready."
done

log "kubectl remote access configured"
echo "Kubeconfig: $HOME/.kube/config"
echo "Cluster: $CLUSTER_NAME"
echo "API server: $API_SERVER"
printf 'Worker: %s Ready\n' "${WORKERS[@]}"
