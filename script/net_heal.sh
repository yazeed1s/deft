#!/bin/bash
# Automatically recovers missing 10.10.1.X IPs on Mellanox interfaces by restoring the CloudLab VLAN

if ! command -v ibdev2netdev >/dev/null 2>&1; then
    exit 0
fi

RDMA_IFACE=$(sudo ibdev2netdev | head -n 1 | awk '{print $5}')
if [[ -z "$RDMA_IFACE" ]]; then
    exit 0
fi

IFMAP=/var/emulab/boot/ifmap
if [[ ! -f $IFMAP ]]; then
    echo "error: No ifmap found. Cannot restore CloudLab network."
    exit 1
fi

# Find the vlan line, typically looks like: vlan306 10.10.1.1 02fcbf43aeb2
TARGET_IP=$(grep -m 1 vlan "$IFMAP" | awk '{print $2}')
RAW_MAC=$(grep -m 1 vlan "$IFMAP" | awk '{print $3}')
VLAN_NAME=$(grep -m 1 vlan "$IFMAP" | awk '{print $1}')

if [[ -z "$VLAN_NAME" || -z "$TARGET_IP" || -z "$RAW_MAC" ]]; then
    echo "error: Could not parse vlan info from $IFMAP."
    exit 1
fi

# Extract VLAN ID from the name (e.g. vlan306 -> 306)
VLAN_ID=${VLAN_NAME//[!0-9]/}

# Format MAC (e.g. 02fcbf43aeb2 -> 02:fc:bf:43:ae:b2)
MAC=$(echo "$RAW_MAC" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')

if ip addr show "$VLAN_NAME" >/dev/null 2>&1 && ip addr show "$VLAN_NAME" | grep -q "$TARGET_IP"; then
    echo "network healthy: $TARGET_IP already mapped on $VLAN_NAME"
    exit 0
fi

echo "healing network: mapping $TARGET_IP and MAC $MAC to $VLAN_NAME over $RDMA_IFACE"

# Clean up incorrect direct mapping on the physical interface if it exists
sudo ip addr flush dev "$RDMA_IFACE" || true

sudo ip link set dev "$RDMA_IFACE" up || true
sudo ip link set dev "$RDMA_IFACE" mtu 9000 || true
sudo modprobe 8021q || true

# Recreate the tagged VLAN interface and assign proper MAC & IP
sudo ip link add link "$RDMA_IFACE" name "$VLAN_NAME" type vlan id "$VLAN_ID" 2>/dev/null || true
sudo ip link set dev "$VLAN_NAME" down
sudo ip link set dev "$VLAN_NAME" address "$MAC"
sudo ip addr add "$TARGET_IP/24" dev "$VLAN_NAME" 2>/dev/null || true
sudo ip link set dev "$VLAN_NAME" up
sudo ip link set dev "$VLAN_NAME" mtu 9000
