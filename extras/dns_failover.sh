#!/bin/sh
# 🛡️ Ci5 DNS Failover Watchdog (v7.4-RC-1)
#
# Purpose: Monitors AdGuard Home container and automatically fails over
#          to Unbound if AdGuard becomes unavailable.
#
# Behavior:
#   - Normal: AdGuard on :53 → Unbound on :5335 (upstream)
#   - Failover: Unbound promoted to :53, direct resolution
#   - Recovery: Auto-restores when AdGuard comes back
#
# Install: This script is automatically installed by install-full.sh
# Manual:  cp dns_failover.sh /etc/ci5-dns-failover.sh
#          cp dns_failover.init /etc/init.d/ci5-dns-failover
#          /etc/init.d/ci5-dns-failover enable && start

ADGUARD_PORT=53
UNBOUND_PORT=5335
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
FAIL_COUNT=0
FALLBACK_ACTIVE=0

log() {
    logger -t ci5-dns-failover "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_adguard() {
    # Check 1: Is the container running?
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^adguard(home)?$'; then
        return 1
    fi
    
    # Check 2: Is it actually responding on port 53?
    if ! nc -z -w2 127.0.0.1 $ADGUARD_PORT 2>/dev/null; then
        return 1
    fi
    
    # Check 3: Can it resolve a query? (optional, more thorough)
    # if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    #     return 1
    # fi
    
    return 0
}

check_unbound() {
    if pgrep -x unbound >/dev/null 2>&1; then
        if nc -z -w2 127.0.0.1 $UNBOUND_PORT 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

enable_unbound_primary() {
    log "🚨 AdGuard DOWN - Activating Unbound fallback on :53"
    
    # Ensure dnsmasq is out of the way
    uci set dhcp.@dnsmasq[0].port='53535'
    uci commit dhcp
    /etc/init.d/dnsmasq restart 2>/dev/null
    
    # Promote Unbound to port 53
    uci set unbound.ub_main.listen_port='53'
    uci set unbound.ub_main.localservice='0'
    uci commit unbound
    /etc/init.d/unbound restart
    
    sleep 2
    
    # Verify Unbound is now on :53
    if nc -z -w2 127.0.0.1 53 2>/dev/null; then
        FALLBACK_ACTIVE=1
        log "✅ Unbound now serving DNS on :53"
    else
        log "❌ CRITICAL: Failed to start Unbound on :53"
    fi
}

restore_adguard_primary() {
    log "✅ AdGuard RECOVERED - Restoring normal DNS chain"
    
    # Demote Unbound back to upstream port
    uci set unbound.ub_main.listen_port='5335'
    uci set unbound.ub_main.localservice='1'
    uci commit unbound
    /etc/init.d/unbound restart
    
    sleep 2
    
    # AdGuard should now be answering on :53
    if nc -z -w2 127.0.0.1 53 2>/dev/null; then
        FALLBACK_ACTIVE=0
        FAIL_COUNT=0
        log "✅ AdGuard restored as primary DNS on :53"
    else
        log "⚠️ AdGuard may not be fully ready, keeping watch"
    fi
}

# ─────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────
log "🚀 DNS Failover Watchdog started (v7.4-RC-1)"
log "   AdGuard check interval: ${CHECK_INTERVAL}s"
log "   Fail threshold: ${FAIL_THRESHOLD} consecutive failures"

# Initial state check
if check_unbound; then
    log "✓ Unbound available on :${UNBOUND_PORT}"
else
    log "⚠️ Unbound not detected - failover may not work"
fi

while true; do
    if check_adguard; then
        # AdGuard is healthy
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log "✓ AdGuard responding (recovered from $FAIL_COUNT failures)"
        fi
        FAIL_COUNT=0
        
        # If we were in fallback mode, restore normal operation
        if [ "$FALLBACK_ACTIVE" = "1" ]; then
            restore_adguard_primary
        fi
    else
        # AdGuard is not responding
        FAIL_COUNT=$((FAIL_COUNT + 1))
        
        if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
            log "⚠️ AdGuard check failed ($FAIL_COUNT/$FAIL_THRESHOLD)"
        fi
        
        # If we've hit the threshold and haven't failed over yet
        if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ] && [ "$FALLBACK_ACTIVE" = "0" ]; then
            enable_unbound_primary
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
