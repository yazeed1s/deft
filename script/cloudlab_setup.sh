#!/bin/bash
# run on mn0 to setup everything
set -e

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: please run on mn0"
    exit 1
fi

echo "installing packages on mn0..."
sudo apt-get update -q
sudo apt-get install -y nfs-kernel-server cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev autoconf automake libtool build-essential python3-paramiko python3-yaml

echo "checking rdma..."
if ! command -v ibv_devinfo >/dev/null 2>&1; then
    echo "warning: ibv_devinfo missing. run ./script/cloudlab_catchup.sh first to install OFED userspace."
    exit 1
fi

RDMA_DEVS=$(ibv_devinfo -l | grep -v "[0-9] HCAs" || true)
if [[ -z "$RDMA_DEVS" ]]; then
    echo "warning: no rdma device found in ibv_devinfo."
    echo "cloudlab using default drivers. deft works better with MLNX_OFED 4.9."
    echo "install mlnx_ofed manually if needed."
else
    echo "ok: rdma device found"
fi

export CC=gcc-10
export CXX=g++-10

echo "2. copy files and install cityhash..."
REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn $REAL_USER)

sudo mkdir -p /mydata/deft
sudo chown -R $REAL_USER:$REAL_GROUP /mydata

echo "syncing repository to /mydata/deft..."
if [[ -d "/local/repository" ]]; then
    sudo cp -ru /local/repository/. /mydata/deft/
elif [[ -f "CMakeLists.txt" ]]; then
    sudo cp -ru . /mydata/deft/
else
    echo "error: cannot find repo folder"
    exit 1
fi
sudo chown -R $REAL_USER:$REAL_GROUP /mydata/deft

cd /mydata/deft

if [[ ! -d "/usr/local/include/cityhash" ]] && ! ldconfig -p | grep libcityhash > /dev/null; then
    echo "building cityhash..."
    cd /tmp
    if [ ! -d "cityhash" ]; then
        git clone https://github.com/google/cityhash.git
    fi
    cd cityhash
    autoreconf -if
    ./configure
    make -j$(nproc)
    sudo make install
    sudo ldconfig
    cd /mydata/deft
fi

echo "3. we setup hugepage later in run script."

echo "4. build deft..."
mkdir -p build
cd build
if ! cmake -DCMAKE_BUILD_TYPE=Release .. ; then
    echo "error: cmake failed"
    exit 1
fi
if ! make -j$(nproc); then
    echo "error: make failed"
    exit 1
fi
cd ..

echo "5. fix down rdma ports..."
if command -v ibdev2netdev >/dev/null 2>&1; then
    sudo ibdev2netdev | while read -r line; do
        iface=$(echo "$line" | awk '{print $5}')
        state=$(echo "$line" | awk '{print $6}')
        if [[ "$state" == "(Down)" ]]; then
            sudo ip link set dev "$iface" up
        fi
    done
fi

echo "done. deft is built."

echo "6. setting up ssh keys covering all nodes..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -m PEM -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

echo "next run python3 gen_config.py in script folder."
