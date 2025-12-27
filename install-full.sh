#!/bin/bash
# 🏰 Ci5 Unified Installer (v7.6-IDENTITY: Hardware Verification)
# Deploys Docker, Core Services, Community Corks, and Hardware Identity

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${GREEN}Starting Ci5 Full Stack Installation (v7.6-IDENTITY)...${NC}"

#══════════════════════════════════════════════════════════════════════════════
# 1. HARDWARE IDENTITY INITIALIZATION
#══════════════════════════════════════════════════════════════════════════════
# Creates deterministic HWID from Pi serial. Same hardware = same identity forever.
# This runs BEFORE any network operations (offline-friendly).

CI5_IDENTITY_DIR="/etc/ci5"
CI5_IDENTITY_VERSION="v1"
CI5_IDENTITY_FILE="$CI5_IDENTITY_DIR/.hwid"

init_hardware_identity() {
    echo "🦴 Initializing Ci5 Hardware Identity..."
    
    # Skip if already initialized (idempotent)
    if [ -f "$CI5_IDENTITY_FILE" ]; then
        EXISTING_HWID=$(cat "$CI5_IDENTITY_FILE")
        echo -e "✅ Identity exists: ${GREEN}${EXISTING_HWID:0:8}...${NC}"
        return 0
    fi
    
    # Create secure directory
    mkdir -p "$CI5_IDENTITY_DIR"
    chmod 700 "$CI5_IDENTITY_DIR"
    
    # ─────────────────────────────────────────────────────────────────────────
    # GET HARDWARE SERIAL
    # Priority: Pi Serial > DMI UUID > MAC Address > Random (last resort)
    # ─────────────────────────────────────────────────────────────────────────
    
    SERIAL=""
    
    # Try 1: Raspberry Pi serial from cpuinfo (most reliable for Pi 5)
    if [ -f /proc/cpuinfo ]; then
        SERIAL=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}' | head -1)
        
        # Exclude invalid/default values
        if [ "$SERIAL" = "0000000000000000" ] || [ "$SERIAL" = "00000000" ]; then
            SERIAL=""
        fi
    fi
    
    # Try 2: x86/Server DMI product UUID
    if [ -z "$SERIAL" ] && [ -f /sys/class/dmi/id/product_uuid ]; then
        SERIAL=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
    
    # Try 3: Primary network interface MAC address
    if [ -z "$SERIAL" ]; then
        for iface in eth0 enp0s3 ens33 wlan0 end0; do
            if [ -f "/sys/class/net/$iface/address" ]; then
                MAC=$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr -d ':')
                if [ -n "$MAC" ] && [ "$MAC" != "000000000000" ]; then
                    SERIAL="MAC_$MAC"
                    break
                fi
            fi
        done
    fi
    
    # Try 4: Last resort - generate random UUID
    # WARNING: This identity will change if you reinstall!
    if [ -z "$SERIAL" ]; then
        echo -e "${YELLOW}⚠️  Warning: No hardware serial found. Using random identity.${NC}"
        echo -e "${YELLOW}   (This identity will change if you reinstall.)${NC}"
        SERIAL="RANDOM_$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
    fi
    
    # ─────────────────────────────────────────────────────────────────────────
    # GENERATE DETERMINISTIC HWID
    # SHA256(Serial + Salt) — Same hardware always produces same hash
    # The serial NEVER leaves this device. Only the hash is ever transmitted.
    # ─────────────────────────────────────────────────────────────────────────
    
    HWID=$(echo -n "${SERIAL}:ci5-permanent-identity-${CI5_IDENTITY_VERSION}" | sha256sum | cut -d' ' -f1)
    
    # Store identity (readable only by root)
    echo "$HWID" > "$CI5_IDENTITY_FILE"
    chmod 600 "$CI5_IDENTITY_FILE"
    
    echo -e "✅ Identity Generated: ${GREEN}${HWID:0:8}...${HWID: -8}${NC}"
    echo ""
    return 0
}

# Run identity initialization immediately (before any network ops)
init_hardware_identity

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
opkg update && opkg install git-http curl ca-certificates parted losetup resize2fs jq

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
# CLI INSTALLATION (Identity-Aware)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[*] Installing Ci5 CLI (v3.0-IDENTITY)...${NC}"

# Create CLI directories
mkdir -p /opt/ci5/bin
mkdir -p /opt/ci5/scripts

# Download CLI with identity commands (link, verify, whoami)
CLI_URL="https://raw.githubusercontent.com/dreamswag/ci5/main/tools/ci5-cli"
CLI_PATH="/opt/ci5/bin/ci5"

if curl -sfL "$CLI_URL" -o "$CLI_PATH" 2>/dev/null; then
    chmod +x "$CLI_PATH"
    echo "    ✓ CLI downloaded from repository"
else
    # Fallback: Use bundled CLI if network fails
    if [ -f "/opt/ci5/tools/ci5-cli" ]; then
        cp /opt/ci5/tools/ci5-cli "$CLI_PATH"
        chmod +x "$CLI_PATH"
        echo "    ✓ CLI installed from bundle"
    else
        echo -e "${YELLOW}    ⚠ CLI download failed. Install manually later.${NC}"
    fi
fi

# Create symlink for global access
ln -sf "$CLI_PATH" /usr/bin/ci5 2>/dev/null || ln -sf "$CLI_PATH" /usr/local/bin/ci5 2>/dev/null

# Verify CLI works
if command -v ci5 &>/dev/null; then
    echo -e "    ✓ CLI available: ${CYAN}ci5 --help${NC}"
fi

# ─────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────
HWID=$(cat "$CI5_IDENTITY_FILE" 2>/dev/null || echo "unknown")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ FULL STACK INSTALLATION COMPLETE                             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "    ${CYAN}Hardware Identity${NC}"
echo -e "    HWID: ${GREEN}${HWID:0:8}...${HWID: -8}${NC}"
echo -e "    File: /etc/ci5/.hwid"
echo ""
echo -e "    ${CYAN}Community Participation (Optional)${NC}"
echo -e "    Run '${GREEN}ci5 link${NC}' to connect your GitHub account."
echo -e "    This enables posting in forums and voting on corks."
echo ""
echo -e "    ${CYAN}Cork Installation (No Login Required)${NC}"
echo -e "    Run '${GREEN}ci5 install <cork>${NC}' to fetch packages."
echo ""
echo -e "    ${CYAN}Access Points${NC}"
echo "      SSH:        ssh root@192.168.99.1"
echo "      AdGuard:    http://192.168.99.1:3000"
echo "      Ntopng:     http://192.168.99.1:3001"
echo ""
echo -e "    ${CYAN}Quick Commands${NC}"
echo "      ci5 whoami     — Show identity status"
echo "      ci5 link       — Link to GitHub (one-time)"
echo "      ci5 verify     — Verify browser session"
echo ""

trap - ERR
rm -f "$ROLLBACK_MARKER" 2>/dev/null
