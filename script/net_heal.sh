#!/bin/bash
# Automatically recovers missing 10.10.1.X IPs on Mellanox interfaces

HOSTNAME=$(hostname -s)
if [[ "$HOSTNAME" == "mn0" ]]; then
    TARGET_IP="10.10.1.1"
elif [[ "$HOSTNAME" == cn* ]]; then
    IDX=${HOSTNAME//[!0-9]/}
    TARGET_IP="10.10.1.$((IDX + 2))"
else
    exit 0
fi

if command -v ibdev2netdev >/dev/null 2>&1; then
    RDMA_IFACE=$(sudo ibdev2netdev | head -n 1 | awk '{print $5}')
    if [[ -n "$RDMA_IFACE" ]]; then
        sudo ip link set dev "$RDMA_IFACE" up || true
        if ! ip addr show "$RDMA_IFACE" | grep -q "$TARGET_IP"; then
            echo "healing network: mapping $TARGET_IP to $RDMA_IFACE"
            sudo ip addr add "$TARGET_IP/24" dev "$RDMA_IFACE" || true
        else
            echo "network healthy: $TARGET_IP already mapped on $RDMA_IFACE"
        fi
    fi
fi
