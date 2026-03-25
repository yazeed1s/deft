#!/bin/bash
# script/link_cluster.sh

USER="yazeed_n"
KEY="~/.ssh/id_cloudlab"
MN=$1
shift
CNS=("$@")

if [ -z "$MN" ] || [ ${#CNS[@]} -eq 0 ]; then
    echo "usage: ./link_cluster.sh <mn> <cn1> [cn2...]"
    exit 1
fi

echo "fetching pub key from $MN"
MN_KEY=$(ssh -i "$KEY" -o StrictHostKeyChecking=no "$USER@$MN" "ssh-keygen -t rsa -f ~/.ssh/id_rsa -N '' >/dev/null 2>&1; cat ~/.ssh/id_rsa.pub")

if [ -z "$MN_KEY" ]; then
    echo "error: failed to fetch key"
    exit 1
fi

for CN in "${CNS[@]}"; do
    echo "linking $CN"
    ssh -i "$KEY" -o StrictHostKeyChecking=no "$USER@$CN" "echo \"$MN_KEY\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    if [ $? -ne 0 ]; then
        echo "error: failed on $CN"
    fi
done

echo "done"
