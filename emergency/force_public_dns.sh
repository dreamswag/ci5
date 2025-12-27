#!/bin/sh
# 🆘 Ci5 Emergency DNS Rescue (v7.5-RELEASE)
# Route: /rescue
# Purpose: Force public DNS resolvers when local DNS fails
#          Restores basic internet access for troubleshooting
#
# Usage: curl ci5.run/rescue | sh
#
# What it does:
#   1. Bypasses AdGuard/Unbound and uses public resolvers directly
#   2. Flushes DNS cache
#   3. Tests connectivity
#   4. Provides instructions to restore normal operation

set -e

# ─────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Public DNS servers (privacy-respecting choices)
DNS_PRIMARY="1.1.1.1"           # Cloudflare
DNS_SECONDARY="9.9.9.9"         # Quad9
DNS_TERTIARY="8.8.8.8"          # Google (fallback)

BACKUP_DIR="/tmp/ci5_dns_rescue_$(date +%Y%m%d_%H%M%S)"

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
log_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_err() {
    echo -e "${RED}[✗]${NC} $1"
}

log_info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# ─────────────────────────────────────────────────────────────
# DIAGNOSE CURRENT STATE
# ─────────────────────────────────────────────────────────────
diagnose() {
    echo ""
    echo -e "${CYAN}[*] Diagnosing current DNS state...${NC}"
    echo ""
    
    # Check raw connectivity first
    echo -n "   Raw IP connectivity (1.1.1.1): "
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        RAW_CONN=1
    else
        echo -e "${RED}FAILED${NC}"
        RAW_CONN=0
    fi
    
    # Check DNS resolution
    echo -n "   DNS resolution (google.com):  "
    if nslookup google.com >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        DNS_OK=1
    else
        echo -e "${RED}FAILED${NC}"
        DNS_OK=0
    fi
    
    # Check local resolvers
    echo -n "   Unbound (127.0.0.1:5335):     "
    if nc -z -w2 127.0.0.1 5335 2>/dev/null; then
        echo -e "${GREEN}LISTENING${NC}"
    else
        echo -e "${YELLOW}DOWN${NC}"
    fi
    
    echo -n "   AdGuard (127.0.0.1:53):       "
    if nc -z -w2 127.0.0.1 53 2>/dev/null; then
        echo -e "${GREEN}LISTENING${NC}"
    else
        echo -e "${YELLOW}DOWN${NC}"
    fi
    
    # Check dnsmasq
    echo -n "   Dnsmasq:                      "
    if pgrep dnsmasq >/dev/null 2>&1; then
        DNSMASQ_PORT=$(uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "53")
        echo -e "${GREEN}RUNNING (port $DNSMASQ_PORT)${NC}"
    else
        echo -e "${YELLOW}STOPPED${NC}"
    fi
    
    echo ""
    
    # Decision
    if [ "$RAW_CONN" -eq 0 ]; then
        log_err "No raw IP connectivity - this is a network/WAN issue, not DNS"
        log_info "Check: Is WAN cable connected? Is PPPoE authenticated?"
        log_info "Run: ifconfig wan / logread | grep ppp"
        exit 1
    fi
    
    if [ "$DNS_OK" -eq 1 ]; then
        log_ok "DNS is already working!"
        echo ""
        echo -n "Force rescue mode anyway? [y/N]: "
        read -r FORCE_RESCUE
        if [ "$FORCE_RESCUE" != "y" ] && [ "$FORCE_RESCUE" != "Y" ]; then
            exit 0
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# BACKUP CURRENT CONFIG
# ─────────────────────────────────────────────────────────────
backup_config() {
    echo ""
    log_info "Creating backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup resolv.conf
    cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    cp /tmp/resolv.conf "$BACKUP_DIR/tmp_resolv.conf.bak" 2>/dev/null || true
    cp /tmp/resolv.conf.d/* "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup UCI settings
    uci export dhcp > "$BACKUP_DIR/dhcp.uci" 2>/dev/null || true
    uci export network > "$BACKUP_DIR/network.uci" 2>/dev/null || true
    
    # Save current dnsmasq port
    echo "$(uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo '53')" > "$BACKUP_DIR/dnsmasq_port"
    echo "$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo '0')" > "$BACKUP_DIR/dnsmasq_noresolv"
    
    log_ok "Backup saved to $BACKUP_DIR"
}

# ─────────────────────────────────────────────────────────────
# APPLY EMERGENCY DNS
# ─────────────────────────────────────────────────────────────
apply_rescue_dns() {
    echo ""
    log_info "Applying emergency DNS configuration..."
    
    # Method 1: Direct resolv.conf override
    cat > /tmp/resolv.conf.rescue << EOF
# Ci5 Emergency DNS Rescue Mode
# Generated: $(date)
# To restore: curl ci5.run/rescue | sh -s restore
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY
nameserver $DNS_TERTIARY
EOF

    # Backup and replace
    cp /tmp/resolv.conf.rescue /tmp/resolv.conf
    
    # Some systems use /etc/resolv.conf directly
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /tmp/resolv.conf.rescue /etc/resolv.conf
    fi
    
    log_ok "Direct resolv.conf updated"
    
    # Method 2: Configure dnsmasq to forward to public DNS
    echo ""
    log_info "Configuring dnsmasq fallback..."
    
    # Set dnsmasq to listen on port 53 and forward to public DNS
    uci set dhcp.@dnsmasq[0].port='53'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].localservice='0'
    
    # Clear existing servers
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done 2>/dev/null
    
    # Add public DNS servers
    uci add_list dhcp.@dnsmasq[0].server="$DNS_PRIMARY"
    uci add_list dhcp.@dnsmasq[0].server="$DNS_SECONDARY"
    
    uci commit dhcp
    
    log_ok "Dnsmasq configured to use public DNS"
    
    # Method 3: Stop competing DNS services temporarily
    echo ""
    log_info "Pausing local DNS services..."
    
    # Stop AdGuard if running via Docker
    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "adguardhome"; then
            docker stop adguardhome 2>/dev/null || true
            log_ok "AdGuard Home paused"
        fi
    fi
    
    # Don't stop Unbound - just make sure dnsmasq doesn't point to it
    # (Unbound can stay running for when we restore)
    
    # Restart dnsmasq with new config
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    
    log_ok "DNS services reconfigured"
}

# ─────────────────────────────────────────────────────────────
# FLUSH DNS CACHE
# ─────────────────────────────────────────────────────────────
flush_cache() {
    echo ""
    log_info "Flushing DNS caches..."
    
    # Flush dnsmasq cache
    killall -HUP dnsmasq 2>/dev/null || true
    
    # Flush Unbound cache if running
    if command -v unbound-control >/dev/null 2>&1; then
        unbound-control flush_zone . 2>/dev/null || true
    fi
    
    # Clear conntrack (may help with stuck connections)
    if [ -f /proc/net/nf_conntrack ]; then
        echo "f" > /proc/net/nf_conntrack 2>/dev/null || true
    fi
    
    log_ok "Caches flushed"
}

# ─────────────────────────────────────────────────────────────
# TEST CONNECTIVITY
# ─────────────────────────────────────────────────────────────
test_connectivity() {
    echo ""
    log_info "Testing DNS resolution..."
    
    sleep 2  # Give services time to restart
    
    TESTS_PASSED=0
    
    for domain in google.com cloudflare.com github.com; do
        echo -n "   Resolving $domain: "
        if nslookup "$domain" >/dev/null 2>&1; then
            IP=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | head -1 | awk '{print $2}')
            echo -e "${GREEN}$IP${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
    
    echo ""
    
    if [ "$TESTS_PASSED" -ge 2 ]; then
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────
# RESTORE NORMAL OPERATION
# ─────────────────────────────────────────────────────────────
restore_normal() {
    echo ""
    echo -e "${CYAN}[*] Restoring normal DNS configuration...${NC}"
    echo ""
    
    # Find the most recent backup
    LATEST_BACKUP=$(ls -td /tmp/ci5_dns_rescue_* 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
        log_err "No rescue backup found"
        log_info "Run the full rescue first, then restore later"
        exit 1
    fi
    
    log_info "Restoring from: $LATEST_BACKUP"
    
    # Restore dnsmasq settings
    OLD_PORT=$(cat "$LATEST_BACKUP/dnsmasq_port" 2>/dev/null || echo "53535")
    OLD_NORESOLV=$(cat "$LATEST_BACKUP/dnsmasq_noresolv" 2>/dev/null || echo "1")
    
    uci set dhcp.@dnsmasq[0].port="$OLD_PORT"
    uci set dhcp.@dnsmasq[0].noresolv="$OLD_NORESOLV"
    
    # Clear public DNS servers
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done 2>/dev/null
    
    # Restore to point to Unbound
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
    
    uci commit dhcp
    
    # Restore resolv.conf
    if [ -f "$LATEST_BACKUP/resolv.conf.bak" ]; then
        cp "$LATEST_BACKUP/resolv.conf.bak" /etc/resolv.conf 2>/dev/null || true
    fi
    
    # Restart AdGuard if it was running
    if command -v docker >/dev/null 2>&1; then
        docker start adguardhome 2>/dev/null || true
    fi
    
    # Restart services
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    /etc/init.d/unbound restart 2>/dev/null || true
    
    log_ok "Normal DNS configuration restored"
    log_info "Testing..."
    
    sleep 2
    
    if nslookup google.com >/dev/null 2>&1; then
        log_ok "DNS working normally"
    else
        log_warn "DNS may need additional troubleshooting"
        log_info "Run: sh /opt/ci5/validate.sh"
    fi
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${RED}🆘 Ci5 EMERGENCY DNS RESCUE (v7.5)${NC}                    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    # Check for restore mode
    if [ "$1" = "restore" ] || [ "$1" = "--restore" ] || [ "$1" = "-r" ]; then
        restore_normal
        exit 0
    fi
    
    # Diagnostic
    diagnose
    
    # Backup current state
    backup_config
    
    # Apply rescue DNS
    apply_rescue_dns
    
    # Flush caches
    flush_cache
    
    # Test
    if test_connectivity; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ✅ DNS RESCUE SUCCESSFUL                             ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_ok "Internet access restored via public DNS"
        echo ""
        echo -e "${YELLOW}[!] IMPORTANT:${NC}"
        echo "    This is EMERGENCY mode - DNS filtering is BYPASSED"
        echo ""
        echo "    To restore normal Ci5 DNS (AdGuard + Unbound):"
        echo "    ${CYAN}curl ci5.run/rescue | sh -s restore${NC}"
        echo ""
        echo "    Or fix the underlying issue:"
        echo "    ${CYAN}curl ci5.run/heal | sh${NC}"
        echo ""
    else
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              ❌ DNS RESCUE FAILED                                  ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_err "Could not establish DNS resolution"
        log_info "This may be a deeper network issue"
        log_info "Check WAN connectivity: ping 1.1.1.1"
        log_info "Check WAN interface: ifconfig"
        log_info "Check logs: logread | tail -50"
        exit 1
    fi
}

main "$@"