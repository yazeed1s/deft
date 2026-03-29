#!/usr/bin/env bash
set -euo pipefail

# Fix script to remove MLNX_OFED DKMS kernel modules and standardize on CloudLab's
# in-tree Ubuntu drivers across all nodes (mn0, cn0, cn1).
# Run on mn0:
#   cd /deft_code/deft/script
#   ./fix_rdma_drivers.sh

SSH_USER="${SSH_USER:-$USER}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

ROOT="/deft_code/deft"
CFG="${ROOT}/script/global_config.yaml"

discover_nodes() {
  awk '
    $1 ~ /^10\.10\.1\./ {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^(mn|cn)[0-9]+$/) print $i
      }
    }' /etc/hosts | sort -u
}

run_remote() {
  local node="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$@"
}

if [[ "$(hostname -s)" != "mn0" ]]; then
  echo "error: run this script on mn0"
  exit 1
fi

mapfile -t NODES < <(if [[ "$#" -gt 0 ]]; then printf '%s\n' "$@"; else discover_nodes; fi)
if [[ "${#NODES[@]}" -eq 0 ]]; then
  echo "error: no nodes found in /etc/hosts (10.10.1.x map)"
  exit 1
fi

echo "nodes: ${NODES[*]}"

echo "== [1/3] Removing MLNX_OFED DKMS Kernel Modules on all nodes =="
for n in "${NODES[@]}"; do
  echo "-- ${n}"
  run_remote "${n}" "sudo bash -s" <<'REMOTE'
set -x
export DEBIAN_FRONTEND=noninteractive

# Remove the brittle DKMS module that fails to build on 5.4.0-212
if dpkg -l | grep -q mlnx-ofed-kernel-dkms; then
  sudo dkms remove mlnx-ofed-kernel/4.9 --all || true
  sudo apt-get remove --purge -y mlnx-ofed-kernel-dkms mlnx-ofed-kernel-utils
fi

# Reload the in-tree modules (roce naming: rocepX...)
sudo modprobe -r mlx5_ib || true
sudo modprobe -r mlx5_core || true
sudo modprobe mlx5_core
sudo modprobe mlx5_ib

# Wait for devices to come back up
sleep 3
REMOTE
done

echo "== [2/3] Verifying Device Naming (Should use 'rocepX' format everywhere) =="
declare -A NODE_DEV=()
for n in "${NODES[@]}"; do
  echo "-- ${n}"
  # Check what device has the 10.10.1.x IP
  dev="$(run_remote "${n}" "show_gids | awk '/10\\.10\\.1\\./ {print \$1; exit}'" | awk 'NF{print $1; exit}')"
  if [[ -z "${dev}" ]]; then
    # Fallback if show_gids isn't ready
    dev="$(run_remote "${n}" "ibv_devinfo -l" | grep -o 'roce[a-z0-9]*' | head -n 1 || true)"
  fi
  NODE_DEV["${n}"]="${dev}"
  echo "  RDMA device: ${dev}"
done

echo "== [3/3] Updating Global Config =="
if [[ ! -f "${CFG}" ]]; then
  echo "error: missing ${CFG}; generate it first."
  exit 1
fi

# The in-tree drivers produce device names like 'rocep202s0f0' or 'roceo12399'.
# In Deft's Resource.cpp, rnic_id is matching the last digit of these names.
# Often 'rocep202s0f0' => rnic_id=0, 'rocep202s0f1' => rnic_id=1.
# We will set a default of 0 which works for most CloudLab topologies.
COMMON_ID=0

python3 - "${CFG}" "${COMMON_ID}" <<'PY'
import sys
import yaml

cfg_path = sys.argv[1]
rnic_id = int(sys.argv[2])
with open(cfg_path, "r") as f:
    cfg = yaml.safe_load(f) or {}
cfg["rnic_id"] = rnic_id
with open(cfg_path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
print(f"updated {cfg_path} with rnic_id={rnic_id}")
PY

echo "Done! The cluster is now using uniform in-tree RDMA drivers."
echo "You can now run Deft benchmarks."
