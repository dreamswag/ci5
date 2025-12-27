#!/bin/sh
# 🧹 Ci5 Partial Uninstaller (v7.4-RC-1)
# Selectively remove Full Stack components and revert to OpenWrt/ISP defaults
# Location: /root/ci5/extras/partial-uninstall.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# COMPONENT DETECTION
# ─────────────────────────────────────────────────────────────
detect_components() {
    # Reset all detection flags
    HAS_UNBOUND=0
    HAS_ADGUARD=0
    HAS_SURICATA=0
    HAS_CROWDSEC=0
    HAS_NTOPNG=0
    HAS_REDIS=0
    HAS_DNS_WATCHDOG=0
    HAS_PPPOE_GUARD=0
    HAS_PARANOIA_WATCHDOG=0
    HAS_DOCKER=0
    IS_LITE_ONLY=1
    
    # Check Unbound
    if pgrep -x unbound >/dev/null 2>&1 || [ -f /etc/config/unbound ]; then
        HAS_UNBOUND=1
    fi
    
    # Check Docker availability
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        HAS_DOCKER=1
        IS_LITE_ONLY=0
        
        # Check Docker containers
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^adguardhome$"; then
            HAS_ADGUARD=1
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^suricata$"; then
            HAS_SURICATA=1
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^crowdsec$"; then
            HAS_CROWDSEC=1
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^ntopng$"; then
            HAS_NTOPNG=1
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^redis$"; then
            HAS_REDIS=1
        fi
    fi
    
    # Check DNS Failover Watchdog
    if [ -f /etc/init.d/ci5-dns-failover ] || pgrep -f "ci5-dns-failover" >/dev/null 2>&1; then
        HAS_DNS_WATCHDOG=1
        IS_LITE_ONLY=0
    fi
    
    # Check PPPoE Guard
    if [ -f /etc/hotplug.d/iface/99-pppoe-noqdisc ]; then
        HAS_PPPOE_GUARD=1
        IS_LITE_ONLY=0
    fi
    
    # Check Paranoia Watchdog
    if [ -f /root/scripts/paranoia_watchdog.sh ] || pgrep -f "paranoia_watchdog" >/dev/null 2>&1; then
        HAS_PARANOIA_WATCHDOG=1
        IS_LITE_ONLY=0
    fi
}

# ─────────────────────────────────────────────────────────────
# FRESH INSTALL STATE CHECK
# ─────────────────────────────────────────────────────────────
check_fresh_state() {
    FRESH_STATE=1
    DEVIATIONS=""
    
    # Check for unexpected UCI modifications
    if ! uci get network.vlan10 >/dev/null 2>&1; then
        FRESH_STATE=0
        DEVIATIONS="$DEVIATIONS\n    - VLANs not configured (missing network.vlan10)"
    fi
    
    # Check for custom firewall rules not from Ci5
    CUSTOM_RULES=$(uci show firewall 2>/dev/null | grep -c "@rule\[" || echo "0")
    if [ "$CUSTOM_RULES" -gt 15 ]; then
        FRESH_STATE=0
        DEVIATIONS="$DEVIATIONS\n    - Unusual number of firewall rules ($CUSTOM_RULES)"
    fi
    
    # Check for non-standard Docker networks
    if [ "$HAS_DOCKER" -eq 1 ]; then
        CUSTOM_NETWORKS=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v -E "^(bridge|host|none)$" | wc -l)
        if [ "$CUSTOM_NETWORKS" -gt 1 ]; then
            FRESH_STATE=0
            DEVIATIONS="$DEVIATIONS\n    - Custom Docker networks detected ($CUSTOM_NETWORKS)"
        fi
    fi
    
    # Check for additional init scripts
    EXTRA_INITS=$(ls /etc/init.d/ 2>/dev/null | grep -E "^ci5-" | grep -v "ci5-dns-failover" | wc -l)
    if [ "$EXTRA_INITS" -gt 0 ]; then
        FRESH_STATE=0
        DEVIATIONS="$DEVIATIONS\n    - Non-standard Ci5 init scripts found"
    fi
}

# ─────────────────────────────────────────────────────────────
# STATUS INDICATOR
# ─────────────────────────────────────────────────────────────
status_icon() {
    if [ "$1" -eq 1 ]; then
        echo -e "${GREEN}✅${NC}"
    else
        echo -e "${RED}❌${NC}"
    fi
}

running_status() {
    if [ "$1" -eq 1 ]; then
        # Check if actually running
        case "$2" in
            unbound)
                pgrep -x unbound >/dev/null 2>&1 && echo "(running)" || echo "(stopped)"
                ;;
            adguard|suricata|crowdsec|ntopng|redis)
                docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$2" && echo "(running)" || echo "(stopped)"
                ;;
            *)
                echo "(installed)"
                ;;
        esac
    else
        echo ""
    fi
}

# ─────────────────────────────────────────────────────────────
# DISPLAY MENU
# ─────────────────────────────────────────────────────────────
display_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}         ${BOLD}🧹 Ci5 Partial Uninstaller (v7.4-RC-1)${NC}                  ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    
    if [ "$IS_LITE_ONLY" -eq 1 ]; then
        echo -e "${BLUE}║${NC}  ${YELLOW}Mode: LITE STACK${NC} (Only Unbound available for removal)          ${BLUE}║${NC}"
    else
        echo -e "${BLUE}║${NC}  ${CYAN}Mode: FULL STACK${NC} (Docker + Security Services)                 ${BLUE}║${NC}"
    fi
    
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}Detected Components:${NC}                                            ${BLUE}║${NC}"
    echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────╢${NC}"
    
    # DNS Services
    printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
        "1." "Unbound (DNS Resolver)" "$(status_icon $HAS_UNBOUND)" "$(running_status $HAS_UNBOUND unbound)"
    
    if [ "$IS_LITE_ONLY" -eq 0 ]; then
        printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
            "2." "AdGuard Home (DNS Filter)" "$(status_icon $HAS_ADGUARD)" "$(running_status $HAS_ADGUARD adguardhome)"
        
        echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${BLUE}║${NC}  ${BOLD}Security Stack:${NC}                                                 ${BLUE}║${NC}"
        
        printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
            "3." "Suricata (IDS)" "$(status_icon $HAS_SURICATA)" "$(running_status $HAS_SURICATA suricata)"
        printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
            "4." "CrowdSec (IPS)" "$(status_icon $HAS_CROWDSEC)" "$(running_status $HAS_CROWDSEC crowdsec)"
        
        echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${BLUE}║${NC}  ${BOLD}Monitoring & Data:${NC}                                              ${BLUE}║${NC}"
        
        printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
            "5." "Ntopng (Traffic Monitor)" "$(status_icon $HAS_NTOPNG)" "$(running_status $HAS_NTOPNG ntopng)"
        printf "${BLUE}║${NC}  %-3s %-25s %s %-10s                  ${BLUE}║${NC}\n" \
            "6." "Redis (Data Store)" "$(status_icon $HAS_REDIS)" "$(running_status $HAS_REDIS redis)"
        
        echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${BLUE}║${NC}  ${BOLD}System Services:${NC}                                                ${BLUE}║${NC}"
        
        printf "${BLUE}║${NC}  %-3s %-28s %s                         ${BLUE}║${NC}\n" \
            "7." "DNS Failover Watchdog" "$(status_icon $HAS_DNS_WATCHDOG)"
        printf "${BLUE}║${NC}  %-3s %-28s %s                         ${BLUE}║${NC}\n" \
            "8." "PPPoE Guard (Hotplug)" "$(status_icon $HAS_PPPOE_GUARD)"
        printf "${BLUE}║${NC}  %-3s %-28s %s                         ${BLUE}║${NC}\n" \
            "9." "Paranoia Watchdog" "$(status_icon $HAS_PARANOIA_WATCHDOG)"
    fi
    
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}Actions:${NC}                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}R${NC} - Refresh detection                                          ${BLUE}║${NC}"
    
    if [ "$IS_LITE_ONLY" -eq 0 ]; then
        echo -e "${BLUE}║${NC}   ${RED}A${NC} - Remove ALL Docker components                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${RED}F${NC} - FULL RESET (Remove everything → ISP defaults)             ${BLUE}║${NC}"
    fi
    
    echo -e "${BLUE}║${NC}   ${GREEN}0${NC} - Exit (No changes)                                          ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# DEPENDENCY CHECKS
# ─────────────────────────────────────────────────────────────
check_dependencies() {
    COMPONENT="$1"
    DEPS_REQUIRED=""
    DEPS_WARNING=""
    
    case "$COMPONENT" in
        redis)
            # Redis is required by Ntopng
            if [ "$HAS_NTOPNG" -eq 1 ]; then
                DEPS_REQUIRED="ntopng"
            fi
            ;;
        unbound)
            # AdGuard uses Unbound as upstream
            if [ "$HAS_ADGUARD" -eq 1 ]; then
                DEPS_WARNING="adguard (will lose upstream DNS)"
            fi
            # DNS Watchdog manages Unbound/AdGuard relationship
            if [ "$HAS_DNS_WATCHDOG" -eq 1 ]; then
                DEPS_REQUIRED="dns_watchdog"
            fi
            ;;
        adguard)
            # DNS Watchdog manages AdGuard failover
            if [ "$HAS_DNS_WATCHDOG" -eq 1 ]; then
                DEPS_WARNING="dns_watchdog (will be orphaned)"
            fi
            ;;
        ntopng)
            # Ntopng uses Redis but Redis can stay
            DEPS_WARNING=""
            ;;
    esac
    
    echo "$DEPS_REQUIRED|$DEPS_WARNING"
}

# ─────────────────────────────────────────────────────────────
# REMOVAL FUNCTIONS
# ─────────────────────────────────────────────────────────────

remove_unbound() {
    echo -e "${YELLOW}[*] Removing Unbound...${NC}"
    
    # Stop and disable
    /etc/init.d/unbound stop 2>/dev/null
    /etc/init.d/unbound disable 2>/dev/null
    
    # Restore dnsmasq to handle DNS
    echo -e "    -> Restoring dnsmasq as primary DNS..."
    uci set dhcp.@dnsmasq[0].port='53'
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci -q delete dhcp.@dnsmasq[0].server
    
    # Set ISP DNS (or common public DNS)
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    uci add_list dhcp.@dnsmasq[0].server='8.8.4.4'
    
    # Remove custom DHCP options pointing to local DNS
    for pool in lan vlan10 vlan20 vlan30 vlan40; do
        uci -q delete dhcp.${pool}.dhcp_option
    done
    
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    
    # Remove Unbound config (optional, keep for potential reinstall)
    # rm -f /etc/config/unbound
    
    echo -e "${GREEN}    ✓ Unbound removed. DNS reverted to ISP/Public DNS.${NC}"
    HAS_UNBOUND=0
}

remove_adguard() {
    echo -e "${YELLOW}[*] Removing AdGuard Home...${NC}"
    
    # Stop and remove container
    docker stop adguardhome 2>/dev/null
    docker rm adguardhome 2>/dev/null
    
    # Remove data (optional prompt)
    echo -n "    Delete AdGuard data/config? [y/N]: "
    read -r DEL_DATA
    if [ "$DEL_DATA" = "y" ] || [ "$DEL_DATA" = "Y" ]; then
        rm -rf /opt/ci5-docker/adguard 2>/dev/null
        echo -e "    ${GREEN}✓ Data deleted${NC}"
    fi
    
    # If Unbound still exists, point dnsmasq to it
    if [ "$HAS_UNBOUND" -eq 1 ]; then
        echo -e "    -> Routing DNS through Unbound (port 5335)..."
        uci set dhcp.@dnsmasq[0].port='53'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
    fi
    
    echo -e "${GREEN}    ✓ AdGuard Home removed.${NC}"
    HAS_ADGUARD=0
}

remove_suricata() {
    echo -e "${YELLOW}[*] Removing Suricata IDS...${NC}"
    
    # Check if paranoia watchdog is active
    if pgrep -f "paranoia_watchdog" >/dev/null 2>&1; then
        echo -e "    ${RED}! Stopping Paranoia Watchdog first (prevents WAN kill)...${NC}"
        pkill -f "paranoia_watchdog" 2>/dev/null
    fi
    
    docker stop suricata 2>/dev/null
    docker rm suricata 2>/dev/null
    
    echo -n "    Delete Suricata logs? [y/N]: "
    read -r DEL_LOGS
    if [ "$DEL_LOGS" = "y" ] || [ "$DEL_LOGS" = "Y" ]; then
        rm -rf /opt/ci5-docker/suricata 2>/dev/null
        echo -e "    ${GREEN}✓ Logs deleted${NC}"
    fi
    
    echo -e "${GREEN}    ✓ Suricata IDS removed.${NC}"
    HAS_SURICATA=0
}

remove_crowdsec() {
    echo -e "${YELLOW}[*] Removing CrowdSec IPS...${NC}"
    
    docker stop crowdsec 2>/dev/null
    docker rm crowdsec 2>/dev/null
    
    # Remove firewall bouncer if installed
    if opkg list-installed 2>/dev/null | grep -q "crowdsec-firewall-bouncer"; then
        echo -e "    -> Removing CrowdSec Firewall Bouncer..."
        /etc/init.d/crowdsec-firewall-bouncer stop 2>/dev/null
        /etc/init.d/crowdsec-firewall-bouncer disable 2>/dev/null
        opkg remove crowdsec-firewall-bouncer 2>/dev/null
    fi
    
    echo -n "    Delete CrowdSec data? [y/N]: "
    read -r DEL_DATA
    if [ "$DEL_DATA" = "y" ] || [ "$DEL_DATA" = "Y" ]; then
        rm -rf /opt/ci5-docker/crowdsec 2>/dev/null
        echo -e "    ${GREEN}✓ Data deleted${NC}"
    fi
    
    echo -e "${GREEN}    ✓ CrowdSec IPS removed.${NC}"
    HAS_CROWDSEC=0
}

remove_ntopng() {
    echo -e "${YELLOW}[*] Removing Ntopng...${NC}"
    
    docker stop ntopng 2>/dev/null
    docker rm ntopng 2>/dev/null
    
    echo -n "    Delete Ntopng data? [y/N]: "
    read -r DEL_DATA
    if [ "$DEL_DATA" = "y" ] || [ "$DEL_DATA" = "Y" ]; then
        rm -rf /opt/ci5-docker/data/ntopng 2>/dev/null
        rm -rf /opt/ci5-docker/config/ntopng 2>/dev/null
        echo -e "    ${GREEN}✓ Data deleted${NC}"
    fi
    
    echo -e "${GREEN}    ✓ Ntopng removed.${NC}"
    HAS_NTOPNG=0
}

remove_redis() {
    echo -e "${YELLOW}[*] Removing Redis...${NC}"
    
    docker stop redis 2>/dev/null
    docker rm redis 2>/dev/null
    
    # Remove Docker volume
    docker volume rm ci5-docker_redis_data 2>/dev/null
    
    echo -e "${GREEN}    ✓ Redis removed.${NC}"
    HAS_REDIS=0
}

remove_dns_watchdog() {
    echo -e "${YELLOW}[*] Removing DNS Failover Watchdog...${NC}"
    
    /etc/init.d/ci5-dns-failover stop 2>/dev/null
    /etc/init.d/ci5-dns-failover disable 2>/dev/null
    rm -f /etc/init.d/ci5-dns-failover 2>/dev/null
    rm -f /etc/ci5-dns-failover.sh 2>/dev/null
    
    echo -e "${GREEN}    ✓ DNS Watchdog removed.${NC}"
    HAS_DNS_WATCHDOG=0
}

remove_pppoe_guard() {
    echo -e "${YELLOW}[*] Removing PPPoE Guard...${NC}"
    
    rm -f /etc/hotplug.d/iface/99-pppoe-noqdisc 2>/dev/null
    
    echo -e "${GREEN}    ✓ PPPoE Guard removed.${NC}"
    HAS_PPPOE_GUARD=0
}

remove_paranoia_watchdog() {
    echo -e "${YELLOW}[*] Removing Paranoia Watchdog...${NC}"
    
    pkill -f "paranoia_watchdog" 2>/dev/null
    rm -f /root/scripts/paranoia_watchdog.sh 2>/dev/null
    
    # Remove from rc.local if present
    if grep -q "paranoia_watchdog" /etc/rc.local 2>/dev/null; then
        sed -i '/paranoia_watchdog/d' /etc/rc.local
    fi
    
    echo -e "${GREEN}    ✓ Paranoia Watchdog removed.${NC}"
    HAS_PARANOIA_WATCHDOG=0
}

# ─────────────────────────────────────────────────────────────
# REMOVE ALL DOCKER
# ─────────────────────────────────────────────────────────────
remove_all_docker() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  WARNING: This will remove ALL Docker containers & data      ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will remove:"
    echo "  - AdGuard Home (DNS filtering)"
    echo "  - Suricata (IDS)"
    echo "  - CrowdSec (IPS)"
    echo "  - Ntopng (traffic monitoring)"
    echo "  - Redis (data store)"
    echo "  - DNS Failover Watchdog"
    echo "  - All container data and logs"
    echo ""
    echo -n "Type 'REMOVE ALL' to confirm: "
    read -r CONFIRM
    
    if [ "$CONFIRM" != "REMOVE ALL" ]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}[*] Stopping all containers...${NC}"
    
    # Stop watchdogs first
    pkill -f "paranoia_watchdog" 2>/dev/null
    /etc/init.d/ci5-dns-failover stop 2>/dev/null
    
    # Stop and remove all Ci5 containers
    for container in adguardhome suricata crowdsec ntopng redis; do
        docker stop "$container" 2>/dev/null
        docker rm "$container" 2>/dev/null
    done
    
    # Remove Docker volumes
    docker volume rm ci5-docker_redis_data 2>/dev/null
    
    # Clean up data directories
    echo -n "Delete all container data? [y/N]: "
    read -r DEL_ALL
    if [ "$DEL_ALL" = "y" ] || [ "$DEL_ALL" = "Y" ]; then
        rm -rf /opt/ci5-docker 2>/dev/null
        echo -e "${GREEN}    ✓ All data deleted${NC}"
    fi
    
    # Remove services
    rm -f /etc/init.d/ci5-dns-failover 2>/dev/null
    rm -f /etc/ci5-dns-failover.sh 2>/dev/null
    rm -f /etc/hotplug.d/iface/99-pppoe-noqdisc 2>/dev/null
    rm -f /root/scripts/paranoia_watchdog.sh 2>/dev/null
    
    # Restore DNS to Unbound if it exists, otherwise ISP
    if pgrep -x unbound >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Routing DNS through Unbound...${NC}"
        uci set dhcp.@dnsmasq[0].port='53'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
    else
        echo -e "${YELLOW}[*] Reverting DNS to ISP/Public DNS...${NC}"
        uci set dhcp.@dnsmasq[0].port='53'
        uci set dhcp.@dnsmasq[0].noresolv='0'
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
        uci add_list dhcp.@dnsmasq[0].server='8.8.4.4'
    fi
    
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    
    # Update detection
    HAS_ADGUARD=0
    HAS_SURICATA=0
    HAS_CROWDSEC=0
    HAS_NTOPNG=0
    HAS_REDIS=0
    HAS_DNS_WATCHDOG=0
    HAS_PPPOE_GUARD=0
    HAS_PARANOIA_WATCHDOG=0
    
    echo ""
    echo -e "${GREEN}✅ All Docker components removed.${NC}"
    echo -e "${CYAN}   System is now running in Lite mode (Unbound only).${NC}"
    echo ""
    echo "Press Enter to continue..."
    read -r
}

# ─────────────────────────────────────────────────────────────
# FULL RESET TO ISP DEFAULTS
# ─────────────────────────────────────────────────────────────
full_reset() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🚨 FULL RESET - REVERT TO ISP/OpenWrt DEFAULTS                  ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║  This will:                                                       ║${NC}"
    echo -e "${RED}║  • Remove ALL Ci5 components (Docker + Unbound + services)       ║${NC}"
    echo -e "${RED}║  • Restore dnsmasq as default DNS                                ║${NC}"
    echo -e "${RED}║  • Remove SQM/CAKE tuning                                        ║${NC}"
    echo -e "${RED}║  • Remove kernel tuning from sysctl.conf                         ║${NC}"
    echo -e "${RED}║  • Remove rc.local performance optimizations                     ║${NC}"
    echo -e "${RED}║  • Keep VLANs and basic network config intact                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Note: Network/VLAN config will remain. Use 'firstboot' for complete reset.${NC}"
    echo ""
    echo -n "Type 'FACTORY RESET' to confirm: "
    read -r CONFIRM
    
    if [ "$CONFIRM" != "FACTORY RESET" ]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}[1/6] Removing Docker stack...${NC}"
    
    # Stop watchdogs
    pkill -f "paranoia_watchdog" 2>/dev/null
    /etc/init.d/ci5-dns-failover stop 2>/dev/null
    /etc/init.d/ci5-dns-failover disable 2>/dev/null
    
    # Remove all containers
    for container in adguardhome suricata crowdsec ntopng redis; do
        docker stop "$container" 2>/dev/null
        docker rm "$container" 2>/dev/null
    done
    docker volume rm ci5-docker_redis_data 2>/dev/null
    rm -rf /opt/ci5-docker 2>/dev/null
    
    echo -e "${YELLOW}[2/6] Removing Unbound...${NC}"
    /etc/init.d/unbound stop 2>/dev/null
    /etc/init.d/unbound disable 2>/dev/null
    
    echo -e "${YELLOW}[3/6] Restoring dnsmasq defaults...${NC}"
    uci set dhcp.@dnsmasq[0].port='53'
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci -q delete dhcp.@dnsmasq[0].server
    
    # Remove Ci5 DHCP options
    for pool in lan vlan10 vlan20 vlan30 vlan40; do
        uci -q delete dhcp.${pool}.dhcp_option
    done
    uci commit dhcp
    
    echo -e "${YELLOW}[4/6] Removing SQM/CAKE config...${NC}"
    uci set sqm.eth1.enabled='0'
    uci commit sqm
    /etc/init.d/sqm stop 2>/dev/null
    
    echo -e "${YELLOW}[5/6] Restoring kernel defaults...${NC}"
    
    # Reset sysctl.conf to minimal
    cat > /etc/sysctl.conf << 'SYSCTL'
# OpenWrt defaults
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1
SYSCTL
    sysctl -p >/dev/null 2>&1
    
    # Reset rc.local
    cat > /etc/rc.local << 'RCLOCAL'
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

exit 0
RCLOCAL
    chmod +x /etc/rc.local
    
    echo -e "${YELLOW}[6/6] Cleaning up Ci5 files...${NC}"
    rm -f /etc/init.d/ci5-dns-failover 2>/dev/null
    rm -f /etc/ci5-dns-failover.sh 2>/dev/null
    rm -f /etc/hotplug.d/iface/99-pppoe-noqdisc 2>/dev/null
    rm -rf /root/scripts 2>/dev/null
    
    # Restart services
    /etc/init.d/dnsmasq restart
    /etc/init.d/network reload
    /etc/init.d/firewall reload
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ FULL RESET COMPLETE                                          ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  • DNS: ISP defaults (via dnsmasq)                               ║${NC}"
    echo -e "${GREEN}║  • QoS: Disabled (standard FIFO)                                 ║${NC}"
    echo -e "${GREEN}║  • Security: Basic OpenWrt firewall only                         ║${NC}"
    echo -e "${GREEN}║  • VLANs: Still configured (manual removal if needed)           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}To completely reset OpenWrt: run 'firstboot -y && reboot'${NC}"
    echo ""
    echo "Press Enter to exit..."
    read -r
    exit 0
}

# ─────────────────────────────────────────────────────────────
# PROCESS SELECTION
# ─────────────────────────────────────────────────────────────
process_selection() {
    SELECTION="$1"
    
    case "$SELECTION" in
        1)
            if [ "$HAS_UNBOUND" -eq 0 ]; then
                echo -e "${YELLOW}Unbound is not installed.${NC}"
                sleep 1
                return
            fi
            
            # Check dependencies
            DEPS=$(check_dependencies "unbound")
            DEPS_REQ=$(echo "$DEPS" | cut -d'|' -f1)
            DEPS_WARN=$(echo "$DEPS" | cut -d'|' -f2)
            
            if [ -n "$DEPS_REQ" ]; then
                echo ""
                echo -e "${RED}⚠️  Unbound has required dependencies:${NC}"
                echo -e "    ${YELLOW}Must also remove: $DEPS_REQ${NC}"
                echo ""
                echo -n "Remove Unbound AND $DEPS_REQ? [y/N]: "
                read -r CONFIRM
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    remove_dns_watchdog
                    remove_unbound
                fi
            else
                if [ -n "$DEPS_WARN" ]; then
                    echo -e "${YELLOW}Warning: $DEPS_WARN${NC}"
                fi
                echo -n "Remove Unbound? [y/N]: "
                read -r CONFIRM
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    remove_unbound
                fi
            fi
            ;;
        2)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_ADGUARD" -eq 0 ]; then
                echo -e "${YELLOW}AdGuard Home is not installed.${NC}"
                sleep 1
                return
            fi
            
            DEPS=$(check_dependencies "adguard")
            DEPS_WARN=$(echo "$DEPS" | cut -d'|' -f2)
            
            if [ -n "$DEPS_WARN" ]; then
                echo -e "${YELLOW}Warning: $DEPS_WARN${NC}"
            fi
            echo -n "Remove AdGuard Home? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_adguard
            fi
            ;;
        3)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_SURICATA" -eq 0 ]; then
                echo -e "${YELLOW}Suricata is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove Suricata IDS? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_suricata
            fi
            ;;
        4)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_CROWDSEC" -eq 0 ]; then
                echo -e "${YELLOW}CrowdSec is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove CrowdSec IPS? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_crowdsec
            fi
            ;;
        5)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_NTOPNG" -eq 0 ]; then
                echo -e "${YELLOW}Ntopng is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove Ntopng? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_ntopng
            fi
            ;;
        6)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_REDIS" -eq 0 ]; then
                echo -e "${YELLOW}Redis is not installed.${NC}"
                sleep 1
                return
            fi
            
            # Check if Ntopng depends on Redis
            DEPS=$(check_dependencies "redis")
            DEPS_REQ=$(echo "$DEPS" | cut -d'|' -f1)
            
            if [ -n "$DEPS_REQ" ] && [ "$HAS_NTOPNG" -eq 1 ]; then
                echo ""
                echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  ⚠️  DEPENDENCY CONFLICT                                         ║${NC}"
                echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
                echo -e "${RED}║  Ntopng REQUIRES Redis to function.                              ║${NC}"
                echo -e "${RED}║  Removing Redis alone will break Ntopng.                         ║${NC}"
                echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${GREEN}Recommended: Remove BOTH Ntopng and Redis together.${NC}"
                echo ""
                echo "Options:"
                echo "  Y - Remove BOTH Ntopng and Redis (recommended)"
                echo "  F - Force remove Redis only (Ntopng will be broken)"
                echo "  N - Cancel"
                echo ""
                echo -n "Choice [Y/F/N]: "
                read -r CHOICE
                
                case "$CHOICE" in
                    Y|y)
                        remove_ntopng
                        remove_redis
                        ;;
                    F|f)
                        echo -e "${RED}⚠️  Force removing Redis. Ntopng will fail to start.${NC}"
                        remove_redis
                        ;;
                    *)
                        echo "Cancelled."
                        ;;
                esac
            else
                echo -n "Remove Redis? [y/N]: "
                read -r CONFIRM
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    remove_redis
                fi
            fi
            ;;
        7)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_DNS_WATCHDOG" -eq 0 ]; then
                echo -e "${YELLOW}DNS Failover Watchdog is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove DNS Failover Watchdog? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_dns_watchdog
            fi
            ;;
        8)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_PPPOE_GUARD" -eq 0 ]; then
                echo -e "${YELLOW}PPPoE Guard is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove PPPoE Guard? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_pppoe_guard
            fi
            ;;
        9)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            if [ "$HAS_PARANOIA_WATCHDOG" -eq 0 ]; then
                echo -e "${YELLOW}Paranoia Watchdog is not installed.${NC}"
                sleep 1
                return
            fi
            echo -n "Remove Paranoia Watchdog? [y/N]: "
            read -r CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                remove_paranoia_watchdog
            fi
            ;;
        r|R)
            detect_components
            ;;
        a|A)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            remove_all_docker
            ;;
        f|F)
            [ "$IS_LITE_ONLY" -eq 1 ] && return
            full_reset
            ;;
        0|q|Q)
            echo ""
            echo -e "${GREEN}Exiting. No changes made.${NC}"
            exit 0
            ;;
        *)
            echo -e "${YELLOW}Invalid selection.${NC}"
            sleep 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────

# Initial detection
detect_components
check_fresh_state

# Display fresh state warning if needed
if [ "$FRESH_STATE" -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  NON-STANDARD INSTALLATION DETECTED                          ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  This system appears to deviate from a fresh Ci5 install:       ║${NC}"
    echo -e "$DEVIATIONS"
    echo -e "${YELLOW}║                                                                   ║${NC}"
    echo -e "${YELLOW}║  This script is designed for fresh install-full.sh systems.     ║${NC}"
    echo -e "${YELLOW}║  Removal of components may not work as expected.                ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -n "Continue anyway? [y/N]: "
    read -r CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Main loop
while true; do
    display_menu
    echo -n "Select component to remove (or action): "
    read -r SELECTION
    process_selection "$SELECTION"
    
    # Re-detect after any change
    detect_components
done
