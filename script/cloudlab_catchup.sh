#!/bin/bash
# update old cloudlab nodes to match new profile
set -e

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
    echo "error: please run on mn0"
    exit 1
fi

echo "setting up ssh keys so mn0 can talk to cn nodes..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

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
    ssh -o StrictHostKeyChecking=no $node "sudo apt-get install -y nfs-common cmake gcc-10 g++-10 libgflags-dev libnuma-dev memcached libmemcached-dev libboost-all-dev ibverbs-utils infiniband-diags autoconf automake libtool build-essential"
    
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
