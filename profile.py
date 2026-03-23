import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()
request = pc.makeRequestRSpec()

# how many memory nodes and compute nodes we need
# paper use 2 MN and 10 CN in most experiments (ses section 5.2 in the paper)
NUM_MN = 2
NUM_CN = 10

# r650 is the machine type at clemson cluster
# it has mellanox connectx-6 NIC which is good because
# deft paper require connectx-5 or above (see system requirements in readme)
# also r650 have 96GB memory which MN need to store the whole tree index
NODE_TYPE = "r650"

# ubuntu 20.04 because paper use 18.04 but cloudlab not support it good anymore
# 20.04 still work with MLNX_OFED 4.9 which deft need
DISK_IMAGE = "urn:publicid:IDN+clemson.cloudlab.us+image+emulab-ops:UBUNTU20-64-STD"

#  memory nodes
mn_nodes = []
# MN is where deft tree index actually live in memory
# paper explain in section 2.1 that MN have lot of memory but weak CPU
# this is important because CN access MN memory directly with RDMA
# without asking MN cpu to do anything (this is "one-sided" RDMA)
for i in range(NUM_MN):
    mn = request.RawPC("mn{}".format(i))
    mn.hardware_type = NODE_TYPE
    mn.disk_image = DISK_IMAGE
    mn_nodes.append(mn)

# compute nodes
cn_nodes = []
# CN is where benchmark client threads run
# paper use 30 threads per CN, so with 10 CN = 300 threads total (section 5.2)
# each CN also have 1GB local memory for index cache
# this cache is very important for performance, paper talk about it a lot
# when cache is full the CN need more RDMA round trips which is slow
for i in range(NUM_CN):
    cn = request.RawPC("cn{}".format(i))
    cn.hardware_type = NODE_TYPE
    cn.disk_image = DISK_IMAGE
    cn_nodes.append(cn)

# nfs setup on mn0
# readme say we need to mount repo with nfs on all nodes with same path
# so we build deft code only one time on mn0
# then all other nodes can see the binary through nfs, no need build again
# this save a lot of time when you have 10 nodes
mn_nodes[0].addService(pg.Execute(
    shell="bash",
    command="""
    sudo apt-get update -q
    sudo apt-get install -y nfs-kernel-server
    sudo mkdir -p /mydata
    echo '/mydata *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
    sudo exportfs -a
    sudo systemctl restart nfs-kernel-server
    echo 'nfs server ready' > /tmp/nfs_ready
    """
))

# network between all nodes
# all 10 nodes need to be on same high speed network for RDMA to work
# paper use 100gbps infiniband switch at clemson (section 5.1)
# this is very critical because deft paper show in figure 1 that
# when node size is big, the network bandwidth become bottleneck
# deft design specifically try to not waste this 100gbps bandwidth
# by reducing how much data it read for each operation
lan = request.LAN("deft-lan")
lan.bandwidth = 100000  # this is in kbps so 100000 = 100 gbps

for i in range(NUM_MN):
    node = request.get_node("mn{}".format(i))
    iface = node.addInterface("iface-mn{}".format(i))
    iface.bandwidth = 100000
    lan.addInterface(iface)

for i in range(NUM_CN):
    node = request.get_node("cn{}".format(i))
    iface = node.addInterface("iface-cn{}".format(i))
    iface.bandwidth = 100000
    lan.addInterface(iface)

pc.printRequestRSpec()
