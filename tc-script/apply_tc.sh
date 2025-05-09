#!/bin/bash

# Variables
IFACE="lo"
BITRATE="80mbit"

# Load IFB module
sudo modprobe ifb numifbs=1

# Set up IFB interface
sudo ip link set dev ifb0 up

# Clear existing qdiscs (if any)
sudo tc qdisc del dev $IFACE root 2>/dev/null
sudo tc qdisc del dev $IFACE ingress 2>/dev/null
sudo tc qdisc del dev ifb0 root 2>/dev/null

# Egress (upload) shaping on $IFACE
sudo tc qdisc add dev $IFACE root handle 1: htb default 10
sudo tc class add dev $IFACE parent 1: classid 1:1 htb rate $BITRATE
sudo tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $BITRATE

# Redirect ingress (download) traffic to IFB
sudo tc qdisc add dev $IFACE handle ffff: ingress
sudo tc filter add dev $IFACE parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

# Ingress (download) shaping on IFB
sudo tc qdisc add dev ifb0 root handle 1: htb default 10
sudo tc class add dev ifb0 parent 1: classid 1:1 htb rate $BITRATE
sudo tc class add dev ifb0 parent 1:1 classid 1:10 htb rate $BITRATE

echo "✅ Bandwidth constraints of $BITRATE applied on interface $IFACE (upload/download)."

