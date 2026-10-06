#!/usr/bin/env bash

: "${REPO_DIR:=kubernetes-the-hard-way}"
: "${SSH_USER:=root}"
: "${REDIS_HOST:=redis-server-ts}"
: "${WORKERS_HASH:=workers}"
: "${MASTERS_HASH:=masters}"
: "${CLUSTER_NAME:=kubernetes-the-hard-way}"
: "${RETRY_ATTEMPTS:=60}"
: "${RETRY_DELAY:=2}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this script as root."
}

require_commands() {
  local command

  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 \
      || die "Required command not found: $command"
  done
}

require_files() {
  local file

  for file in "$@"; do
    [ -f "$file" ] || die "Missing required file: $file"
  done
}

enter_repo() {
  [ -d "$REPO_DIR" ] \
    || die "$REPO_DIR does not exist. Run the jumpbox setup first."

  cd "$REPO_DIR"
  log "Working directory"
  pwd
}

load_inventory() {
  local host i j

  require_files workers.txt servers.txt machines.txt

  mapfile -t WORKERS < <(sed 's/\r$//; /^[[:space:]]*$/d' workers.txt)
  mapfile -t SERVERS < <(sed 's/\r$//; /^[[:space:]]*$/d' servers.txt)

  [ "${#WORKERS[@]}" -gt 0 ] || die "workers.txt is empty."
  [ "${#SERVERS[@]}" -gt 0 ] || die "servers.txt is empty."

  ALL_HOSTS=("${SERVERS[@]}" "${WORKERS[@]}")

  for host in "${ALL_HOSTS[@]}"; do
    [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] \
      || die "Invalid hostname in inventory: $host"
    [ -n "$(machine_ip "$host")" ] \
      || die "$host is missing from machines.txt."
  done

  for host in "${WORKERS[@]}"; do
    [ -n "$(machine_subnet "$host")" ] \
      || die "$host has no Pod subnet in machines.txt."
  done

  for ((i = 0; i < ${#ALL_HOSTS[@]}; i++)); do
    for ((j = i + 1; j < ${#ALL_HOSTS[@]}; j++)); do
      [ "${ALL_HOSTS[$i]}" != "${ALL_HOSTS[$j]}" ] \
        || die "Duplicate hostname in inventory: ${ALL_HOSTS[$i]}"
    done
  done

  PRIMARY_SERVER="${SERVERS[0]}"
  API_HOST="${PRIMARY_SERVER}.kubernetes.local"
  API_SERVER="https://${API_HOST}:6443"
}

machine_ip() {
  awk -v host="$1" '$3 == host {print $1; exit}' machines.txt
}

machine_subnet() {
  awk -v host="$1" '$3 == host {print $4; exit}' machines.txt
}

join_by() {
  local delimiter="$1"
  shift
  local value prefix=""

  for value in "$@"; do
    printf '%s%s' "$prefix" "$value"
    prefix="$delimiter"
  done
}

etcd_endpoints() {
  local host
  local endpoints=()

  for host in "${SERVERS[@]}"; do
    endpoints+=("http://$(machine_ip "$host"):2379")
  done
  join_by , "${endpoints[@]}"
}

etcd_initial_cluster() {
  local host
  local members=()

  for host in "${SERVERS[@]}"; do
    members+=("${host}=http://$(machine_ip "$host"):2380")
  done
  join_by , "${members[@]}"
}

retry() {
  local attempts="$1"
  local delay="$2"
  local message="$3"
  local attempt
  shift 3

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    "$@" && return 0
    [ "$attempt" -lt "$attempts" ] || return 1
    echo "$message ($attempt/$attempts)"
    sleep "$delay"
  done
}

_tailnet_ready() {
  tailscale ping --timeout=2s "$1" >/dev/null 2>&1
}

_tailscale_ssh_ready() {
  tailscale ssh "${SSH_USER}@$1" "echo SSH_OK" 2>/dev/null \
    | grep -qx SSH_OK
}

_native_ssh_ready() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" "echo SSH_OK" 2>/dev/null \
    | grep -qx SSH_OK
}

wait_for_tailnet_hosts() {
  local host

  for host in "$@"; do
    echo "Waiting for Tailscale node: $host"
    retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
      "$host is not reachable yet." _tailnet_ready "$host" \
      || die "Timed out waiting for $host"
    echo "$host is reachable."
  done
}

wait_for_tailscale_ssh() {
  local host

  for host in "$@"; do
    echo "Testing Tailscale SSH to $host..."
    retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
      "SSH to $host is not ready yet." _tailscale_ssh_ready "$host" \
      || die "Unable to SSH to $host"
    echo "SSH to $host is ready."
  done
}

wait_for_native_ssh() {
  local host

  for host in "$@"; do
    echo "Testing SSH to $host..."
    retry "$RETRY_ATTEMPTS" "$RETRY_DELAY" \
      "SSH to $host is not ready yet." _native_ssh_ready "$host" \
      || die "Unable to SSH to $host"
    echo "SSH to $host is ready."
  done
}

wait_for_remote_service() {
  local host="$1"
  local service="$2"
  local status attempt

  for ((attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++)); do
    status="$(tailscale ssh "${SSH_USER}@${host}" \
      "systemctl is-active '$service' 2>/dev/null || true" || true)"

    if [ "$status" = active ]; then
      echo "$service is active on $host."
      return 0
    fi

    echo "$service on $host: ${status:-unknown} ($attempt/$RETRY_ATTEMPTS)"
    [ "$attempt" -eq "$RETRY_ATTEMPTS" ] || sleep "$RETRY_DELAY"
  done

  tailscale ssh "${SSH_USER}@${host}" "
    systemctl status '$service' --no-pager --full || true
    journalctl -u '$service' --no-pager -n 150 || true
  "
  die "$service did not become active on $host"
}
