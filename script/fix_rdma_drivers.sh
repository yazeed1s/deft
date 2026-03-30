#!/usr/bin/env bash
set -euo pipefail

# RDMA repair script for Deft/CloudLab.
# Deft README requires MLNX_OFED_LINUX-4.9-5.1.0.0 user-space libs.
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
log "[1/4] Enforcing MLNX_OFED 4.9 user-space stack"

for n in "${NODES[@]}"; do
  log "-- ${n}"
  run_remote "${n}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if command -v mlnxofeduninstall >/dev/null 2>&1; then
  sudo mlnxofeduninstall --force || true
fi

OFED_OS="ubuntu18.04"
if grep -q 'VERSION_ID="20.04"' /etc/os-release; then
  OFED_OS="ubuntu20.04"
fi
REPO_BASE="http://linux.mellanox.com/public/repo/mlnx_ofed/4.9-5.1.0.0/${OFED_OS}/x86_64"

sudo rm -f /etc/apt/sources.list.d/mlnx_ofed.list /etc/apt/preferences.d/*mlnx* /etc/apt/preferences.d/*ofed* || true
sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<OFEDAPT
deb [trusted=yes] ${REPO_BASE}/MLNX_LIBS ./
OFEDAPT

HELD_RDMA="$(apt-mark showhold 2>/dev/null | grep -E '(ibverbs|rdma|mlx|infiniband|openmpi|libfabric)' || true)"
if [[ -n "${HELD_RDMA}" ]]; then
  sudo apt-mark unhold ${HELD_RDMA} || true
fi

OFED_VER_PKGS="$(dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | awk '$2 ~ /(mlnx|OFED)/ {print $1}')"
if [[ -n "${OFED_VER_PKGS}" ]]; then
  sudo apt-get purge -y ${OFED_VER_PKGS} || true
fi

OLD_PKGS="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(mlnx-ofed|mlnx-fw-updater|ofed-|openibd|mstflint)' || true)"
if [[ -n "${OLD_PKGS}" ]]; then
  sudo apt-get purge -y ${OLD_PKGS} || true
fi

sudo apt-get purge -y \
  libmlx5-dev libibverbs-dev librdmacm-dev \
  libopenmpi-dev libopenmpi3 libfabric1 rdma-core ibverbs-providers || true

sudo dpkg --configure -a || true
sudo apt-get -o Acquire::AllowInsecureRepositories=true update -y
sudo apt-get -y --fix-broken install || true
sudo apt-get -y --fix-broken install || true
sudo apt-get autoremove -y || true

pick_ofed49() {
  local pkg="$1"
  apt-cache madison "$pkg" | awk '/OFED\.4\.9/ {print $3; exit}'
}

install_ofed_pkg() {
  local pkg="$1"
  local ver
  ver="$(pick_ofed49 "$pkg")"
  if [[ -n "${ver}" ]]; then
    sudo apt-get install -y --allow-unauthenticated --allow-downgrades --allow-change-held-packages "${pkg}=${ver}"
    return 0
  fi
  return 1
}

# Required runtime libs for verbs and rdma-cm.
for pkg in libibverbs1 ibverbs-utils librdmacm1; do
  if ! install_ofed_pkg "${pkg}"; then
    sudo apt-get install -y --allow-unauthenticated --allow-downgrades --allow-change-held-packages "${pkg}"
  fi
done

# Provider naming differs by repo revision; try both packages.
install_ofed_pkg libmlx5 || sudo apt-get install -y --allow-unauthenticated --allow-downgrades --allow-change-held-packages libmlx5 || true
install_ofed_pkg libmlx5-1 || sudo apt-get install -y --allow-unauthenticated --allow-downgrades --allow-change-held-packages libmlx5-1 || true

# Optional helper/dev packages used by diagnostics/builds.
for pkg in libibverbs-dev librdmacm-dev libmlx5-dev libibumad libibmad libibumad3 infiniband-diags rdma-core; do
  install_ofed_pkg "${pkg}" || sudo apt-get install -y --allow-unauthenticated --allow-downgrades --allow-change-held-packages "${pkg}" || true
done

if [[ ! -e /usr/lib/libibverbs/libmlx5-rdmav2.so && -e /lib/x86_64-linux-gnu/libmlx5.so.1 ]]; then
  sudo mkdir -p /usr/lib/libibverbs
  # Compatibility shim for mixed provider naming (rdmav2 vs libmlx5.so.1).
  sudo ln -sf /lib/x86_64-linux-gnu/libmlx5.so.1 /usr/lib/libibverbs/libmlx5-rdmav2.so
fi

sudo ldconfig
sudo modprobe ib_uverbs || true
sudo modprobe rdma_cm || true
sudo modprobe mlx5_core || true
sudo modprobe mlx5_ib || true
REMOTE
done

log "[2/4] Validating RDMA stack"
for n in "${NODES[@]}"; do
  log "-- ${n}"
  run_remote "${n}" "bash -s" <<'REMOTE'
set -euo pipefail
echo "hostname: $(hostname -s)"
export LD_LIBRARY_PATH="/usr/lib/libibverbs:/usr/lib/x86_64-linux-gnu/libibverbs:${LD_LIBRARY_PATH:-}"
ibv_devinfo -l || true
show_gids 2>/dev/null | sed -n '1,40p' || true
ldconfig -p | egrep 'libibverbs|libmlx5|librdmacm|rdmav2' || true
ls -l /usr/lib/libibverbs/libmlx5-rdmav2.so 2>/dev/null || true
REMOTE
done

detect_rnic_id_remote() {
  local node="$1"
  run_remote "${node}" "bash -s" <<'REMOTE' | tr -d '[:space:]'
set -euo pipefail

dev="$({ show_gids 2>/dev/null || true; } | awk '/10\.10\.1\./ {print $1; exit}')"
if [[ -z "${dev}" ]]; then
  dev="$({ ibv_devinfo -l 2>/dev/null || true; } | awk 'tolower($0) !~ /hcas found/ && $1 ~ /[[:alpha:]]/ {print $1; exit}')"
fi

if [[ "${dev}" =~ _([0-9]+)$ ]]; then
  echo "${BASH_REMATCH[1]}"
elif [[ "${dev}" =~ f([0-9]+)$ ]]; then
  echo "${BASH_REMATCH[1]}"
else
  echo 0
fi
REMOTE
}

log "[3/4] Selecting rnic_id"
declare -A COUNT=()
for n in "${NODES[@]}"; do
  id="$(detect_rnic_id_remote "$n")"
  [[ -z "${id}" ]] && id=0
  COUNT["${id}"]=$(( ${COUNT["${id}"]:-0} + 1 ))
  log "  ${n}: rnic_id candidate=${id}"
done

BEST_ID=0
BEST_COUNT=-1
for id in "${!COUNT[@]}"; do
  if (( COUNT["${id}"] > BEST_COUNT )); then
    BEST_COUNT=${COUNT["${id}"]}
    BEST_ID=${id}
  fi
done

log "selected rnic_id=${BEST_ID}"

if [[ ! -f "${CFG}" ]]; then
  log "${CFG} not found; generating config"
  if [[ -f "${ROOT}/script/gen_config.py" ]]; then
    python3 "${ROOT}/script/gen_config.py"
  else
    echo "error: missing ${ROOT}/script/gen_config.py"
    exit 1
  fi
fi

log "[4/4] Updating ${CFG}"
python3 - "${CFG}" "${BEST_ID}" <<'PY'
import sys
import yaml

cfg_path = sys.argv[1]
rnic_id = int(sys.argv[2])

with open(cfg_path, "r") as f:
    cfg = yaml.safe_load(f) or {}

cfg["rnic_id"] = rnic_id

with open(cfg_path, "w") as f:
    try:
        yaml.safe_dump(cfg, f, sort_keys=False)
    except TypeError:
        yaml.safe_dump(cfg, f)

print(f"updated {cfg_path} with rnic_id={rnic_id}")
PY

log "done. next: python3 ${ROOT}/script/run_bench.py --smoke"
