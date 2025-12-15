#!/bin/sh
# 👁️ Ci5 Paranoia Watchdog (Optional Security)
# Checks if Suricata is running. If not, kills WAN.
CHECK_INTERVAL=5
while true; do
    if ! docker ps | grep -q suricata; then
        logger -t paranoia "🚨 SECURITY FAILURE - KILLING WAN"
        ifdown wan
        exit 1
    fi
    sleep $CHECK_INTERVAL
done
