#!/usr/bin/env bash
set -euo pipefail

OFED_VER="${OFED_VER:-4.9-5.1.0.0}"
OS_FLAVOR="${OS_FLAVOR:-ubuntu20.04}"
ARCH="${ARCH:-x86_64}"
BASE_URL="${BASE_URL:-https://content.mellanox.com/ofed}"

TGZ="MLNX_OFED_LINUX-${OFED_VER}-${OS_FLAVOR}-${ARCH}.tgz"
DIR="MLNX_OFED_LINUX-${OFED_VER}-${OS_FLAVOR}-${ARCH}"
URL="${BASE_URL}/MLNX_OFED-${OFED_VER}/${TGZ}"

LOG="/tmp/install_rdma_drivers.log"
exec > >(tee -a "$LOG") 2>&1

usage() {
  cat <<'EOF'
Usage:
  ./script/install_rdma_drivers.sh --local
  ./script/install_rdma_drivers.sh --cluster

Modes:
  --local    Install on the current machine only.
  --cluster  Run from mn0; install on all mn*/cn* nodes (including mn0).

Environment overrides:
  OFED_VER, OS_FLAVOR, ARCH, BASE_URL
EOF
}

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1"
    exit 1
  }
}

get_lan_ip_for_node() {
  local node="$1"
  local ip
  ip="$(awk -F'[:,]' -v n="$node" '$1==n && $2=="0"{print $3; exit}' /var/emulab/boot/hostmap 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(awk -v n="$node" '$1 ~ /^10\.10\.1\./ && $0 ~ ("(^|[[:space:]])" n "([[:space:]]|$)") {print $1; exit}' /etc/hosts 2>/dev/null || true)"
  fi
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}"
}

can_reach_ssh_port() {
  local host="$1"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/22" >/dev/null 2>&1
}

pick_reachable_ssh_target() {
  local node="$1"
  local lan_ip=""
  if can_reach_ssh_port "${node}"; then
    printf '%s\n' "${node}"
    return 0
  fi
  lan_ip="$(get_lan_ip_for_node "${node}" || true)"
  if [[ -n "${lan_ip}" ]] && can_reach_ssh_port "${lan_ip}"; then
    printf '%s\n' "${lan_ip}"
    return 0
  fi
  return 1
}

install_local() {
  local SUDO=""
  if [[ "${EUID}" -ne 0 ]]; then
    SUDO="sudo"
  fi

  need_cmd uname
  need_cmd tar
  need_cmd tee

  if command -v ofed_info >/dev/null 2>&1; then
    echo "existing OFED: $(ofed_info -s || true)"
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "detected OS: ${PRETTY_NAME:-unknown}"
  fi

  if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
    echo "error: unsupported arch $(uname -m); expected x86_64/amd64"
    exit 1
  fi

  echo "using OFED ${OFED_VER} for ${OS_FLAVOR} (${ARCH})"
  echo "download: ${URL}"

  cd /tmp

  if [[ ! -f "${TGZ}" ]]; then
    if command -v wget >/dev/null 2>&1; then
      retry 5 5 wget -q -O "${TGZ}" "${URL}"
    elif command -v curl >/dev/null 2>&1; then
      retry 5 5 curl -fL -o "${TGZ}" "${URL}"
    else
      echo "error: need wget or curl to download ${TGZ}"
      exit 1
    fi
  else
    echo "found ${TGZ} in /tmp; reusing"
  fi

  if [[ -d "${DIR}" ]]; then
    echo "removing existing /tmp/${DIR}"
    rm -rf "${DIR}"
  fi

  tar -xvf "${TGZ}"
  cd "${DIR}"

  echo "installing OFED (log: ${LOG})"
  ${SUDO} ./mlnxofedinstall

  if [[ -x /etc/init.d/openibd ]]; then
    ${SUDO} /etc/init.d/openibd restart
  else
    echo "warning: openibd not found; reboot may be required"
  fi
}

install_cluster() {
  if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: --cluster must be run on mn0"
    exit 1
  fi

  local nodes=()
  mapfile -t nodes < <(grep -oE '\b(mn|cn)[0-9]+\b' /etc/hosts | sort -u)

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "error: no nodes found in /etc/hosts"
    exit 1
  fi

  echo "cluster nodes: ${nodes[*]}"

  install_local

  local user="${SUDO_USER:-$USER}"
  local ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
  local script_path
  script_path="$(realpath "$0")"

  for node in "${nodes[@]}"; do
    if [[ "$node" == "mn0" ]]; then
      continue
    fi
    target="$(pick_reachable_ssh_target "${node}" || true)"
    if [[ -z "${target}" ]]; then
      echo "error: cannot reach ssh on ${node}"
      exit 1
    fi
    echo "installing on ${node} (${target})"
    retry 3 5 scp ${ssh_opts} "${script_path}" "${user}@${target}:/tmp/install_rdma_drivers.sh"
    retry 3 5 ssh ${ssh_opts} "${user}@${target}" \
      "OFED_VER='${OFED_VER}' OS_FLAVOR='${OS_FLAVOR}' ARCH='${ARCH}' BASE_URL='${BASE_URL}' bash /tmp/install_rdma_drivers.sh --local"
  done
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  --local)
    install_local
    ;;
  --cluster)
    install_cluster
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "done"
