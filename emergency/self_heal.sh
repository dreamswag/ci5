#!/bin/sh
# 🩹 Ci5 Self-Heal (v7.5-RELEASE)
# Route: /heal
# Purpose: Verify local scripts against trusted server checksums
#          Automatically restores missing or corrupted files
#
# Usage: curl ci5.run/heal | sh
#
# What it does:
#   1. Fetches manifest from ci5.host (checksums of all core files)
#   2. Compares local files against manifest
#   3. Downloads and replaces any corrupted/missing files
#   4. Verifies post-repair integrity
#   5. Restarts affected services

set -e

# ─────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CI5_BASE="/opt/ci5"
CI5_HOST="https://ci5.host"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
MANIFEST_URL="$CI5_HOST/manifest.sha256"
BACKUP_DIR="/root/ci5-heal-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/ci5-heal-$(date +%Y%m%d_%H%M%S).log"

# Core files to verify (relative to CI5_BASE)
CORE_FILES="
install-lite.sh
install-full.sh
setup.sh
validate.sh
preflight.sh
bone_marrow.sh
configs/network_init.sh
configs/firewall_init.sh
configs/sqm_init.sh
configs/dnsmasq_init.sh
configs/tuning_sysctl.conf
configs/tuning_rclocal.sh
configs/unbound
extras/speed_wizard.sh
extras/emergency_recovery.sh
extras/dns_failover.sh
extras/paranoia_watchdog.sh
docker/docker-compose.yml
docker/adguard/conf/AdGuardHome.yaml
"

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_ok() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"
}

log_err() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${CYAN}[i]${NC} $1" | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────
check_deps() {
    for cmd in curl sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_err "Missing dependency: $cmd"
            log_info "Installing..."
            opkg update && opkg install "$cmd" 2>/dev/null || {
                log_err "Failed to install $cmd"
                exit 1
            }
        fi
    done
}

# ─────────────────────────────────────────────────────────────
# NETWORK CHECK
# ─────────────────────────────────────────────────────────────
check_network() {
    log "Checking network connectivity..."
    
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        log_err "No internet connectivity"
        log_info "Attempting emergency DNS fix..."
        echo "nameserver 1.1.1.1" > /tmp/resolv.conf.heal
        cat /tmp/resolv.conf.heal > /etc/resolv.conf
        
        if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
            log_err "Still no connectivity. Run 'curl ci5.run/rescue | sh' first."
            exit 1
        fi
    fi
    
    log_ok "Network connectivity verified"
}

# ─────────────────────────────────────────────────────────────
# CREATE BACKUP
# ─────────────────────────────────────────────────────────────
create_backup() {
    log "Creating backup at $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    
    if [ -d "$CI5_BASE" ]; then
        cp -r "$CI5_BASE" "$BACKUP_DIR/ci5_backup" 2>/dev/null || true
    fi
    
    # Backup UCI config
    cp -r /etc/config "$BACKUP_DIR/config_backup" 2>/dev/null || true
    
    log_ok "Backup created"
}

# ─────────────────────────────────────────────────────────────
# FETCH MANIFEST
# ─────────────────────────────────────────────────────────────
fetch_manifest() {
    log "Fetching integrity manifest from $CI5_HOST..."
    
    MANIFEST_FILE="/tmp/ci5_manifest.sha256"
    
    if curl -sfL "$MANIFEST_URL" -o "$MANIFEST_FILE" 2>/dev/null; then
        log_ok "Manifest downloaded"
        return 0
    fi
    
    # Fallback: Generate manifest from GitHub raw files
    log_warn "Could not fetch manifest from ci5.host, generating from source..."
    > "$MANIFEST_FILE"
    
    for file in $CORE_FILES; do
        REMOTE_HASH=$(curl -sfL "$CI5_RAW/$file" 2>/dev/null | sha256sum | awk '{print $1}')
        if [ -n "$REMOTE_HASH" ] && [ "$REMOTE_HASH" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
            echo "$REMOTE_HASH  $file" >> "$MANIFEST_FILE"
        fi
    done
    
    log_ok "Manifest generated from source"
}

# ─────────────────────────────────────────────────────────────
# VERIFY FILES
# ─────────────────────────────────────────────────────────────
verify_files() {
    log "Verifying local file integrity..."
    
    CORRUPTED=""
    MISSING=""
    VERIFIED=0
    
    MANIFEST_FILE="/tmp/ci5_manifest.sha256"
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        EXPECTED_HASH=$(echo "$line" | awk '{print $1}')
        FILE_PATH=$(echo "$line" | awk '{print $2}')
        FULL_PATH="$CI5_BASE/$FILE_PATH"
        
        if [ ! -f "$FULL_PATH" ]; then
            MISSING="$MISSING $FILE_PATH"
            log_warn "Missing: $FILE_PATH"
        else
            LOCAL_HASH=$(sha256sum "$FULL_PATH" 2>/dev/null | awk '{print $1}')
            
            if [ "$LOCAL_HASH" != "$EXPECTED_HASH" ]; then
                CORRUPTED="$CORRUPTED $FILE_PATH"
                log_warn "Corrupted: $FILE_PATH"
                log_info "  Expected: $EXPECTED_HASH"
                log_info "  Found:    $LOCAL_HASH"
            else
                VERIFIED=$((VERIFIED + 1))
            fi
        fi
    done < "$MANIFEST_FILE"
    
    log_ok "$VERIFIED files verified OK"
    
    if [ -n "$MISSING" ] || [ -n "$CORRUPTED" ]; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# REPAIR FILES
# ─────────────────────────────────────────────────────────────
repair_files() {
    log "Repairing damaged/missing files..."
    
    REPAIRED=0
    FAILED=0
    
    MANIFEST_FILE="/tmp/ci5_manifest.sha256"
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        EXPECTED_HASH=$(echo "$line" | awk '{print $1}')
        FILE_PATH=$(echo "$line" | awk '{print $2}')
        FULL_PATH="$CI5_BASE/$FILE_PATH"
        
        NEEDS_REPAIR=0
        
        if [ ! -f "$FULL_PATH" ]; then
            NEEDS_REPAIR=1
        else
            LOCAL_HASH=$(sha256sum "$FULL_PATH" 2>/dev/null | awk '{print $1}')
            if [ "$LOCAL_HASH" != "$EXPECTED_HASH" ]; then
                NEEDS_REPAIR=1
            fi
        fi
        
        if [ "$NEEDS_REPAIR" -eq 1 ]; then
            log_info "Downloading: $FILE_PATH"
            
            # Create directory if needed
            mkdir -p "$(dirname "$FULL_PATH")"
            
            # Download from GitHub
            if curl -sfL "$CI5_RAW/$FILE_PATH" -o "$FULL_PATH.new" 2>/dev/null; then
                NEW_HASH=$(sha256sum "$FULL_PATH.new" | awk '{print $1}')
                
                if [ "$NEW_HASH" = "$EXPECTED_HASH" ]; then
                    mv "$FULL_PATH.new" "$FULL_PATH"
                    chmod +x "$FULL_PATH" 2>/dev/null || true
                    log_ok "Repaired: $FILE_PATH"
                    REPAIRED=$((REPAIRED + 1))
                else
                    rm -f "$FULL_PATH.new"
                    log_err "Hash mismatch after download: $FILE_PATH"
                    FAILED=$((FAILED + 1))
                fi
            else
                log_err "Failed to download: $FILE_PATH"
                FAILED=$((FAILED + 1))
            fi
        fi
    done < "$MANIFEST_FILE"
    
    log_ok "Repaired $REPAIRED files"
    
    if [ "$FAILED" -gt 0 ]; then
        log_err "Failed to repair $FAILED files"
        return 1
    fi
    
    return 0
}

# ─────────────────────────────────────────────────────────────
# RESTART SERVICES
# ─────────────────────────────────────────────────────────────
restart_services() {
    log "Restarting affected services..."
    
    # Reload sysctl if tuning was repaired
    if [ -f "$CI5_BASE/configs/tuning_sysctl.conf" ]; then
        sysctl -p "$CI5_BASE/configs/tuning_sysctl.conf" >/dev/null 2>&1 || true
    fi
    
    # Restart network services
    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    
    # Restart Unbound if present
    if [ -f /etc/init.d/unbound ]; then
        /etc/init.d/unbound restart 2>/dev/null || true
    fi
    
    # Restart SQM if present
    if [ -f /etc/init.d/sqm ]; then
        /etc/init.d/sqm restart 2>/dev/null || true
    fi
    
    # Restart Docker containers if present
    if command -v docker >/dev/null 2>&1; then
        if [ -f "$CI5_BASE/docker/docker-compose.yml" ]; then
            cd "$CI5_BASE/docker" && docker compose restart 2>/dev/null || true
        fi
    fi
    
    log_ok "Services restarted"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}            ${GREEN}🩹 Ci5 SELF-HEAL (v7.5-RELEASE)${NC}                       ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log "Starting self-heal process..."
    log "Log file: $LOG_FILE"
    echo ""
    
    # Pre-flight checks
    check_deps
    check_network
    
    # Create safety backup
    create_backup
    
    # Fetch and verify
    fetch_manifest
    
    if verify_files; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ✅ ALL FILES VERIFIED - SYSTEM HEALTHY              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_ok "No repairs needed"
        exit 0
    fi
    
    # Repair needed
    echo ""
    log_warn "Integrity issues detected, initiating repair..."
    echo ""
    
    if repair_files; then
        restart_services
        
        # Final verification
        echo ""
        log "Running final verification..."
        
        if verify_files; then
            echo ""
            echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║              ✅ SELF-HEAL COMPLETE - ALL VERIFIED                ║${NC}"
            echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            log_ok "System healed successfully"
            log_info "Backup preserved at: $BACKUP_DIR"
            exit 0
        fi
    fi
    
    # Repair failed
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              ❌ SELF-HEAL INCOMPLETE                              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_err "Some files could not be repaired"
    log_info "Options:"
    log_info "  1. Run 'sh $CI5_BASE/install-lite.sh' to reinstall"
    log_info "  2. Restore from backup: $BACKUP_DIR"
    log_info "  3. Check log: $LOG_FILE"
    exit 1
}

main "$@"