import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

# Parameters
pc.defineParameter("mn_count", "Memory Nodes", portal.ParameterType.INTEGER, 1)
pc.defineParameter("cn_count", "Compute Nodes", portal.ParameterType.INTEGER, 5)
pc.defineParameter("node_type", "Hardware Type", portal.ParameterType.STRING, "r650")
pc.defineParameter("os_image", "Disk Image URN", portal.ParameterType.STRING,
                   "urn:publicid:IDN+clemson.cloudlab.us+image+emulab-ops:UBUNTU18-64-STD")

params = pc.bindParameters()
request = pc.makeRequestRSpec()

NODE_TYPE = params.node_type
OS_IMAGE = params.os_image

# 100G RDMA LAN
lan = request.LAN("rdma_lan")
lan.bandwidth = 100000
lan.best_effort = True

# Common dependencies and builds required for Deft
common_setup = """
#!/bin/bash
set -e

# System Dependencies
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-yaml python3-paramiko nfs-common \
    cmake g++ libboost-all-dev memcached libgoogle-perftools-dev numactl git \
    autoconf libtool build-essential libnuma-dev

# Build CityHash from Source
if [ ! -f /usr/local/lib/libcityhash.so ]; then
    cd /tmp
    git clone https://github.com/google/cityhash.git
    cd cityhash
    ./configure
    make all check -j$(nproc)
    sudo make install
    sudo ldconfig
fi

# Install MLNX_OFED 4.9-5.1.0.0 (User-space only)
if [ ! -d "/usr/local/ofed" ]; then
    cd /tmp
    wget -q http://content.mellanox.com/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64.tgz
    tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64.tgz
    cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64
    sudo ./mlnxofedinstall --user-space-only --force --quiet
    sudo /etc/init.d/openibd restart || true
fi
"""

# logic for the very first memory node (mn0)
nfs_server_logic = """
# NFS Setup for automated Benchmarking Coordination
sudo apt-get install -y nfs-kernel-server
sudo mkdir -p /deft_share
sudo chmod 777 /deft_share
echo "/deft_share 10.10.1.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -a
sudo systemctl restart nfs-kernel-server
"""

# logic for all other nodes
nfs_client_logic = """
# NFS Client setup
sudo mkdir -p /deft_share
# Wait for mn0 (10.10.1.1) to be reachable
until ping -c1 10.10.1.1 >/dev/null 2>&1; do sleep 5; done
sudo mount -t nfs 10.10.1.1:/deft_share /deft_share
echo "10.10.1.1:/deft_share /deft_share nfs defaults 0 0" | sudo tee -a /etc/fstab
"""

def create_node(name, ip_suffix, is_first_mn):
    node = request.RawPC(name)
    node.hardware_type = NODE_TYPE
    node.disk_image = OS_IMAGE

    # Use eth1 for RDMA to keep the SSH control network clean
    iface = node.addInterface("eth1")
    iface.addAddress(pg.IPv4Address("10.10.1." + str(ip_suffix), "255.255.255.0"))
    lan.addInterface(iface)

    # Append the specific NFS logic based on node role
    if is_first_mn:
        full_script = common_setup + nfs_server_logic
    else:
        full_script = common_setup + nfs_client_logic

    node.addService(pg.Execute(shell="bash", command=full_script))
    return node

# Memory Nodes: Only the first one (i=0) becomes the NFS server
for i in range(params.mn_count):
    create_node("mn" + str(i), i + 1, is_first_mn=(i == 0))

# Compute Nodes: All are NFS clients
for i in range(params.cn_count):
    # IP suffix continues after the memory nodes
    create_node("cn" + str(i), params.mn_count + i + 1, is_first_mn=False)

pc.printRequestRSpec(request)
