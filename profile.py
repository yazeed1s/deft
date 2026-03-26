import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

pc.defineParameter("NUM_MN", "Memory Nodes", portal.ParameterType.INTEGER, 2)
pc.defineParameter("NUM_CN", "Compute Nodes", portal.ParameterType.INTEGER, 6)
pc.defineParameter("NODE_TYPE", "Hardware Type", portal.ParameterType.STRING, "d6515")
pc.defineParameter(
    "DISK_IMAGE",
    "Disk Image",
    portal.ParameterType.STRING,
    "urn:publicid:IDN+utah.cloudlab.us+image+emulab-ops:UBUNTU20-64-STD",
)

params = pc.bindParameters()
request = pc.makeRequestRSpec()

NUM_MN = params.NUM_MN
NUM_CN = params.NUM_CN
NODE_TYPE = params.NODE_TYPE
DISK_IMAGE = params.DISK_IMAGE

if NUM_MN < 1:
    pc.reportError(portal.ParameterError("NUM_MN must be >= 1"))
if NUM_MN + NUM_CN > 254:
    pc.reportError(portal.ParameterError("NUM_MN + NUM_CN must be <= 254"))
pc.verifyParameters()

# MN installation and NFS setup
mn_setup = """
#!/bin/bash
set -e
sudo apt-get update -q
sudo apt-get install -y nfs-kernel-server cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential python3-paramiko python3-yaml
cd /tmp
wget -q -4 http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --basic --user-space-only --without-fw-update --force
sudo /etc/init.d/openibd restart || true
EXP_IFACE=$(ip -4 -o addr show | awk '$4 ~ /^10\\.10\\.1\\./ {print $2; exit}')
if [[ -n "$EXP_IFACE" ]]; then
    sudo ip link set dev "$EXP_IFACE" up || true
    sudo ip link set dev "$EXP_IFACE" mtu 9000 || true
fi

cd /tmp
wget -q -4 -O cityhash.tar.gz "https://github.com/google/cityhash/archive/refs/heads/master.tar.gz"
tar xzf cityhash.tar.gz
cd cityhash-master
./configure
make all check CXXFLAGS="-g -O3"
sudo make install
sudo ldconfig

sudo mkdir -p /deft_code
sudo chmod 777 /deft_code
echo '/deft_code *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -a
sudo systemctl restart nfs-kernel-server
echo 'nfs server ready' > /tmp/nfs_ready
"""

# CN installation and NFS mount
cn_setup = """
#!/bin/bash
set -e
sudo apt-get update -q
sudo apt-get install -y nfs-common cmake gcc-10 g++-10 libgflags-dev libnuma-dev numactl memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential python3-paramiko python3-yaml
cd /tmp
wget -q -4 http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.9-5.1.0.0/MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
tar xzf MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64.tgz
cd MLNX_OFED_LINUX-4.9-5.1.0.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --basic --user-space-only --without-fw-update --force
sudo /etc/init.d/openibd restart || true
EXP_IFACE=$(ip -4 -o addr show | awk '$4 ~ /^10\\.10\\.1\\./ {print $2; exit}')
if [[ -n "$EXP_IFACE" ]]; then
    sudo ip link set dev "$EXP_IFACE" up || true
    sudo ip link set dev "$EXP_IFACE" mtu 9000 || true
fi

cd /tmp
wget -q -4 -O cityhash.tar.gz "https://github.com/google/cityhash/archive/refs/heads/master.tar.gz"
tar xzf cityhash.tar.gz
cd cityhash-master
./configure
make all check CXXFLAGS="-g -O3"
sudo make install
sudo ldconfig

echo "Waiting for mn0 NFS to be ready..."
while ! showmount -e 10.10.1.1 > /dev/null 2>&1; do
    sleep 5
done
sudo mkdir -p /deft_code
sudo mount -t nfs 10.10.1.1:/deft_code /deft_code
echo "10.10.1.1:/deft_code /deft_code nfs defaults 0 0" | sudo tee -a /etc/fstab
sudo chmod 777 /deft_code
"""

lan = request.LAN("deft-lan")
lan.bandwidth = 100000  # 100 gbps
lan.best_effort = True
lan.vlan_tagging = True
lan.link_multiplexing = True

ip_idx = 1

mn_nodes = []
for i in range(NUM_MN):
    mn = request.RawPC("mn{}".format(i))
    mn.hardware_type = NODE_TYPE
    mn.disk_image = DISK_IMAGE

    if i == 0:
        mn.addService(pg.Execute(shell="bash", command=mn_setup))
    else:
        mn.addService(pg.Execute(shell="bash", command=cn_setup))

    iface = mn.addInterface("iface-mn{}".format(i))
    iface.bandwidth = 100000
    iface.addAddress(pg.IPv4Address("10.10.1.{}".format(ip_idx), "255.255.255.0"))
    ip_idx += 1
    lan.addInterface(iface)
    mn_nodes.append(mn)

cn_nodes = []
for i in range(NUM_CN):
    cn = request.RawPC("cn{}".format(i))
    cn.hardware_type = NODE_TYPE
    cn.disk_image = DISK_IMAGE

    cn.addService(pg.Execute(shell="bash", command=cn_setup))

    iface = cn.addInterface("iface-cn{}".format(i))
    iface.bandwidth = 100000
    iface.addAddress(pg.IPv4Address("10.10.1.{}".format(ip_idx), "255.255.255.0"))
    ip_idx += 1
    lan.addInterface(iface)
    cn_nodes.append(cn)

pc.printRequestRSpec()
