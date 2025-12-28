#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/ddns — Dynamic DNS Monitor with WireGuard Re-sync
# Version: 2.0-PHOENIX
# 
# Updates DNS records when your home IP changes and automatically
# re-syncs WireGuard peers to maintain VPN connectivity.
# 
# Supports: Cloudflare, DuckDNS, No-IP, Dynu, custom webhook
# ═══════════════════════════════════════════════════════════════════════════

set -e

DDNS_CONFIG="/etc/ci5/ddns.conf"
DDNS_STATE="/var/run/ci5-ddns"
DDNS_SCRIPT="/usr/local/bin/ci5-ddns-update"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# IP DETECTION
# ─────────────────────────────────────────────────────────────────────────────
get_public_ip() {
    local ip=""
    
    # Try multiple services for redundancy
    for service in \
        "https://ifconfig.me" \
        "https://api.ipify.org" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com"; do
        ip=$(curl -fsSL --connect-timeout 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

get_cached_ip() {
    [ -f "$DDNS_STATE/last_ip" ] && cat "$DDNS_STATE/last_ip"
}

save_ip() {
    mkdir -p "$DDNS_STATE"
    echo "$1" > "$DDNS_STATE/last_ip"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
load_config() {
    [ -f "$DDNS_CONFIG" ] && . "$DDNS_CONFIG"
}

save_config() {
    mkdir -p "$(dirname "$DDNS_CONFIG")"
    cat > "$DDNS_CONFIG" << EOF
# CI5 Dynamic DNS Configuration
# Generated: $(date -Iseconds)

# Provider: cloudflare, duckdns, noip, dynu, custom
DDNS_PROVIDER="${DDNS_PROVIDER:-cloudflare}"

# Cloudflare settings
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_RECORD_NAME="${CF_RECORD_NAME:-}"
CF_RECORD_ID="${CF_RECORD_ID:-}"

# DuckDNS settings
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"

# No-IP settings
NOIP_HOSTNAME="${NOIP_HOSTNAME:-}"
NOIP_USERNAME="${NOIP_USERNAME:-}"
NOIP_PASSWORD="${NOIP_PASSWORD:-}"

# Dynu settings
DYNU_HOSTNAME="${DYNU_HOSTNAME:-}"
DYNU_USERNAME="${DYNU_USERNAME:-}"
DYNU_PASSWORD="${DYNU_PASSWORD:-}"

# Custom webhook (GET request with {IP} placeholder)
CUSTOM_WEBHOOK="${CUSTOM_WEBHOOK:-}"

# WireGuard re-sync
WG_RESYNC_ENABLED="${WG_RESYNC_ENABLED:-0}"
WG_PEERS="${WG_PEERS:-}"

# Notifications
NOTIFY_ON_CHANGE="${NOTIFY_ON_CHANGE:-1}"

# Check interval (minutes)
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
EOF
    chmod 600 "$DDNS_CONFIG"
    info "Configuration saved"
}

# ─────────────────────────────────────────────────────────────────────────────
# PROVIDER UPDATES
# ─────────────────────────────────────────────────────────────────────────────
update_cloudflare() {
    local ip="$1"
    
    [ -z "$CF_API_TOKEN" ] && { warn "Cloudflare API token not set"; return 1; }
    [ -z "$CF_ZONE_ID" ] && { warn "Cloudflare Zone ID not set"; return 1; }
    [ -z "$CF_RECORD_NAME" ] && { warn "Cloudflare record name not set"; return 1; }
    
    # Get record ID if not cached
    if [ -z "$CF_RECORD_ID" ]; then
        CF_RECORD_ID=$(curl -fsSL \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$CF_RECORD_NAME" \
            2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        if [ -z "$CF_RECORD_ID" ]; then
            warn "Could not find DNS record for $CF_RECORD_NAME"
            return 1
        fi
        
        # Save for next time
        sed -i "s/^CF_RECORD_ID=.*/CF_RECORD_ID=\"$CF_RECORD_ID\"/" "$DDNS_CONFIG"
    fi
    
    # Update record
    local result=$(curl -fsSL -X PUT \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$ip\",\"ttl\":300,\"proxied\":false}" \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        2>/dev/null)
    
    if echo "$result" | grep -q '"success":true'; then
        info "Cloudflare updated: $CF_RECORD_NAME → $ip"
        return 0
    else
        warn "Cloudflare update failed"
        return 1
    fi
}

update_duckdns() {
    local ip="$1"
    
    [ -z "$DUCKDNS_DOMAIN" ] && { warn "DuckDNS domain not set"; return 1; }
    [ -z "$DUCKDNS_TOKEN" ] && { warn "DuckDNS token not set"; return 1; }
    
    local result=$(curl -fsSL \
        "https://www.duckdns.org/update?domains=$DUCKDNS_DOMAIN&token=$DUCKDNS_TOKEN&ip=$ip" \
        2>/dev/null)
    
    if [ "$result" = "OK" ]; then
        info "DuckDNS updated: $DUCKDNS_DOMAIN → $ip"
        return 0
    else
        warn "DuckDNS update failed: $result"
        return 1
    fi
}

update_noip() {
    local ip="$1"
    
    [ -z "$NOIP_HOSTNAME" ] && { warn "No-IP hostname not set"; return 1; }
    [ -z "$NOIP_USERNAME" ] && { warn "No-IP username not set"; return 1; }
    [ -z "$NOIP_PASSWORD" ] && { warn "No-IP password not set"; return 1; }
    
    local result=$(curl -fsSL \
        -u "$NOIP_USERNAME:$NOIP_PASSWORD" \
        "https://dynupdate.no-ip.com/nic/update?hostname=$NOIP_HOSTNAME&myip=$ip" \
        2>/dev/null)
    
    if echo "$result" | grep -qE "^(good|nochg)"; then
        info "No-IP updated: $NOIP_HOSTNAME → $ip"
        return 0
    else
        warn "No-IP update failed: $result"
        return 1
    fi
}

update_dynu() {
    local ip="$1"
    
    [ -z "$DYNU_HOSTNAME" ] && { warn "Dynu hostname not set"; return 1; }
    [ -z "$DYNU_USERNAME" ] && { warn "Dynu username not set"; return 1; }
    [ -z "$DYNU_PASSWORD" ] && { warn "Dynu password not set"; return 1; }
    
    local pass_hash=$(echo -n "$DYNU_PASSWORD" | md5sum | cut -d' ' -f1)
    
    local result=$(curl -fsSL \
        "https://api.dynu.com/nic/update?hostname=$DYNU_HOSTNAME&myip=$ip&username=$DYNU_USERNAME&password=$pass_hash" \
        2>/dev/null)
    
    if echo "$result" | grep -qE "^(good|nochg)"; then
        info "Dynu updated: $DYNU_HOSTNAME → $ip"
        return 0
    else
        warn "Dynu update failed: $result"
        return 1
    fi
}

update_custom() {
    local ip="$1"
    
    [ -z "$CUSTOM_WEBHOOK" ] && { warn "Custom webhook not set"; return 1; }
    
    local url=$(echo "$CUSTOM_WEBHOOK" | sed "s/{IP}/$ip/g")
    
    if curl -fsSL "$url" >/dev/null 2>&1; then
        info "Custom webhook called: $ip"
        return 0
    else
        warn "Custom webhook failed"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WIREGUARD RE-SYNC
# ─────────────────────────────────────────────────────────────────────────────
resync_wireguard() {
    local new_ip="$1"
    
    [ "$WG_RESYNC_ENABLED" = "1" ] || return 0
    [ -z "$WG_PEERS" ] && return 0
    
    info "Re-syncing WireGuard peers..."
    
    # For each peer, update their endpoint if we're the server
    for iface in /etc/wireguard/*.conf; do
        [ -f "$iface" ] || continue
        
        local iface_name=$(basename "$iface" .conf)
        
        # Restart interface to pick up new endpoint
        if command -v wg >/dev/null 2>&1; then
            wg syncconf "$iface_name" <(wg-quick strip "$iface_name") 2>/dev/null || true
        fi
    done
    
    # If we have remote peers to notify (optional feature)
    for peer in $WG_PEERS; do
        # peer format: user@host or just host
        if echo "$peer" | grep -q "@"; then
            local remote_host=$(echo "$peer" | cut -d'@' -f2)
            local remote_user=$(echo "$peer" | cut -d'@' -f1)
            
            # Try to SSH and update (non-blocking)
            ssh -o ConnectTimeout=5 -o BatchMode=yes "$peer" \
                "wg set wg0 peer \$(wg show wg0 | grep 'peer:' | awk '{print \$2}' | head -1) endpoint $new_ip:51820" \
                >/dev/null 2>&1 &
        fi
    done
    
    info "WireGuard re-sync initiated"
}

# ─────────────────────────────────────────────────────────────────────────────
# UPDATE FLOW
# ─────────────────────────────────────────────────────────────────────────────
do_update() {
    local force="${1:-0}"
    
    load_config
    
    # Get current IP
    local current_ip=$(get_public_ip)
    if [ -z "$current_ip" ]; then
        warn "Could not determine public IP"
        return 1
    fi
    
    # Get cached IP
    local cached_ip=$(get_cached_ip)
    
    # Check if changed
    if [ "$current_ip" = "$cached_ip" ] && [ "$force" != "1" ]; then
        info "IP unchanged: $current_ip"
        return 0
    fi
    
    if [ -n "$cached_ip" ]; then
        info "IP changed: $cached_ip → $current_ip"
    else
        info "Current IP: $current_ip"
    fi
    
    # Update provider
    local update_success=0
    case "$DDNS_PROVIDER" in
        cloudflare) update_cloudflare "$current_ip" && update_success=1 ;;
        duckdns)    update_duckdns "$current_ip" && update_success=1 ;;
        noip)       update_noip "$current_ip" && update_success=1 ;;
        dynu)       update_dynu "$current_ip" && update_success=1 ;;
        custom)     update_custom "$current_ip" && update_success=1 ;;
        *)          warn "Unknown provider: $DDNS_PROVIDER"; return 1 ;;
    esac
    
    if [ "$update_success" = "1" ]; then
        # Save new IP
        save_ip "$current_ip"
        
        # Re-sync WireGuard
        resync_wireguard "$current_ip"
        
        # Notify if enabled
        if [ "$NOTIFY_ON_CHANGE" = "1" ] && [ -x /usr/local/bin/ci5-notify ]; then
            /usr/local/bin/ci5-notify "🌐 IP Changed" "New IP: $current_ip" "low" "globe"
        fi
        
        # Log
        logger -t "ci5-ddns" "IP updated to $current_ip"
    fi
    
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SETUP WIZARD
# ─────────────────────────────────────────────────────────────────────────────
setup_wizard() {
    step "DYNAMIC DNS SETUP"
    
    printf "Select your DDNS provider:\n"
    printf "  [1] Cloudflare (recommended)\n"
    printf "  [2] DuckDNS (free)\n"
    printf "  [3] No-IP\n"
    printf "  [4] Dynu\n"
    printf "  [5] Custom webhook\n"
    printf "\n"
    printf "Choice [1]: "
    read -r choice
    
    case "${choice:-1}" in
        1)
            DDNS_PROVIDER="cloudflare"
            printf "\nCloudflare API Token: "
            read -r CF_API_TOKEN
            printf "Zone ID: "
            read -r CF_ZONE_ID
            printf "Record name (e.g., home.example.com): "
            read -r CF_RECORD_NAME
            ;;
        2)
            DDNS_PROVIDER="duckdns"
            printf "\nDuckDNS subdomain (without .duckdns.org): "
            read -r DUCKDNS_DOMAIN
            printf "DuckDNS token: "
            read -r DUCKDNS_TOKEN
            ;;
        3)
            DDNS_PROVIDER="noip"
            printf "\nNo-IP hostname: "
            read -r NOIP_HOSTNAME
            printf "No-IP username: "
            read -r NOIP_USERNAME
            printf "No-IP password: "
            read -r NOIP_PASSWORD
            ;;
        4)
            DDNS_PROVIDER="dynu"
            printf "\nDynu hostname: "
            read -r DYNU_HOSTNAME
            printf "Dynu username: "
            read -r DYNU_USERNAME
            printf "Dynu password: "
            read -r DYNU_PASSWORD
            ;;
        5)
            DDNS_PROVIDER="custom"
            printf "\nWebhook URL (use {IP} as placeholder): "
            read -r CUSTOM_WEBHOOK
            ;;
        *)
            err "Invalid choice"
            ;;
    esac
    
    # WireGuard re-sync
    printf "\n"
    printf "Enable WireGuard re-sync when IP changes? [Y/n]: "
    read -r wg_sync
    WG_RESYNC_ENABLED=$([ "$wg_sync" = "n" ] && echo 0 || echo 1)
    
    # Check interval
    printf "Check interval in minutes [5]: "
    read -r interval
    CHECK_INTERVAL="${interval:-5}"
    
    save_config
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL CRON
# ─────────────────────────────────────────────────────────────────────────────
install_cron() {
    step "INSTALLING CRON JOB"
    
    load_config
    
    # Create update script
    cat > "$DDNS_SCRIPT" << 'UPDATE_SCRIPT'
#!/bin/sh
# CI5 DDNS Update Script
exec curl -fsSL ci5.run/ddns 2>/dev/null | sh -s check
UPDATE_SCRIPT
    chmod +x "$DDNS_SCRIPT"
    
    # Remove old cron entries
    crontab -l 2>/dev/null | grep -v "ci5-ddns" | crontab - 2>/dev/null || true
    
    # Add new cron entry
    local cron_line="*/${CHECK_INTERVAL} * * * * $DDNS_SCRIPT >/dev/null 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    
    info "Cron job installed (every $CHECK_INTERVAL minutes)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    step "DDNS STATUS"
    
    load_config
    
    local current_ip=$(get_public_ip)
    local cached_ip=$(get_cached_ip)
    
    printf "  Provider:   %s\n" "$DDNS_PROVIDER"
    printf "  Current IP: %s\n" "${current_ip:-unknown}"
    printf "  Cached IP:  %s\n" "${cached_ip:-none}"
    printf "  Interval:   %s minutes\n" "$CHECK_INTERVAL"
    printf "  WG re-sync: %s\n" "$([ "$WG_RESYNC_ENABLED" = "1" ] && echo "enabled" || echo "disabled")"
    printf "\n"
    
    case "$DDNS_PROVIDER" in
        cloudflare) printf "  Record: %s\n" "$CF_RECORD_NAME" ;;
        duckdns)    printf "  Domain: %s.duckdns.org\n" "$DUCKDNS_DOMAIN" ;;
        noip)       printf "  Host:   %s\n" "$NOIP_HOSTNAME" ;;
        dynu)       printf "  Host:   %s\n" "$DYNU_HOSTNAME" ;;
        custom)     printf "  Webhook: %s\n" "$CUSTOM_WEBHOOK" ;;
    esac
    printf "\n"
    
    # Check cron
    if crontab -l 2>/dev/null | grep -q "ci5-ddns"; then
        printf "  Cron: ${G}active${N}\n"
    else
        printf "  Cron: ${Y}not installed${N}\n"
    fi
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
do_uninstall() {
    step "UNINSTALLING DDNS"
    
    # Remove cron
    crontab -l 2>/dev/null | grep -v "ci5-ddns" | crontab - 2>/dev/null || true
    info "Removed cron job"
    
    # Remove scripts
    rm -f "$DDNS_SCRIPT"
    info "Removed scripts"
    
    # Remove state
    rm -rf "$DDNS_STATE"
    info "Removed state"
    
    # Config?
    printf "Remove configuration? [y/N]: "
    read -r rm_conf
    if [ "$rm_conf" = "y" ]; then
        rm -f "$DDNS_CONFIG"
        info "Removed configuration"
    fi
    
    info "Uninstall complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
CI5 Dynamic DNS Monitor

Usage:
  curl ci5.run/ddns | sh              Setup wizard
  curl ci5.run/ddns | sh -s check     Check and update if needed
  curl ci5.run/ddns | sh -s force     Force update regardless of change
  curl ci5.run/ddns | sh -s status    Show current status
  curl ci5.run/ddns | sh -s uninstall Remove DDNS integration

Supported Providers:
  • Cloudflare (recommended - fast propagation)
  • DuckDNS (free, easy setup)
  • No-IP
  • Dynu
  • Custom webhook (any URL with {IP} placeholder)

Features:
  • Automatic IP change detection
  • WireGuard peer re-sync on IP change
  • Push notifications (if ntfy configured)
  • Cron-based periodic checking
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    command -v curl >/dev/null 2>&1 || err "curl required"
    
    mkdir -p "$DDNS_STATE"
    
    case "${1:-}" in
        check)
            do_update 0
            ;;
        force)
            do_update 1
            ;;
        status)
            show_status
            ;;
        uninstall|remove)
            do_uninstall
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            # Full setup
            if [ -f "$DDNS_CONFIG" ]; then
                printf "DDNS already configured. Reconfigure? [y/N]: "
                read -r reconf
                [ "$reconf" != "y" ] && { show_status; exit 0; }
            fi
            
            setup_wizard
            install_cron
            
            # Initial update
            step "INITIAL UPDATE"
            do_update 1
            
            printf "\n"
            printf "  ${G}DDNS monitoring is active!${N}\n"
            printf "  IP will be checked every %s minutes.\n" "$CHECK_INTERVAL"
            printf "\n"
            ;;
    esac
}

main "$@"
