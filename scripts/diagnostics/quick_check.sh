#!/bin/sh
# 🩺 Ci5 Quick Health Check (v7.5-RELEASE)
# Route: /status
# Purpose: Fast pass/fail diagnostic with exit codes
#          Useful for scripted health monitoring
#
# Usage: curl ci5.run/status | sh
#
# Exit Codes:
#   0 = All checks passed
#   1 = Critical failure (no internet)
#   2 = Warning (some services down)
#   3 = Configuration issues

set -e

# ─────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# Load config if available
[ -f "/opt/ci5/ci5.config" ] && . /opt/ci5/ci5.config
[ -f "/root/ci5/ci5.config" ] && . /root/ci5/ci5.config

# Determine WAN interface
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    WAN_TARGET="${WAN_IFACE}.${WAN_VLAN}"
else
    WAN_TARGET="${WAN_IFACE:-eth1}"
fi

# Counters
CHECKS_PASSED=0
CHECKS_WARNED=0
CHECKS_FAILED=0
TOTAL_CHECKS=0

# ─────────────────────────────────────────────────────────────
# CHECK FUNCTIONS
# ─────────────────────────────────────────────────────────────
check_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

check_warn() {
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

check_fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    printf "${RED}[FAIL]${NC} %s\n" "$1"
}

check_skip() {
    printf "${DIM}[SKIP]${NC} %s\n" "$1"
}

# ─────────────────────────────────────────────────────────────
# CHECKS
# ─────────────────────────────────────────────────────────────

# 1. Internet Connectivity (Critical)
check_internet() {
    printf "${CYAN}[1/10]${NC} Internet Connectivity... "
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        check_pass "WAN online"
    else
        check_fail "NO INTERNET"
        return 1
    fi
}

# 2. DNS Resolution (Critical)
check_dns() {
    printf "${CYAN}[2/10]${NC} DNS Resolution... "
    if nslookup google.com >/dev/null 2>&1; then
        check_pass "Resolving domains"
    elif nslookup google.com 1.1.1.1 >/dev/null 2>&1; then
        check_warn "Only via public DNS (local DNS down)"
    else
        check_fail "DNS broken"
    fi
}

# 3. Unbound
check_unbound() {
    printf "${CYAN}[3/10]${NC} Unbound (Recursive DNS)... "
    if pgrep -x unbound >/dev/null 2>&1; then
        if nc -z -w1 127.0.0.1 5335 2>/dev/null; then
            check_pass "Running on :5335"
        else
            check_warn "Running but not listening"
        fi
    else
        check_warn "Not running (using fallback DNS)"
    fi
}

# 4. SQM/CAKE
check_sqm() {
    printf "${CYAN}[4/10]${NC} SQM (CAKE) on $WAN_TARGET... "
    if tc qdisc show dev "$WAN_TARGET" 2>/dev/null | grep -q cake; then
        DOWNLOAD=$(uci get sqm.eth1.download 2>/dev/null || echo "?")
        UPLOAD=$(uci get sqm.eth1.upload 2>/dev/null || echo "?")
        check_pass "Active (${DOWNLOAD}k/${UPLOAD}k)"
    else
        check_warn "Not active (bufferbloat possible)"
    fi
}

# 5. Firewall
check_firewall() {
    printf "${CYAN}[5/10]${NC} Firewall... "
    if /etc/init.d/firewall status >/dev/null 2>&1; then
        RULES=$(nft list ruleset 2>/dev/null | grep -c "rule" || iptables -L -n 2>/dev/null | grep -c "Chain" || echo "0")
        check_pass "Active ($RULES rules)"
    else
        check_fail "Firewall DOWN"
    fi
}

# 6. VLANs
check_vlans() {
    printf "${CYAN}[6/10]${NC} VLAN Interfaces... "
    VLANS_OK=0
    VLANS_MISSING=""
    
    for vlan in 10 20 30 40; do
        if ip link show "eth0.${vlan}" >/dev/null 2>&1; then
            VLANS_OK=$((VLANS_OK + 1))
        else
            VLANS_MISSING="$VLANS_MISSING $vlan"
        fi
    done
    
    if [ "$VLANS_OK" -eq 4 ]; then
        check_pass "All 4 VLANs present"
    elif [ "$VLANS_OK" -gt 0 ]; then
        check_warn "$VLANS_OK/4 (missing:$VLANS_MISSING)"
    else
        check_warn "No VLANs configured"
    fi
}

# 7. Docker (if installed)
check_docker() {
    printf "${CYAN}[7/10]${NC} Docker Stack... "
    
    if ! command -v docker >/dev/null 2>&1; then
        check_skip "Not installed (Lite mode)"
        return 0
    fi
    
    if ! docker info >/dev/null 2>&1; then
        check_fail "Docker daemon not running"
        return 0
    fi
    
    RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
    TOTAL=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)
    
    if [ "$RUNNING" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        check_pass "$RUNNING containers running"
    elif [ "$RUNNING" -gt 0 ]; then
        check_warn "$RUNNING/$TOTAL containers running"
    else
        check_fail "No containers running"
    fi
}

# 8. AdGuard Home
check_adguard() {
    printf "${CYAN}[8/10]${NC} AdGuard Home... "
    
    if ! command -v docker >/dev/null 2>&1; then
        check_skip "Docker not installed"
        return 0
    fi
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "adguardhome"; then
        if nc -z -w1 127.0.0.1 3000 2>/dev/null; then
            check_pass "Running (web UI on :3000)"
        else
            check_warn "Container up but UI unreachable"
        fi
    else
        check_skip "Not deployed"
    fi
}

# 9. Suricata IDS
check_suricata() {
    printf "${CYAN}[9/10]${NC} Suricata IDS... "
    
    if ! command -v docker >/dev/null 2>&1; then
        check_skip "Docker not installed"
        return 0
    fi
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "suricata"; then
        # Check if actually processing
        EVE_LOG="/opt/ci5-docker/suricata/eve.json"
        if [ -f "$EVE_LOG" ]; then
            RECENT=$(find "$EVE_LOG" -mmin -5 2>/dev/null)
            if [ -n "$RECENT" ]; then
                check_pass "Active & logging"
            else
                check_warn "Running but no recent logs"
            fi
        else
            check_pass "Running"
        fi
    else
        check_skip "Not deployed"
    fi
}

# 10. System Resources
check_resources() {
    printf "${CYAN}[10/10]${NC} System Resources... "
    
    # Memory
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    MEM_PCT=$((100 - (MEM_AVAIL * 100 / MEM_TOTAL)))
    
    # CPU temp (Pi)
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        CPU_TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
    else
        CPU_TEMP=0
    fi
    
    # Load
    LOAD=$(cat /proc/loadavg | awk '{print $1}')
    
    STATUS="Mem:${MEM_PCT}%"
    [ "$CPU_TEMP" -gt 0 ] && STATUS="$STATUS Temp:${CPU_TEMP}°C"
    STATUS="$STATUS Load:$LOAD"
    
    if [ "$MEM_PCT" -gt 90 ] || [ "$CPU_TEMP" -gt 80 ]; then
        check_warn "$STATUS"
    else
        check_pass "$STATUS"
    fi
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}            ${GREEN}🩺 Ci5 QUICK HEALTH CHECK (v7.5)${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Run all checks
    check_internet || CRITICAL_FAIL=1
    check_dns
    check_unbound
    check_sqm
    check_firewall
    check_vlans
    check_docker
    check_adguard
    check_suricata
    check_resources
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    
    # Summary
    if [ "${CRITICAL_FAIL:-0}" -eq 1 ]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    ❌ CRITICAL: NO INTERNET                       ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "   Troubleshooting:"
        echo "   • Check WAN cable"
        echo "   • Run: ifconfig ${WAN_IFACE:-eth1}"
        echo "   • Run: logread | grep -i wan"
        echo "   • Try: curl ci5.run/rescue | sh"
        echo ""
        exit 1
    elif [ "$CHECKS_FAILED" -gt 0 ]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        printf "${RED}║${NC}     ⚠️  ISSUES FOUND: ${GREEN}%d PASS${NC} / ${YELLOW}%d WARN${NC} / ${RED}%d FAIL${NC}              ${RED}║${NC}\n" \
            "$CHECKS_PASSED" "$CHECKS_WARNED" "$CHECKS_FAILED"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "   Fix: curl ci5.run/heal | sh"
        echo ""
        exit 2
    elif [ "$CHECKS_WARNED" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
        printf "${YELLOW}║${NC}     ⚡ MOSTLY OK: ${GREEN}%d PASS${NC} / ${YELLOW}%d WARN${NC} / ${RED}%d FAIL${NC}                  ${YELLOW}║${NC}\n" \
            "$CHECKS_PASSED" "$CHECKS_WARNED" "$CHECKS_FAILED"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "   Some optional services not running"
        echo "   Core routing is functional"
        echo ""
        exit 0
    else
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        printf "${GREEN}║${NC}     ✅ ALL SYSTEMS GO: ${GREEN}%d PASS${NC} / ${YELLOW}%d WARN${NC} / ${RED}%d FAIL${NC}             ${GREEN}║${NC}\n" \
            "$CHECKS_PASSED" "$CHECKS_WARNED" "$CHECKS_FAILED"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 0
    fi
}

# JSON output mode for scripting
if [ "$1" = "--json" ] || [ "$1" = "-j" ]; then
    # Suppress normal output, run checks silently
    exec 3>&1 1>/dev/null
    
    check_internet 2>/dev/null || INTERNET="false"
    INTERNET="${INTERNET:-true}"
    
    check_dns 2>/dev/null
    check_unbound 2>/dev/null
    check_sqm 2>/dev/null
    check_firewall 2>/dev/null
    check_docker 2>/dev/null
    
    exec 1>&3
    
    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "status": "$([ "$CHECKS_FAILED" -eq 0 ] && echo "healthy" || echo "degraded")",
  "internet": $INTERNET,
  "checks": {
    "passed": $CHECKS_PASSED,
    "warned": $CHECKS_WARNED,
    "failed": $CHECKS_FAILED
  }
}
EOF
    exit 0
fi

main "$@"