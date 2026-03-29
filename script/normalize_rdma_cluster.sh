#!/usr/bin/env bash
set -euo pipefail

# Normalize RDMA stack across CloudLab nodes and refresh DEFT config.
# Run on mn0:
#   cd /deft_code/deft/script
#   ./normalize_rdma_cluster.sh
# Optional:
#   ./normalize_rdma_cluster.sh mn0 cn0 cn1

SSH_USER="${SSH_USER:-$USER}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

OFED_VER="${OFED_VER:-4.9-5.1.0.0}"
OFED_OS="${OFED_OS:-ubuntu20.04}"
REPO_BASE="http://linux.mellanox.com/public/repo/mlnx_ofed/${OFED_VER}/${OFED_OS}/x86_64"

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

id_from_dev() {
  local dev="$1"
  if [[ "$dev" =~ ^mlx5_([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$dev" =~ f([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
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

echo "== [1/6] Install consistent OFED packages on all nodes =="
for n in "${NODES[@]}"; do
  echo "-- ${n}"
  run_remote "${n}" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
OFED_VER="${OFED_VER}"
OFED_OS="${OFED_OS}"
REPO_BASE="${REPO_BASE}"

sudo apt-get update -q
sudo apt-get install -y --no-install-recommends \
  dkms build-essential "linux-headers-\$(uname -r)" \
  ca-certificates wget

sudo rm -f /etc/apt/sources.list.d/mlnx_ofed.list
sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<EOF
deb [trusted=yes] \${REPO_BASE}/MLNX_LIBS ./
EOF

# Newer MLNX mirrors may not expose COMMON for this OFED version.
sudo apt-get -o Acquire::AllowInsecureRepositories=true update -q
sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
  libibverbs1 libibverbs-dev ibverbs-utils \
  librdmacm1 librdmacm-dev \
  libmlx5-1 libmlx5-dev \
  libibumad3 libibumad-dev libibmad5 libibmad-dev infiniband-diags \
  mlnx-ofed-kernel-dkms --allow-unauthenticated || true

sudo ldconfig
REMOTE
done

echo "== [2/6] Reboot all nodes =="
for n in "${NODES[@]}"; do
  echo "rebooting ${n}"
  run_remote "${n}" "sudo reboot" || true
done

echo "== [3/6] Wait for SSH on all nodes =="
sleep 8
for n in "${NODES[@]}"; do
  printf 'waiting %-8s ' "${n}"
  ready=0
  for _ in $(seq 1 90); do
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${n}" "true" >/dev/null 2>&1; then
      ready=1
      break
    fi
    printf '.'
    sleep 2
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo
    echo "error: ${n} did not come back after reboot"
    exit 1
  fi
  echo " ok"
done

echo "== [4/6] Collect per-node RDMA device for 10.10.1.x =="
declare -A NODE_DEV=()
declare -A NODE_ID=()

for n in "${NODES[@]}"; do
  echo "-- ${n}"
  run_remote "${n}" "uname -r; ofed_info -s || true"
  run_remote "${n}" "modinfo mlx5_ib | egrep '^version:|^srcversion:' || true"
  run_remote "${n}" "ibv_devinfo -l || true"

  dev="$(run_remote "${n}" "show_gids | awk '/10\\.10\\.1\\./ {print \$1; exit}'" | awk 'NF{print $1; exit}')"
  if [[ -z "${dev}" ]]; then
    echo "error: cannot detect RDMA verbs device carrying 10.10.1.x on ${n}"
    exit 1
  fi

  if ! rid="$(id_from_dev "${dev}")"; then
    echo "error: unable to infer rnic_id from verbs device '${dev}' on ${n}"
    exit 1
  fi

  NODE_DEV["${n}"]="${dev}"
  NODE_ID["${n}"]="${rid}"
  echo "selected: dev=${dev} rnic_id=${rid}"
done

echo "== [5/6] Ensure one common rnic_id across cluster =="
COMMON_ID=""
for n in "${NODES[@]}"; do
  echo "${n}: dev=${NODE_DEV[${n}]} id=${NODE_ID[${n}]}"
  if [[ -z "${COMMON_ID}" ]]; then
    COMMON_ID="${NODE_ID[${n}]}"
  elif [[ "${COMMON_ID}" != "${NODE_ID[${n}]}" ]]; then
    echo "error: nodes do not share one numeric rnic_id"
    echo "hint: DEFT currently uses one global rnic_id; add per-node mapping in config/code if needed."
    exit 2
  fi
done
echo "common rnic_id=${COMMON_ID}"

if [[ ! -f "${CFG}" ]]; then
  echo "error: missing ${CFG}; run python3 ${ROOT}/script/gen_config.py first"
  exit 1
fi

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

echo "== [6/6] RDMA pingpong sanity (mn0 <-> cn0 if present) =="
if [[ -n "${NODE_DEV[mn0]:-}" && -n "${NODE_DEV[cn0]:-}" ]]; then
  MN_DEV="${NODE_DEV[mn0]}"
  CN0_DEV="${NODE_DEV[cn0]}"
  run_remote "mn0" "pkill -f ibv_rc_pingpong || true"
  run_remote "cn0" "pkill -f ibv_rc_pingpong || true"
  run_remote "mn0" "nohup timeout 25 ibv_rc_pingpong -d ${MN_DEV} -i 1 -g 3 >/tmp/pp_srv.log 2>&1 &"
  sleep 2
  run_remote "cn0" "timeout 25 ibv_rc_pingpong -d ${CN0_DEV} -i 1 -g 3 10.10.1.1 >/tmp/pp_cli.log 2>&1; echo client_rc:\$?"
  run_remote "mn0" "tail -n 40 /tmp/pp_srv.log || true"
  run_remote "cn0" "tail -n 40 /tmp/pp_cli.log || true"
else
  echo "skipped pingpong: mn0/cn0 device map unavailable"
fi

echo "done"
echo "next: cd ${ROOT}/script && python3 run_bench.py --smoke"
