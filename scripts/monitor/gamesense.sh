#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/gamesense — GameSense: Anti-Lag Learning Mode
# Version: 2.0-PHOENIX
# 
# Captures game server IPs during gaming sessions to build a whitelist
# for VPN split-tunneling. Allows games to bypass VPN for low latency
# while keeping everything else tunneled for privacy.
#
# Features:
# - Learn mode: Capture IPs while gaming
# - Pre-defined game profiles (common servers/domains)
# - Custom game support
# - Anti-Lag OC: Maximum priority queue for game packets
# - Automatic iptables/nftables bypass rules
# - WireGuard/OpenVPN split-tunnel integration
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

GAMESENSE_DIR="/etc/ci5/gamesense"
PROFILES_DIR="$GAMESENSE_DIR/profiles"
LEARNED_DIR="$GAMESENSE_DIR/learned"
ACTIVE_FILE="$GAMESENSE_DIR/active_bypass.conf"
STATE_FILE="/var/run/ci5-gamesense.state"
CAPTURE_FILE="/tmp/gamesense-capture.pcap"
LOG_FILE="/var/log/ci5-gamesense.log"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
M='\033[0;35m'  # Magenta for gaming theme

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${M}═══ %s ═══${N}\n\n" "$1"; }
game() { printf "${M}[🎮]${N} %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# GAME PROFILES DATABASE
# ─────────────────────────────────────────────────────────────────────────────

# Pre-defined game server patterns
# Format: "ports|domain_patterns|known_ip_ranges|description"

init_profiles() {
    mkdir -p "$PROFILES_DIR"
    
    # Valve / Steam Games (CS2, Dota 2, TF2, etc.)
    cat > "$PROFILES_DIR/steam.profile" << 'EOF'
name=Steam / Valve Games
games=CS2, Dota 2, TF2, L4D2
ports=27015-27050,3478,4379-4380
domains=valve.net,steamcontent.com,steamserver.net
ip_ranges=155.133.224.0/19,162.254.192.0/21,185.25.180.0/22,205.196.6.0/24
EOF

    # Riot Games (League, Valorant)
    cat > "$PROFILES_DIR/riot.profile" << 'EOF'
name=Riot Games
games=League of Legends, Valorant, TFT
ports=5000-5500,8393-8400,2099,5222-5223
domains=riotgames.com,leagueoflegends.com,valorant.com,riotcdn.net
ip_ranges=104.160.128.0/17,162.249.72.0/21,45.7.108.0/22
EOF

    # Epic Games (Fortnite, Rocket League)
    cat > "$PROFILES_DIR/epic.profile" << 'EOF'
name=Epic Games
games=Fortnite, Rocket League
ports=5222,5795-5847,9000-9100
domains=epicgames.com,fortnite.com,unrealengine.com,psyonix.com
ip_ranges=
EOF

    # Activision / Blizzard (CoD, WoW, Overwatch)
    cat > "$PROFILES_DIR/blizzard.profile" << 'EOF'
name=Blizzard / Activision
games=CoD Warzone, Overwatch 2, WoW, Diablo IV
ports=1119,3724,6112-6119,27014-27050
domains=blizzard.com,battle.net,activision.com
ip_ranges=24.105.0.0/18,37.244.0.0/17,185.60.112.0/22
EOF

    # EA Games (Apex, FIFA, Battlefield)
    cat > "$PROFILES_DIR/ea.profile" << 'EOF'
name=EA Games
games=Apex Legends, FIFA, Battlefield
ports=3659,9960-9969,17503-17504,42127
domains=ea.com,origin.com,eaassets-a.akamaihd.net
ip_ranges=159.153.0.0/16
EOF

    # Xbox Live
    cat > "$PROFILES_DIR/xbox.profile" << 'EOF'
name=Xbox Live
games=Xbox Cloud Gaming, Game Pass
ports=3074,88,500,3544,4500
domains=xboxlive.com,xbox.com,microsoft.com
ip_ranges=
EOF

    # PlayStation Network
    cat > "$PROFILES_DIR/playstation.profile" << 'EOF'
name=PlayStation Network
games=PS Remote Play, PS Plus
ports=3478-3480,9295-9304
domains=playstation.net,playstation.com,sonyentertainmentnetwork.com
ip_ranges=
EOF

    # Minecraft
    cat > "$PROFILES_DIR/minecraft.profile" << 'EOF'
name=Minecraft
games=Minecraft Java, Bedrock
ports=25565,19132-19133
domains=mojang.com,minecraft.net,minecraftservices.com
ip_ranges=
EOF

    # Ubisoft (R6, For Honor, The Division)
    cat > "$PROFILES_DIR/ubisoft.profile" << 'EOF'
name=Ubisoft
games=Rainbow Six Siege, For Honor, The Division
ports=3074,14000-14016
domains=ubisoft.com,ubi.com
ip_ranges=
EOF

    # General / Common
    cat > "$PROFILES_DIR/general.profile" << 'EOF'
name=General Gaming Ports
games=Generic UDP game traffic
ports=27000-27050,7777-7799,9000-9100
domains=
ip_ranges=
EOF

    info "Game profiles initialized"
}

# ─────────────────────────────────────────────────────────────────────────────
# PROFILE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

list_profiles() {
    step "AVAILABLE GAME PROFILES"
    
    local i=1
    for profile in "$PROFILES_DIR"/*.profile; do
        [ -f "$profile" ] || continue
        
        local name=$(grep "^name=" "$profile" | cut -d= -f2)
        local games=$(grep "^games=" "$profile" | cut -d= -f2)
        local pname=$(basename "$profile" .profile)
        
        printf "  ${M}[%d]${N} ${B}%s${N}\n" "$i" "$name"
        printf "      Games: ${C}%s${N}\n" "$games"
        printf "      Profile: ${Y}%s${N}\n\n" "$pname"
        
        i=$((i + 1))
    done
    
    printf "  ${M}[C]${N} Create custom profile\n"
    printf "  ${M}[Q]${N} Back to main menu\n\n"
}

load_profile() {
    local profile_name="$1"
    local profile_file="$PROFILES_DIR/${profile_name}.profile"
    
    if [ ! -f "$profile_file" ]; then
        return 1
    fi
    
    # Source the profile
    PROFILE_NAME=$(grep "^name=" "$profile_file" | cut -d= -f2)
    PROFILE_GAMES=$(grep "^games=" "$profile_file" | cut -d= -f2)
    PROFILE_PORTS=$(grep "^ports=" "$profile_file" | cut -d= -f2)
    PROFILE_DOMAINS=$(grep "^domains=" "$profile_file" | cut -d= -f2)
    PROFILE_IP_RANGES=$(grep "^ip_ranges=" "$profile_file" | cut -d= -f2)
    
    return 0
}

create_custom_profile() {
    step "CREATE CUSTOM GAME PROFILE"
    
    printf "Profile name (lowercase, no spaces): "
    read -r profile_id
    
    if [ -z "$profile_id" ]; then
        warn "Profile name required"
        return 1
    fi
    
    profile_id=$(echo "$profile_id" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    
    printf "Display name: "
    read -r display_name
    
    printf "Games (comma separated): "
    read -r games
    
    printf "Ports (e.g., 27015-27050,3478): "
    read -r ports
    
    printf "Domains (comma separated, optional): "
    read -r domains
    
    printf "IP ranges (CIDR, comma separated, optional): "
    read -r ip_ranges
    
    cat > "$PROFILES_DIR/${profile_id}.profile" << EOF
name=${display_name:-$profile_id}
games=${games:-Custom game}
ports=${ports}
domains=${domains}
ip_ranges=${ip_ranges}
EOF

    info "Created profile: $profile_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# PACKET CAPTURE / LEARN MODE
# ─────────────────────────────────────────────────────────────────────────────

start_learning() {
    local profile_name="$1"
    local duration="${2:-300}"  # Default 5 minutes
    
    if ! load_profile "$profile_name"; then
        err "Profile not found: $profile_name"
    fi
    
    step "LEARN MODE: $PROFILE_NAME"
    
    game "Starting packet capture for: $PROFILE_GAMES"
    info "Duration: ${duration}s (Ctrl+C to stop early)"
    info "Play your game now to capture server IPs!"
    
    # Create learned directory
    mkdir -p "$LEARNED_DIR"
    local learned_file="$LEARNED_DIR/${profile_name}.ips"
    
    # Build tcpdump filter
    local filter=""
    
    # Add port filters
    if [ -n "$PROFILE_PORTS" ]; then
        local port_filter=""
        IFS=','
        for port_spec in $PROFILE_PORTS; do
            if echo "$port_spec" | grep -q '-'; then
                # Port range
                local start=$(echo "$port_spec" | cut -d- -f1)
                local end=$(echo "$port_spec" | cut -d- -f2)
                [ -n "$port_filter" ] && port_filter="$port_filter or "
                port_filter="${port_filter}portrange $start-$end"
            else
                # Single port
                [ -n "$port_filter" ] && port_filter="$port_filter or "
                port_filter="${port_filter}port $port_spec"
            fi
        done
        IFS=' '
        filter="($port_filter)"
    fi
    
    # Detect WAN interface
    local wan_if=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$wan_if" ] && wan_if="eth0"
    
    # Get local network to exclude
    local local_net=$(ip route | grep -E "^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\." | head -1 | awk '{print $1}')
    [ -z "$local_net" ] && local_net="192.168.0.0/16"
    
    # Add exclusion for local traffic
    if [ -n "$filter" ]; then
        filter="$filter and not net $local_net"
    else
        filter="not net $local_net"
    fi
    
    # Add UDP preference (most game traffic)
    filter="($filter) and (udp or tcp)"
    
    info "Capture filter: $filter"
    info "Interface: $wan_if"
    printf "\n"
    
    # Create state file
    echo "learning" > "$STATE_FILE"
    echo "$profile_name" >> "$STATE_FILE"
    echo "$$" >> "$STATE_FILE"
    
    # Trap Ctrl+C
    trap 'stop_learning; exit 0' INT TERM
    
    # Start capture
    game "🎮 CAPTURE ACTIVE — Play your game now!"
    printf "\n"
    
    # Run tcpdump and extract unique destination IPs
    timeout "$duration" tcpdump -i "$wan_if" -nn "$filter" 2>/dev/null | \
    while read -r line; do
        # Extract destination IP (format: IP src > dst: ...)
        local dst=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
        
        if [ -n "$dst" ]; then
            # Skip local IPs
            case "$dst" in
                192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*)
                    continue
                    ;;
            esac
            
            # Add if not already in list
            if ! grep -q "^$dst$" "$learned_file" 2>/dev/null; then
                echo "$dst" >> "$learned_file"
                printf "  ${G}+${N} Learned: ${C}%s${N}\n" "$dst"
            fi
        fi
    done || true
    
    stop_learning
}

stop_learning() {
    rm -f "$STATE_FILE"
    
    printf "\n"
    game "Learning session complete!"
    
    local profile_name=$(head -2 "$STATE_FILE" 2>/dev/null | tail -1)
    local learned_file="$LEARNED_DIR/${profile_name}.ips"
    
    if [ -f "$learned_file" ]; then
        local count=$(wc -l < "$learned_file")
        info "Learned $count unique server IPs"
        
        # Show summary
        printf "\n  Captured IPs:\n"
        head -20 "$learned_file" | while read -r ip; do
            # Try reverse DNS
            local hostname=$(nslookup "$ip" 2>/dev/null | grep "name = " | awk '{print $NF}' | sed 's/\.$//')
            [ -z "$hostname" ] && hostname="(no PTR)"
            printf "    ${C}%s${N} → %s\n" "$ip" "$hostname"
        done
        
        local total=$(wc -l < "$learned_file")
        if [ "$total" -gt 20 ]; then
            printf "    ... and %d more\n" "$((total - 20))"
        fi
    else
        warn "No IPs captured. Ensure game was active during capture."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DNS-BASED LEARNING
# ─────────────────────────────────────────────────────────────────────────────

learn_from_dns() {
    local profile_name="$1"
    
    if ! load_profile "$profile_name"; then
        err "Profile not found: $profile_name"
    fi
    
    step "DNS LEARNING: $PROFILE_NAME"
    
    if [ -z "$PROFILE_DOMAINS" ]; then
        warn "No domains defined in profile"
        return 1
    fi
    
    mkdir -p "$LEARNED_DIR"
    local learned_file="$LEARNED_DIR/${profile_name}.ips"
    
    info "Resolving known game domains..."
    
    IFS=','
    for domain in $PROFILE_DOMAINS; do
        domain=$(echo "$domain" | tr -d ' ')
        game "Resolving: $domain"
        
        # Get A records
        local ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
        
        for ip in $ips; do
            if ! grep -q "^$ip$" "$learned_file" 2>/dev/null; then
                echo "$ip" >> "$learned_file"
                printf "    ${G}+${N} %s\n" "$ip"
            fi
        done
        
        # Also try common subdomains
        for sub in game server login auth matchmaking; do
            local sub_ips=$(dig +short "${sub}.${domain}" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
            for ip in $sub_ips; do
                if ! grep -q "^$ip$" "$learned_file" 2>/dev/null; then
                    echo "$ip" >> "$learned_file"
                    printf "    ${G}+${N} %s (${sub}.${domain})\n" "$ip"
                fi
            done
        done
    done
    IFS=' '
    
    # Add known IP ranges from profile
    if [ -n "$PROFILE_IP_RANGES" ]; then
        info "Adding known IP ranges..."
        
        IFS=','
        for range in $PROFILE_IP_RANGES; do
            range=$(echo "$range" | tr -d ' ')
            if ! grep -q "^$range$" "$learned_file" 2>/dev/null; then
                echo "$range" >> "$learned_file"
                printf "    ${G}+${N} %s (known range)\n" "$range"
            fi
        done
        IFS=' '
    fi
    
    local count=$(wc -l < "$learned_file" 2>/dev/null || echo 0)
    info "Total IPs/ranges for $profile_name: $count"
}

# ─────────────────────────────────────────────────────────────────────────────
# BYPASS RULE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

generate_bypass_rules() {
    step "GENERATE BYPASS RULES"
    
    # Combine all learned IPs
    mkdir -p "$(dirname "$ACTIVE_FILE")"
    : > "$ACTIVE_FILE"
    
    local total=0
    
    for learned_file in "$LEARNED_DIR"/*.ips; do
        [ -f "$learned_file" ] || continue
        
        local profile=$(basename "$learned_file" .ips)
        echo "# Profile: $profile" >> "$ACTIVE_FILE"
        
        while read -r ip; do
            echo "$ip" >> "$ACTIVE_FILE"
            total=$((total + 1))
        done < "$learned_file"
        
        echo "" >> "$ACTIVE_FILE"
    done
    
    info "Generated bypass rules for $total IPs/ranges"
    info "Config: $ACTIVE_FILE"
}

apply_bypass_rules() {
    step "APPLY VPN BYPASS RULES"
    
    if [ ! -f "$ACTIVE_FILE" ]; then
        warn "No bypass rules found. Run learn mode first."
        return 1
    fi
    
    # Detect VPN interface
    local vpn_if=""
    local vpn_table=""
    
    if ip link show wg0 >/dev/null 2>&1; then
        vpn_if="wg0"
        vpn_table="51820"
        info "Detected WireGuard VPN (wg0)"
    elif ip link show tun0 >/dev/null 2>&1; then
        vpn_if="tun0"
        vpn_table="1"
        info "Detected OpenVPN (tun0)"
    else
        warn "No VPN interface detected (wg0/tun0)"
        printf "Apply rules anyway for future VPN connection? [y/N]: "
        read -r confirm
        [ "$confirm" != "y" ] && return 1
        vpn_table="51820"
    fi
    
    # Get default gateway (non-VPN)
    local default_gw=$(ip route show table main | grep -E "^default.*metric" | head -1 | awk '{print $3}')
    [ -z "$default_gw" ] && default_gw=$(ip route show table main | grep "^default" | head -1 | awk '{print $3}')
    
    if [ -z "$default_gw" ]; then
        err "Cannot determine default gateway"
    fi
    
    local default_if=$(ip route show table main | grep "^default" | head -1 | awk '{print $5}')
    
    info "Default gateway: $default_gw via $default_if"
    
    # Create routing table for game traffic
    if ! grep -q "^200 gamebypass$" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "200 gamebypass" >> /etc/iproute2/rt_tables
    fi
    
    # Flush existing game bypass rules
    ip rule del table gamebypass 2>/dev/null || true
    ip route flush table gamebypass 2>/dev/null || true
    
    # Add default route via non-VPN
    ip route add default via "$default_gw" dev "$default_if" table gamebypass
    
    # Add bypass rules for each IP
    local applied=0
    
    while read -r line; do
        # Skip comments and empty lines
        case "$line" in
            \#*|"") continue ;;
        esac
        
        # Check if it's a CIDR range or single IP
        if echo "$line" | grep -qE '/[0-9]+$'; then
            # CIDR range
            ip rule add to "$line" table gamebypass priority 100 2>/dev/null || true
        else
            # Single IP
            ip rule add to "$line/32" table gamebypass priority 100 2>/dev/null || true
        fi
        
        applied=$((applied + 1))
    done < "$ACTIVE_FILE"
    
    info "Applied $applied bypass rules"
    
    # Verify
    printf "\n  ${B}Active bypass destinations:${N}\n"
    ip rule show | grep "gamebypass" | head -10 | while read -r rule; do
        printf "    %s\n" "$rule"
    done
    
    local rule_count=$(ip rule show | grep -c "gamebypass" || echo 0)
    if [ "$rule_count" -gt 10 ]; then
        printf "    ... and %d more\n" "$((rule_count - 10))"
    fi
    
    # Save state
    echo "active" > "$STATE_FILE"
    echo "gamebypass" >> "$STATE_FILE"
}

remove_bypass_rules() {
    step "REMOVE BYPASS RULES"
    
    # Remove all gamebypass rules
    while ip rule del table gamebypass 2>/dev/null; do :; done
    
    # Flush routing table
    ip route flush table gamebypass 2>/dev/null || true
    
    rm -f "$STATE_FILE"
    
    info "All bypass rules removed"
    info "Game traffic now routes through VPN"
}

# ─────────────────────────────────────────────────────────────────────────────
# ANTI-LAG OC — DSCP/TC PRIORITY QUEUE (ENABLED BY DEFAULT)
# ─────────────────────────────────────────────────────────────────────────────

# DSCP markings for game traffic
# EF (Expedited Forwarding) = 46 = highest priority real-time
# CS6 = 48 = network control (alternative)
GAME_DSCP="46"  # EF class

ANTILAG_MARK="0x10"  # fwmark for game traffic
ANTILAG_CLASS="1:10" # tc class for priority queue

is_overclock_active() {
    iptables -t mangle -L GAMESENSE_ANTILAG >/dev/null 2>&1
}

enable_overclock() {
    step "🚀 ANTI-LAG OC"
    
    if is_overclock_active; then
        warn "Anti-Lag OC already active"
        return 0
    fi
    
    if [ ! -f "$ACTIVE_FILE" ] && [ ! -d "$LEARNED_DIR" ]; then
        warn "No learned game IPs found. Run learn mode first."
        return 1
    fi
    
    # Detect interfaces
    local wan_if=$(ip route | grep default | awk '{print $5}' | head -1)
    local lan_if=$(ip route | grep -E "^192\.168\.|^10\.|^172\." | head -1 | awk '{print $3}')
    
    [ -z "$wan_if" ] && wan_if="eth0"
    [ -z "$lan_if" ] && lan_if="br-lan"
    
    info "WAN interface: $wan_if"
    info "LAN interface: $lan_if"
    
    # ═══════════════════════════════════════════════════════════════════════
    # STEP 1: Create iptables mangle chain for DSCP marking
    # ═══════════════════════════════════════════════════════════════════════
    
    game "Creating packet marking rules..."
    
    # Create custom chain
    iptables -t mangle -N GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -F GAMESENSE_ANTILAG
    
    # Mark packets TO game servers (upload: your inputs)
    while read -r line; do
        case "$line" in \#*|"") continue ;; esac
        
        if echo "$line" | grep -qE '/[0-9]+$'; then
            # CIDR range
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$line" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$line" -j MARK --set-mark "$ANTILAG_MARK"
        else
            # Single IP
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$line" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$line" -j MARK --set-mark "$ANTILAG_MARK"
        fi
    done < "$ACTIVE_FILE" 2>/dev/null || \
    for learned_file in "$LEARNED_DIR"/*.ips; do
        [ -f "$learned_file" ] || continue
        while read -r ip; do
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$ip" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -d "$ip" -j MARK --set-mark "$ANTILAG_MARK"
        done < "$learned_file"
    done
    
    # Mark packets FROM game servers (download: game state)
    while read -r line; do
        case "$line" in \#*|"") continue ;; esac
        
        if echo "$line" | grep -qE '/[0-9]+$'; then
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$line" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$line" -j MARK --set-mark "$ANTILAG_MARK"
        else
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$line" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$line" -j MARK --set-mark "$ANTILAG_MARK"
        fi
    done < "$ACTIVE_FILE" 2>/dev/null || \
    for learned_file in "$LEARNED_DIR"/*.ips; do
        [ -f "$learned_file" ] || continue
        while read -r ip; do
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$ip" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -s "$ip" -j MARK --set-mark "$ANTILAG_MARK"
        done < "$learned_file"
    done
    
    # Also mark by game ports (UDP, common game ports)
    for port_range in "27000:27050" "5000:5500" "3074" "3478:3480" "9000:9100"; do
        if echo "$port_range" | grep -q ":"; then
            iptables -t mangle -A GAMESENSE_ANTILAG -p udp --dport "$port_range" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -p udp --sport "$port_range" -j DSCP --set-dscp "$GAME_DSCP"
        else
            iptables -t mangle -A GAMESENSE_ANTILAG -p udp --dport "$port_range" -j DSCP --set-dscp "$GAME_DSCP"
            iptables -t mangle -A GAMESENSE_ANTILAG -p udp --sport "$port_range" -j DSCP --set-dscp "$GAME_DSCP"
        fi
    done
    
    # Hook into PREROUTING and OUTPUT
    iptables -t mangle -I PREROUTING -j GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -I OUTPUT -j GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -I POSTROUTING -j GAMESENSE_ANTILAG 2>/dev/null || true
    
    local rule_count=$(iptables -t mangle -L GAMESENSE_ANTILAG -n 2>/dev/null | grep -c "DSCP" || echo 0)
    info "Created $rule_count DSCP marking rules"
    
    # ═══════════════════════════════════════════════════════════════════════
    # STEP 2: Configure tc qdisc for priority queuing
    # ═══════════════════════════════════════════════════════════════════════
    
    game "Configuring priority queue (tc)..."
    
    # Check if SQM/CAKE is already running
    local existing_qdisc=$(tc qdisc show dev "$wan_if" 2>/dev/null | head -1 | awk '{print $2}')
    
    if [ "$existing_qdisc" = "cake" ]; then
        info "CAKE qdisc detected — using diffserv4 for game priority"
        
        # CAKE with diffserv4 already respects DSCP!
        # EF (46) goes to "Voice" tin = highest priority
        # Just ensure diffserv is enabled
        
        local cake_opts=$(tc qdisc show dev "$wan_if" 2>/dev/null | grep -o "diffserv[^ ]*" || echo "")
        if [ -z "$cake_opts" ]; then
            warn "CAKE running without diffserv — game priority may not be optimal"
            warn "Consider: tc qdisc replace dev $wan_if root cake diffserv4 ..."
        else
            info "CAKE diffserv mode: $cake_opts (game traffic → Voice tin)"
        fi
        
    elif [ "$existing_qdisc" = "fq_codel" ] || [ "$existing_qdisc" = "sfq" ]; then
        info "$existing_qdisc detected — adding priority wrapper"
        
        # Add PRIO qdisc as root, chain existing qdisc
        tc qdisc del dev "$wan_if" root 2>/dev/null || true
        
        # PRIO with 4 bands: 0=game, 1=interactive, 2=bulk, 3=background
        tc qdisc add dev "$wan_if" root handle 1: prio bands 4 priomap 2 2 2 2 2 2 2 2 1 1 1 1 1 1 1 1
        
        # Band 0: Game traffic (marked packets) — use pfifo_fast for minimum latency
        tc qdisc add dev "$wan_if" parent 1:1 handle 10: pfifo limit 50
        
        # Band 1-3: Everything else gets fq_codel
        tc qdisc add dev "$wan_if" parent 1:2 handle 20: fq_codel
        tc qdisc add dev "$wan_if" parent 1:3 handle 30: fq_codel
        tc qdisc add dev "$wan_if" parent 1:4 handle 40: fq_codel
        
        # Filter: marked packets → band 0 (highest priority)
        tc filter add dev "$wan_if" parent 1: protocol ip prio 1 handle "$ANTILAG_MARK" fw flowid 1:1
        
        # Filter: DSCP EF → band 0
        tc filter add dev "$wan_if" parent 1: protocol ip prio 2 u32 \
            match ip tos 0xb8 0xfc flowid 1:1  # EF = 46 << 2 = 0xb8
        
        info "Priority queue configured: game → band 0 (pfifo)"
        
    else
        info "No existing qdisc — creating optimized game priority queue"
        
        # Fresh install: use HTB + pfifo for game, fq_codel for rest
        tc qdisc del dev "$wan_if" root 2>/dev/null || true
        
        # Get link speed (or estimate)
        local speed=$(ethtool "$wan_if" 2>/dev/null | grep "Speed:" | grep -oE "[0-9]+" || echo "1000")
        local rate="${speed}mbit"
        
        # HTB root
        tc qdisc add dev "$wan_if" root handle 1: htb default 30
        tc class add dev "$wan_if" parent 1: classid 1:1 htb rate "$rate" burst 15k
        
        # Game class: 30% guaranteed, can burst to 100%, MINIMUM latency
        tc class add dev "$wan_if" parent 1:1 classid 1:10 htb rate "$((speed * 30 / 100))mbit" ceil "$rate" burst 5k prio 0
        tc qdisc add dev "$wan_if" parent 1:10 handle 10: pfifo limit 50
        
        # Interactive class: 40%
        tc class add dev "$wan_if" parent 1:1 classid 1:20 htb rate "$((speed * 40 / 100))mbit" ceil "$rate" burst 10k prio 1
        tc qdisc add dev "$wan_if" parent 1:20 handle 20: fq_codel
        
        # Bulk class: 30%
        tc class add dev "$wan_if" parent 1:1 classid 1:30 htb rate "$((speed * 30 / 100))mbit" ceil "$rate" burst 10k prio 2
        tc qdisc add dev "$wan_if" parent 1:30 handle 30: fq_codel
        
        # Filters
        tc filter add dev "$wan_if" parent 1: protocol ip prio 1 handle "$ANTILAG_MARK" fw flowid 1:10
        tc filter add dev "$wan_if" parent 1: protocol ip prio 2 u32 match ip tos 0xb8 0xfc flowid 1:10
        
        info "HTB priority queue configured"
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # STEP 3: Repeat for LAN interface (important for download priority)
    # ═══════════════════════════════════════════════════════════════════════
    
    if [ -n "$lan_if" ] && [ "$lan_if" != "$wan_if" ]; then
        game "Configuring LAN egress priority..."
        
        local lan_qdisc=$(tc qdisc show dev "$lan_if" 2>/dev/null | head -1 | awk '{print $2}')
        
        if [ "$lan_qdisc" != "cake" ] && [ "$lan_qdisc" != "htb" ]; then
            # Add simple priority for LAN
            tc qdisc del dev "$lan_if" root 2>/dev/null || true
            tc qdisc add dev "$lan_if" root handle 1: prio bands 4 priomap 2 2 2 2 2 2 2 2 1 1 1 1 1 1 1 1
            tc qdisc add dev "$lan_if" parent 1:1 handle 10: pfifo limit 100
            tc qdisc add dev "$lan_if" parent 1:2 handle 20: fq_codel
            tc qdisc add dev "$lan_if" parent 1:3 handle 30: fq_codel
            tc qdisc add dev "$lan_if" parent 1:4 handle 40: fq_codel
            
            tc filter add dev "$lan_if" parent 1: protocol ip prio 1 handle "$ANTILAG_MARK" fw flowid 1:1
            tc filter add dev "$lan_if" parent 1: protocol ip prio 2 u32 match ip tos 0xb8 0xfc flowid 1:1
            
            info "LAN priority queue configured"
        fi
    fi
    
    # ═══════════════════════════════════════════════════════════════════════
    # STEP 4: Kernel tuning for minimum latency
    # ═══════════════════════════════════════════════════════════════════════
    
    game "Applying kernel latency optimizations..."
    
    # Reduce network buffer sizes for lower latency (trade throughput for latency)
    sysctl -w net.core.netdev_budget=300 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_budget_usecs=2000 >/dev/null 2>&1 || true
    
    # Faster TCP (helps TCP game traffic)
    sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    
    # Reduce buffering
    sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1 || true
    
    # Faster UDP
    sysctl -w net.core.rmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_default=212992 >/dev/null 2>&1 || true
    
    info "Kernel latency optimizations applied"
    
    # ═══════════════════════════════════════════════════════════════════════
    # Save state
    # ═══════════════════════════════════════════════════════════════════════
    
    echo "antilag" >> "$STATE_FILE"
    
    step "🎮 ANTI-LAG OC ACTIVE"
    
    printf "\n"
    printf "  ${G}Game traffic is now MAXIMUM PRIORITY${N}\n"
    printf "\n"
    printf "  What's happening:\n"
    printf "    • Game packets marked with DSCP EF (46)\n"
    printf "    • Marked packets go to front of queue\n"
    printf "    • pfifo qdisc = zero processing overhead\n"
    printf "    • Kernel tuned for minimum latency\n"
    printf "\n"
    printf "  ${Y}Note: This prioritizes latency over throughput.${N}\n"
    printf "  ${Y}Disable for bulk downloads: ci5 gamelearn overclock off${N}\n"
    printf "\n"
    
    # Show live stats command
    printf "  Monitor game traffic:\n"
    printf "    ${C}watch -n1 'tc -s qdisc show dev %s'${N}\n" "$wan_if"
    printf "    ${C}iptables -t mangle -L GAMESENSE_ANTILAG -v${N}\n"
    printf "\n"
}

disable_overclock() {
    step "DISABLING ANTI-LAG OC"
    
    if ! is_overclock_active; then
        info "Anti-Lag OC not active"
        return 0
    fi
    
    # Remove iptables rules
    iptables -t mangle -D PREROUTING -j GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -D OUTPUT -j GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -j GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -F GAMESENSE_ANTILAG 2>/dev/null || true
    iptables -t mangle -X GAMESENSE_ANTILAG 2>/dev/null || true
    
    info "Removed DSCP marking rules"
    
    # Note: We don't remove tc rules as they may be part of user's SQM setup
    # Just removing the iptables marks is enough — unmarked packets go to default queue
    
    # Restore default kernel settings
    sysctl -w net.ipv4.tcp_low_latency=0 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_budget=600 >/dev/null 2>&1 || true
    
    info "Restored default kernel settings"
    
    # Update state
    sed -i '/antilag/d' "$STATE_FILE" 2>/dev/null || true
    
    info "Anti-Lag OC disabled — normal traffic priority restored"
}

show_overclock_stats() {
    step "ANTI-LAG OC STATISTICS"
    
    if ! is_overclock_active; then
        printf "  Status: ${Y}INACTIVE${N}\n\n"
        return 0
    fi
    
    printf "  Status: ${G}ACTIVE${N}\n\n"
    
    # iptables stats
    printf "  ${B}Packet Marking (iptables mangle):${N}\n"
    iptables -t mangle -L GAMESENSE_ANTILAG -v -n 2>/dev/null | head -20 | \
    while read -r line; do
        printf "    %s\n" "$line"
    done
    
    printf "\n"
    
    # tc stats
    local wan_if=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$wan_if" ] && wan_if="eth0"
    
    printf "  ${B}Queue Statistics (tc on %s):${N}\n" "$wan_if"
    tc -s qdisc show dev "$wan_if" 2>/dev/null | head -30 | \
    while read -r line; do
        printf "    %s\n" "$line"
    done
    
    printf "\n"
    
    # Class stats if HTB
    if tc class show dev "$wan_if" 2>/dev/null | grep -q "htb"; then
        printf "  ${B}Class Statistics:${N}\n"
        tc -s class show dev "$wan_if" 2>/dev/null | grep -A5 "class htb 1:10" | \
        while read -r line; do
            printf "    %s\n" "$line"
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS / VIEW
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "GAMESENSE STATUS"
    
    # Active bypass rules
    local rule_count=$(ip rule show 2>/dev/null | grep -c "gamebypass" || echo 0)
    if [ "$rule_count" -gt 0 ]; then
        printf "  VPN Bypass:  ${G}ACTIVE${N} ($rule_count rules)\n"
    else
        printf "  VPN Bypass:  ${Y}INACTIVE${N}\n"
    fi
    
    # Anti-Lag OC status
    if is_overclock_active; then
        local marked=$(iptables -t mangle -L GAMESENSE_ANTILAG -v -n 2>/dev/null | grep -c "DSCP" || echo 0)
        printf "  Anti-Lag OC: ${G}ACTIVE${N} ($marked marking rules)\n"
    else
        printf "  Anti-Lag OC: ${Y}INACTIVE${N}\n"
    fi
    
    # Learned IPs per profile
    printf "\n  ${B}Learned IPs:${N}\n"
    for learned_file in "$LEARNED_DIR"/*.ips 2>/dev/null; do
        [ -f "$learned_file" ] || continue
        
        local profile=$(basename "$learned_file" .ips)
        local count=$(wc -l < "$learned_file")
        printf "    %s: ${C}%d${N} IPs\n" "$profile" "$count"
    done
    
    if [ ! -d "$LEARNED_DIR" ] || [ -z "$(ls -A "$LEARNED_DIR" 2>/dev/null)" ]; then
        printf "    ${Y}No learned IPs yet${N}\n"
    fi
    
    # VPN detection
    printf "\n  ${B}VPN Status:${N}\n"
    if ip link show wg0 >/dev/null 2>&1; then
        printf "    WireGuard: ${G}UP${N}\n"
    else
        printf "    WireGuard: ${Y}DOWN${N}\n"
    fi
    
    if ip link show tun0 >/dev/null 2>&1; then
        printf "    OpenVPN: ${G}UP${N}\n"
    else
        printf "    OpenVPN: ${Y}DOWN${N}\n"
    fi
    
    printf "\n"
}

show_learned() {
    local profile_name="$1"
    
    if [ -z "$profile_name" ]; then
        # Show all
        for learned_file in "$LEARNED_DIR"/*.ips 2>/dev/null; do
            [ -f "$learned_file" ] || continue
            
            local profile=$(basename "$learned_file" .ips)
            printf "\n${M}═══ %s ═══${N}\n" "$profile"
            
            while read -r ip; do
                local hostname=$(nslookup "$ip" 2>/dev/null | grep "name = " | awk '{print $NF}' | sed 's/\.$//' || echo "")
                [ -z "$hostname" ] && hostname="-"
                printf "  ${C}%-18s${N} %s\n" "$ip" "$hostname"
            done < "$learned_file"
        done
    else
        local learned_file="$LEARNED_DIR/${profile_name}.ips"
        if [ -f "$learned_file" ]; then
            cat "$learned_file"
        else
            warn "No learned IPs for profile: $profile_name"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

interactive_menu() {
    while true; do
        clear
        printf "${M}"
        cat << 'BANNER'
   ___                      ____                      
  / _ \__ _ _ __ ___   ___ / ___|  ___ _ __  ___  ___ 
 / /_\/ _` | '_ ` _ \ / _ \\___ \ / _ \ '_ \/ __|/ _ \
/ /_\\ (_| | | | | | |  __/ ___) |  __/ | | \__ \  __/
\____/\__,_|_| |_| |_|\___|____/ \___|_| |_|___/\___|
                                                      
BANNER
        printf "${N}"
        printf "        ${C}Anti-Lag VPN Split-Tunnel System${N}\n"
        printf "        ${Y}v2.0-PHOENIX${N}\n\n"
        
        # Quick status
        local rule_count=$(ip rule show 2>/dev/null | grep -c "gamebypass" || echo 0)
        local oc_status=""
        if is_overclock_active; then
            oc_status="${G}●${N} ANTI-LAG"
        else
            oc_status="${Y}○${N} anti-lag off"
        fi
        
        if [ "$rule_count" -gt 0 ]; then
            printf "  Status: ${G}●${N} Bypass ACTIVE ($rule_count rules) $oc_status\n\n"
        else
            printf "  Status: ${Y}○${N} Bypass inactive $oc_status\n\n"
        fi
        
        printf "  ${B}LEARN${N}\n"
        printf "    ${M}[1]${N} Start capture session (play while capturing)\n"
        printf "    ${M}[2]${N} Learn from DNS (resolve known domains)\n"
        printf "    ${M}[3]${N} View learned IPs\n\n"
        
        printf "  ${B}BYPASS${N}\n"
        printf "    ${M}[4]${N} Apply bypass rules (games skip VPN)\n"
        printf "    ${M}[5]${N} Remove bypass rules (all through VPN)\n\n"
        
        printf "  ${B}🚀 ANTI-LAG OC${N}\n"
        if is_overclock_active; then
            printf "    ${M}[8]${N} ${G}■${N} Disable Anti-Lag OC (currently: MAX PRIORITY)\n"
            printf "    ${M}[9]${N} View Anti-Lag statistics\n\n"
        else
            printf "    ${M}[8]${N} ${R}□${N} Enable Anti-Lag OC (priority queue disabled)\n\n"
        fi
        
        printf "  ${B}PROFILES${N}\n"
        printf "    ${M}[6]${N} List game profiles\n"
        printf "    ${M}[7]${N} Create custom profile\n\n"
        
        printf "  ${M}[S]${N} Status    ${M}[Q]${N} Quit\n\n"
        
        printf "  Choice: "
        read -r choice
        
        case "$choice" in
            1)
                clear
                list_profiles
                printf "  Select profile number: "
                read -r pnum
                
                case "$pnum" in
                    [Qq]) continue ;;
                    [Cc]) create_custom_profile; continue ;;
                esac
                
                # Get profile by number
                local profile=$(ls "$PROFILES_DIR"/*.profile 2>/dev/null | sed -n "${pnum}p" | xargs basename 2>/dev/null | sed 's/\.profile$//')
                
                if [ -n "$profile" ]; then
                    printf "  Capture duration in seconds [300]: "
                    read -r duration
                    duration="${duration:-300}"
                    
                    clear
                    start_learning "$profile" "$duration"
                    
                    printf "\n  Press Enter to continue..."
                    read -r _
                else
                    warn "Invalid selection"
                    sleep 1
                fi
                ;;
            2)
                clear
                list_profiles
                printf "  Select profile number: "
                read -r pnum
                
                local profile=$(ls "$PROFILES_DIR"/*.profile 2>/dev/null | sed -n "${pnum}p" | xargs basename 2>/dev/null | sed 's/\.profile$//')
                
                if [ -n "$profile" ]; then
                    clear
                    learn_from_dns "$profile"
                    printf "\n  Press Enter to continue..."
                    read -r _
                fi
                ;;
            3)
                clear
                show_learned
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            4)
                clear
                generate_bypass_rules
                apply_bypass_rules
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            5)
                clear
                remove_bypass_rules
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            6)
                clear
                list_profiles
                printf "  Press Enter to continue..."
                read -r _
                ;;
            7)
                clear
                create_custom_profile
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            8)
                clear
                if is_overclock_active; then
                    disable_overclock
                else
                    enable_overclock
                fi
                printf "\n  Press Enter to continue..."
                read -r _
                ;;
            9)
                clear
                show_overclock_stats
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
CI5 GameSense — Anti-Lag VPN Split-Tunnel System

Usage:
  curl ci5.run/gamesense | sh              Interactive menu
  curl ci5.run/gamesense | sh -s learn PROFILE [DURATION]
  curl ci5.run/gamesense | sh -s dns PROFILE
  curl ci5.run/gamesense | sh -s apply
  curl ci5.run/gamesense | sh -s remove
  curl ci5.run/gamesense | sh -s antilag [on|off]
  curl ci5.run/gamesense | sh -s status
  curl ci5.run/gamesense | sh -s profiles
  curl ci5.run/gamesense | sh -s show [PROFILE]

Commands:
  learn PROFILE [DURATION]  Start packet capture (default 300s)
  dns PROFILE               Learn IPs from known domains
  apply                     Apply bypass rules to routing
  remove                    Remove all bypass rules
  antilag [on|off]          Toggle maximum priority queue (ON by default)
  status                    Show current state
  profiles                  List available game profiles
  show [PROFILE]            Show learned IPs

Anti-Lag OC Mode (ENABLED BY DEFAULT):
  When enabled, game traffic is:
  • Marked with DSCP EF (Expedited Forwarding, class 46)
  • Pushed to absolute front of packet queue
  • Processed with pfifo (zero-overhead queue discipline)
  • Kernel tuned for minimum latency
  
  Disable with 'antilag off' for bulk downloads.

Pre-defined Profiles:
  steam       Valve/Steam (CS2, Dota 2, TF2)
  riot        Riot Games (LoL, Valorant)
  epic        Epic Games (Fortnite, Rocket League)
  blizzard    Blizzard (CoD, Overwatch, WoW)
  ea          EA Games (Apex, FIFA, Battlefield)
  xbox        Xbox Live
  playstation PlayStation Network
  minecraft   Minecraft
  ubisoft     Ubisoft (R6 Siege, etc.)

Examples:
  # Learn Valorant servers while playing
  curl ci5.run/gamesense | sh -s learn riot 600
  
  # Resolve known Steam server domains
  curl ci5.run/gamesense | sh -s dns steam
  
  # Apply bypass rules (Anti-Lag OC auto-enabled)
  curl ci5.run/gamesense | sh -s apply
  
  # Disable Anti-Lag OC for bulk downloads
  curl ci5.run/gamesense | sh -s antilag off
  
  # Remove bypass, route games through VPN again
  curl ci5.run/gamesense | sh -s remove
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    # Check dependencies
    command -v tcpdump >/dev/null 2>&1 || command -v tshark >/dev/null 2>&1 || {
        warn "tcpdump not found, installing..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update && opkg install tcpdump
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y tcpdump
        else
            err "Please install tcpdump: apt install tcpdump"
        fi
    }
    
    command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1 || true
    
    # Initialize profiles if needed
    [ -d "$PROFILES_DIR" ] || init_profiles
    
    case "${1:-}" in
        learn)
            start_learning "${2:-steam}" "${3:-300}"
            ;;
        dns)
            learn_from_dns "${2:-steam}"
            ;;
        apply)
            generate_bypass_rules
            apply_bypass_rules
            # Auto-enable Anti-Lag OC when applying bypass rules
            if ! is_overclock_active; then
                info "Auto-enabling Anti-Lag OC..."
                enable_overclock
            fi
            ;;
        remove)
            remove_bypass_rules
            ;;
        antilag|overclock)
            case "${2:-}" in
                on|enable|1)
                    enable_overclock
                    ;;
                off|disable|0)
                    disable_overclock
                    ;;
                stats|status)
                    show_overclock_stats
                    ;;
                *)
                    # Toggle
                    if is_overclock_active; then
                        disable_overclock
                    else
                        enable_overclock
                    fi
                    ;;
            esac
            ;;
        status)
            show_status
            ;;
        profiles)
            list_profiles
            ;;
        show)
            show_learned "$2"
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
