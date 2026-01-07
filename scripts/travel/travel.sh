#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/travel — Travel Security Toolkit (Procd Compliant)
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

TRAVEL_DIR="/etc/ci5/travel"
STATE_FILE="/var/run/ci5-travel.state"
HOSTAPD_CONF="/etc/ci5/travel/hostapd.conf"
DNSMASQ_CONF="/etc/ci5/travel/dnsmasq-ap.conf"
BACKUP_DIR="/etc/ci5/travel/backup"
LOG_FILE="/var/log/ci5-travel.log"

# Default AP settings
DEFAULT_AP_SSID="CI5-Travel"
DEFAULT_AP_PASS="travel-$(head -c 4 /dev/urandom | xxd -p)"
DEFAULT_AP_CHANNEL="36"  # 5GHz channel
DEFAULT_AP_SUBNET="10.55.0"

# Pi 5 internal WiFi interface (Broadcom BCM4345)
INTERNAL_WIFI="wlan0"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }
travel() { printf "${M}[✈]${N} %s\n" "$1"; }

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# ... (Interface detection and MAC randomization logic remains similar but uses ip link) ...

portal_mode() {
    # ... (MAC randomization logic) ...
    
    # Start VPN if available (Procd only)
    if command -v wg >/dev/null; then
        if ! wg show wg0 2>/dev/null | grep -q "latest handshake"; then
            echo "Starting WireGuard..."
            if [ -x /etc/init.d/wireguard ]; then
                /etc/init.d/wireguard start
            elif command -v wg-quick >/dev/null;
 then
                wg-quick up wg0 2>/dev/null || true
            fi
        fi
    fi
}

ap_mode_enable() {
    # ... (AP setup logic) ...
    
    # Start WireGuard (Procd only)
    if ! wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        echo "Starting WireGuard..."
        if [ -x /etc/init.d/wireguard ]; then
            /etc/init.d/wireguard start
        elif command -v wg-quick >/dev/null;
 then
            wg-quick up wg0 2>/dev/null || true
        fi
    fi
    
    # ... (Rest of logic) ...
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    # Check dependencies (OpenWrt/opkg only)
    for cmd in ip iw hostapd dnsmasq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "$cmd not found, installing..."
            if command -v opkg >/dev/null 2>&1; then
                opkg update && opkg install "$cmd" 2>/dev/null || true
            else
                err "Required dependency $cmd missing and opkg not found."
            fi
        fi
    done
    
    # ... (Command handling) ...
}

main "$@"