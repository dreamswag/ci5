#!/bin/sh
# 🕵️‍♂️ Paranoia Watchdog - Fail-Closed Security

CRITICAL="suricata crowdsec"
WAN="eth1"

while true; do
    FAIL=0
    for c in $CRITICAL; do
        if ! docker ps | grep -q "$c"; then FAIL=1; fi
    done

    if [ $FAIL -eq 1 ]; then
        ip link set $WAN down
        logger -t ci5-watchdog "🚨 KILL SWITCH: $WAN DOWN"
    else
        # Only up if it was down
        if ip link show $WAN | grep -q "DOWN"; then
            ip link set $WAN up
            logger -t ci5-watchdog "✅ Systems Recovered"
        fi
    fi
    sleep 10
done
