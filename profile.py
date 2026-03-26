import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

# Parameters
pc.defineParameter("mn_count", "Memory Nodes", portal.ParameterType.INTEGER, 1)
pc.defineParameter("cn_count", "Compute Nodes", portal.ParameterType.INTEGER, 5)
params = pc.bindParameters()

request = pc.makeRequestRSpec()

NODE_TYPE = "r650"
OS_IMAGE = "urn:publicid:IDN+clemson.cloudlab.us+image+emulab-ops:UBUNTU18-64-STD"

# 100G RDMA LAN
lan = request.LAN("rdma_lan")
lan.bandwidth = 100000000
lan.best_effort = True


setup_script = """
#!/bin/bash
set -e

#  System Dependencies
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-yaml python3-paramiko nfs-common cmake g++ libboost-all-dev memcached libgoogle-perftools-dev python3-yaml numactl git autoconf libtool build-essential libnuma-dev

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

# Install MLNX_OFED 4.9-5.1.0.0 (User-space only to prevent kernel crashes)
if [ ! -d "/usr/local/ofed" ]; then
    cd /tmp
    wget -q http://content.mellanox.com/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64.tgz
    tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64.tgz
    cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu18.04-x86_64
    sudo ./mlnxofedinstall --user-space-only --force --quiet
    sudo /etc/init.d/openibd restart || true
fi

# NFS Setup for Coordination
if [ "$(hostname)" == "mn0" ]; then
    sudo apt-get install -y nfs-kernel-server
    sudo mkdir -p /deft_share
    sudo chmod 777 /deft_share
    echo "/deft_share 10.10.1.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
    sudo exportfs -a
    sudo systemctl restart nfs-kernel-server
else
    sudo mkdir -p /deft_share
    # Wait for mn0 to come online
    until ping -c1 10.10.1.1 >/dev/null 2>&1; do sleep 5; done
    sudo mount -t nfs 10.10.1.1:/deft_share /deft_share
    echo "10.10.1.1:/deft_share /deft_share nfs defaults 0 0" | sudo tee -a /etc/fstab
fi
"""

def create_node(name, ip_suffix):
    node = request.RawPC(name)
    node.hardware_type = NODE_TYPE
    node.disk_image = OS_IMAGE

    # use the secondary interface for the RDMA LAN to avoid SSH lockouts
    iface = node.addInterface("eth1")
    iface.addAddress(pg.IPv4Address("10.10.1." + str(ip_suffix), "255.255.255.0"))
    lan.addInterface(iface)

    node.addService(pg.Execute(shell="bash", command=setup_script))
    return node


for i in range(params.mn_count):
    create_node("mn" + str(i), i + 1)

for i in range(params.cn_count):
    create_node("cn" + str(i), params.mn_count + i + 1)

pc.printRequestRSpec(request)
