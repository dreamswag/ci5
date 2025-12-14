#!/bin/sh
# 🕵️‍♂️ Paranoia Watchdog

# Load Config
if [ -f "$(dirname "$0")/../ci5.config" ]; then
    . "$(dirname "$0")/../ci5.config"
elif [ -f "/root/ci5/ci5.config" ]; then
    . "/root/ci5/ci5.config"
fi

# Target correct WAN
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    WAN="${WAN_IFACE}.${WAN_VLAN}"
else
    WAN="${WAN_IFACE:-eth1}"
fi

CRITICAL="suricata crowdsec"

while true; do
    FAIL=0
    for c in $CRITICAL; do
        if ! docker ps | grep -q "$c"; then FAIL=1; fi
    done

    if [ $FAIL -eq 1 ]; then
        ip link set $WAN down
        logger -t ci5-watchdog "🚨 KILL SWITCH: $WAN DOWN"
    else
        # Only up if it was down (check logic can be improved but this works)
        if ip link show $WAN | grep -q "DOWN"; then
            ip link set $WAN up
            logger -t ci5-watchdog "✅ Systems Recovered"
        fi
    fi
    sleep 10
done
