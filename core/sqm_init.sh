#!/bin/sh
# 🚀 Ci5 SQM Init (v7.4-RC-1)
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    TARGET_IFACE="${WAN_IFACE}.${WAN_VLAN}"
else
    TARGET_IFACE="${WAN_IFACE:-eth1}"
fi

echo "[*] Configuring SQM on: $TARGET_IFACE"
uci -q delete sqm.eth1
uci set sqm.eth1=queue
uci set sqm.eth1.interface="$TARGET_IFACE"
uci set sqm.eth1.qdisc='cake'
uci set sqm.eth1.script='layer_cake.qos'
uci set sqm.eth1.linklayer='ethernet'
uci set sqm.eth1.overhead='40'
uci set sqm.eth1.enabled='0'
uci commit sqm
