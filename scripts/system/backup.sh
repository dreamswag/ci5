#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/backup — Hardware-Locked Configuration Export
# Version: 2.0-PHOENIX
# 
# Creates an encrypted backup of router configuration bound to this device's
# hardware identity. Cannot be decrypted on any other router.
# ═══════════════════════════════════════════════════════════════════════════

set -e

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE IDENTITY
# ─────────────────────────────────────────────────────────────────────────────
get_hwid() {
    # Check for existing HWID
    if [ -f /etc/ci5/.hwid ]; then
        cat /etc/ci5/.hwid
        return 0
    fi
    
    # Generate from hardware
    local serial=""
    
    # Pi serial
    if [ -f /proc/cpuinfo ]; then
        serial=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}')
    fi
    
    # DMI UUID fallback
    if [ -z "$serial" ] && [ -f /sys/class/dmi/id/product_uuid ]; then
        serial=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
    
    # MAC fallback
    if [ -z "$serial" ]; then
        for iface in eth0 end0 enp0s3 wlan0; do
            if [ -f "/sys/class/net/$iface/address" ]; then
                serial=$(cat "/sys/class/net/$iface/address" | tr -d ':')
                break
            fi
        done
    fi
    
    if [ -z "$serial" ]; then
        err "Cannot determine hardware identity"
    fi
    
    # Generate HWID
    echo -n "${serial}:ci5-backup-key" | sha256sum | cut -d' ' -f1
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "linux"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BACKUP FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
backup_openwrt() {
    local backup_dir="$1"
    
    info "Backing up OpenWrt configuration..."
    
    # UCI config
    if [ -d /etc/config ]; then
        cp -r /etc/config "$backup_dir/"
        info "UCI configs saved"
    fi
    
    # Installed packages list
    if command -v opkg >/dev/null 2>&1; then
        opkg list-installed > "$backup_dir/packages.txt"
        info "Package list saved"
    fi
    
    # Firewall rules
    [ -f /etc/firewall.user ] && cp /etc/firewall.user "$backup_dir/"
    
    # Crontabs
    [ -f /etc/crontabs/root ] && cp /etc/crontabs/root "$backup_dir/crontab"
    
    # SSH keys
    [ -d /etc/dropbear ] && cp -r /etc/dropbear "$backup_dir/"
    [ -f /root/.ssh/authorized_keys ] && {
        mkdir -p "$backup_dir/.ssh"
        cp /root/.ssh/authorized_keys "$backup_dir/.ssh/"
    }
}

backup_debian() {
    local backup_dir="$1"
    
    info "Backing up Debian configuration..."
    
    # Network config
    [ -d /etc/netplan ] && cp -r /etc/netplan "$backup_dir/"
    [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$backup_dir/"
    
    # Sysctl
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$backup_dir/"
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$backup_dir/"
    
    # Installed packages
    dpkg --get-selections > "$backup_dir/packages.txt" 2>/dev/null || true
    
    # SSH
    [ -f /root/.ssh/authorized_keys ] && {
        mkdir -p "$backup_dir/.ssh"
        cp /root/.ssh/authorized_keys "$backup_dir/.ssh/"
    }
    
    # Crontabs
    crontab -l > "$backup_dir/crontab" 2>/dev/null || true
}

backup_ci5() {
    local backup_dir="$1"
    
    info "Backing up CI5 configuration..."
    
    mkdir -p "$backup_dir/ci5"
    
    # CI5 identity (NOT the private key, just config)
    [ -d /etc/ci5 ] && cp -r /etc/ci5 "$backup_dir/"
    
    # CI5 scripts
    [ -d /opt/ci5 ] && {
        # Just configs, not binaries
        find /opt/ci5 -name "*.conf" -o -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
        while read -r f; do
            mkdir -p "$backup_dir/ci5/$(dirname "$f" | sed 's|^/opt/ci5/||')"
            cp "$f" "$backup_dir/ci5/$(echo "$f" | sed 's|^/opt/ci5/||')"
        done
    }
    
    # Docker compose files
    [ -f /opt/ci5/docker/docker-compose.yml ] && {
        mkdir -p "$backup_dir/ci5/docker"
        cp /opt/ci5/docker/docker-compose.yml "$backup_dir/ci5/docker/"
    }
    
    # Cork list
    [ -f /etc/ci5_corks ] && cp /etc/ci5_corks "$backup_dir/ci5/"
}

backup_vpn() {
    local backup_dir="$1"
    
    info "Backing up VPN configurations..."
    
    mkdir -p "$backup_dir/vpn"
    
    # WireGuard
    if [ -d /etc/wireguard ]; then
        # Copy configs but warn about private keys
        cp -r /etc/wireguard "$backup_dir/vpn/"
        warn "WireGuard private keys included — keep backup secure!"
    fi
    
    # OpenVPN
    [ -d /etc/openvpn ] && cp -r /etc/openvpn "$backup_dir/vpn/"
    
    # Tailscale state (if exists)
    [ -d /var/lib/tailscale ] && {
        mkdir -p "$backup_dir/vpn/tailscale"
        cp /var/lib/tailscale/*.json "$backup_dir/vpn/tailscale/" 2>/dev/null || true
    }
}

backup_docker_volumes() {
    local backup_dir="$1"
    
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    
    info "Backing up Docker volume configs..."
    
    mkdir -p "$backup_dir/docker"
    
    # AdGuard config
    [ -d /opt/ci5/docker/adguard/conf ] && \
        cp -r /opt/ci5/docker/adguard/conf "$backup_dir/docker/adguard-conf"
    
    # Unbound config
    [ -d /opt/ci5/docker/unbound ] && \
        cp -r /opt/ci5/docker/unbound "$backup_dir/docker/unbound"
    
    # Homepage config
    [ -d /opt/ci5/docker/homepage ] && \
        cp -r /opt/ci5/docker/homepage "$backup_dir/docker/homepage"
    
    # CrowdSec config (not data)
    [ -d /opt/ci5/docker/crowdsec/config ] && \
        cp -r /opt/ci5/docker/crowdsec/config "$backup_dir/docker/crowdsec-config"
    
    # Note: We don't backup Suricata rules or ntopng data (too large, auto-downloaded)
}

# ─────────────────────────────────────────────────────────────────────────────
# ENCRYPTION
# ─────────────────────────────────────────────────────────────────────────────
encrypt_backup() {
    local archive="$1"
    local hwid="$2"
    local output="$3"
    
    info "Encrypting backup with hardware-bound key..."
    
    # Derive encryption key from HWID
    # Using HWID + salt through PBKDF2-like process
    local key=$(echo -n "${hwid}:ci5-backup-encryption-v1" | sha256sum | cut -d' ' -f1)
    
    # Encrypt with openssl (AES-256-CBC)
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$archive" \
        -out "$output" \
        -pass "pass:$key"
    
    # Clear key from memory (best effort)
    key="0000000000000000000000000000000000000000000000000000000000000000"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
decrypt_backup() {
    local encrypted="$1"
    local hwid="$2"
    local output="$3"
    
    local key=$(echo -n "${hwid}:ci5-backup-encryption-v1" | sha256sum | cut -d' ' -f1)
    
    if ! openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$encrypted" \
        -out "$output" \
        -pass "pass:$key" 2>/dev/null; then
        return 1
    fi
    
    key="0000000000000000000000000000000000000000000000000000000000000000"
    return 0
}

do_restore() {
    local backup_file="$1"
    
    step "RESTORE FROM BACKUP"
    
    if [ ! -f "$backup_file" ]; then
        err "Backup file not found: $backup_file"
    fi
    
    local hwid=$(get_hwid)
    local temp_tar="/tmp/ci5-restore-$$.tar.gz"
    local temp_dir="/tmp/ci5-restore-$$"
    
    info "Decrypting backup..."
    if ! decrypt_backup "$backup_file" "$hwid" "$temp_tar"; then
        err "Decryption failed — wrong device or corrupted backup"
    fi
    
    info "Extracting backup..."
    mkdir -p "$temp_dir"
    tar xzf "$temp_tar" -C "$temp_dir"
    
    warn "This will overwrite current configuration!"
    printf "Continue? [y/N]: "
    read -r confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        rm -rf "$temp_dir" "$temp_tar"
        echo "Restore cancelled."
        exit 0
    fi
    
    # Restore based on what exists
    local backup_content="$temp_dir/ci5-backup"
    
    [ -d "$backup_content/config" ] && {
        info "Restoring UCI configs..."
        cp -r "$backup_content/config/"* /etc/config/
    }
    
    [ -d "$backup_content/ci5" ] && {
        info "Restoring CI5 configs..."
        cp -r "$backup_content/ci5/"* /etc/ci5/ 2>/dev/null || true
    }
    
    [ -d "$backup_content/vpn/wireguard" ] && {
        info "Restoring WireGuard configs..."
        cp -r "$backup_content/vpn/wireguard/"* /etc/wireguard/
    }
    
    [ -f "$backup_content/crontab" ] && {
        info "Restoring crontab..."
        crontab "$backup_content/crontab"
    }
    
    # Cleanup
    rm -rf "$temp_dir" "$temp_tar"
    
    info "Restore complete!"
    warn "Reboot recommended: reboot"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN BACKUP FLOW
# ─────────────────────────────────────────────────────────────────────────────
do_backup() {
    step "CI5 HARDWARE-LOCKED BACKUP"
    
    local platform=$(detect_platform)
    local hwid=$(get_hwid)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/tmp/ci5-backup-$$"
    local archive_name="ci5-backup-${timestamp}"
    local temp_tar="/tmp/${archive_name}.tar.gz"
    local final_file
    
    # Determine output location
    if [ -d /mnt/usb ] && [ -w /mnt/usb ]; then
        final_file="/mnt/usb/${archive_name}.enc"
    elif [ -d /tmp/upload ]; then
        final_file="/tmp/upload/${archive_name}.enc"
    else
        final_file="/root/${archive_name}.enc"
    fi
    
    info "Platform: $platform"
    info "HWID: ${hwid:0:8}...${hwid: -8}"
    info "Output: $final_file"
    
    mkdir -p "$backup_dir"
    
    # Collect backups
    case "$platform" in
        openwrt) backup_openwrt "$backup_dir" ;;
        debian)  backup_debian "$backup_dir" ;;
        *)       backup_debian "$backup_dir" ;;  # Generic fallback
    esac
    
    backup_ci5 "$backup_dir"
    backup_vpn "$backup_dir"
    backup_docker_volumes "$backup_dir"
    
    # Create metadata
    cat > "$backup_dir/metadata.txt" << EOF
CI5 Backup
──────────────────────────────────
Created: $(date -Iseconds)
Platform: $platform
HWID: ${hwid:0:8}...${hwid: -8}
Hostname: $(hostname)
Version: 2.0-PHOENIX

This backup is encrypted with a key derived from
the hardware identity of the source device.
It can ONLY be restored on the same device.
──────────────────────────────────
EOF
    
    # Create archive
    info "Creating archive..."
    tar czf "$temp_tar" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
    
    # Encrypt
    encrypt_backup "$temp_tar" "$hwid" "$final_file"
    
    # Cleanup
    rm -rf "$backup_dir" "$temp_tar"
    
    # Calculate size
    local size=$(du -h "$final_file" | cut -f1)
    
    step "BACKUP COMPLETE"
    
    printf "\n"
    printf "  ${G}File:${N} %s\n" "$final_file"
    printf "  ${G}Size:${N} %s\n" "$size"
    printf "  ${G}HWID:${N} %s...%s\n" "${hwid:0:8}" "${hwid: -8}"
    printf "\n"
    printf "  ${Y}⚠ This backup can ONLY be restored on this device${N}\n"
    printf "  ${Y}⚠ Store securely — contains VPN private keys${N}\n"
    printf "\n"
    printf "  To restore:\n"
    printf "    ${C}curl ci5.run/backup | sh -s restore %s${N}\n" "$final_file"
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
CI5 Hardware-Locked Backup

Usage:
  curl ci5.run/backup | sh              Create encrypted backup
  curl ci5.run/backup | sh -s restore FILE   Restore from backup

The backup is encrypted with a key derived from this device's
hardware identity. It cannot be decrypted on any other device.

Includes:
  • Network configuration (UCI/netplan)
  • Firewall rules
  • CI5 configs and cork list
  • VPN configurations (WireGuard, Tailscale)
  • Docker service configs
  • SSH authorized keys
  • Crontabs

Does NOT include:
  • Docker images (re-downloaded on restore)
  • Suricata rules (auto-updated)
  • Log files
  • Temporary data
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    # Check for required tools
    command -v openssl >/dev/null 2>&1 || err "openssl required but not found"
    command -v tar >/dev/null 2>&1 || err "tar required but not found"
    
    case "${1:-}" in
        restore)
            shift
            do_restore "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            do_backup
            ;;
    esac
}

main "$@"
