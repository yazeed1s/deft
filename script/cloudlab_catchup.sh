#!/bin/bash
# update old cloudlab nodes to match new profile
set -e

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: please run on mn0"
    exit 1
fi

echo "setting up ssh keys so mn0 can talk to cn nodes..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -m PEM -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

echo "installing packages on mn0..."
sudo apt-get update -q
sudo apt-get install -y nfs-kernel-server cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential python3-paramiko python3-yaml

echo "installing MLNX_OFED user-space headers on mn0..."
cd /tmp
if [ ! -d "MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64" ]; then
    wget -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
    tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
fi
cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --force --without-fw-update
sudo /etc/init.d/openibd restart
if command -v ibdev2netdev >/dev/null 2>&1; then sudo ibdev2netdev | awk '{print $5}' | xargs -I {} sudo ip link set dev {} up; fi

echo "installing CityHash on mn0..."
cd /tmp
if [ ! -d "cityhash-master" ]; then
    wget -q -O cityhash.tar.gz "https://github.com/google/cityhash/archive/refs/heads/master.tar.gz"
    tar xzf cityhash.tar.gz
fi
cd cityhash-master
./configure
make all CXXFLAGS="-g -O3"
sudo make install
sudo ldconfig

MN0_IP=$(hostname -I | awk '{print $1}')

echo "finding compute nodes..."
CN_NODES=$(grep -oE "\bcn[0-9]+\b" /etc/hosts | sort | uniq)

if [ -z "$CN_NODES" ]; then
    echo "no cn nodes found in /etc/hosts. guessing cn0 cn1..."
    CN_NODES="cn0 cn1"
fi

for node in $CN_NODES; do
    echo "updating node: $node"
    
    # install packages
    ssh -o StrictHostKeyChecking=no $node "sudo apt-get update -q"
    ssh -o StrictHostKeyChecking=no $node "sudo apt-get install -y nfs-common cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential python3-paramiko python3-yaml"
    ssh -o StrictHostKeyChecking=no $node "cd /tmp && if [ ! -d \"MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64\" ]; then wget -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz && tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz; fi && cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64 && sudo ./mlnxofedinstall --force --without-fw-update && sudo /etc/init.d/openibd restart; if command -v ibdev2netdev >/dev/null 2>&1; then sudo ibdev2netdev | awk '{print \$5}' | xargs -I {} sudo ip link set dev {} up; fi"
    
    # install cityhash natively (bypassing slow 'make check')
    ssh -o StrictHostKeyChecking=no $node "cd /tmp && if [ ! -d \"cityhash-master\" ]; then wget -q -O cityhash.tar.gz \"https://github.com/google/cityhash/archive/refs/heads/master.tar.gz\" && tar xzf cityhash.tar.gz; fi && cd cityhash-master && ./configure && make all CXXFLAGS=\"-g -O3\" && sudo make install && sudo ldconfig"
    
    # nfs mount
    ssh -o StrictHostKeyChecking=no $node "sudo mkdir -p /mydata"
    
    if ssh -o StrictHostKeyChecking=no $node "mount | grep -q '/mydata'"; then
        echo "$node already has /mydata mounted."
    else
        ssh -o StrictHostKeyChecking=no $node "sudo mount -t nfs $MN0_IP:/mydata /mydata"
        ssh -o StrictHostKeyChecking=no $node "echo \"$MN0_IP:/mydata /mydata nfs defaults 0 0\" | sudo tee -a /etc/fstab"
        echo "$node nfs mount complete."
    fi
done

echo "now run: sudo ./script/cloudlab_setup.sh"
