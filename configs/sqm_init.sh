#!/bin/sh
# 🚀 Ci5 SQM Init (v7.4-RC-1)
# CAKE is applied ONLY to the physical WAN interface (eth1 or eth1.VLAN)
# NOT to pppoe-wan (which rides on top of eth1)

# Determine target interface
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    TARGET_IFACE="${WAN_IFACE}.${WAN_VLAN}"
else
    TARGET_IFACE="${WAN_IFACE:-eth1}"
fi

echo "[*] Configuring SQM on: $TARGET_IFACE"

# Clear any existing SQM config
uci -q delete sqm.eth1

# Create SQM configuration for physical interface only
uci set sqm.eth1=queue
uci set sqm.eth1.interface="$TARGET_IFACE"
uci set sqm.eth1.qdisc='cake'
uci set sqm.eth1.script='layer_cake.qos'

echo "    -> Applying SQM Tuning for: $LINK_TYPE"
case "$LINK_TYPE" in
    dsl)
        uci set sqm.eth1.linklayer='atm'
        uci set sqm.eth1.overhead='44'
        ;;
    starlink)
        uci set sqm.eth1.linklayer='ethernet'
        uci set sqm.eth1.overhead='0'
        ;;
    *)
        # Fiber/Ethernet default
        uci set sqm.eth1.linklayer='ethernet'
        uci set sqm.eth1.overhead='40'
        ;;
esac

# Disabled by default - speed_wizard.sh will enable with correct bandwidth
uci set sqm.eth1.enabled='0'
uci commit sqm

# ─────────────────────────────────────────────────────────────
# PPPOE PROTECTION: Prevent CAKE from being applied to pppoe-wan
# ─────────────────────────────────────────────────────────────
# This is critical for PPPoE users: CAKE should only be on eth1,
# not on the pppoe-wan virtual interface that rides on top of it.

if [ "$WAN_PROTO" = "pppoe" ]; then
    echo "    -> PPPoE detected: Installing qdisc guard"
    
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/99-pppoe-noqdisc << 'GUARD'
#!/bin/sh
# Ci5: Prevent CAKE from pppoe-wan (v7.4-RC-1)
# CAKE must only be on the physical interface (eth1), not the PPP overlay
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && {
    sleep 2
    PPPOE_DEV=$(ip link show 2>/dev/null | grep pppoe | awk -F: '{print $2}' | tr -d ' ' | head -1)
    if [ -n "$PPPOE_DEV" ]; then
        if tc qdisc show dev "$PPPOE_DEV" 2>/dev/null | grep -q cake; then
            tc qdisc del dev "$PPPOE_DEV" root 2>/dev/null
            logger -t ci5-sqm "Removed spurious CAKE from $PPPOE_DEV"
        fi
    fi
}
GUARD
    chmod +x /etc/hotplug.d/iface/99-pppoe-noqdisc
fi

echo "[*] SQM configuration complete"
