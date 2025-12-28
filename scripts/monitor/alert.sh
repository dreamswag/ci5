#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/alert — Mobile Push Notifications via ntfy.sh
# Version: 2.0-PHOENIX
# 
# Configures ntfy.sh to send push alerts to your phone for:
# - Intrusion attempts (Suricata/CrowdSec)
# - Service failures
# - System reboots
# - WAN IP changes
# - Custom events
# ═══════════════════════════════════════════════════════════════════════════

set -e

NTFY_CONFIG="/etc/ci5/ntfy.conf"
NTFY_SCRIPT="/usr/local/bin/ci5-notify"
MONITOR_SCRIPT="/usr/local/bin/ci5-alert-monitor"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
load_config() {
    if [ -f "$NTFY_CONFIG" ]; then
        . "$NTFY_CONFIG"
        return 0
    fi
    return 1
}

save_config() {
    mkdir -p "$(dirname "$NTFY_CONFIG")"
    cat > "$NTFY_CONFIG" << EOF
# CI5 ntfy.sh Configuration
# Generated: $(date -Iseconds)

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NTFY_PRIORITY="${NTFY_PRIORITY:-default}"

# Alert types (1=enabled, 0=disabled)
ALERT_INTRUSION=${ALERT_INTRUSION:-1}
ALERT_SERVICE=${ALERT_SERVICE:-1}
ALERT_REBOOT=${ALERT_REBOOT:-1}
ALERT_WAN_CHANGE=${ALERT_WAN_CHANGE:-1}
ALERT_SSH_LOGIN=${ALERT_SSH_LOGIN:-0}
EOF
    chmod 600 "$NTFY_CONFIG"
    info "Configuration saved to $NTFY_CONFIG"
}

# ─────────────────────────────────────────────────────────────────────────────
# SETUP WIZARD
# ─────────────────────────────────────────────────────────────────────────────
setup_wizard() {
    step "NTFY.SH SETUP"
    
    printf "${C}ntfy.sh${N} is a free, open-source push notification service.\n"
    printf "Install the app on your phone from ntfy.sh to receive alerts.\n\n"
    
    # Server
    printf "ntfy server [${C}https://ntfy.sh${N}]: "
    read -r server
    NTFY_SERVER="${server:-https://ntfy.sh}"
    
    # Topic
    printf "\n"
    printf "Choose a unique, secret topic name (like a password).\n"
    printf "Anyone who knows the topic can send you notifications.\n"
    printf "\n"
    
    # Generate suggestion
    local suggested="ci5-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    
    printf "Topic name [${C}${suggested}${N}]: "
    read -r topic
    NTFY_TOPIC="${topic:-$suggested}"
    
    # Token (optional)
    printf "\n"
    printf "Access token (optional, for private topics): "
    read -r token
    NTFY_TOKEN="$token"
    
    # Alert types
    printf "\n"
    printf "Which alerts do you want to receive?\n"
    printf "\n"
    
    printf "  [1] Intrusion attempts (Suricata/CrowdSec) [Y/n]: "
    read -r a1; ALERT_INTRUSION=$([ "$a1" = "n" ] && echo 0 || echo 1)
    
    printf "  [2] Service failures [Y/n]: "
    read -r a2; ALERT_SERVICE=$([ "$a2" = "n" ] && echo 0 || echo 1)
    
    printf "  [3] System reboots [Y/n]: "
    read -r a3; ALERT_REBOOT=$([ "$a3" = "n" ] && echo 0 || echo 1)
    
    printf "  [4] WAN IP changes [Y/n]: "
    read -r a4; ALERT_WAN_CHANGE=$([ "$a4" = "n" ] && echo 0 || echo 1)
    
    printf "  [5] SSH logins [y/N]: "
    read -r a5; ALERT_SSH_LOGIN=$([ "$a5" = "y" ] && echo 1 || echo 0)
    
    save_config
}

# ─────────────────────────────────────────────────────────────────────────────
# NOTIFICATION SCRIPT
# ─────────────────────────────────────────────────────────────────────────────
install_notify_script() {
    step "INSTALLING NOTIFICATION SCRIPT"
    
    cat > "$NTFY_SCRIPT" << 'NOTIFY_SCRIPT'
#!/bin/sh
# CI5 Notify - Send push notifications via ntfy.sh
# Usage: ci5-notify <title> <message> [priority] [tags]

NTFY_CONFIG="/etc/ci5/ntfy.conf"

# Load config
if [ -f "$NTFY_CONFIG" ]; then
    . "$NTFY_CONFIG"
else
    echo "Error: ntfy not configured. Run: curl ci5.run/alert | sh" >&2
    exit 1
fi

TITLE="${1:-CI5 Alert}"
MESSAGE="${2:-No message}"
PRIORITY="${3:-$NTFY_PRIORITY}"
TAGS="${4:-}"

# Build curl command
CURL_OPTS="-fsSL"
CURL_OPTS="$CURL_OPTS -H 'Title: $TITLE'"
CURL_OPTS="$CURL_OPTS -H 'Priority: $PRIORITY'"

[ -n "$TAGS" ] && CURL_OPTS="$CURL_OPTS -H 'Tags: $TAGS'"
[ -n "$NTFY_TOKEN" ] && CURL_OPTS="$CURL_OPTS -H 'Authorization: Bearer $NTFY_TOKEN'"

# Send notification
eval curl $CURL_OPTS -d "$MESSAGE" "${NTFY_SERVER}/${NTFY_TOPIC}" >/dev/null 2>&1

exit 0
NOTIFY_SCRIPT
    
    chmod +x "$NTFY_SCRIPT"
    info "Installed: $NTFY_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# MONITOR DAEMON
# ─────────────────────────────────────────────────────────────────────────────
install_monitor() {
    step "INSTALLING ALERT MONITOR"
    
    cat > "$MONITOR_SCRIPT" << 'MONITOR_SCRIPT'
#!/bin/sh
# CI5 Alert Monitor - Background service for system alerts
# Monitors logs and system state, sends notifications via ci5-notify

NTFY_CONFIG="/etc/ci5/ntfy.conf"
STATE_DIR="/var/run/ci5-alert"
LAST_WAN_FILE="$STATE_DIR/last_wan_ip"

[ -f "$NTFY_CONFIG" ] && . "$NTFY_CONFIG"

mkdir -p "$STATE_DIR"

notify() {
    /usr/local/bin/ci5-notify "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# INTRUSION MONITOR (Suricata/CrowdSec)
# ─────────────────────────────────────────────────────────────────────────────
check_intrusions() {
    [ "$ALERT_INTRUSION" = "1" ] || return 0
    
    # Suricata fast.log
    if [ -f /var/log/suricata/fast.log ]; then
        local last_check="$STATE_DIR/suricata_pos"
        local current_size=$(wc -c < /var/log/suricata/fast.log)
        local last_size=0
        [ -f "$last_check" ] && last_size=$(cat "$last_check")
        
        if [ "$current_size" -gt "$last_size" ]; then
            local new_alerts=$(tail -c +$((last_size + 1)) /var/log/suricata/fast.log | grep -c "Priority: 1\|Priority: 2" || true)
            if [ "$new_alerts" -gt 0 ]; then
                notify "🚨 Intrusion Alert" "$new_alerts high-priority alerts detected" "urgent" "warning"
            fi
        fi
        echo "$current_size" > "$last_check"
    fi
    
    # CrowdSec decisions
    if command -v cscli >/dev/null 2>&1; then
        local new_bans=$(cscli decisions list -o raw 2>/dev/null | wc -l)
        local last_bans="$STATE_DIR/crowdsec_bans"
        local prev_bans=0
        [ -f "$last_bans" ] && prev_bans=$(cat "$last_bans")
        
        if [ "$new_bans" -gt "$prev_bans" ]; then
            local diff=$((new_bans - prev_bans))
            notify "🛡️ CrowdSec" "$diff new IP(s) banned" "high" "shield"
        fi
        echo "$new_bans" > "$last_bans"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE MONITOR
# ─────────────────────────────────────────────────────────────────────────────
check_services() {
    [ "$ALERT_SERVICE" = "1" ] || return 0
    
    local services="suricata crowdsec adguard unbound"
    local failed=""
    
    for svc in $services; do
        # Check Docker
        if command -v docker >/dev/null 2>&1; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "ci5-$svc"; then
                continue
            fi
        fi
        
        # Check systemd
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                continue
            fi
        fi
        
        # Check procd (OpenWrt)
        if [ -f "/etc/init.d/$svc" ]; then
            if /etc/init.d/$svc status >/dev/null 2>&1; then
                continue
            fi
        fi
        
        # Service expected but not running
        if [ -f "/opt/ci5/docker/docker-compose.yml" ] && grep -q "$svc" /opt/ci5/docker/docker-compose.yml; then
            failed="$failed $svc"
        fi
    done
    
    if [ -n "$failed" ]; then
        local status_file="$STATE_DIR/service_alert"
        local last_alert=""
        [ -f "$status_file" ] && last_alert=$(cat "$status_file")
        
        if [ "$failed" != "$last_alert" ]; then
            notify "⚠️ Service Down" "Failed:$failed" "high" "warning"
            echo "$failed" > "$status_file"
        fi
    else
        rm -f "$STATE_DIR/service_alert"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WAN IP MONITOR
# ─────────────────────────────────────────────────────────────────────────────
check_wan_ip() {
    [ "$ALERT_WAN_CHANGE" = "1" ] || return 0
    
    local current_ip=$(curl -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                       curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
                       echo "unknown")
    
    [ "$current_ip" = "unknown" ] && return 0
    
    local last_ip=""
    [ -f "$LAST_WAN_FILE" ] && last_ip=$(cat "$LAST_WAN_FILE")
    
    if [ -n "$last_ip" ] && [ "$current_ip" != "$last_ip" ]; then
        notify "🌐 WAN IP Changed" "Old: $last_ip\nNew: $current_ip" "default" "globe"
    fi
    
    echo "$current_ip" > "$LAST_WAN_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH LOGIN MONITOR
# ─────────────────────────────────────────────────────────────────────────────
check_ssh_logins() {
    [ "$ALERT_SSH_LOGIN" = "1" ] || return 0
    
    local auth_log="/var/log/auth.log"
    [ -f /var/log/messages ] && auth_log="/var/log/messages"
    
    [ -f "$auth_log" ] || return 0
    
    local last_check="$STATE_DIR/ssh_pos"
    local current_size=$(wc -c < "$auth_log")
    local last_size=0
    [ -f "$last_check" ] && last_size=$(cat "$last_check")
    
    if [ "$current_size" -gt "$last_size" ]; then
        local new_logins=$(tail -c +$((last_size + 1)) "$auth_log" | grep -c "Accepted\|session opened" || true)
        if [ "$new_logins" -gt 0 ]; then
            local last_login=$(tail -c +$((last_size + 1)) "$auth_log" | grep "Accepted\|session opened" | tail -1)
            notify "🔐 SSH Login" "$last_login" "default" "key"
        fi
    fi
    echo "$current_size" > "$last_check"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    once)
        # Single check (for cron)
        check_intrusions
        check_services
        check_wan_ip
        check_ssh_logins
        ;;
    daemon)
        # Continuous monitoring
        while true; do
            check_intrusions
            check_services
            check_wan_ip
            check_ssh_logins
            sleep 60
        done
        ;;
    *)
        echo "Usage: $0 {once|daemon}"
        exit 1
        ;;
esac
MONITOR_SCRIPT
    
    chmod +x "$MONITOR_SCRIPT"
    info "Installed: $MONITOR_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT NOTIFICATION
# ─────────────────────────────────────────────────────────────────────────────
install_boot_notify() {
    step "INSTALLING BOOT NOTIFICATION"
    
    load_config || return 1
    [ "$ALERT_REBOOT" = "1" ] || { info "Boot alerts disabled"; return 0; }
    
    # Create boot notification script
    cat > /usr/local/bin/ci5-boot-notify << 'BOOT'
#!/bin/sh
# Wait for network
sleep 30

# Get system info
UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')
IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
HOSTNAME=$(hostname)

/usr/local/bin/ci5-notify "🔄 System Reboot" "$HOSTNAME is online\nIP: $IP\n$UPTIME" "low" "computer"
BOOT
    chmod +x /usr/local/bin/ci5-boot-notify
    
    # Add to rc.local or systemd
    if [ -f /etc/rc.local ]; then
        grep -q 'ci5-boot-notify' /etc/rc.local || \
            sed -i '/^exit 0/i /usr/local/bin/ci5-boot-notify &' /etc/rc.local
        info "Added to /etc/rc.local"
    elif [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/ci5-boot-notify.service << 'SYSTEMD'
[Unit]
Description=CI5 Boot Notification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ci5-boot-notify
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        systemctl enable ci5-boot-notify
        info "Systemd service enabled"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON SETUP
# ─────────────────────────────────────────────────────────────────────────────
install_cron() {
    step "INSTALLING CRON MONITOR"
    
    local cron_line="* * * * * $MONITOR_SCRIPT once >/dev/null 2>&1"
    
    # Check if already installed
    if crontab -l 2>/dev/null | grep -q "ci5-alert-monitor"; then
        info "Cron job already installed"
        return 0
    fi
    
    # Add to crontab
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    info "Cron job installed (runs every minute)"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST NOTIFICATION
# ─────────────────────────────────────────────────────────────────────────────
send_test() {
    step "SENDING TEST NOTIFICATION"
    
    load_config || err "ntfy not configured"
    
    info "Sending test to $NTFY_SERVER/$NTFY_TOPIC ..."
    
    if "$NTFY_SCRIPT" "🧪 CI5 Test" "If you see this, notifications are working!" "default" "white_check_mark"; then
        info "Test notification sent!"
        printf "\n"
        printf "  Check your phone for the notification.\n"
        printf "  Topic: ${C}${NTFY_TOPIC}${N}\n"
        printf "\n"
        printf "  If you didn't receive it:\n"
        printf "    1. Open ntfy.sh app on your phone\n"
        printf "    2. Subscribe to topic: ${C}${NTFY_TOPIC}${N}\n"
        printf "    3. Run: ${C}curl ci5.run/alert | sh -s test${N}\n"
        printf "\n"
    else
        err "Failed to send test notification"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    step "NTFY STATUS"
    
    if ! load_config; then
        warn "ntfy not configured"
        printf "\nRun: ${C}curl ci5.run/alert | sh${N} to set up\n\n"
        exit 1
    fi
    
    printf "  Server:  %s\n" "$NTFY_SERVER"
    printf "  Topic:   %s\n" "$NTFY_TOPIC"
    printf "  Token:   %s\n" "$([ -n "$NTFY_TOKEN" ] && echo "[set]" || echo "[none]")"
    printf "\n"
    printf "  Alerts enabled:\n"
    printf "    Intrusions:  %s\n" "$([ "$ALERT_INTRUSION" = "1" ] && echo "✓" || echo "✗")"
    printf "    Services:    %s\n" "$([ "$ALERT_SERVICE" = "1" ] && echo "✓" || echo "✗")"
    printf "    Reboots:     %s\n" "$([ "$ALERT_REBOOT" = "1" ] && echo "✓" || echo "✗")"
    printf "    WAN changes: %s\n" "$([ "$ALERT_WAN_CHANGE" = "1" ] && echo "✓" || echo "✗")"
    printf "    SSH logins:  %s\n" "$([ "$ALERT_SSH_LOGIN" = "1" ] && echo "✓" || echo "✗")"
    printf "\n"
    
    # Check cron
    if crontab -l 2>/dev/null | grep -q "ci5-alert-monitor"; then
        printf "  Monitor: ${G}running (cron)${N}\n"
    else
        printf "  Monitor: ${Y}not scheduled${N}\n"
    fi
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
do_uninstall() {
    step "UNINSTALLING NTFY ALERTS"
    
    # Remove cron
    crontab -l 2>/dev/null | grep -v "ci5-alert-monitor" | crontab - 2>/dev/null || true
    info "Removed cron job"
    
    # Remove scripts
    rm -f "$NTFY_SCRIPT" "$MONITOR_SCRIPT" /usr/local/bin/ci5-boot-notify
    info "Removed scripts"
    
    # Remove systemd service
    if [ -f /etc/systemd/system/ci5-boot-notify.service ]; then
        systemctl disable ci5-boot-notify 2>/dev/null || true
        rm -f /etc/systemd/system/ci5-boot-notify.service
        systemctl daemon-reload
        info "Removed systemd service"
    fi
    
    # Remove from rc.local
    [ -f /etc/rc.local ] && sed -i '/ci5-boot-notify/d' /etc/rc.local
    
    # Keep config? 
    printf "Remove configuration? [y/N]: "
    read -r rm_conf
    if [ "$rm_conf" = "y" ]; then
        rm -f "$NTFY_CONFIG"
        info "Removed configuration"
    else
        info "Configuration kept at $NTFY_CONFIG"
    fi
    
    info "Uninstall complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    command -v curl >/dev/null 2>&1 || err "curl required"
    
    case "${1:-}" in
        test)
            send_test
            ;;
        status)
            show_status
            ;;
        uninstall|remove)
            do_uninstall
            ;;
        help|--help|-h)
            cat << 'EOF'
CI5 ntfy.sh Push Notifications

Usage:
  curl ci5.run/alert | sh              Setup wizard
  curl ci5.run/alert | sh -s test      Send test notification
  curl ci5.run/alert | sh -s status    Show configuration
  curl ci5.run/alert | sh -s uninstall Remove ntfy integration

Manual notification:
  ci5-notify "Title" "Message" [priority] [tags]

Priorities: min, low, default, high, urgent
Tags: emoji shortcodes (e.g., warning, shield, key)
EOF
            ;;
        *)
            # Full setup
            setup_wizard
            install_notify_script
            install_monitor
            install_boot_notify
            install_cron
            
            step "SETUP COMPLETE"
            
            printf "\n"
            printf "  ${G}ntfy.sh integration is ready!${N}\n"
            printf "\n"
            printf "  On your phone:\n"
            printf "    1. Install ntfy.sh app\n"
            printf "    2. Subscribe to topic: ${C}${NTFY_TOPIC}${N}\n"
            printf "\n"
            printf "  Test it:\n"
            printf "    ${C}ci5-notify \"Test\" \"Hello from CI5!\"${N}\n"
            printf "\n"
            
            send_test
            ;;
    esac
}

main "$@"
