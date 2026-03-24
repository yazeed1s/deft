#!/bin/bash
# setup_all.sh - run on every node (MNs and CNs)
# installs RDMA drivers and dependencies, must be done before anything else

set -e

echo "starting setup on $(hostname)..."

sudo apt-get update -q
sudo apt-get install -y \
    memcached \
    libmemcached-dev \
    libcityhash-dev \
    libboost-all-dev \
    cmake \
    build-essential \
    libnuma-dev \
    nfs-common \
    ibverbs-utils \
    infiniband-diags

# MLNX_OFED 4.9-5.1.0.0 (5.x requires source modifications, see readme)
cd /tmp
wget -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --force --without-fw-update
sudo /etc/init.d/openibd restart

# huge pages
echo 4096 | sudo tee /proc/sys/vm/nr_hugepages
echo "vm.nr_hugepages = 4096" | sudo tee -a /etc/sysctl.conf

# mount nfs from mn0
MN0_IP=$1
if [ -z "$MN0_IP" ]; then
    echo "usage: ./setup_all.sh <mn0-ip>"
    exit 1
fi

sudo mkdir -p /mydata
sudo mount -t nfs $MN0_IP:/mydata /mydata
echo "$MN0_IP:/mydata /mydata nfs defaults 0 0" | sudo tee -a /etc/fstab

echo "done."
