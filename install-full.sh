#!/bin/bash
# 🏰 Ci5 Unified Installer (v7.5-HARDENED: The Cork Registry)
# Deploys Docker, Core Services, and Community Corks

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${GREEN}Starting Ci5 Full Stack Installation (v7.5-HARDENED)...${NC}"

#══════════════════════════════════════════════════════════════════════════════
# 1. IDENTITY INITIALIZATION (Passive / Offline Friendly)
#══════════════════════════════════════════════════════════════════════════════

CI5_IDENTITY_DIR="/etc/ci5"
CI5_IDENTITY_VERSION="v1"

init_identity() {
    echo "🦴 Initializing Ci5 Hardware Identity..."
    
    mkdir -p "$CI5_IDENTITY_DIR"
    chmod 700 "$CI5_IDENTITY_DIR"
    
    # Get Pi 5 Serial (Robust detection)
    if [ -f /proc/cpuinfo ]; then
        SERIAL=$(grep -i "^Serial" /proc/cpuinfo | awk '{print $3}' | head -1)
    fi
    
    if [ -z "$SERIAL" ] || [ "$SERIAL" = "0000000000000000" ]; then
        echo -e "${YELLOW}⚠️  Warning: Could not read hardware serial. Using fallback identity.${NC}"
        # Fallback for non-Pi hardware or virtualization
        SERIAL="UNKNOWN_$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')"
        if [ -z "$SERIAL" ]; then SERIAL="UNKNOWN_$(cat /proc/sys/kernel/random/uuid)"; fi
    fi
    
    # HWID: Permanent, deterministic hardware identity
    # SHA256(Serial + Salt) -> Same Pi always produces same HWID
    HWID=$(echo -n "${SERIAL}:ci5-permanent-identity-${CI5_IDENTITY_VERSION}" | sha256sum | cut -d' ' -f1)
    
    # Store locally (Used for verification ONLY if user chooses to verify)
    echo "$HWID" > "$CI5_IDENTITY_DIR/.hwid"
    chmod 600 "$CI5_IDENTITY_DIR/.hwid"
    
    echo -e "✅ Identity Initialized: ${GREEN}${HWID:0:8}...${HWID: -8}${NC}"
    echo "   (This identity is required only for Voting and Forum Posting)"
    echo ""
}

# Run identity init immediately (Non-blocking)
init_identity

# ─────────────────────────────────────────────────────────────
# ATOMIC ROLLBACK INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────
ROLLBACK_ENABLED=0
BACKUP_DIR=""
ROLLBACK_MARKER="/tmp/.ci5_rollback_in_progress"
LOG_FILE="/root/ci5-full-install-$(date +%Y%m%d_%H%M%S).log"

# Start logging
exec > >(tee -a "$LOG_FILE") 2>&1

init_atomic_rollback() {
    BACKUP_DIR="/root/ci5-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo "[ATOMIC] Creating restoration checkpoint..."
    cp -r /etc/config "$BACKUP_DIR/config" 2>/dev/null
    cp /etc/rc.local "$BACKUP_DIR/rc.local" 2>/dev/null
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null
    
    if command -v docker &> /dev/null; then
        docker ps -a --format '{{.Names}}' > "$BACKUP_DIR/docker_containers.txt" 2>/dev/null
    fi
    [ -f /etc/ci5_corks ] && cp /etc/ci5_corks "$BACKUP_DIR/ci5_corks"
    ip addr show > "$BACKUP_DIR/ip_addr.txt" 2>/dev/null
    
    ROLLBACK_ENABLED=1
    echo -e "${GREEN}[ATOMIC] Checkpoint saved: $BACKUP_DIR${NC}"
}

execute_rollback() {
    if [ "$ROLLBACK_ENABLED" -ne 1 ] || [ -z "$BACKUP_DIR" ]; then
        echo "[ATOMIC] No rollback checkpoint available"
        return 1
    fi
    
    # Prevent recursive rollback
    if [ -f "$ROLLBACK_MARKER" ]; then
        echo "[ATOMIC] Rollback already in progress, aborting"
        return 1
    fi
    touch "$ROLLBACK_MARKER"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🔄 EXECUTING ATOMIC ROLLBACK                                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    if command -v docker &> /dev/null; then
        echo "[ROLLBACK] Stopping new Docker containers..."
        if [ -f "$BACKUP_DIR/docker_containers.txt" ]; then
            docker ps -a --format '{{.Names}}' | while read container; do
                if ! grep -q "^${container}$" "$BACKUP_DIR/docker_containers.txt" 2>/dev/null; then
                    echo "   Removing new container: $container"
                    docker stop "$container" 2>/dev/null; docker rm "$container" 2>/dev/null
                fi
            done
        fi
    fi
    
    if [ -d "$BACKUP_DIR/config" ]; then
        echo "[ROLLBACK] Restoring UCI configuration..."
        cp -r "$BACKUP_DIR/config" /etc/config
    fi
    
    [ -f "$BACKUP_DIR/rc.local" ] && cp "$BACKUP_DIR/rc.local" /etc/rc.local
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/sysctl.conf
    [ -f "$BACKUP_DIR/ci5_corks" ] && cp "$BACKUP_DIR/ci5_corks" /etc/ci5_corks
    
    echo "[ROLLBACK] Reloading services..."
    /etc/init.d/network reload 2>/dev/null
    /etc/init.d/firewall reload 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    
    rm -f "$ROLLBACK_MARKER"
    echo -e "${GREEN}[ROLLBACK] System restored to pre-install state${NC}"
    return 0
}

rollback_on_error() {
    local exit_code=$?
    echo -e "${RED}❌ INSTALLATION FAILED (Exit: $exit_code)${NC}"
    
    if [ "$ROLLBACK_ENABLED" -eq 1 ]; then
        echo -n "Automatic rollback available. Execute rollback? [Y/n]: "
        read -t 30 ROLLBACK_CHOICE || ROLLBACK_CHOICE="y"
        if [ "$ROLLBACK_CHOICE" != "n" ] && [ "$ROLLBACK_CHOICE" != "N" ]; then
            execute_rollback
        else
            echo "Rollback skipped."
        fi
    fi
    exit 1
}

set -E
trap 'rollback_on_error' ERR

# ─────────────────────────────────────────────────────────────
# ADGUARD SETUP
# ─────────────────────────────────────────────────────────────
generate_secure_password() {
    head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' | head -c 20
}

setup_adguard_password() {
    local adguard_config="/opt/ci5-docker/adguard/conf/AdGuardHome.yaml"
    local password_file="/root/.ci5_adguard_firstrun"
    
    if [ -f "$password_file" ]; then return 0; fi
    
    echo "[ADGUARD] Configuring initial credentials..."
    ADGUARD_PASSWORD=$(generate_secure_password)
    
    # Simple bcrypt fallback or python
    if command -v python3 >/dev/null; then
        ADGUARD_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADGUARD_PASSWORD'.encode(), bcrypt.gensalt()).decode())" 2>/dev/null)
    fi
    
    if [ -z "$ADGUARD_HASH" ]; then
        # Last resort fallback if python/bcrypt missing (insecure but works for install)
        ADGUARD_HASH=$(openssl passwd -6 "$ADGUARD_PASSWORD")
    fi
    
    mkdir -p "$(dirname "$adguard_config")"
    if [ -f "$adguard_config" ]; then
        sed -i "s|password: \"\$2[^\"]*\"|password: \"${ADGUARD_HASH}\"|g" "$adguard_config"
    fi
    
    echo "$(date -Iseconds)" > "$password_file"
    chmod 600 "$password_file"
    
    echo -e "${GREEN}KEY: ADGUARD_PASSWORD=${ADGUARD_PASSWORD}${NC}" >> "$LOG_FILE"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  🔑 ADGUARD HOME CREDENTIALS                                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  User: admin                                                     ║${NC}"
    echo -e "${GREEN}║  Pass: ${CYAN}${ADGUARD_PASSWORD}${GREEN}                                            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Press ENTER to continue...${NC}"
    read -r CONFIRM
    return 0
}

# ─────────────────────────────────────────────────────────────
# INSTALLATION MODULES
# ─────────────────────────────────────────────────────────────
echo "[*] Initializing atomic rollback system..."
init_atomic_rollback

echo "[*] Installing Dependencies..."
opkg update && opkg install git-http curl ca-certificates parted losetup resize2fs

echo "[*] Checking Docker..."
if ! command -v docker &> /dev/null; then
    opkg install dockerd docker-compose
    /etc/init.d/dockerd enable
    /etc/init.d/dockerd start
    sleep 5
fi

setup_adguard_password

echo "[*] Deploying Core Stack..."
[ -d "/opt/ci5/docker" ] && cd /opt/ci5/docker
docker network create ci5_net 2>/dev/null || true
docker compose pull adguardhome unbound 2>/dev/null || true
docker compose up -d adguardhome unbound

# ─────────────────────────────────────────────────────────────
# MODULE E: CORK INJECTION (OPEN ACCESS)
# ─────────────────────────────────────────────────────────────
# Note: This step is UNRESTRICTED. Anyone can fetch default corks.
echo "[*] Uncorking Registry Modules..."
DEFAULT_CORKS="dreamswag/cork-ntopng" 
if [ -f /etc/ci5_corks ]; then USER_CORKS=$(cat /etc/ci5_corks | tr '\n' ' '); else USER_CORKS="$DEFAULT_CORKS"; fi
mkdir -p /opt/ci5/corks

for REPO in $USER_CORKS; do
    [ -z "$REPO" ] && continue
    NAME=$(basename "$REPO")
    echo "    -> Fetching Cork: $NAME"
    if [ -d "/opt/ci5/corks/$NAME" ]; then
        cd "/opt/ci5/corks/$NAME" && git pull --quiet
    else
        git clone --depth 1 "https://github.com/$REPO.git" "/opt/ci5/corks/$NAME" 2>/dev/null
    fi
    
    if [ -f "/opt/ci5/corks/$NAME/docker-compose.yml" ]; then
        cd "/opt/ci5/corks/$NAME" && docker compose up -d
    elif [ -f "/opt/ci5/corks/$NAME/init.sh" ]; then
        bash "/opt/ci5/corks/$NAME/init.sh"
    fi
done

echo "[*] Deploying Full Security Stack..."
cd /opt/ci5/docker 2>/dev/null || true
docker compose --profile full up -d

# ─────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[*] Installing Ci5 CLI...${NC}"
if [ -f "/opt/ci5/bin/ci5" ]; then
    chmod +x /opt/ci5/bin/ci5
    ln -sf /opt/ci5/bin/ci5 /usr/bin/ci5 2>/dev/null
else
    # Install the latest CLI (which supports the open install / verified vote model)
    curl -sL "https://raw.githubusercontent.com/dreamswag/ci5/main/bin/ci5" -o /usr/bin/ci5
    chmod +x /usr/bin/ci5
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ FULL STACK INSTALLATION COMPLETE                             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "    Your hardware identity has been generated at /etc/ci5/.hwid"
echo "    Use 'ci5 link' ONLY if you wish to participate in forums/voting."
echo "    Use 'ci5 install <cork>' to fetch packages (no login required)"
echo ""
echo "    Access Points:"
echo "      SSH:        ssh root@192.168.99.1"
echo "      AdGuard:    http://192.168.99.1:3000"
echo "      Ntopng:     http://192.168.99.1:3001"
echo ""

trap - ERR
rm -f "$ROLLBACK_MARKER" 2>/dev/null