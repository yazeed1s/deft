import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

pc.defineParameter("NUM_MN", "Memory Nodes", portal.ParameterType.INTEGER, 2)
pc.defineParameter("NUM_CN", "Compute Nodes", portal.ParameterType.INTEGER, 6)
pc.defineParameter("NODE_TYPE", "Hardware Type", portal.ParameterType.STRING, "d6515")
pc.defineParameter("DISK_IMAGE", "Disk Image", portal.ParameterType.STRING, "urn:publicid:IDN+utah.cloudlab.us+image+emulab-ops:UBUNTU20-64-STD")

params = pc.bindParameters()
request = pc.makeRequestRSpec()

NUM_MN = params.NUM_MN
NUM_CN = params.NUM_CN
NODE_TYPE = params.NODE_TYPE
DISK_IMAGE = params.DISK_IMAGE

# MN installation and NFS setup
mn_setup = """
#!/bin/bash
set -e
sudo apt-get update -q
# Install required packages immediately at boot
sudo apt-get install -y nfs-kernel-server cmake gcc-10 g++-10 libgflags-dev libnuma-dev memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential
cd /tmp
wget -q https://content.mellanox.com/ofed/MLNX_OFED-4.9-3.1.5.0/MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64.tgz
tar xzf MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64.tgz
cd MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --basic --user-space-only --without-fw-update --force
sudo /etc/init.d/openibd restart || true

# Setup NFS
sudo mkdir -p /mydata
# Try to chown to regular user if possible
sudo chmod 777 /mydata
echo '/mydata *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -a
sudo systemctl restart nfs-kernel-server
echo 'nfs server ready' > /tmp/nfs_ready
"""

# CN installation and NFS mount
cn_setup = """
#!/bin/bash
set -e
sudo apt-get update -q
sudo apt-get install -y nfs-common cmake gcc-10 g++-10 libgflags-dev libnuma-dev memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential
cd /tmp
wget -q https://content.mellanox.com/ofed/MLNX_OFED-4.9-3.1.5.0/MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64.tgz
tar xzf MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64.tgz
cd MLNX_OFED_LINUX-4.9-3.1.5.0-ubuntu20.04-x86_64
sudo ./mlnxofedinstall --basic --user-space-only --without-fw-update --force
sudo /etc/init.d/openibd restart || true

# Wait for mn0 to export NFS and mount it
echo "Waiting for mn0 NFS to be ready..."
while ! showmount -e mn0 > /dev/null 2>&1; do
    sleep 5
done
sudo mkdir -p /mydata
sudo mount -t nfs mn0:/mydata /mydata
echo "mn0:/mydata /mydata nfs defaults 0 0" | sudo tee -a /etc/fstab
sudo chmod 777 /mydata
"""

lan = request.LAN("deft-lan")
lan.bandwidth = 100000  # 100 gbps

mn_nodes = []
for i in range(NUM_MN):
    mn = request.RawPC("mn{}".format(i))
    mn.hardware_type = NODE_TYPE
    mn.disk_image = DISK_IMAGE
    
    if i == 0:
        mn.addService(pg.Execute(shell="bash", command=mn_setup))
    else:
        # Other MNs act like CNs in terms of setup (they just need to mount NFS)
        mn.addService(pg.Execute(shell="bash", command=cn_setup))

    iface = mn.addInterface("iface-mn{}".format(i))
    iface.bandwidth = 100000
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
    lan.addInterface(iface)
    cn_nodes.append(cn)

pc.printRequestRSpec()
