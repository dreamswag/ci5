#!/bin/sh
# 🛡️ Ci5 DNS Failover Watchdog v7.4-RC-1
# Logic: AdGuard (53) -> Unbound (5335). If AdGuard dies, Unbound takes 53.

ADGUARD_CONTAINER="adguard"
UNBOUND_CFG="unbound.ub_main"
CHECK_DOMAIN="google.com"
MAX_FAILURES=3
CHECK_INTERVAL=10
RECOVERY_INTERVAL=60

FAIL_COUNT=0
MODE="PRIMARY" # PRIMARY (AdGuard) or FAILOVER (Unbound)

log() { logger -t ci5-dns-watchdog "$1"; }

# Test DNS resolution on specific IP/Port
test_dns() {
    # -W 2 (wait 2s), -p (port)
    nslookup -port=$2 $CHECK_DOMAIN $1 >/dev/null 2>&1
    return $?
}

switch_to_failover() {
    log "🚨 AdGuard Failed. Switching to Unbound on Port 53 (Failover Mode)"
    # 1. Move Unbound to 53
    uci set ${UNBOUND_CFG}.listen_port='53'
    uci set ${UNBOUND_CFG}.localservice='0'
    uci commit unbound
    /etc/init.d/unbound restart
    
    # 2. Stop AdGuard to prevent port bind conflicts
    docker stop $ADGUARD_CONTAINER >/dev/null 2>&1
    
    MODE="FAILOVER"
    FAIL_COUNT=0
}

switch_to_primary() {
    log "♻️ Attempting Recovery: Restoring AdGuard..."
    # 1. Move Unbound back to 5335
    uci set ${UNBOUND_CFG}.listen_port='5335'
    uci set ${UNBOUND_CFG}.localservice='1'
    uci commit unbound
    /etc/init.d/unbound restart
    
    # 2. Start AdGuard
    docker start $ADGUARD_CONTAINER
    
    # 3. Grace period for AdGuard to load blocklists
    sleep 15
    
    # 4. Verify
    if test_dns "127.0.0.1" "53"; then
        log "✅ AdGuard is healthy. Primary mode restored."
        MODE="PRIMARY"
        FAIL_COUNT=0
    else
        log "❌ AdGuard failed to recover. Reverting to Failover."
        switch_to_failover
    fi
}

log "🚀 Watchdog Started. Initial Grace Period (10s)..."
sleep 10

while true; do
    if [ "$MODE" = "PRIMARY" ]; then
        # Check if AdGuard is resolving
        if test_dns "127.0.0.1" "53"; then
            FAIL_COUNT=0
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
                switch_to_failover
            fi
        fi
        sleep $CHECK_INTERVAL
        
    elif [ "$MODE" = "FAILOVER" ]; then
        # We are in failover. Internet works via Unbound :53.
        # Periodically try to recover.
        sleep $RECOVERY_INTERVAL
        switch_to_primary
    fi
done
