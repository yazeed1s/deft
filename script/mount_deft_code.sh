#!/usr/bin/env bash
# Configure NFS export on mn0 and mount /deft_code on all cluster nodes.
set -euo pipefail

NFS_PATH="${1:-/deft_code}"
SERVER_NODE="${2:-mn0}"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

retry() {
    local attempts="$1"
    local sleep_s="$2"
    shift 2
    local i
    for i in $(seq 1 "$attempts"); do
        if "$@"; then
            return 0
        fi
        echo "retry $i/$attempts failed: $*"
        sleep "$sleep_s"
    done
    return 1
}

if [[ "$(hostname)" != "${SERVER_NODE}" && "$(hostname)" != "${SERVER_NODE}."* ]]; then
    echo "error: run this script on ${SERVER_NODE}"
    exit 1
fi

echo "[1/4] preparing NFS server on ${SERVER_NODE} (${NFS_PATH})..."
export DEBIAN_FRONTEND=noninteractive
retry 5 10 sudo apt-get update -q
retry 5 10 sudo apt-get install -y nfs-kernel-server nfs-common

sudo mkdir -p "${NFS_PATH}"
sudo chmod 777 "${NFS_PATH}"
if ! grep -qE "^[[:space:]]*${NFS_PATH}[[:space:]]" /etc/exports; then
    echo "${NFS_PATH} *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports >/dev/null
fi
sudo exportfs -arv
sudo systemctl enable rpcbind nfs-kernel-server >/dev/null 2>&1 || true
sudo systemctl restart rpcbind nfs-kernel-server

if ! showmount -e localhost | grep -q "${NFS_PATH}"; then
    echo "error: export not visible in showmount output"
    exit 1
fi

echo "[2/4] discovering cluster nodes..."
mapfile -t ALL_NODES < <(grep -oE '\b(mn|cn)[0-9]+\b' /etc/hosts | sort -u)
CLIENT_NODES=()
for node in "${ALL_NODES[@]}"; do
    if [[ "${node}" != "${SERVER_NODE}" ]]; then
        CLIENT_NODES+=("${node}")
    fi
done

if [[ "${#CLIENT_NODES[@]}" -eq 0 ]]; then
    echo "warning: no client nodes found in /etc/hosts"
    exit 0
fi

echo "[3/4] mounting ${NFS_PATH} on client nodes..."
for node in "${CLIENT_NODES[@]}"; do
    echo "  -> ${node}"
    retry 3 5 ssh ${SSH_OPTS} "${node}" "bash -s" -- "${SERVER_NODE}" "${NFS_PATH}" <<'EOF'
set -euo pipefail
SERVER_NODE="$1"
NFS_PATH="$2"
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -q >/dev/null
sudo apt-get install -y nfs-common >/dev/null

sudo mkdir -p "${NFS_PATH}"

if mountpoint -q "${NFS_PATH}"; then
    SRC=$(findmnt -n -o SOURCE --target "${NFS_PATH}" || true)
    if [[ "${SRC}" != "${SERVER_NODE}:${NFS_PATH}" ]]; then
        sudo umount "${NFS_PATH}" || true
    fi
fi

if ! mountpoint -q "${NFS_PATH}"; then
    sudo mount -t nfs "${SERVER_NODE}:${NFS_PATH}" "${NFS_PATH}"
fi

if ! grep -qE "^[^#].*[[:space:]]${NFS_PATH}[[:space:]]nfs([[:space:]]|$)" /etc/fstab; then
    echo "${SERVER_NODE}:${NFS_PATH} ${NFS_PATH} nfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab >/dev/null
fi
EOF
done

echo "[4/4] validation..."
echo "server exports:"
showmount -e localhost
for node in "${CLIENT_NODES[@]}"; do
    ssh ${SSH_OPTS} "${node}" "findmnt -n -o SOURCE,TARGET --target '${NFS_PATH}' || true"
done

echo "done: ${NFS_PATH} is exported from ${SERVER_NODE} and mounted on all discovered nodes."
