#!/bin/bash
# Run on mn0 to prep build + SSH connectivity for benchmark scripts.
set -euo pipefail

LOG_FILE=/tmp/cloudlab_setup.log
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname -s)] $*"
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

build_gcc10_from_source() {
    local gcc_ver="10.5.0"
    local src_dir="/tmp/gcc-${gcc_ver}"
    local build_dir="/tmp/gcc-${gcc_ver}-build"
    local tarball="gcc-${gcc_ver}.tar.xz"
    local url="https://ftp.gnu.org/gnu/gcc/gcc-${gcc_ver}/${tarball}"
    local jobs

    log "building gcc-${gcc_ver} from source (fallback)..."
    retry 3 10 sudo apt-get update -q
    retry 3 10 sudo apt-get install -y \
        build-essential flex bison gawk m4 texinfo libgmp-dev libmpfr-dev \
        libmpc-dev zlib1g-dev wget xz-utils

    if [[ ! -d "${src_dir}" ]]; then
        cd /tmp
        retry 3 10 wget -q -L -O "${tarball}" "${url}"
        rm -rf "${src_dir}"
        tar -xf "${tarball}"
    fi

    cd "${src_dir}"
    ./contrib/download_prerequisites

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    cd "${build_dir}"
    "${src_dir}/configure" \
        --prefix=/opt/gcc-10 \
        --disable-multilib \
        --enable-languages=c,c++

    jobs="$(nproc)"
    [[ -z "${jobs}" || "${jobs}" -lt 1 ]] && jobs=1
    make -j"${jobs}"
    sudo make install

    sudo ln -sfn /opt/gcc-10/bin/gcc-10 /usr/local/bin/gcc-10
    sudo ln -sfn /opt/gcc-10/bin/g++-10 /usr/local/bin/g++-10
    hash -r || true
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
            log "cmake ${cmake_ver} is sufficient."
            return 0
        fi
        log "cmake ${cmake_ver} is too old for C++20; upgrading..."
    else
        log "cmake not found; installing..."
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
        log "gcc-10/g++-10 already present."
        return 0
    fi

    if apt-cache show g++-10 >/dev/null 2>&1 && apt-cache show gcc-10 >/dev/null 2>&1; then
        log "installing gcc-10/g++-10 from current apt sources..."
        retry 5 10 sudo apt-get install -y gcc-10 g++-10
    fi

    if command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1; then
        return 0
    fi

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == 18.04 ]]; then
            log "enabling ubuntu-toolchain-r/test PPA for gcc-10 on Ubuntu 18.04..."
            if timeout 60 bash -lc '
                set -euo pipefail
                sudo apt-get install -y software-properties-common
                if ! sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test; then
                    echo "deb http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu bionic main" | \
                        sudo tee /etc/apt/sources.list.d/ubuntu-toolchain-r-test.list >/dev/null
                    sudo apt-key adv --keyserver keyserver.ubuntu.com \
                        --recv-keys C8EC952E2A0E1FBDC5090F6A2C277A0A352154E5
                fi
                sudo apt-get update -q
                sudo apt-get install -y gcc-10 g++-10
            '; then
                :
            else
                rc=$?
                if [[ "$rc" -eq 124 ]]; then
                    log "gcc PPA path timed out after 60s; falling back to source build."
                else
                    log "gcc PPA path failed (rc=${rc}); falling back to source build."
                fi
                build_gcc10_from_source
            fi
        fi
    fi

    if ! (command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1); then
        build_gcc10_from_source
    fi

    command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1
}

ensure_python_cmd() {
    local py_major=""
    if command -v python >/dev/null 2>&1; then
        py_major="$(python -c 'import sys; print(sys.version_info[0])' 2>/dev/null || true)"
        if [[ "${py_major}" == "3" ]]; then
            log "python command already points to Python 3."
            return 0
        fi
    fi

    if command -v python3 >/dev/null 2>&1; then
        log "setting /usr/local/bin/python -> $(command -v python3)"
        sudo ln -sfn "$(command -v python3)" /usr/local/bin/python
        return 0
    fi

    return 1
}

ensure_ofed49_userspace() {
    local ofed_os
    local repo_base

    ofed_os="ubuntu18.04"
    if [[ -r /etc/os-release ]]; then
        if grep -q 'VERSION_ID="20.04"' /etc/os-release; then
            ofed_os="ubuntu20.04"
        fi
    fi
    repo_base="http://linux.mellanox.com/public/repo/mlnx_ofed/4.9-5.1.0.0/${ofed_os}/x86_64"

    log "ensuring MLNX_OFED 4.9 user-space libraries (${ofed_os})..."

    sudo rm -f /etc/apt/sources.list.d/mlnx_ofed.list /etc/apt/preferences.d/*mlnx* /etc/apt/preferences.d/*ofed* || true
    sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<OFEDAPT
deb [trusted=yes] ${repo_base}/MLNX_LIBS ./
OFEDAPT

    # Avoid Ubuntu/MLNX mixed RDMA stacks. Ubuntu ibverbs-providers conflicts
    # with MLNX libmlx5-1 on /etc/libibverbs.d/mlx5.driver.
    # Also remove Ubuntu libfabric/libucx if present since they depend on
    # Ubuntu ibverbs-providers and force the conflicting package set.
    sudo apt-get purge -y rdma-core ibverbs-providers libfabric1 libucx0 || true
    sudo apt-get -f install -y || true

    retry 3 10 sudo apt-get -o Acquire::AllowInsecureRepositories=true update -q
    retry 3 10 sudo apt-get install -y --allow-downgrades --allow-change-held-packages --allow-unauthenticated \
        libibverbs1 libibverbs-dev ibverbs-utils \
        libmlx5-1 libmlx5-dev \
        librdmacm1 librdmacm-dev \
        libibumad libibmad infiniband-diags

    sudo ldconfig
}

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    log "error: please run on mn0"
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "detected OS: ${PRETTY_NAME:-unknown}"
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn "$REAL_USER")
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DEFT_ROOT=/deft_code/deft

log "[1/7] installing packages on mn0..."
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
    log "installing missing packages: ${MISSING_PKGS[*]}"
    retry 5 10 sudo apt-get update -q
    retry 5 10 sudo apt-get install -y "${MISSING_PKGS[@]}"
else
    log "all base packages already installed; skipping apt install."
fi

if ! ensure_modern_cmake; then
    log "error: unable to install a modern cmake version."
    exit 1
fi
log "starting gcc-10/g++-10 setup..."
if ! ensure_modern_gcc; then
    log "error: unable to install gcc-10/g++-10 required for C++20."
    exit 1
fi
log "gcc setup step completed."
if ! ensure_python_cmd; then
    log "error: unable to ensure python command uses Python 3."
    exit 1
fi
ensure_ofed49_userspace


log "[2/7] syncing repository to ${DEFT_ROOT}..."
sudo mkdir -p "$DEFT_ROOT"
sudo chown "$REAL_USER:$REAL_GROUP" /deft_code "$DEFT_ROOT"

if [[ -d /local/repository/.git ]]; then
    sudo rsync -a --delete --exclude build /local/repository/ "$DEFT_ROOT"/
elif [[ -f CMakeLists.txt ]]; then
    sudo rsync -a --delete --exclude build ./ "$DEFT_ROOT"/
else
    log "error: cannot find repo source. expected /local/repository or current repo root."
    exit 1
fi

sudo chown -R "$REAL_USER:$REAL_GROUP" "$DEFT_ROOT"
cd "$DEFT_ROOT"

# Calculate safe make jobs based on available memory (~2GB per job)
AVAIL_MEM_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo || echo 0)
if [[ "$AVAIL_MEM_KB" -eq 0 ]]; then
    AVAIL_MEM_KB=$(awk '/MemFree/ {print $2}' /proc/meminfo || echo 2048000)
fi
MAKE_JOBS=$(( AVAIL_MEM_KB / 1024 / 1024 / 2 ))
[[ $MAKE_JOBS -lt 1 ]] && MAKE_JOBS=1
MAX_CORES=$(nproc)
[[ $MAKE_JOBS -gt $MAX_CORES ]] && MAKE_JOBS=$MAX_CORES

log "[3/7] ensuring cityhash..."
if ! ldconfig -p | grep -q libcityhash; then
    cd /tmp
    if [[ ! -d cityhash ]]; then
        git clone https://github.com/google/cityhash.git
    fi
    cd cityhash
    autoreconf -if
    ./configure
    make -j"${MAKE_JOBS}"
    sudo make install
    sudo ldconfig
fi

log "[4/7] building deft..."
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
echo "using make -j${MAKE_JOBS} based on available RAM"
# CMake caches compiler choice in CMakeCache.txt; clear it so upgrades are picked up.
rm -f CMakeCache.txt
rm -rf CMakeFiles
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" ..
make -j"${MAKE_JOBS}"
test -x ./server
test -x ./client

log "[5/7] preparing passwordless ssh from ${REAL_USER}..."
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
    log "error: passwordless ssh from mn0 failed for: ${SSH_FAIL[*]}"
    log "hint: run script/link_cluster.sh from your local machine to sync mn key to cn nodes."
    exit 1
fi

log "[6/7] ensuring runtime libraries on client nodes..."
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
    log "runtime deps on ${node} (${target})"
    if ! sudo -u "$REAL_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${REAL_USER}@${target}" "bash -s" <<'EOF'
set -euo pipefail
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname -s)] starting runtime dependency checks"
export DEBIAN_FRONTEND=noninteractive

# Install runtime shared libraries needed by deft binaries
RUNTIME_PKGS=(libgflags-dev libnuma-dev libmemcached-dev libboost-all-dev)
MISSING=()
for p in "${RUNTIME_PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
        MISSING+=("$p")
    fi
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname -s)] installing missing runtime packages: ${MISSING[*]}"
    sudo apt-get update -q || true
    sudo apt-get install -y "${MISSING[@]}"
fi

# Install MLNX OFED ibverbs if missing
if ! ldconfig -p | grep -q 'libibverbs\.so'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname -s)] installing ibverbs from MLNX OFED..."
    sudo apt-get purge -y rdma-core ibverbs-providers libfabric1 libucx0 2>/dev/null || true
    sudo apt-get -f install -y || true
    OFED_OS="ubuntu18.04"
    if grep -q 'VERSION_ID="20.04"' /etc/os-release 2>/dev/null; then
        OFED_OS="ubuntu20.04"
    fi
    echo "deb [trusted=yes] http://linux.mellanox.com/public/repo/mlnx_ofed/4.9-5.1.0.0/${OFED_OS}/x86_64/MLNX_LIBS ./" | sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null
    sudo apt-get -o Acquire::AllowInsecureRepositories=true update -q || true
    sudo apt-get install -y --allow-downgrades --allow-change-held-packages --allow-unauthenticated \
        libibverbs1 libibverbs-dev libmlx5-1 librdmacm1 libibumad libibmad || true
    sudo ldconfig
fi

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
    log "error: runtime dependency install failed for: ${RUNTIME_FAIL[*]}"
    exit 1
fi

log "[7/7] done. build + ssh + runtime dependency checks passed."
log "next: cd /deft_code/deft/script && python3 gen_config.py && ./cloudlab_run.sh --smoke"
