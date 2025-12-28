#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/update — Secure Self-Update with Rollback
# Version: 2.0-PHOENIX
# 
# Fetches latest CI5 scripts with signature verification.
# Creates a rollback checkpoint before applying changes.
# ═══════════════════════════════════════════════════════════════════════════

set -e

CI5_BASE="https://ci5.run"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# VERSION MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
get_local_version() {
    if [ -f /etc/ci5/version ]; then
        cat /etc/ci5/version
    elif [ -f /opt/ci5/version ]; then
        cat /opt/ci5/version
    else
        echo "unknown"
    fi
}

get_remote_version() {
    curl -fsSL --connect-timeout 10 "${CI5_RAW}/VERSION" 2>/dev/null || echo "unknown"
}

# ─────────────────────────────────────────────────────────────────────────────
# SIGNATURE VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_PUBKEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
REPLACE_WITH_ACTUAL_KEY
-----END PUBLIC KEY-----"

verify_signature() {
    local file="$1"
    local sig="$2"
    
    echo "$CI5_PUBKEY" > /tmp/ci5-update-pubkey.pem
    
    if openssl dgst -sha256 -verify /tmp/ci5-update-pubkey.pem \
        -signature "$sig" "$file" >/dev/null 2>&1; then
        rm -f /tmp/ci5-update-pubkey.pem
        return 0
    else
        rm -f /tmp/ci5-update-pubkey.pem
        return 1
    fi
}

download_verified() {
    local name="$1"
    local url="$2"
    local dest="$3"
    
    curl -fsSL --connect-timeout 10 "$url" -o "$dest" || return 1
    curl -fsSL --connect-timeout 10 "${url}.sig" -o "${dest}.sig" || return 1
    
    if ! verify_signature "$dest" "${dest}.sig"; then
        rm -f "$dest" "${dest}.sig"
        return 1
    fi
    
    rm -f "${dest}.sig"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
ROLLBACK_DIR=""

create_rollback_checkpoint() {
    step "CREATING ROLLBACK CHECKPOINT"
    
    ROLLBACK_DIR="/root/.ci5-rollback-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ROLLBACK_DIR"
    
    # Backup current scripts
    if [ -d /opt/ci5 ]; then
        cp -r /opt/ci5 "$ROLLBACK_DIR/opt-ci5"
        info "Backed up /opt/ci5"
    fi
    
    if [ -d /usr/local/bin ]; then
        mkdir -p "$ROLLBACK_DIR/usr-local-bin"
        for f in /usr/local/bin/ci5*; do
            [ -f "$f" ] && cp "$f" "$ROLLBACK_DIR/usr-local-bin/"
        done
        info "Backed up CI5 scripts"
    fi
    
    # Backup version info
    [ -f /etc/ci5/version ] && cp /etc/ci5/version "$ROLLBACK_DIR/"
    
    # Save rollback path
    echo "$ROLLBACK_DIR" > /tmp/.ci5-rollback-path
    
    info "Checkpoint: $ROLLBACK_DIR"
}

execute_rollback() {
    if [ ! -f /tmp/.ci5-rollback-path ]; then
        err "No rollback checkpoint available"
    fi
    
    ROLLBACK_DIR=$(cat /tmp/.ci5-rollback-path)
    
    if [ ! -d "$ROLLBACK_DIR" ]; then
        err "Rollback directory missing: $ROLLBACK_DIR"
    fi
    
    step "EXECUTING ROLLBACK"
    
    # Restore /opt/ci5
    if [ -d "$ROLLBACK_DIR/opt-ci5" ]; then
        rm -rf /opt/ci5
        cp -r "$ROLLBACK_DIR/opt-ci5" /opt/ci5
        info "Restored /opt/ci5"
    fi
    
    # Restore scripts
    if [ -d "$ROLLBACK_DIR/usr-local-bin" ]; then
        cp "$ROLLBACK_DIR/usr-local-bin/"* /usr/local/bin/ 2>/dev/null || true
        info "Restored CI5 scripts"
    fi
    
    # Restore version
    [ -f "$ROLLBACK_DIR/version" ] && cp "$ROLLBACK_DIR/version" /etc/ci5/
    
    rm -f /tmp/.ci5-rollback-path
    
    info "Rollback complete"
}

cleanup_rollback() {
    if [ -f /tmp/.ci5-rollback-path ]; then
        ROLLBACK_DIR=$(cat /tmp/.ci5-rollback-path)
        rm -rf "$ROLLBACK_DIR"
        rm -f /tmp/.ci5-rollback-path
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UPDATE COMPONENTS
# ─────────────────────────────────────────────────────────────────────────────
update_core_scripts() {
    step "UPDATING CORE SCRIPTS"
    
    local scripts="ci5-irq-balance ci5-sqm"
    local updated=0
    
    for script in $scripts; do
        info "Checking $script..."
        
        if download_verified "$script" \
            "${CI5_BASE}/modules/core/$script" \
            "/tmp/$script"; then
            
            # Compare with existing
            if [ -f "/usr/local/bin/$script" ]; then
                local old_hash=$(sha256sum "/usr/local/bin/$script" | cut -d' ' -f1)
                local new_hash=$(sha256sum "/tmp/$script" | cut -d' ' -f1)
                
                if [ "$old_hash" = "$new_hash" ]; then
                    info "$script: up to date"
                    rm -f "/tmp/$script"
                    continue
                fi
            fi
            
            mv "/tmp/$script" "/usr/local/bin/$script"
            chmod +x "/usr/local/bin/$script"
            info "$script: updated"
            updated=$((updated + 1))
        else
            warn "$script: verification failed, skipping"
        fi
    done
    
    echo "$updated"
}

update_sysctl() {
    step "UPDATING SYSCTL TUNING"
    
    if download_verified "99-ci5-network.conf" \
        "${CI5_BASE}/modules/core/99-ci5-network.conf" \
        "/tmp/99-ci5-network.conf"; then
        
        if [ -f "/etc/sysctl.d/99-ci5-network.conf" ]; then
            local old_hash=$(sha256sum "/etc/sysctl.d/99-ci5-network.conf" | cut -d' ' -f1)
            local new_hash=$(sha256sum "/tmp/99-ci5-network.conf" | cut -d' ' -f1)
            
            if [ "$old_hash" = "$new_hash" ]; then
                info "Sysctl config: up to date"
                rm -f "/tmp/99-ci5-network.conf"
                return 0
            fi
        fi
        
        mv "/tmp/99-ci5-network.conf" "/etc/sysctl.d/"
        sysctl --system >/dev/null 2>&1 || true
        info "Sysctl config: updated and applied"
        return 1
    else
        warn "Sysctl config: verification failed, skipping"
        return 0
    fi
}

update_cli() {
    step "UPDATING CI5 CLI"
    
    if [ ! -f /opt/ci5/bin/ci5 ] && [ ! -f /usr/local/bin/ci5 ]; then
        info "CI5 CLI not installed, skipping"
        return 0
    fi
    
    if download_verified "ci5-cli" \
        "${CI5_RAW}/tools/ci5-cli" \
        "/tmp/ci5-cli"; then
        
        local dest="/opt/ci5/bin/ci5"
        [ ! -d /opt/ci5/bin ] && dest="/usr/local/bin/ci5"
        
        if [ -f "$dest" ]; then
            local old_hash=$(sha256sum "$dest" | cut -d' ' -f1)
            local new_hash=$(sha256sum "/tmp/ci5-cli" | cut -d' ' -f1)
            
            if [ "$old_hash" = "$new_hash" ]; then
                info "CI5 CLI: up to date"
                rm -f "/tmp/ci5-cli"
                return 0
            fi
        fi
        
        mv "/tmp/ci5-cli" "$dest"
        chmod +x "$dest"
        info "CI5 CLI: updated"
        return 1
    else
        warn "CI5 CLI: verification failed, skipping"
        return 0
    fi
}

update_docker_images() {
    step "UPDATING DOCKER IMAGES"
    
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker not installed, skipping"
        return 0
    fi
    
    if [ ! -f /opt/ci5/docker/docker-compose.yml ]; then
        info "No CI5 Docker stack found, skipping"
        return 0
    fi
    
    printf "Update Docker images? This may take several minutes. [y/N]: "
    read -r confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Docker update skipped"
        return 0
    fi
    
    cd /opt/ci5/docker
    
    info "Pulling latest images..."
    docker compose pull 2>/dev/null || docker-compose pull
    
    info "Restarting services..."
    docker compose up -d 2>/dev/null || docker-compose up -d
    
    info "Docker images updated"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SELF-TEST
# ─────────────────────────────────────────────────────────────────────────────
run_self_test() {
    step "RUNNING SELF-TEST"
    
    local failed=0
    
    # Test core scripts
    if [ -x /usr/local/bin/ci5-sqm ]; then
        info "ci5-sqm: executable"
    else
        warn "ci5-sqm: missing or not executable"
        failed=1
    fi
    
    if [ -x /usr/local/bin/ci5-irq-balance ]; then
        info "ci5-irq-balance: executable"
    else
        warn "ci5-irq-balance: missing or not executable"
        failed=1
    fi
    
    # Test sysctl
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        info "BBR congestion control: active"
    else
        warn "BBR congestion control: not active"
    fi
    
    # Test Docker (if installed)
    if command -v docker >/dev/null 2>&1; then
        local running=$(docker ps -q 2>/dev/null | wc -l)
        info "Docker containers running: $running"
    fi
    
    return $failed
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN UPDATE FLOW
# ─────────────────────────────────────────────────────────────────────────────
do_update() {
    step "CI5 SECURE UPDATE"
    
    local local_ver=$(get_local_version)
    local remote_ver=$(get_remote_version)
    
    info "Current version: $local_ver"
    info "Latest version:  $remote_ver"
    
    if [ "$local_ver" = "$remote_ver" ] && [ "$local_ver" != "unknown" ]; then
        info "Already up to date!"
        
        printf "\nForce update anyway? [y/N]: "
        read -r force
        
        if [ "$force" != "y" ] && [ "$force" != "Y" ]; then
            exit 0
        fi
    fi
    
    # Create rollback checkpoint
    create_rollback_checkpoint
    
    # Trap for rollback on failure
    trap 'warn "Update failed!"; printf "Rollback? [Y/n]: "; read rb; [ "$rb" != "n" ] && execute_rollback; exit 1' ERR
    
    local changes=0
    
    # Update components
    update_core_scripts && changes=$((changes + 1))
    update_sysctl && changes=$((changes + 1))
    update_cli && changes=$((changes + 1))
    update_docker_images && changes=$((changes + 1))
    
    # Update version file
    if [ "$remote_ver" != "unknown" ]; then
        mkdir -p /etc/ci5
        echo "$remote_ver" > /etc/ci5/version
    fi
    
    # Self-test
    if ! run_self_test; then
        warn "Self-test detected issues"
        printf "Rollback to previous version? [y/N]: "
        read -r rb
        
        if [ "$rb" = "y" ] || [ "$rb" = "Y" ]; then
            execute_rollback
            exit 1
        fi
    fi
    
    # Success - cleanup rollback
    trap - ERR
    cleanup_rollback
    
    step "UPDATE COMPLETE"
    
    printf "\n"
    printf "  ${G}Version:${N} %s → %s\n" "$local_ver" "$remote_ver"
    printf "  ${G}Components updated:${N} %d\n" "$changes"
    printf "\n"
    
    if [ $changes -gt 0 ]; then
        warn "Reboot recommended for all changes to take effect"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK ONLY MODE
# ─────────────────────────────────────────────────────────────────────────────
do_check() {
    local local_ver=$(get_local_version)
    local remote_ver=$(get_remote_version)
    
    printf "Current: %s\n" "$local_ver"
    printf "Latest:  %s\n" "$remote_ver"
    
    if [ "$local_ver" = "$remote_ver" ]; then
        printf "Status:  ${G}Up to date${N}\n"
        exit 0
    else
        printf "Status:  ${Y}Update available${N}\n"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
CI5 Secure Update

Usage:
  curl ci5.run/update | sh              Perform update
  curl ci5.run/update | sh -s check     Check for updates only
  curl ci5.run/update | sh -s rollback  Rollback last update

Features:
  • Signature verification on all downloads
  • Automatic rollback checkpoint before changes
  • Self-test after update
  • Optional Docker image updates

Updated components:
  • Core scripts (ci5-sqm, ci5-irq-balance)
  • Sysctl tuning configuration
  • CI5 CLI (if installed)
  • Docker images (optional, interactive)
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    command -v curl >/dev/null 2>&1 || err "curl required"
    command -v openssl >/dev/null 2>&1 || err "openssl required"
    
    case "${1:-}" in
        check)
            do_check
            ;;
        rollback)
            execute_rollback
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            do_update
            ;;
    esac
}

main "$@"
