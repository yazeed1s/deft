#!/bin/bash
# update old cloudlab nodes to match new profile
set -e

OFED_DIR="MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64"
OFED_TGZ="${OFED_DIR}.tgz"
OFED_URL="http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/${OFED_TGZ}"

has_rdma_hca() {
    ibv_devinfo -l 2>/dev/null | grep -Eq '^[[:space:]]*[1-9][0-9]* HCAs found'
}

has_exp_verbs_api() {
    [ -f /usr/include/infiniband/verbs_exp.h ] && grep -q "ibv_exp_dct" /usr/include/infiniband/verbs_exp.h
}

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: please run on mn0"
    exit 1
fi

echo "setting up ssh keys so mn0 can talk to cn nodes..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -m PEM -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi
if ! grep -q "$(cat ~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys; then
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
fi

echo "installing packages on mn0..."
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq nfs-kernel-server cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev autoconf automake libtool build-essential python3-paramiko python3-yaml

echo "configuring nfs server on mn0..."
sudo chmod 777 /mydata
# Remove any existing /mydata or /local/repository exports to prevent duplicates
sudo sed -i '/\/mydata/d' /etc/exports
sudo sed -i '/\/local\/repository/d' /etc/exports
echo '/mydata *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports

sudo systemctl enable rpcbind
sudo systemctl restart rpcbind
sudo exportfs -arv || true
sudo systemctl restart nfs-kernel-server || true

echo "installing MLNX_OFED user-space headers on mn0..."
cd /tmp
if ! has_rdma_hca || ! has_exp_verbs_api; then
    echo "rdma stack on mn0 is not compatible with DEFT; installing OFED 4.9 userspace..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y rdma-core libibverbs1 ibverbs-providers libmlx5-1 librdmacm1 ibverbs-utils infiniband-diags || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y

    if [ ! -f "$OFED_TGZ" ]; then
        wget -q "$OFED_URL"
    fi
    rm -rf "$OFED_DIR"
    tar xzf "$OFED_TGZ"
    cd "$OFED_DIR"
    sudo ./mlnxofedinstall --basic --user-space-only --force --without-fw-update
    sudo /etc/init.d/openibd restart || true
    sudo ldconfig

    if ! has_rdma_hca || ! has_exp_verbs_api; then
        echo "warning: OFED install finished, but RDMA checks are not clean yet on mn0."
        echo "warning: this can happen right after openibd restart; continue and verify before build."
    fi
    touch /tmp/.ofed_done
else
    echo "skip: rdma already healthy on mn0"
fi
if command -v ibdev2netdev >/dev/null 2>&1; then sudo ibdev2netdev | awk '{print $5}' | xargs -I {} sudo ip link set dev {} up; fi

echo "installing CityHash on mn0..."
cd /tmp
if [ ! -f "/tmp/.cityhash_done" ]; then
    if [ ! -d "cityhash-master" ]; then
        wget -q -O cityhash.tar.gz "https://github.com/google/cityhash/archive/refs/heads/master.tar.gz"
        tar xzf cityhash.tar.gz
    fi
    cd cityhash-master
    ./configure
    make all CXXFLAGS="-g -O3"
    sudo make install
    sudo ldconfig
    touch /tmp/.cityhash_done
else
    echo "skip: cityhash loaded"
fi

MN0_IP=$(hostname -I | tr ' ' '\n' | grep '10.10.1.' | head -n 1)
if [ -z "$MN0_IP" ]; then
    MN0_IP=$(hostname -I | awk '{print $1}')
fi
echo "using mn0 ip: $MN0_IP"

echo "finding compute nodes..."
CN_NODES=$(grep -oE "\bcn[0-9]+\b" /etc/hosts | sort -ru)

if [ -z "$CN_NODES" ]; then
    echo "no cn nodes found in /etc/hosts. guessing cn2 cn1 cn0..."
    CN_NODES="cn2 cn1 cn0"
fi

for node in $CN_NODES; do
    echo "updating node: $node"

    # install packages
    ssh -o StrictHostKeyChecking=no $node "sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
    ssh -o StrictHostKeyChecking=no $node "sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true"
    ssh -o StrictHostKeyChecking=no $node "sudo DEBIAN_FRONTEND=noninteractive apt-get update -q"
    ssh -o StrictHostKeyChecking=no $node "sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq nfs-common cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev autoconf automake libtool build-essential python3-paramiko python3-yaml"

    # copy MLNX_OFED tarball directly from mn0 to avoid internet proxy lag
    if ! ssh -o StrictHostKeyChecking=no $node "command -v ibv_devinfo >/dev/null 2>&1 && ibv_devinfo -l 2>/dev/null | grep -Eq '^[[:space:]]*[1-9][0-9]* HCAs found' && [ -f /usr/include/infiniband/verbs_exp.h ] && grep -q 'ibv_exp_dct' /usr/include/infiniband/verbs_exp.h"; then
        ssh -o StrictHostKeyChecking=no $node "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y rdma-core libibverbs1 ibverbs-providers libmlx5-1 librdmacm1 ibverbs-utils infiniband-diags || true"
        ssh -o StrictHostKeyChecking=no $node "sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y"

        echo "copying ofed tarball from mn0 -> $node"
        scp -o StrictHostKeyChecking=no /tmp/"$OFED_TGZ" $node:/tmp/
        ssh -o StrictHostKeyChecking=no $node "cd /tmp && rm -rf $OFED_DIR && tar xzf $OFED_TGZ && cd $OFED_DIR && sudo ./mlnxofedinstall --basic --user-space-only --force --without-fw-update && (sudo /etc/init.d/openibd restart || true) && sudo ldconfig && touch /tmp/.ofed_done"
        if ! ssh -o StrictHostKeyChecking=no $node "ibv_devinfo -l | grep -Eq '^[[:space:]]*[1-9][0-9]* HCAs found' && [ -f /usr/include/infiniband/verbs_exp.h ] && grep -q 'ibv_exp_dct' /usr/include/infiniband/verbs_exp.h"; then
            echo "warning: post-install RDMA check is still not clean on $node; continuing."
        fi
    else
        echo "skip: rdma already healthy on $node"
    fi
    ssh -o StrictHostKeyChecking=no $node "if command -v ibdev2netdev >/dev/null 2>&1; then sudo ibdev2netdev | awk '{print \$5}' | xargs -I {} sudo ip link set dev {} up; fi" || true

    # push natively compiled CityHash modules from mn0 directly into local lib to avoid redundant make cycles
    if ssh -o StrictHostKeyChecking=no $node "[ ! -f /tmp/.cityhash_done ]"; then
        echo "copying cityhash from mn0 -> $node"
        scp -o StrictHostKeyChecking=no /usr/local/include/city* $node:/tmp/
        tar -cf - -C /usr/local/lib libcityhash.a libcityhash.la libcityhash.so libcityhash.so.0 libcityhash.so.0.0.0 | ssh -o StrictHostKeyChecking=no $node "tar -xf - -C /tmp/" || true
        ssh -o StrictHostKeyChecking=no $node "sudo cp /tmp/city* /usr/local/include/ ; sudo cp -P /tmp/libcityhash* /usr/local/lib/ ; sudo ldconfig ; touch /tmp/.cityhash_done" || true
    else
        echo "skip: cityhash loaded"
    fi

    # nfs mount
    ssh -o StrictHostKeyChecking=no $node "(sudo umount -l /mydata 2>/dev/null ; sudo rm -rf /mydata 2>/dev/null ; sudo mkdir -p /mydata) || true"

    if ssh -o StrictHostKeyChecking=no $node "mount | grep -q \"$MN0_IP:/mydata on /mydata\""; then
        echo "$node already has /mydata mounted correctly."
    else
        ssh -o StrictHostKeyChecking=no $node "sudo umount -l /mydata 2>/dev/null ; sudo mount -t nfs $MN0_IP:/mydata /mydata" || true
        ssh -o StrictHostKeyChecking=no $node "grep -q '/mydata' /etc/fstab || echo \"$MN0_IP:/mydata /mydata nfs defaults 0 0\" | sudo tee -a /etc/fstab" || true
        # Update fstab if it had the old path
        ssh -o StrictHostKeyChecking=no $node "sudo sed -i \"s|.*$MN0_IP:.* /mydata nfs.*|$MN0_IP:/mydata /mydata nfs defaults 0 0|\" /etc/fstab"
        echo "$node nfs mount refreshed."
    fi
done

echo "now run: sudo ./script/cloudlab_setup.sh"
