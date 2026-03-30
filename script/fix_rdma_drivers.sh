#!/usr/bin/env bash
set -euo pipefail

# Rebuild RDMA stack for Ubuntu 20.04 CloudLab nodes and sync Deft rnic_id.
# Run on mn0:
#   cd /deft_code/deft/script
#   ./fix_rdma_drivers.sh
# Optional:
#   ROOT=/deft_code/deft ./fix_rdma_drivers.sh mn0 cn0 cn1

SSH_USER="${SSH_USER:-${SUDO_USER:-$USER}}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
ROOT="${ROOT:-/deft_code/deft}"
CFG="${ROOT}/script/global_config.yaml"

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

discover_nodes() {
  awk '
    $1 ~ /^10\.10\.1\./ {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^(mn|cn)[0-9]+$/) print $i
      }
    }
  ' /etc/hosts | sort -u
}

run_remote() {
  local node="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$@"
}

if [[ "$(hostname -s)" != "mn0" ]]; then
  log "warning: expected to run on mn0 (current: $(hostname -s))"
fi

mapfile -t NODES < <(
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
  else
    discover_nodes
  fi
)

if [[ "${#NODES[@]}" -eq 0 ]]; then
  echo "error: no nodes found (pass nodes explicitly or fix /etc/hosts)"
  exit 1
fi

log "nodes: ${NODES[*]}"

log "[1/4] Purging stale OFED bits and reinstalling Ubuntu RDMA userspace"
for n in "${NODES[@]}"; do
  log "-- ${n}"
  run_remote "${n}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if command -v mlnxofeduninstall >/dev/null 2>&1; then
  sudo mlnxofeduninstall --force || true
fi

OLD_PKGS="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | \
  grep -E '^(mlnx-ofed|mlnx-fw-updater|ofed-|openibd|mstflint)' || true)"
if [[ -n "${OLD_PKGS}" ]]; then
  sudo apt-get purge -y ${OLD_PKGS} || true
fi

sudo rm -f /etc/apt/sources.list.d/mlnx_ofed.list || true
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  rdma-core ibverbs-utils ibverbs-providers \
  libibverbs1 libibverbs-dev \
  librdmacm1 librdmacm-dev \
  infiniband-diags

sudo modprobe ib_uverbs || true
sudo modprobe rdma_cm || true
sudo modprobe mlx5_core || true
sudo modprobe mlx5_ib || true
REMOTE

done

log "[2/4] Validating verbs stack on each node"
for n in "${NODES[@]}"; do
  log "-- ${n}"
  run_remote "${n}" "bash -lc '
    echo hostname: \\$(hostname -s)
    ibv_devinfo -l || true
    show_gids 2>/dev/null | sed -n "1,40p" || true
    ldconfig -p | egrep "libibverbs|libmlx5|librdmacm" || true
  '"
done

detect_rnic_id_remote() {
  local node="$1"
  run_remote "${node}" "bash -lc '
    dev=\\$(show_gids 2>/dev/null | awk "/10\\.10\\.1\\./{print \\\$1; exit}")
    if [[ -z \\\"\\${dev}\\\" ]]; then
      dev=\\$(ibv_devinfo -l 2>/dev/null | awk "NF{print \\\$1; exit}")
    fi

    if [[ \\\"\\${dev}\\\" =~ _([0-9]+)\\$ ]]; then
      echo \\\"\\${BASH_REMATCH[1]}\\\"
    elif [[ \\\"\\${dev}\\\" =~ f([0-9]+)\\$ ]]; then
      echo \\\"\\${BASH_REMATCH[1]}\\\"
    else
      echo 0
    fi
  '" | tr -d '[:space:]'
}

log "[3/4] Computing rnic_id"
declare -A COUNT=()
declare -A NODE_ID=()
for n in "${NODES[@]}"; do
  id="$(detect_rnic_id_remote "$n")"
  [[ -z "$id" ]] && id=0
  NODE_ID["$n"]="$id"
  COUNT["$id"]=$(( ${COUNT["$id"]:-0} + 1 ))
  log "  ${n}: rnic_id candidate=${id}"
done

BEST_ID=0
BEST_COUNT=-1
for id in "${!COUNT[@]}"; do
  if (( COUNT[$id] > BEST_COUNT )); then
    BEST_COUNT=${COUNT[$id]}
    BEST_ID=$id
  fi
done

log "selected rnic_id=${BEST_ID} (majority across nodes)"

if [[ ! -f "${CFG}" ]]; then
  log "warning: ${CFG} not found; generating config first"
  if [[ -x "${ROOT}/script/gen_config.py" ]]; then
    python3 "${ROOT}/script/gen_config.py"
  else
    echo "error: missing ${ROOT}/script/gen_config.py"
    exit 1
  fi
fi

log "[4/4] Writing rnic_id to ${CFG}"
python3 - "${CFG}" "${BEST_ID}" <<'PY'
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

log "done. next: python3 ${ROOT}/script/run_bench.py --smoke"
