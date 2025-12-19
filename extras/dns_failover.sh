#!/bin/sh
# 🛡️ Ci5 DNS Failover (Docker Edition)
# Usage: ./dns_failover.sh [init|watch]

CONFIG_DIR="/opt/ci5/configs/unbound"
LINK="$CONFIG_DIR/unbound.conf"
PRIM="$CONFIG_DIR/unbound.conf.primary"
FAIL="$CONFIG_DIR/unbound.conf.failover"

if [ "$1" = "init" ]; then
    # Create templates if missing
    if [ ! -f "$PRIM" ]; then cp "$LINK" "$PRIM"; fi
    cp "$PRIM" "$FAIL"
    sed -i 's/port: 5335/port: 53/g' "$FAIL"
    exit 0
fi

log() { logger -t ci5-dns "Watchdog: $1"; }
test_dns() { nslookup -port=$1 google.com 127.0.0.1 >/dev/null 2>&1; return $?; }

while true; do
    # Check if AdGuard container is running
    if [ "$(docker inspect -f '{{.State.Running}}' adguardhome 2>/dev/null)" = "true" ]; then
        # Check if Primary config is active
        if [ "$(readlink -f $LINK)" != "$PRIM" ]; then
            log "Restoring Primary Config..."
            ln -sf "$PRIM" "$LINK"
            docker restart unbound
        fi
        
        # Test AdGuard (Port 53)
        if ! test_dns "53"; then
            FAIL_COUNT=$((FAIL_COUNT+1))
            if [ $FAIL_COUNT -ge 3 ]; then
                log "AdGuard Dead. Failing over to Unbound on Port 53..."
                docker stop adguardhome
                ln -sf "$FAIL" "$LINK"
                docker restart unbound
            fi
        else
            FAIL_COUNT=0
        fi
    else
        # AdGuard stopped/crashed - Try to recover every 60s
        sleep 60
        log "Attempting Recovery..."
        ln -sf "$PRIM" "$LINK"
        docker restart unbound
        docker start adguardhome
    fi
    sleep 10
done