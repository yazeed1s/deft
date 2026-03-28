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

install_ofed_via_apt() {
    local ofed_ver="$1"
    local ofed_os="$2"
    local repo_base="http://linux.mellanox.com/public/repo/mlnx_ofed/${ofed_ver}/${ofed_os}/x86_64"

    echo "installing MLNX_OFED ${ofed_ver} via apt repository..."
    echo "  repo: ${repo_base}/MLNX_LIBS"

    # Add MLNX_OFED apt sources
    sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<APTEOF
deb [trusted=yes] ${repo_base}/MLNX_LIBS ./
deb [trusted=yes] ${repo_base}/COMMON ./
APTEOF

    retry 3 10 sudo apt-get update -q

    # Install OFED packages; --allow-downgrades replaces inbox rdma-core versions.
    retry 3 10 sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
        libibverbs1 libibverbs-dev ibverbs-utils \
        libmlx5-1 libmlx5-dev \
        librdmacm1 librdmacm-dev \
        libibumad libibmad infiniband-diags \
        mlnx-ofed-kernel-dkms || true

    # Skip openibd restart to avoid dropping network interfaces.
    # New kernel modules will load on next reboot.
    echo "skipping openibd restart (reboot nodes after install to load new modules)."
    sudo ldconfig
}

ensure_rdma_userspace() {
    local ofed_ver="4.9-5.1.0.0"
    local ofed_os="ubuntu20.04"
    if [[ -r /etc/os-release ]]; then
        local ver_id
        ver_id="$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
        if [[ "${ver_id}" == "18.04" ]]; then
            ofed_os="ubuntu18.04"
        fi
    fi

    if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
        echo "rdma userspace already present; skipping install."
        return 0
    fi

    if has_ofed_49; then
        echo "MLNX_OFED 4.9 detected; checking headers..."
        sudo ldconfig || true
        if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
            return 0
        fi
        echo "existing OFED install is incomplete; will reinstall."
    fi

    # Primary method: install from apt repository (tarball URLs are deprecated).
    install_ofed_via_apt "${ofed_ver}" "${ofed_os}"
    if command -v ibv_devinfo >/dev/null 2>&1 && has_exp_verbs_api; then
        echo "OFED installed successfully via apt."
        return 0
    fi

    # Fallback: try tarball download (in case apt method missed something).
    echo "apt install incomplete; trying tarball fallback..."
    local ofed_dir="MLNX_OFED_LINUX-${ofed_ver}-${ofed_os}-x86_64"
    local ofed_tgz="${ofed_dir}.tgz"
    cd /tmp
    if [[ ! -f "${ofed_tgz}" ]]; then
        retry 3 10 wget -q -L -O "${ofed_tgz}" \
            "https://linux.mellanox.com/public/repo/mlnx_ofed/${ofed_ver}/${ofed_os}-x86_64/${ofed_tgz}" \
            || retry 3 10 wget -q -L -O "${ofed_tgz}" \
            "http://content.mellanox.com/ofed/MLNX_OFED-${ofed_ver}/${ofed_tgz}" \
            || { echo "tarball download also failed; continuing with what we have."; return 1; }
    fi
    rm -rf "${ofed_dir}"
    tar xzf "${ofed_tgz}"
    cd "${ofed_dir}"
    sudo ./mlnxofedinstall --basic --force --without-fw-update --skip-repo || true

    echo "skipping openibd restart (reboot nodes after install to load new modules)."
    sudo ldconfig

    echo "post-install check:"
    command -v ibv_devinfo >/dev/null 2>&1 && ibv_devinfo -l || true
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

ensure_python_cmd() {
    local py_major=""
    if command -v python >/dev/null 2>&1; then
        py_major="$(python -c 'import sys; print(sys.version_info[0])' 2>/dev/null || true)"
        if [[ "${py_major}" == "3" ]]; then
            echo "python command already points to Python 3."
            return 0
        fi
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "setting /usr/local/bin/python -> $(command -v python3)"
        sudo ln -sfn "$(command -v python3)" /usr/local/bin/python
        return 0
    fi

    return 1
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
if ! ensure_python_cmd; then
    echo "error: unable to ensure python command uses Python 3."
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
    sudo rsync -a --delete --exclude build /local/repository/ "$DEFT_ROOT"/
elif [[ -f CMakeLists.txt ]]; then
    sudo rsync -a --delete --exclude build ./ "$DEFT_ROOT"/
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
    export CC="$(command -v gcc-10)"
    export CXX="$(command -v g++-10)"
else
    export CC="$(command -v gcc)"
    export CXX="$(command -v g++)"
fi
mkdir -p "$DEFT_ROOT/build"
cd "$DEFT_ROOT/build"
echo "using CC=${CC}"
echo "using CXX=${CXX}"
# CMake caches compiler choice in CMakeCache.txt; clear it so upgrades are picked up.
rm -f CMakeCache.txt
rm -rf CMakeFiles
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" ..
make -j"$(nproc)"
test -x ./server
test -x ./client

echo "[6/7] preparing passwordless ssh from ${REAL_USER}..."
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
    target="${node}"
    if ! target="$(pick_reachable_ssh_target "${node}")"; then
        SSH_FAIL+=("${node}(unreachable)")
        continue
    fi
    if ! sudo -u "$REAL_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${REAL_USER}@${target}" "hostname >/dev/null"; then
        SSH_FAIL+=("${node}->${target}")
    fi
done

if [[ "${#SSH_FAIL[@]}" -gt 0 ]]; then
    echo "error: passwordless ssh from mn0 failed for: ${SSH_FAIL[*]}"
    echo "hint: run script/link_cluster.sh from your local machine to sync mn key to cn nodes."
    exit 1
fi

echo "[7/7] ensuring runtime libraries on client nodes..."
RUNTIME_FAIL=()
for node in "${CLUSTER_NODES[@]}"; do
    if [[ "$node" == "mn0" ]]; then
        continue
    fi
    target="${node}"
    if ! target="$(pick_reachable_ssh_target "${node}")"; then
        RUNTIME_FAIL+=("${node}(unreachable)")
        continue
    fi
    echo "  -> ${node} (${target})"
    if ! sudo -u "$REAL_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${REAL_USER}@${target}" "bash -s" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
REQ_PKGS="libmemcached11 libmemcached-dev libnuma1 numactl nfs-common libgflags2.2 libgflags-dev libboost-all-dev libgoogle-perftools-dev rdma-core ibverbs-utils"
MISSING=""
for p in $REQ_PKGS; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [[ -n "$MISSING" ]]; then
    sudo apt-get update -q
    sudo apt-get install -y $MISSING
fi

# Keep CN OFED userspace aligned with MN build/runtime expectations.
if ! [ -f /usr/include/infiniband/verbs_exp.h ] || ! grep -q "ibv_exp_dct" /usr/include/infiniband/verbs_exp.h 2>/dev/null; then
    OFED_VER="4.9-5.1.0.0"
    OFED_OS="ubuntu20.04"
    REPO_BASE="http://linux.mellanox.com/public/repo/mlnx_ofed/${OFED_VER}/${OFED_OS}/x86_64"

    sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<REOF
deb [trusted=yes] ${REPO_BASE}/MLNX_LIBS ./
deb [trusted=yes] ${REPO_BASE}/COMMON ./
REOF
    sudo apt-get update -q
    sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
        libibverbs1 libibverbs-dev ibverbs-utils \
        libmlx5-1 libmlx5-dev \
        librdmacm1 librdmacm-dev \
        libibumad libibmad infiniband-diags \
        mlnx-ofed-kernel-dkms || true

    echo "skipping openibd restart on CN (reboot to load new modules)."
fi

sudo ldconfig || true

# client/server binaries are dynamically linked against libcityhash from /usr/local/lib.
if ! ldconfig -p | grep -q 'libcityhash\.so'; then
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

for bin in /deft_code/deft/build/client /deft_code/deft/build/server; do
    if [[ -x "$bin" ]]; then
        if ldd "$bin" | grep -q "not found"; then
            echo "missing shared libraries for $bin on $(hostname -s):"
            ldd "$bin" | grep "not found"
            exit 1
        fi
    fi
done
EOF
    then
        RUNTIME_FAIL+=("${node}->${target}")
    fi
done

if [[ "${#RUNTIME_FAIL[@]}" -gt 0 ]]; then
    echo "error: runtime dependency install failed for: ${RUNTIME_FAIL[*]}"
    exit 1
fi

echo "done. build + ssh + runtime dependency checks passed."
echo "next: cd /deft_code/deft/script && python3 gen_config.py && ./cloudlab_run.sh --smoke"
