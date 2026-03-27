#!/bin/bash
# Run on mn0 to prep build + SSH connectivity for benchmark scripts.
set -euo pipefail

LOG_FILE=/tmp/cloudlab_setup.log
exec > >(tee -a "$LOG_FILE") 2>&1

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

version_ge() {
    # Returns success when $1 >= $2
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" == "$1" ]]
}

has_exp_verbs_api() {
    [[ -f /usr/include/infiniband/verbs_exp.h ]] && grep -q "ibv_exp_dct" /usr/include/infiniband/verbs_exp.h
}

has_ofed_49() {
    command -v ofed_info >/dev/null 2>&1 && ofed_info -s 2>/dev/null | grep -q "MLNX_OFED_LINUX-4.9-5.1.0.0"
}

ensure_rdma_userspace() {
    local ofed_ver="4.9-5.1.0.0"
    local ofed_dir="MLNX_OFED_LINUX-${ofed_ver}-ubuntu18.04-x86_64"
    local ofed_tgz="${ofed_dir}.tgz"
    local ofed_url_primary="https://linux.mellanox.com/public/repo/mlnx_ofed/${ofed_ver}/ubuntu18.04-x86_64/${ofed_tgz}"
    local ofed_url_fallback="http://content.mellanox.com/ofed/MLNX_OFED-${ofed_ver}/${ofed_tgz}"

    if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
        echo "rdma userspace already present; skipping install."
        return 0
    fi

    # If OFED 4.9 is already installed, do not reinstall it in setup.
    # Try a lightweight refresh, then fail with guidance if still incomplete.
    if has_ofed_49; then
        echo "MLNX_OFED 4.9 already installed; skipping reinstall."
        sudo /etc/init.d/openibd restart || true
        sudo ldconfig || true
        if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
            return 0
        fi
        echo "existing OFED install is present but rdma tools/headers are incomplete."
        return 1
    fi

    echo "rdma userspace incomplete; installing distro rdma tools..."
    retry 3 10 sudo apt-get install -y rdma-core ibverbs-utils infiniband-diags || true
    if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
        echo "rdma userspace fixed by distro packages; skipping OFED install."
        return 0
    fi

    echo "installing MLNX OFED userspace (${ofed_ver})..."
    cd /tmp
    if [[ ! -f "${ofed_tgz}" ]]; then
        retry 3 10 wget -q -L -O "${ofed_tgz}" "${ofed_url_primary}" \
            || retry 3 10 wget -q -L -O "${ofed_tgz}" "${ofed_url_fallback}" \
            || return 1
    fi
    rm -rf "${ofed_dir}"
    tar xzf "${ofed_tgz}"
    cd "${ofed_dir}"
    sudo ./mlnxofedinstall --user-space-only --force --without-fw-update --skip-repo || return 1
    sudo /etc/init.d/openibd restart || true
    sudo ldconfig

    command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api
}

ensure_modern_cmake() {
    local min_ver="3.12.0"
    local install_ver="3.28.6"
    local arch
    local cmake_ver
    local tgz
    local url
    local install_dir

    if command -v cmake >/dev/null 2>&1; then
        cmake_ver="$(cmake --version | awk 'NR==1{print $3}')"
        if version_ge "$cmake_ver" "$min_ver"; then
            echo "cmake ${cmake_ver} is sufficient."
            return 0
        fi
        echo "cmake ${cmake_ver} is too old for C++20; upgrading..."
    else
        echo "cmake not found; installing..."
    fi

    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)
            echo "error: unsupported architecture for cmake bootstrap: $arch"
            return 1
            ;;
    esac

    install_dir="/opt/cmake-${install_ver}-linux-${arch}"
    tgz="cmake-${install_ver}-linux-${arch}.tar.gz"
    url="https://github.com/Kitware/CMake/releases/download/v${install_ver}/${tgz}"

    if [[ ! -d "$install_dir" ]]; then
        cd /tmp
        retry 3 10 wget -q -L -O "$tgz" "$url"
        sudo mkdir -p /opt
        sudo tar -xzf "$tgz" -C /opt
    fi

    sudo ln -sfn "${install_dir}/bin/cmake" /usr/local/bin/cmake
    sudo ln -sfn "${install_dir}/bin/ctest" /usr/local/bin/ctest
    sudo ln -sfn "${install_dir}/bin/cpack" /usr/local/bin/cpack
    hash -r || true

    cmake_ver="$(cmake --version | awk 'NR==1{print $3}')"
    if ! version_ge "$cmake_ver" "$min_ver"; then
        echo "error: cmake upgrade failed (found ${cmake_ver}, need >= ${min_ver})."
        return 1
    fi
}

ensure_modern_gcc() {
    if command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1; then
        echo "gcc-10/g++-10 already present."
        return 0
    fi

    if apt-cache show g++-10 >/dev/null 2>&1 && apt-cache show gcc-10 >/dev/null 2>&1; then
        echo "installing gcc-10/g++-10 from current apt sources..."
        retry 5 10 sudo apt-get install -y gcc-10 g++-10
    fi

    if command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1; then
        return 0
    fi

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == 18.04 ]]; then
            echo "enabling ubuntu-toolchain-r/test PPA for gcc-10 on Ubuntu 18.04..."
            retry 5 10 sudo apt-get install -y software-properties-common
            sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
            retry 5 10 sudo apt-get update -q
            retry 5 10 sudo apt-get install -y gcc-10 g++-10
        fi
    fi

    command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1
}

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: please run on mn0"
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "detected OS: ${PRETTY_NAME:-unknown}"
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn "$REAL_USER")
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DEFT_ROOT=/deft_code/deft

echo "[1/6] installing packages on mn0..."
export DEBIAN_FRONTEND=noninteractive
REQ_PKGS=(
    nfs-kernel-server cmake gcc g++
    libgflags-dev libnuma-dev numactl memcached libmemcached-dev
    libboost-all-dev autoconf automake libtool build-essential
    python3-paramiko python3-yaml rsync wget software-properties-common
)
MISSING_PKGS=()
for p in "${REQ_PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
        MISSING_PKGS+=("$p")
    fi
done
if [[ "${#MISSING_PKGS[@]}" -gt 0 ]]; then
    echo "installing missing packages: ${MISSING_PKGS[*]}"
    retry 5 10 sudo apt-get update -q
    retry 5 10 sudo apt-get install -y "${MISSING_PKGS[@]}"
else
    echo "all base packages already installed; skipping apt install."
fi

if ! ensure_modern_cmake; then
    echo "error: unable to install a modern cmake version."
    exit 1
fi
if ! ensure_modern_gcc; then
    echo "error: unable to install gcc-10/g++-10 required for C++20."
    exit 1
fi

echo "[2/6] checking rdma..."
if ! ensure_rdma_userspace; then
    echo "error: rdma userspace is still incomplete (missing ibv_devinfo or ibv_exp_* headers)."
    exit 1
fi

if ibv_devinfo -l | grep -Eq '^[[:space:]]*[1-9][0-9]* HCAs found'; then
    echo "ok: rdma device found"
else
    echo "warning: no rdma device found in ibv_devinfo output."
fi

echo "[3/6] syncing repository to ${DEFT_ROOT}..."
sudo mkdir -p "$DEFT_ROOT"
sudo chown "$REAL_USER:$REAL_GROUP" /deft_code "$DEFT_ROOT"

if [[ -d /local/repository/.git ]]; then
    sudo rsync -a --update --exclude build /local/repository/ "$DEFT_ROOT"/
elif [[ -f CMakeLists.txt ]]; then
    sudo rsync -a --update --exclude build ./ "$DEFT_ROOT"/
else
    echo "error: cannot find repo source. expected /local/repository or current repo root."
    exit 1
fi

sudo chown -R "$REAL_USER:$REAL_GROUP" "$DEFT_ROOT"
cd "$DEFT_ROOT"

echo "[4/6] ensuring cityhash..."
if ! ldconfig -p | grep -q libcityhash; then
    cd /tmp
    if [[ ! -d cityhash ]]; then
        git clone https://github.com/google/cityhash.git
    fi
    cd cityhash
    autoreconf -if
    ./configure
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
fi

echo "[5/6] building deft..."
if command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1; then
    export CC=gcc-10
    export CXX=g++-10
else
    export CC=gcc
    export CXX=g++
fi
mkdir -p "$DEFT_ROOT/build"
cd "$DEFT_ROOT/build"
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j"$(nproc)"
test -x ./server
test -x ./client

echo "[6/6] preparing passwordless ssh from ${REAL_USER}..."
sudo -u "$REAL_USER" mkdir -p "${REAL_HOME}/.ssh"
sudo -u "$REAL_USER" chmod 700 "${REAL_HOME}/.ssh"

if [[ ! -f "${REAL_HOME}/.ssh/id_rsa" ]]; then
    sudo -u "$REAL_USER" ssh-keygen -m PEM -t rsa -b 4096 -N "" -f "${REAL_HOME}/.ssh/id_rsa"
fi

PUB_KEY=$(sudo -u "$REAL_USER" cat "${REAL_HOME}/.ssh/id_rsa.pub")
sudo -u "$REAL_USER" touch "${REAL_HOME}/.ssh/authorized_keys"
sudo -u "$REAL_USER" chmod 600 "${REAL_HOME}/.ssh/authorized_keys"
if ! sudo -u "$REAL_USER" grep -qxF "$PUB_KEY" "${REAL_HOME}/.ssh/authorized_keys"; then
    printf '%s\n' "$PUB_KEY" | sudo -u "$REAL_USER" tee -a "${REAL_HOME}/.ssh/authorized_keys" >/dev/null
fi

mapfile -t CLUSTER_NODES < <(grep -oE '\b(mn|cn)[0-9]+\b' /etc/hosts | sort -u)
SSH_FAIL=()
for node in "${CLUSTER_NODES[@]}"; do
    if [[ "$node" == "mn0" ]]; then
        continue
    fi
    if ! sudo -u "$REAL_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "$node" "hostname >/dev/null"; then
        SSH_FAIL+=("$node")
    fi
done

if [[ "${#SSH_FAIL[@]}" -gt 0 ]]; then
    echo "error: passwordless ssh from mn0 failed for: ${SSH_FAIL[*]}"
    echo "hint: make sure all nodes share authorized_keys, then rerun this script."
    exit 1
fi

echo "done. build + ssh checks passed."
echo "next: cd /deft_code/deft/script && python3 gen_config.py && ./cloudlab_run.sh --smoke"
