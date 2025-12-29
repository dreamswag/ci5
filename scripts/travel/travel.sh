#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/travel — Travel Security Toolkit
# Version: 2.0-PHOENIX
# 
# Handles hostile network scenarios:
# - Captive portal bypass with MAC randomization
# - Portable AP mode (sanitizing gateway for your devices)
# - VPN kill switch enforcement
# - Integration with existing CI5 security stack
#
# Designed for Pi 5 with emphasis on internal WiFi usage to minimize
# hardware footprint while traveling.
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

# ─────────────────────────────────────────────────────────────────────────────
# INTERFACE DETECTION
# ─────────────────────────────────────────────────────────────────────────────

# Detect all WiFi interfaces
detect_wifi_interfaces() {
    # Find all wireless interfaces
    WIFI_INTERFACES=""
    for iface in /sys/class/net/*/wireless; do
        [ -d "$iface" ] || continue
        iface_name=$(echo "$iface" | cut -d/ -f5)
        WIFI_INTERFACES="$WIFI_INTERFACES $iface_name"
    done
    WIFI_INTERFACES=$(echo "$WIFI_INTERFACES" | xargs)  # trim
    
    # Categorize interfaces
    INTERNAL_IF=""
    USB_WIFI_IF=""
    
    for iface in $WIFI_INTERFACES; do
        # Check if it's USB-based
        if readlink -f "/sys/class/net/$iface/device" 2>/dev/null | grep -q "usb"; then
            USB_WIFI_IF="$iface"
        else
            # Assume internal (Pi 5's BCM4345)
            INTERNAL_IF="$iface"
        fi
    done
    
    # Fallback
    [ -z "$INTERNAL_IF" ] && INTERNAL_IF="wlan0"
}

# Check USB WiFi adapter capabilities
check_usb_wifi_caps() {
    local iface="$1"
    
    if [ -z "$iface" ]; then
        return 1
    fi
    
    # Check for AP mode support
    if iw list 2>/dev/null | grep -A 10 "Supported interface modes" | grep -q "AP"; then
        return 0
    fi
    
    return 1
}

# Check if internal WiFi supports concurrent AP+STA
check_concurrent_mode() {
    # Pi 5's BCM4345 technically supports this but with limitations
    # Check via iw
    local combos=$(iw list 2>/dev/null | grep -A 20 "valid interface combinations" || echo "")
    
    if echo "$combos" | grep -q "managed.*AP"; then
        return 0
    fi
    
    return 1
}

# Get WiFi adapter chipset info
get_chipset_info() {
    local iface="$1"
    local driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
    local usb_id=""
    
    if readlink -f "/sys/class/net/$iface/device" 2>/dev/null | grep -q "usb"; then
        usb_id=$(cat "/sys/class/net/$iface/device/../idVendor" 2>/dev/null):$(cat "/sys/class/net/$iface/device/../idProduct" 2>/dev/null)
    fi
    
    echo "$driver ${usb_id:+($usb_id)}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAC RANDOMIZATION
# ─────────────────────────────────────────────────────────────────────────────

# Generate random MAC (locally administered, unicast)
generate_random_mac() {
    # First octet: set bit 1 (locally administered) and clear bit 0 (unicast)
    local first_octet=$(printf '%02x' $(( ($(od -An -N1 -tu1 /dev/urandom) | 0x02) & 0xfe )))
    local rest=$(od -An -N5 -tx1 /dev/urandom | tr -d ' ')
    echo "${first_octet}:${rest:0:2}:${rest:2:2}:${rest:4:2}:${rest:6:2}:${rest:8:2}"
}

# Store original MAC for restoration
backup_mac() {
    local iface="$1"
    local backup_file="$BACKUP_DIR/${iface}_mac"
    
    mkdir -p "$BACKUP_DIR"
    
    if [ ! -f "$backup_file" ]; then
        ip link show "$iface" | grep -o 'link/ether [^ ]*' | awk '{print $2}' > "$backup_file"
        info "Backed up original MAC for $iface"
    fi
}

# Randomize interface MAC
randomize_mac() {
    local iface="$1"
    
    backup_mac "$iface"
    
    local new_mac=$(generate_random_mac)
    
    # Bring interface down, change MAC, bring up
    ip link set "$iface" down 2>/dev/null || true
    ip link set "$iface" address "$new_mac"
    ip link set "$iface" up
    
    info "Randomized MAC on $iface: $new_mac"
    log "MAC randomized on $iface: $new_mac"
}

# Restore original MAC
restore_mac() {
    local iface="$1"
    local backup_file="$BACKUP_DIR/${iface}_mac"
    
    if [ -f "$backup_file" ]; then
        local original_mac=$(cat "$backup_file")
        
        ip link set "$iface" down 2>/dev/null || true
        ip link set "$iface" address "$original_mac"
        ip link set "$iface" up
        
        rm -f "$backup_file"
        info "Restored original MAC on $iface"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK SCANNING & CONNECTION
# ─────────────────────────────────────────────────────────────────────────────

# Scan for available networks
scan_networks() {
    local iface="$1"
    
    travel "Scanning for networks on $iface..."
    
    # Ensure interface is up
    ip link set "$iface" up 2>/dev/null || true
    
    # Use iw for scanning
    iw dev "$iface" scan 2>/dev/null | grep -E "SSID:|signal:|BSS " | \
    awk '
        /^BSS / { bss=$2 }
        /signal:/ { signal=$2 }
        /SSID:/ { 
            ssid=substr($0, index($0,":")+2)
            if (ssid != "") {
                printf "%-30s %s dBm\n", ssid, signal
            }
        }
    ' | sort -t' ' -k2 -rn | head -20
}

# Connect to a network using wpa_supplicant
connect_network() {
    local iface="$1"
    local ssid="$2"
    local password="$3"
    
    travel "Connecting to: $ssid"
    
    # Create wpa_supplicant config
    local wpa_conf="/tmp/ci5-travel-wpa.conf"
    
    if [ -n "$password" ]; then
        wpa_passphrase "$ssid" "$password" > "$wpa_conf"
    else
        # Open network
        cat > "$wpa_conf" << EOF
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
    fi
    
    # Kill any existing wpa_supplicant on this interface
    pkill -f "wpa_supplicant.*$iface" 2>/dev/null || true
    sleep 1
    
    # Start wpa_supplicant
    wpa_supplicant -B -i "$iface" -c "$wpa_conf" -D nl80211,wext
    
    # Wait for connection
    local count=0
    while [ $count -lt 30 ]; do
        if iw dev "$iface" link 2>/dev/null | grep -q "Connected"; then
            info "Connected to $ssid"
            
            # Get IP via DHCP
            dhclient -v "$iface" 2>/dev/null || dhcpcd "$iface" 2>/dev/null || udhcpc -i "$iface" 2>/dev/null
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    warn "Failed to connect to $ssid"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CAPTIVE PORTAL DETECTION & BYPASS
# ─────────────────────────────────────────────────────────────────────────────

# Check for captive portal
detect_captive_portal() {
    # Try multiple detection endpoints
    local endpoints="
        http://captive.apple.com/hotspot-detect.html
        http://connectivitycheck.gstatic.com/generate_204
        http://www.msftconnecttest.com/connecttest.txt
        http://detectportal.firefox.com/success.txt
    "
    
    for endpoint in $endpoints; do
        local response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$endpoint" 2>/dev/null)
        
        case "$response" in
            200|204)
                # Check if we got the expected content
                local content=$(curl -s --max-time 5 "$endpoint" 2>/dev/null)
                
                if echo "$endpoint" | grep -q "apple"; then
                    if echo "$content" | grep -q "Success"; then
                        return 1  # No captive portal
                    fi
                elif echo "$endpoint" | grep -q "gstatic"; then
                    if [ "$response" = "204" ]; then
                        return 1
                    fi
                elif echo "$endpoint" | grep -q "msft"; then
                    if echo "$content" | grep -q "Microsoft Connect Test"; then
                        return 1
                    fi
                elif echo "$endpoint" | grep -q "firefox"; then
                    if echo "$content" | grep -q "success"; then
                        return 1
                    fi
                fi
                ;;
            302|301|307)
                # Redirect = captive portal
                return 0
                ;;
        esac
    done
    
    # Default: assume captive portal if we couldn't verify
    return 0
}

# Get captive portal URL
get_portal_url() {
    local redirect_url=$(curl -s -o /dev/null -w "%{redirect_url}" --max-time 5 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null)
    echo "$redirect_url"
}

# Handle captive portal authentication
captive_portal_auth() {
    step "CAPTIVE PORTAL AUTHENTICATION"
    
    if ! detect_captive_portal; then
        info "No captive portal detected — already authenticated"
        return 0
    fi
    
    local portal_url=$(get_portal_url)
    
    warn "Captive portal detected!"
    
    if [ -n "$portal_url" ]; then
        travel "Portal URL: $portal_url"
    fi
    
    printf "\n"
    printf "  ${B}Options:${N}\n"
    printf "    ${M}[1]${N} Open portal in browser (if available)\n"
    printf "    ${M}[2]${N} Display portal URL to open on another device\n"
    printf "    ${M}[3]${N} Clone MAC from authenticated device\n"
    printf "    ${M}[4]${N} Skip (already authenticated elsewhere)\n"
    printf "\n"
    printf "  Choice: "
    read -r choice
    
    case "$choice" in
        1)
            # Try to open browser
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "${portal_url:-http://captive.apple.com}" &
            elif command -v lynx >/dev/null 2>&1; then
                lynx "${portal_url:-http://captive.apple.com}"
            else
                warn "No browser available"
                printf "\n  Open this URL on any device:\n"
                printf "  ${C}%s${N}\n\n" "${portal_url:-http://captive.apple.com}"
            fi
            
            printf "\n  Press Enter when authentication is complete..."
            read -r _
            ;;
        2)
            printf "\n  Open this URL on any device on the same network:\n"
            printf "  ${C}%s${N}\n\n" "${portal_url:-http://captive.apple.com}"
            printf "  Press Enter when authentication is complete..."
            read -r _
            ;;
        3)
            clone_mac_interactive
            ;;
        4)
            info "Skipping portal authentication"
            ;;
    esac
    
    # Verify authentication
    sleep 2
    if detect_captive_portal; then
        warn "Still behind captive portal — authentication may have failed"
        return 1
    else
        info "Captive portal cleared!"
        return 0
    fi
}

# Clone MAC from another device
clone_mac_interactive() {
    printf "\n  Enter MAC address of authenticated device\n"
    printf "  (Format: AA:BB:CC:DD:EE:FF): "
    read -r target_mac
    
    if echo "$target_mac" | grep -qE "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"; then
        detect_wifi_interfaces
        local upstream_if="${USB_WIFI_IF:-$INTERNAL_IF}"
        
        backup_mac "$upstream_if"
        
        ip link set "$upstream_if" down
        ip link set "$upstream_if" address "$target_mac"
        ip link set "$upstream_if" up
        
        info "Cloned MAC $target_mac to $upstream_if"
        
        # Reconnect
        dhclient -r "$upstream_if" 2>/dev/null || true
        dhclient "$upstream_if" 2>/dev/null || dhcpcd "$upstream_if" 2>/dev/null
    else
        warn "Invalid MAC format"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# VPN KILL SWITCH
# ─────────────────────────────────────────────────────────────────────────────

# Check for WireGuard
detect_wireguard() {
    if ip link show wg0 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Enable strict kill switch
enable_kill_switch() {
    local upstream_if="$1"
    local downstream_if="$2"
    
    step "ENABLING VPN KILL SWITCH"
    
    # Backup current rules
    mkdir -p "$BACKUP_DIR"
    nft list ruleset > "$BACKUP_DIR/nftables-backup.conf" 2>/dev/null || \
    iptables-save > "$BACKUP_DIR/iptables-backup.conf" 2>/dev/null
    
    # Detect VPN endpoint
    local wg_endpoint=""
    if detect_wireguard; then
        wg_endpoint=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1)
    fi
    
    # Create kill switch rules
    if command -v nft >/dev/null 2>&1; then
        # nftables version
        nft flush ruleset 2>/dev/null || true
        
        nft -f - << EOF
table inet ci5_travel {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established
        ct state established,related accept
        
        # Allow loopback
        iif lo accept
        
        # Allow from downstream (AP clients)
        iifname "$downstream_if" accept
        
        # Allow DHCP
        udp dport 68 accept
        
        # Allow WireGuard
        udp dport 51820 accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
        
        ct state established,related accept
        
        # CRITICAL: Only allow downstream -> VPN
        iifname "$downstream_if" oifname "wg0" accept
        iifname "wg0" oifname "$downstream_if" accept
        
        # Block downstream -> upstream bypass
        iifname "$downstream_if" oifname "$upstream_if" log prefix "TRAVEL-BYPASS: " drop
    }
    
    chain output {
        type filter hook output priority 0; policy drop;
        
        ct state established,related accept
        
        # Allow loopback
        oif lo accept
        
        # Allow DNS to VPN
        oifname "wg0" accept
        
        # Allow DHCP
        udp dport 67 accept
        udp sport 68 accept
        
        # Allow WireGuard endpoint only
        ${wg_endpoint:+ip daddr $wg_endpoint accept}
        
        # Allow to downstream
        oifname "$downstream_if" accept
        
        # Block everything else to upstream
        oifname "$upstream_if" log prefix "TRAVEL-LEAK: " drop
    }
}

table inet ci5_travel_nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        
        # NAT through VPN
        oifname "wg0" masquerade
        
        # NAT through upstream (for initial DHCP/portal only)
        oifname "$upstream_if" masquerade
    }
}
EOF
        
        info "Kill switch enabled (nftables)"
        
    else
        # iptables fallback
        iptables -F
        iptables -X
        iptables -t nat -F
        
        # Default DROP
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP
        
        # Established
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        
        # Loopback
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT
        
        # Downstream
        iptables -A INPUT -i "$downstream_if" -j ACCEPT
        iptables -A OUTPUT -o "$downstream_if" -j ACCEPT
        
        # VPN
        iptables -A OUTPUT -o wg0 -j ACCEPT
        iptables -A FORWARD -i "$downstream_if" -o wg0 -j ACCEPT
        iptables -A FORWARD -i wg0 -o "$downstream_if" -j ACCEPT
        
        # DHCP
        iptables -A OUTPUT -p udp --dport 67 -j ACCEPT
        iptables -A INPUT -p udp --dport 68 -j ACCEPT
        
        # WireGuard endpoint
        [ -n "$wg_endpoint" ] && iptables -A OUTPUT -d "$wg_endpoint" -j ACCEPT
        
        # NAT
        iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -o "$upstream_if" -j MASQUERADE
        
        info "Kill switch enabled (iptables)"
    fi
    
    log "Kill switch enabled: upstream=$upstream_if downstream=$downstream_if"
}

# Disable kill switch (restore normal rules)
disable_kill_switch() {
    step "DISABLING KILL SWITCH"
    
    if [ -f "$BACKUP_DIR/nftables-backup.conf" ]; then
        nft -f "$BACKUP_DIR/nftables-backup.conf" 2>/dev/null || true
        rm -f "$BACKUP_DIR/nftables-backup.conf"
        info "Restored nftables rules"
    elif [ -f "$BACKUP_DIR/iptables-backup.conf" ]; then
        iptables-restore < "$BACKUP_DIR/iptables-backup.conf" 2>/dev/null || true
        rm -f "$BACKUP_DIR/iptables-backup.conf"
        info "Restored iptables rules"
    else
        # Fallback: flush and set permissive
        if command -v nft >/dev/null 2>&1; then
            nft flush ruleset 2>/dev/null || true
        fi
        iptables -F 2>/dev/null || true
        iptables -P INPUT ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
        
        warn "No backup found — set permissive rules"
    fi
    
    log "Kill switch disabled"
}

# Temporary kill switch pause (for portal auth)
pause_kill_switch() {
    travel "Temporarily pausing kill switch for portal authentication..."
    
    # Allow HTTP/HTTPS temporarily
    if command -v nft >/dev/null 2>&1; then
        nft add rule inet ci5_travel output tcp dport { 80, 443 } accept 2>/dev/null || true
    else
        iptables -I OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    fi
    
    log "Kill switch paused"
}

# Resume kill switch after portal auth
resume_kill_switch() {
    travel "Resuming kill switch..."
    
    if command -v nft >/dev/null 2>&1; then
        # Remove temporary HTTP/HTTPS rules
        nft delete rule inet ci5_travel output handle $(nft -a list chain inet ci5_travel output | grep "tcp dport { 80, 443 }" | awk '{print $NF}') 2>/dev/null || true
    else
        iptables -D OUTPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -D OUTPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    fi
    
    log "Kill switch resumed"
}

# ─────────────────────────────────────────────────────────────────────────────
# PORTABLE AP MODE
# ─────────────────────────────────────────────────────────────────────────────

# Setup hostapd configuration
setup_hostapd() {
    local ap_if="$1"
    local ssid="$2"
    local password="$3"
    local channel="${4:-36}"
    
    mkdir -p "$(dirname "$HOSTAPD_CONF")"
    
    # Detect band from channel
    local hw_mode="a"
    local ht_capab=""
    local vht_capab=""
    
    if [ "$channel" -lt 15 ]; then
        hw_mode="g"
        ht_capab="[HT40+][SHORT-GI-20][SHORT-GI-40]"
    else
        hw_mode="a"
        ht_capab="[HT40+][SHORT-GI-20][SHORT-GI-40]"
        vht_capab="[SHORT-GI-80][MAX-MPDU-11454]"
    fi
    
    # Check for WPA3 support
    local wpa_key_mgmt="WPA-PSK"
    local ieee80211w="0"
    
    if hostapd -v 2>&1 | grep -q "SAE"; then
        # WPA3 transition mode
        wpa_key_mgmt="SAE WPA-PSK"
        ieee80211w="1"  # Optional MFP
    fi
    
    cat > "$HOSTAPD_CONF" << EOF
# CI5 Travel Mode - Portable Access Point
interface=$ap_if
driver=nl80211
ssid=$ssid
hw_mode=$hw_mode
channel=$channel

# 802.11n
ieee80211n=1
ht_capab=$ht_capab

# 802.11ac (5GHz only)
$([ "$hw_mode" = "a" ] && echo "ieee80211ac=1")
$([ "$hw_mode" = "a" ] && echo "vht_capab=$vht_capab")
$([ "$hw_mode" = "a" ] && echo "vht_oper_chwidth=0")

# Security
auth_algs=1
wpa=2
wpa_passphrase=$password
wpa_key_mgmt=$wpa_key_mgmt
wpa_pairwise=CCMP
rsn_pairwise=CCMP
ieee80211w=$ieee80211w

# Performance
wmm_enabled=1
country_code=US
ieee80211d=1

# Hide SSID (optional, set to 1 for stealth)
ignore_broadcast_ssid=0

# Client isolation (prevent client-to-client)
ap_isolate=1
EOF

    info "Created hostapd config: $HOSTAPD_CONF"
}

# Setup dnsmasq for DHCP on AP
setup_dnsmasq_ap() {
    local ap_if="$1"
    local subnet="$2"
    
    mkdir -p "$(dirname "$DNSMASQ_CONF")"
    
    cat > "$DNSMASQ_CONF" << EOF
# CI5 Travel Mode - AP DHCP
interface=$ap_if
bind-interfaces

# DHCP range
dhcp-range=${subnet}.10,${subnet}.100,255.255.255.0,12h

# DNS - forward to localhost (AdGuard/Unbound if available)
server=127.0.0.1

# Options
dhcp-option=3,${subnet}.1   # Gateway
dhcp-option=6,${subnet}.1   # DNS

# Lease file
dhcp-leasefile=/var/run/ci5-travel-leases
EOF

    info "Created dnsmasq config: $DNSMASQ_CONF"
}

# Start AP mode
start_ap_mode() {
    local ap_if="$1"
    local ssid="${2:-$DEFAULT_AP_SSID}"
    local password="${3:-$DEFAULT_AP_PASS}"
    local channel="${4:-$DEFAULT_AP_CHANNEL}"
    local subnet="${5:-$DEFAULT_AP_SUBNET}"
    
    step "STARTING PORTABLE AP MODE"
    
    # Stop any existing instances
    pkill -f "hostapd.*$HOSTAPD_CONF" 2>/dev/null || true
    pkill -f "dnsmasq.*$DNSMASQ_CONF" 2>/dev/null || true
    
    # Release any DHCP leases on AP interface
    dhclient -r "$ap_if" 2>/dev/null || true
    
    # Kill wpa_supplicant on AP interface
    pkill -f "wpa_supplicant.*$ap_if" 2>/dev/null || true
    sleep 1
    
    # Configure AP interface IP
    ip addr flush dev "$ap_if" 2>/dev/null || true
    ip addr add "${subnet}.1/24" dev "$ap_if"
    ip link set "$ap_if" up
    
    info "AP interface $ap_if configured: ${subnet}.1/24"
    
    # Setup configs
    setup_hostapd "$ap_if" "$ssid" "$password" "$channel"
    setup_dnsmasq_ap "$ap_if" "$subnet"
    
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    # Start dnsmasq
    dnsmasq -C "$DNSMASQ_CONF" --pid-file=/var/run/ci5-travel-dnsmasq.pid
    info "DHCP server started"
    
    # Start hostapd
    hostapd -B "$HOSTAPD_CONF" -P /var/run/ci5-travel-hostapd.pid
    
    if [ $? -eq 0 ]; then
        info "Access Point started"
        travel "SSID: $ssid"
        travel "Password: $password"
        travel "Gateway: ${subnet}.1"
        
        return 0
    else
        err "Failed to start hostapd"
    fi
}

# Stop AP mode
stop_ap_mode() {
    step "STOPPING AP MODE"
    
    # Stop services
    if [ -f /var/run/ci5-travel-hostapd.pid ]; then
        kill $(cat /var/run/ci5-travel-hostapd.pid) 2>/dev/null || true
        rm -f /var/run/ci5-travel-hostapd.pid
    fi
    pkill -f "hostapd.*$HOSTAPD_CONF" 2>/dev/null || true
    
    if [ -f /var/run/ci5-travel-dnsmasq.pid ]; then
        kill $(cat /var/run/ci5-travel-dnsmasq.pid) 2>/dev/null || true
        rm -f /var/run/ci5-travel-dnsmasq.pid
    fi
    pkill -f "dnsmasq.*$DNSMASQ_CONF" 2>/dev/null || true
    
    rm -f /var/run/ci5-travel-leases
    
    info "AP services stopped"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE SELECTION LOGIC
# ─────────────────────────────────────────────────────────────────────────────

# Determine best topology based on available hardware
determine_topology() {
    detect_wifi_interfaces
    
    travel "Detected interfaces: $WIFI_INTERFACES"
    [ -n "$INTERNAL_IF" ] && travel "Internal WiFi: $INTERNAL_IF ($(get_chipset_info $INTERNAL_IF))"
    [ -n "$USB_WIFI_IF" ] && travel "USB WiFi: $USB_WIFI_IF ($(get_chipset_info $USB_WIFI_IF))"
    
    # Priority topologies:
    # 1. USB for AP, Internal for upstream (best: dedicated radios)
    # 2. Internal for AP, USB for upstream (reversed)
    # 3. Internal only with concurrent mode (limited but portable)
    # 4. USB only (single adapter, manual switching)
    
    if [ -n "$USB_WIFI_IF" ] && [ -n "$INTERNAL_IF" ]; then
        # Two radios available
        if check_usb_wifi_caps "$USB_WIFI_IF"; then
            # USB supports AP mode - use it for AP (usually better)
            TOPOLOGY="dual_usb_ap"
            AP_IF="$USB_WIFI_IF"
            UPSTREAM_IF="$INTERNAL_IF"
        else
            # USB doesn't support AP - use internal for AP
            TOPOLOGY="dual_internal_ap"
            AP_IF="$INTERNAL_IF"
            UPSTREAM_IF="$USB_WIFI_IF"
        fi
    elif [ -n "$INTERNAL_IF" ] && check_concurrent_mode; then
        # Single internal WiFi with concurrent mode
        TOPOLOGY="internal_concurrent"
        AP_IF="${INTERNAL_IF}"
        UPSTREAM_IF="${INTERNAL_IF}"  # Same interface, virtual
    elif [ -n "$USB_WIFI_IF" ]; then
        # USB only
        TOPOLOGY="usb_only"
        AP_IF="$USB_WIFI_IF"
        UPSTREAM_IF="$USB_WIFI_IF"
    elif [ -n "$INTERNAL_IF" ]; then
        # Internal only without concurrent
        TOPOLOGY="internal_only"
        AP_IF="$INTERNAL_IF"
        UPSTREAM_IF="$INTERNAL_IF"
    else
        err "No WiFi interfaces detected"
    fi
    
    travel "Selected topology: $TOPOLOGY"
    travel "AP interface: $AP_IF"
    travel "Upstream interface: $UPSTREAM_IF"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN MODES
# ─────────────────────────────────────────────────────────────────────────────

# Quick portal bypass mode
portal_mode() {
    step "CAPTIVE PORTAL BYPASS MODE"
    
    detect_wifi_interfaces
    local upstream_if="${USB_WIFI_IF:-$INTERNAL_IF}"
    
    travel "Using interface: $upstream_if"
    
    # Randomize MAC
    randomize_mac "$upstream_if"
    
    # Scan and connect
    printf "\n  Available networks:\n\n"
    scan_networks "$upstream_if"
    
    printf "\n  Enter network SSID (or 'skip' if already connected): "
    read -r ssid
    
    if [ "$ssid" != "skip" ] && [ -n "$ssid" ]; then
        printf "  Password (empty for open network): "
        stty -echo
        read -r password
        stty echo
        printf "\n"
        
        connect_network "$upstream_if" "$ssid" "$password"
    fi
    
    # Handle captive portal
    captive_portal_auth
    
    # Verify connectivity
    if curl -s --max-time 5 "https://www.google.com" >/dev/null 2>&1; then
        info "Internet connectivity verified!"
    else
        warn "Internet may not be fully available"
    fi
    
    # Start VPN if available
    if detect_wireguard && ! wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        travel "Starting WireGuard..."
        wg-quick up wg0 2>/dev/null || systemctl start wg-quick@wg0 2>/dev/null || true
    fi
}

# Full AP mode
ap_mode_enable() {
    step "PORTABLE AP MODE"
    
    # Determine topology
    determine_topology
    
    # Handle single-interface scenarios
    if [ "$TOPOLOGY" = "internal_only" ] || [ "$TOPOLOGY" = "usb_only" ]; then
        warn "Single interface mode — cannot run AP and client simultaneously"
        printf "\n  Options:\n"
        printf "    ${M}[1]${N} Connect to upstream first, then enable AP (same channel)\n"
        printf "    ${M}[2]${N} Enable AP only (configure upstream manually later)\n"
        printf "    ${M}[3]${N} Cancel\n"
        printf "\n  Choice: "
        read -r choice
        
        case "$choice" in
            1)
                # Connect first
                portal_mode
                # Then enable AP on same channel
                local current_channel=$(iw dev "$UPSTREAM_IF" info 2>/dev/null | grep channel | awk '{print $2}')
                start_ap_mode "$AP_IF" "$DEFAULT_AP_SSID" "$DEFAULT_AP_PASS" "${current_channel:-6}"
                ;;
            2)
                start_ap_mode "$AP_IF"
                ;;
            *)
                return 0
                ;;
        esac
        return
    fi
    
    # Dual interface mode
    
    # Configure AP settings
    printf "\n  ${B}AP Configuration${N}\n"
    printf "  SSID [%s]: " "$DEFAULT_AP_SSID"
    read -r ssid
    ssid="${ssid:-$DEFAULT_AP_SSID}"
    
    printf "  Password [auto-generated]: "
    read -r password
    password="${password:-$DEFAULT_AP_PASS}"
    
    printf "  Channel (1-11 for 2.4GHz, 36-165 for 5GHz) [%s]: " "$DEFAULT_AP_CHANNEL"
    read -r channel
    channel="${channel:-$DEFAULT_AP_CHANNEL}"
    
    # Start AP
    start_ap_mode "$AP_IF" "$ssid" "$password" "$channel"
    
    # Randomize upstream MAC
    randomize_mac "$UPSTREAM_IF"
    
    # Scan and connect upstream
    printf "\n  ${B}Connect to upstream network${N}\n"
    scan_networks "$UPSTREAM_IF"
    
    printf "\n  Enter network SSID: "
    read -r upstream_ssid
    
    if [ -n "$upstream_ssid" ]; then
        printf "  Password (empty for open): "
        stty -echo
        read -r upstream_pass
        stty echo
        printf "\n"
        
        connect_network "$UPSTREAM_IF" "$upstream_ssid" "$upstream_pass"
    fi
    
    # Handle captive portal
    if detect_captive_portal; then
        pause_kill_switch
        captive_portal_auth
    fi
    
    # Enable kill switch
    enable_kill_switch "$UPSTREAM_IF" "$AP_IF"
    
    # Start WireGuard if not running
    if ! detect_wireguard || ! wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        travel "Starting WireGuard..."
        wg-quick up wg0 2>/dev/null || systemctl start wg-quick@wg0 2>/dev/null || warn "WireGuard not available"
    fi
    
    # Save state
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << EOF
mode=ap
ap_if=$AP_IF
upstream_if=$UPSTREAM_IF
ssid=$ssid
password=$password
topology=$TOPOLOGY
started=$(date +%s)
EOF

    # Final status
    step "PORTABLE AP ACTIVE"
    
    printf "\n"
    printf "  ${G}Your secure access point is ready!${N}\n"
    printf "\n"
    printf "  Connect your devices to:\n"
    printf "    SSID:     ${C}%s${N}\n" "$ssid"
    printf "    Password: ${C}%s${N}\n" "$password"
    printf "    Gateway:  ${C}%s.1${N}\n" "$DEFAULT_AP_SUBNET"
    printf "\n"
    printf "  Security status:\n"
    
    if detect_wireguard && wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        printf "    VPN:       ${G}● Connected${N}\n"
    else
        printf "    VPN:       ${Y}○ Not connected${N}\n"
    fi
    
    printf "    Kill switch: ${G}● Enforced${N}\n"
    printf "    MAC randomized: ${G}● Yes${N}\n"
    printf "    Upstream hidden: ${G}● NAT active${N}\n"
    printf "\n"
    
    log "AP mode enabled: ap=$AP_IF upstream=$UPSTREAM_IF ssid=$ssid"
}

# Disable AP mode
ap_mode_disable() {
    step "DISABLING AP MODE"
    
    # Read state
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
    fi
    
    # Stop AP
    stop_ap_mode
    
    # Disable kill switch
    disable_kill_switch
    
    # Restore MACs
    [ -n "$upstream_if" ] && restore_mac "$upstream_if"
    [ -n "$ap_if" ] && restore_mac "$ap_if"
    
    # Cleanup
    rm -f "$STATE_FILE"
    rm -f "$HOSTAPD_CONF"
    rm -f "$DNSMASQ_CONF"
    
    info "AP mode disabled"
    info "Restore normal CI5 operation with: systemctl restart networking"
    
    log "AP mode disabled"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "TRAVEL MODE STATUS"
    
    # Check current mode
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
        printf "  Mode: ${G}%s${N}\n" "${mode:-unknown}"
        printf "  AP Interface: %s\n" "${ap_if:-none}"
        printf "  Upstream Interface: %s\n" "${upstream_if:-none}"
        printf "  SSID: %s\n" "${ssid:-none}"
        printf "  Running since: %s\n" "$(date -d @${started:-0} 2>/dev/null || echo 'unknown')"
    else
        printf "  Mode: ${Y}inactive${N}\n"
    fi
    
    printf "\n  ${B}Interface Status:${N}\n"
    detect_wifi_interfaces
    
    for iface in $WIFI_INTERFACES; do
        local state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        local mode_info=""
        
        # Check if running as AP
        if pgrep -f "hostapd.*interface=$iface" >/dev/null 2>&1; then
            mode_info="[AP]"
        elif iw dev "$iface" link 2>/dev/null | grep -q "Connected"; then
            local connected_ssid=$(iw dev "$iface" link 2>/dev/null | grep SSID | awk '{print $2}')
            mode_info="[Client: $connected_ssid]"
        fi
        
        printf "    %s: %s %s (%s)\n" "$iface" "$state" "$mode_info" "$(get_chipset_info $iface)"
    done
    
    printf "\n  ${B}Security Status:${N}\n"
    
    # VPN
    if detect_wireguard && wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        local endpoint=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | head -1)
        printf "    VPN: ${G}● Connected${N} ($endpoint)\n"
    else
        printf "    VPN: ${Y}○ Not connected${N}\n"
    fi
    
    # Kill switch
    if nft list table inet ci5_travel >/dev/null 2>&1 || iptables -L -n 2>/dev/null | grep -q "TRAVEL"; then
        printf "    Kill switch: ${G}● Active${N}\n"
    else
        printf "    Kill switch: ${Y}○ Inactive${N}\n"
    fi
    
    # Connected clients (if AP mode)
    if [ -f /var/run/ci5-travel-leases ]; then
        local client_count=$(wc -l < /var/run/ci5-travel-leases 2>/dev/null || echo 0)
        printf "    AP Clients: %s\n" "$client_count"
    fi
    
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

interactive_menu() {
    while true; do
        clear
        printf "${M}"
        cat << 'BANNER'
   _____                 _   __  __           _      
  |_   _| __ __ ___   __| | |  \/  | ___   __| | ___ 
    | || '__/ _` \ \ / / _ \ | |\/| |/ _ \ / _` |/ _ \
    | || | | (_| |\ V /  __/ | |  | | (_) | (_| |  __/
    |_||_|  \__,_| \_/ \___| |_|  |_|\___/ \__,_|\___|
                                                      
BANNER
        printf "${N}"
        printf "        ${C}CI5 Travel Security Toolkit${N}\n"
        printf "        ${Y}v2.0-PHOENIX${N}\n\n"
        
        # Quick status
        if [ -f "$STATE_FILE" ]; then
            . "$STATE_FILE" 2>/dev/null
            printf "  Status: ${G}●${N} %s mode active\n\n" "${mode:-unknown}"
        else
            printf "  Status: ${Y}○${N} Inactive\n\n"
        fi
        
        printf "  ${B}QUICK ACTIONS${N}\n"
        printf "    ${M}[1]${N} Portal Bypass (MAC randomize + captive portal)\n"
        printf "    ${M}[2]${N} Enable Portable AP Mode\n"
        printf "    ${M}[3]${N} Disable Portable AP Mode\n\n"
        
        printf "  ${B}NETWORK${N}\n"
        printf "    ${M}[4]${N} Scan nearby networks\n"
        printf "    ${M}[5]${N} Connect to network\n"
        printf "    ${M}[6]${N} Randomize MAC address\n\n"
        
        printf "  ${B}SECURITY${N}\n"
        printf "    ${M}[7]${N} Enable VPN kill switch\n"
        printf "    ${M}[8]${N} Disable VPN kill switch\n"
        printf "    ${M}[9]${N} Clone MAC from device\n\n"
        
        printf "  ${M}[S]${N} Status    ${M}[Q]${N} Quit\n\n"
        
        printf "  Choice: "
        read -r choice
        
        case "$choice" in
            1)
                clear
                portal_mode
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            2)
                clear
                ap_mode_enable
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            3)
                clear
                ap_mode_disable
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            4)
                clear
                detect_wifi_interfaces
                for iface in $WIFI_INTERFACES; do
                    printf "\n${B}=== %s ===${N}\n\n" "$iface"
                    scan_networks "$iface"
                done
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            5)
                clear
                detect_wifi_interfaces
                printf "  Interface to use [%s]: " "${INTERNAL_IF:-wlan0}"
                read -r iface
                iface="${iface:-${INTERNAL_IF:-wlan0}}"
                
                scan_networks "$iface"
                
                printf "\n  SSID: "
                read -r ssid
                printf "  Password: "
                stty -echo
                read -r pass
                stty echo
                printf "\n"
                
                connect_network "$iface" "$ssid" "$pass"
                
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            6)
                clear
                detect_wifi_interfaces
                printf "  Interface to randomize [%s]: " "${INTERNAL_IF:-wlan0}"
                read -r iface
                iface="${iface:-${INTERNAL_IF:-wlan0}}"
                
                randomize_mac "$iface"
                
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            7)
                clear
                detect_wifi_interfaces
                enable_kill_switch "${UPSTREAM_IF:-wlan0}" "${AP_IF:-wlan1}"
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            8)
                clear
                disable_kill_switch
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            9)
                clear
                clone_mac_interactive
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            [Ss])
                clear
                show_status
                printf "  Press Enter to continue..."
                read -r _
                ;;
            [Qq])
                clear
                exit 0
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
CI5 Travel Mode — Hostile Network Security Toolkit

Usage:
  curl ci5.run/travel | sh              Interactive menu
  curl ci5.run/travel | sh -s portal    Quick captive portal bypass
  curl ci5.run/travel | sh -s ap        Enable portable AP mode
  curl ci5.run/travel | sh -s ap off    Disable portable AP mode
  curl ci5.run/travel | sh -s status    Show current status
  curl ci5.run/travel | sh -s scan      Scan nearby networks
  curl ci5.run/travel | sh -s mac       Randomize MAC address

Modes:
  portal    Quick bypass for hotel/airport captive portals
            - Randomizes MAC on upstream interface
            - Handles captive portal authentication
            - Optionally starts VPN after auth
            
  ap        Full portable access point mode
            - Creates secure WiFi AP for your devices
            - Connects to hostile network as client
            - All traffic forced through VPN
            - Kill switch prevents any leakage
            - Your devices invisible to upstream network

Topology (auto-detected):
  - Dual radio: USB WiFi for AP, internal for upstream (best)
  - Dual radio: Internal for AP, USB for upstream (reversed)
  - Single radio: Concurrent AP+Client on same channel (limited)

Hardware:
  Recommended USB adapters (MediaTek mt76 chipset):
  - ALFA AWUS036ACM (mt7612u) — best for AP mode
  - Netgear A6210 (mt7612u) — compact
  - EDUP EP-AX1672 (mt7921au) — WiFi 6

  Internal WiFi (Pi 5 BCM4345):
  - Works for client mode to hostile networks
  - Can run AP but with channel/performance limits
  - MAC randomization supported

Security Features:
  - MAC randomization (locally administered addresses)
  - NAT masquerading (downstream devices invisible)
  - VPN kill switch (no traffic leaks)
  - DNS leak prevention
  - Client isolation on AP
  - WPA3/WPA2 transition mode

Examples:
  # Quick hotel WiFi setup
  curl ci5.run/travel | sh -s portal
  
  # Full portable gateway for travel
  curl ci5.run/travel | sh -s ap
  
  # Check current mode
  curl ci5.run/travel | sh -s status
  
  # Disable and restore normal operation  
  curl ci5.run/travel | sh -s ap off
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    # Create directories
    mkdir -p "$TRAVEL_DIR" "$BACKUP_DIR"
    
    # Check dependencies
    for cmd in ip iw hostapd dnsmasq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "$cmd not found, installing..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y "$cmd" 2>/dev/null || true
            elif command -v opkg >/dev/null 2>&1; then
                opkg update && opkg install "$cmd" 2>/dev/null || true
            fi
        fi
    done
    
    case "${1:-}" in
        portal)
            portal_mode
            ;;
        ap)
            case "${2:-}" in
                off|disable|stop)
                    ap_mode_disable
                    ;;
                *)
                    ap_mode_enable
                    ;;
            esac
            ;;
        status)
            show_status
            ;;
        scan)
            detect_wifi_interfaces
            for iface in $WIFI_INTERFACES; do
                printf "\n${B}=== %s ===${N}\n\n" "$iface"
                scan_networks "$iface"
            done
            ;;
        mac)
            detect_wifi_interfaces
            randomize_mac "${2:-$INTERNAL_IF}"
            ;;
        killswitch)
            case "${2:-}" in
                off|disable)
                    disable_kill_switch
                    ;;
                *)
                    detect_wifi_interfaces
                    enable_kill_switch "${INTERNAL_IF:-wlan0}" "wlan1"
                    ;;
            esac
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            interactive_menu
            ;;
    esac
}

main "$@"
