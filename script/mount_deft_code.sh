#!/usr/bin/env bash
# NFS export on mn0 and mount /deft_code on all cluster nodes.
set -euo pipefail

NFS_PATH="${1:-/deft_code}"
SERVER_NODE="${2:-mn0}"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
SSH_USER="${SUDO_USER:-$USER}"
SERVER_MOUNT_TARGET="${SERVER_NODE}"

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

get_ssh_target() {
    local short_node="$1"
    local map_file
    local fqdn

    for map_file in /var/emulab/boot/hostmap /etc/hosts; do
        if [[ -f "${map_file}" ]]; then
            fqdn=$(awk -v n="$short_node" '
                $0 ~ ("(^|[[:space:]])" n "([[:space:]]|$)") {
                    for (i = 2; i <= NF; i++) {
                        if ($i ~ /\.cloudlab\.us$/) {
                            print $i
                            exit
                        }
                    }
                }
            ' "${map_file}")
            if [[ -n "${fqdn}" ]]; then
                echo "${fqdn}"
                return 0
            fi
        fi
    done

    # Fallback to short node name.
    echo "${short_node}"
}

can_reach_ssh_port() {
    local host="$1"
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/22" >/dev/null 2>&1
}

pick_reachable_target() {
    local short_node="$1"
    local fqdn
    fqdn="$(get_ssh_target "${short_node}")"
    if can_reach_ssh_port "${fqdn}"; then
        echo "${fqdn}"
        return 0
    fi
    if can_reach_ssh_port "${short_node}"; then
        echo "${short_node}"
        return 0
    fi
    return 1
}

get_lan_ip_for_node() {
    local node="$1"
    local mn_count="$2"
    if [[ "${node}" =~ ^mn([0-9]+)$ ]]; then
        echo "10.10.1.$((BASH_REMATCH[1] + 1))"
        return 0
    fi
    if [[ "${node}" =~ ^cn([0-9]+)$ ]]; then
        echo "10.10.1.$((mn_count + BASH_REMATCH[1] + 1))"
        return 0
    fi
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
MN_COUNT=0
for node in "${ALL_NODES[@]}"; do
    if [[ "${node}" =~ ^mn[0-9]+$ ]]; then
        MN_COUNT=$((MN_COUNT + 1))
    fi
done
CLIENT_NODES=()
for node in "${ALL_NODES[@]}"; do
    if [[ "${node}" != "${SERVER_NODE}" ]]; then
        CLIENT_NODES+=("${node}")
    fi
done

# Prefer experiment-LAN IP for NFS mount target when available.
if lan_ip="$(get_lan_ip_for_node "${SERVER_NODE}" "${MN_COUNT}")"; then
    SERVER_MOUNT_TARGET="${lan_ip}"
fi

if [[ "${#CLIENT_NODES[@]}" -eq 0 ]]; then
    echo "warning: no client nodes found in /etc/hosts"
    exit 0
fi

echo "[3/4] mounting ${NFS_PATH} on client nodes..."
for node in "${CLIENT_NODES[@]}"; do
    target=""
    if target="$(pick_reachable_target "${node}")"; then
        :
    else
        # Fall back to deterministic experiment-LAN IPs from profile numbering.
        if lan_ip="$(get_lan_ip_for_node "${node}" "${MN_COUNT}")" && can_reach_ssh_port "${lan_ip}"; then
            target="${lan_ip}"
        fi
    fi
    if [[ -z "${target}" ]]; then
        echo "error: cannot reach ssh port on ${node} (short/FQDN/lan-ip all failed)."
        echo "hint: check /etc/hosts and /var/emulab/boot/hostmap on mn0, and verify mn->cn ssh."
        exit 1
    fi
    echo "  -> ${node} (${SSH_USER}@${target})"
    retry 3 3 ssh ${SSH_OPTS} "${SSH_USER}@${target}" "echo ssh_ok >/dev/null"
    retry 6 5 ssh ${SSH_OPTS} "${SSH_USER}@${target}" "bash -s" -- "${SERVER_MOUNT_TARGET}" "${NFS_PATH}" <<'EOF'
set -euo pipefail
SERVER_TARGET="$1"
NFS_PATH="$2"

if ! command -v mount.nfs >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -q
    sudo apt-get install -y nfs-common
fi

sudo mkdir -p "${NFS_PATH}"

if mountpoint -q "${NFS_PATH}"; then
    SRC=$(findmnt -n -o SOURCE --target "${NFS_PATH}" || true)
    if [[ "${SRC}" != "${SERVER_TARGET}:${NFS_PATH}" ]]; then
        sudo umount "${NFS_PATH}" || true
    fi
fi

if ! mountpoint -q "${NFS_PATH}"; then
    sudo mount -t nfs "${SERVER_TARGET}:${NFS_PATH}" "${NFS_PATH}"
fi

if ! grep -qE "^[^#].*[[:space:]]${NFS_PATH}[[:space:]]nfs([[:space:]]|$)" /etc/fstab; then
    echo "${SERVER_TARGET}:${NFS_PATH} ${NFS_PATH} nfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab >/dev/null
fi
EOF
done

echo "[4/4] validation..."
echo "server exports:"
showmount -e localhost
for node in "${CLIENT_NODES[@]}"; do
    target="$(get_ssh_target "${node}")"
    ssh ${SSH_OPTS} "${SSH_USER}@${target}" "findmnt -n -o SOURCE,TARGET --target '${NFS_PATH}' || true"
done

echo "done: ${NFS_PATH} is exported from ${SERVER_NODE} and mounted on all discovered nodes."
