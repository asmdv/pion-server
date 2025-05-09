#!/bin/bash

# Variables
IFACE="lo"

# Remove qdiscs from interfaces
sudo tc qdisc del dev $IFACE root 2>/dev/null
sudo tc qdisc del dev $IFACE ingress 2>/dev/null
sudo tc qdisc del dev ifb0 root 2>/dev/null

# Bring down IFB interface
sudo ip link set dev ifb0 down

echo "🗑️ Bandwidth constraints removed from interface $IFACE."

