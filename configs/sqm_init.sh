#!/bin/sh
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    TARGET_IFACE="${WAN_IFACE}.${WAN_VLAN}"
else
    TARGET_IFACE="${WAN_IFACE}"
fi

uci set sqm.eth1=queue
uci set sqm.eth1.interface="$TARGET_IFACE"
uci set sqm.eth1.qdisc='cake'
uci set sqm.eth1.script='layer_cake.qos'

echo "    -> Applying SQM Tuning for: $LINK_TYPE"
case "$LINK_TYPE" in
    dsl)
        uci set sqm.eth1.linklayer='atm'; uci set sqm.eth1.overhead='44' ;;
    starlink)
        uci set sqm.eth1.linklayer='ethernet'; uci set sqm.eth1.overhead='0' ;;
    *)
        uci set sqm.eth1.linklayer='ethernet'; uci set sqm.eth1.overhead='40' ;;
esac
uci set sqm.eth1.enabled='0' 
uci commit sqm
