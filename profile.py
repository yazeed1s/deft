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
lan.link_multiplexing = True
lan.vlan_tagging = True

# Common dependencies and builds required for Deft
common_setup = """
#!/bin/bash
set -euo pipefail

retry() {
    local attempts="$1"
    local sleep_s="$2"
    shift 2
    local i
    for i in $(seq 1 "$attempts"); do
        "$@" && return 0
        sleep "$sleep_s"
    done
    return 1
}



# Ensure experiment-LAN IP exists (some single-NIC Clemson nodes miss it at boot).
SHORT_HOST=$(hostname -s)
TARGET_IP=$(awk -v h="$SHORT_HOST" '
    $1 ~ /^10\\.10\\.1\\./ && $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") { print $1; exit }
' /etc/hosts)
if [ -n "$TARGET_IP" ] && ! ip -4 -o addr show | grep -q "10\\.10\\.1\\."; then
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    if [ -z "$IFACE" ]; then
        IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
    fi
    if [ -n "$IFACE" ]; then
        sudo ip link set dev "$IFACE" up || true
        sudo ip addr add "${TARGET_IP}/24" dev "$IFACE" 2>/dev/null || true
    fi
fi

export DEBIAN_FRONTEND=noninteractive
# Heal interrupted apt/dpkg state before installs.
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true
sudo dpkg --configure -a || true
sudo apt-get -f install -y || true

REQ_PKGS="python3 python3-pip python3-yaml python3-paramiko nfs-common \
cmake gcc g++ libboost-all-dev memcached libgoogle-perftools-dev numactl git \
autoconf automake libtool build-essential libnuma-dev rdma-core ibverbs-utils libibverbs-dev libmlx5-dev librdmacm-dev libibumad-dev libibmad-dev infiniband-diags wget curl"
MISSING=""
for p in $REQ_PKGS; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [[ -n "$MISSING" ]]; then
    retry 3 10 sudo apt-get update -q
    retry 3 10 sudo apt-get install -y $MISSING
fi

if [[ ! -f /usr/include/infiniband/verbs_exp.h ]]; then
    OFED_OS=$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); if ($2 ~ /^20/) print "ubuntu20.04"; else print "ubuntu18.04"}' /etc/os-release)
    REPO_BASE="http://linux.mellanox.com/public/repo/mlnx_ofed/4.9-5.1.0.0/${OFED_OS}/x86_64"

    sudo rm -f /etc/apt/sources.list.d/mlnx_ofed.list
    sudo tee /etc/apt/sources.list.d/mlnx_ofed.list >/dev/null <<OFEDAPT
deb [trusted=yes] ${REPO_BASE}/MLNX_LIBS ./
OFEDAPT

    retry 3 10 sudo apt-get -o Acquire::AllowInsecureRepositories=true update -q
    retry 3 10 sudo apt-get install -y --allow-downgrades --allow-change-held-packages --allow-unauthenticated \
        libibverbs1 libibverbs-dev ibverbs-utils \
        libmlx5-1 libmlx5-dev \
        librdmacm1 librdmacm-dev \
        libibumad libibmad infiniband-diags || true

    sudo ldconfig
fi

if [ ! -f /usr/local/lib/libcityhash.so ]; then
    cd /tmp
    [ -d cityhash ] || git clone https://github.com/google/cityhash.git
    cd cityhash
    ./configure
    make all check -j$(nproc)
    sudo make install
    sudo ldconfig
fi


"""

# logic for the very first memory node (mn0)
nfs_server_logic = """
sudo apt-get install -y nfs-kernel-server
sudo mkdir -p /deft_code
sudo chmod 777 /deft_code
sudo sed -i '/\\/deft_code /d' /etc/exports
echo '/deft_code *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -arv
sudo systemctl restart nfs-kernel-server
"""

# logic for all other nodes
nfs_client_logic = """
sudo mkdir -p /deft_code
for i in $(seq 1 60); do
    showmount -e mn0 2>/dev/null | grep -q '/deft_code' && break
    sleep 5
done
mountpoint -q /deft_code || sudo mount -t nfs mn0:/deft_code /deft_code
grep -q '/deft_code ' /etc/fstab || echo 'mn0:/deft_code /deft_code nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab
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
