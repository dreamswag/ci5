#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/away — Complete CI5 Removal (Wraps Pure + Optional Secure Wipe)
# Version: 1.0-PHOENIX
#
# Single command for complete CI5 ecosystem removal with optional secure
# deletion of sensitive data (VPN keys, SSH keys, history) for border
# crossing or device handoff scenarios.
#
# Usage:
#   curl -sL ci5.run | sh -s away              # Remove all corks + CI5 core
#   curl -sL ci5.run | sh -s away --wipe       # + secure delete sensitive data
#   curl -sL ci5.run | sh -s away --dry-run    # Preview what would be removed
#   curl -sL ci5.run | sh -s away --keep-state # Remove corks but keep state/logs
#
# This script:
#   1. Calls 'pure all' to remove all corks in dependency order
#   2. Removes CI5 core infrastructure (/etc/ci5, /opt/ci5, services)
#   3. Optionally wipes sensitive data (--wipe flag)
#
# Philosophy: "Leave no trace"
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CI5_DIR="/etc/ci5"
CI5_OPT="/opt/ci5"
CI5_VAR="/var/lib/ci5"
CI5_SYSTEMD="/etc/systemd/system/ci5-*.service"
CI5_LOG="/var/log/ci5-*.log"

# Sensitive paths for --wipe mode
WIPE_PATHS="
/etc/wireguard
/etc/ci5/keys
/var/lib/tailscale
/etc/tailscale
/root/.ssh
/root/.gnupg
/root/.bash_history
/root/.zsh_history
/home/*/.ssh
/home/*/.gnupg
/home/*/.bash_history
/home/*/.zsh_history
"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }
dry()  { printf "${D}[DRY]${N} %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

WIPE_MODE=false
DRY_RUN=false
FORCE_MODE=false
KEEP_STATE=false
NO_REBOOT=true  # Default: don't reboot unless wiping

for arg in "$@"; do
    case "$arg" in
        --wipe|-w)       WIPE_MODE=true; NO_REBOOT=false ;;
        --dry-run|-n)    DRY_RUN=true ;;
        --force|-f)      FORCE_MODE=true ;;
        --keep-state)    KEEP_STATE=true ;;
        --no-reboot)     NO_REBOOT=true ;;
        --help|-h)
            cat << 'HELP'
CI5 Away — Complete Ecosystem Removal

Usage: curl -sL ci5.run | sh -s away [OPTIONS]

Options:
  --wipe, -w       Also securely delete sensitive data (VPN keys, SSH, history)
  --dry-run, -n    Preview what would be removed without changes
  --force, -f      Skip confirmation prompts
  --keep-state     Remove corks but preserve /etc/ci5 state directory
  --no-reboot      Don't reboot after wipe (default unless --wipe)
  --help, -h       Show this help

Modes:
  away             Remove all corks + CI5 infrastructure
  away --wipe      Above + secure delete keys/history (border crossing mode)

Examples:
  # Standard removal
  curl -sL ci5.run | sh -s away

  # Border crossing (remove everything + wipe sensitive data)
  curl -sL ci5.run | sh -s away --wipe

  # Preview what would be removed
  curl -sL ci5.run | sh -s away --dry-run

What gets removed:
  • All installed corks (via Pure dependency-aware uninstall)
  • CI5 directories (/etc/ci5, /opt/ci5, /var/lib/ci5)
  • CI5 systemd services
  • CI5 log files

What --wipe additionally removes:
  • WireGuard/Mullvad configs and keys
  • Tailscale state
  • SSH keys
  • GPG keys  
  • Shell history

Note: For true security on flash storage (SD cards, SSDs), use full disk
encryption from the start. The --wipe flag is "best effort" on flash.
HELP
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || err "Must run as root"

# Check if CI5 is installed
if [ ! -d "$CI5_DIR" ] && [ ! -d "$CI5_OPT" ]; then
    info "CI5 is not installed on this system"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────

show_plan() {
    step "REMOVAL PLAN"
    
    # Count corks
    local cork_count=0
    if [ -d "$CI5_DIR/state/corks" ]; then
        cork_count=$(ls -1 "$CI5_DIR/state/corks" 2>/dev/null | wc -l)
    fi
    
    echo "Will remove:"
    printf "  ${M}◈${N} %d installed cork(s)\n" "$cork_count"
    [ -d "$CI5_DIR" ] && printf "  ${R}✗${N} %s\n" "$CI5_DIR"
    [ -d "$CI5_OPT" ] && printf "  ${R}✗${N} %s\n" "$CI5_OPT"
    [ -d "$CI5_VAR" ] && printf "  ${R}✗${N} %s\n" "$CI5_VAR"
    
    local svc_count=$(ls $CI5_SYSTEMD 2>/dev/null | wc -l)
    [ "$svc_count" -gt 0 ] && printf "  ${R}✗${N} %d systemd service(s)\n" "$svc_count"
    
    if $WIPE_MODE; then
        echo ""
        printf "  ${R}+ SECURE WIPE:${N}\n"
        printf "    ${R}✗${N} VPN configurations and keys\n"
        printf "    ${R}✗${N} SSH keys\n"
        printf "    ${R}✗${N} GPG keys\n"
        printf "    ${R}✗${N} Shell history\n"
    fi
    
    echo ""
}

confirm() {
    if $FORCE_MODE || $DRY_RUN; then
        return 0
    fi
    
    printf "${Y}This will completely remove CI5"
    $WIPE_MODE && printf " and sensitive data"
    printf ".${N}\n"
    
    local confirm_word="GOODBYE"
    $WIPE_MODE && confirm_word="WIPE"
    
    printf "Type ${B}${confirm_word}${N} to confirm: "
    read -r response
    
    [ "$response" = "$confirm_word" ] || { echo "Aborted."; exit 0; }
}

# ─────────────────────────────────────────────────────────────────────────────
# REMOVAL FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

remove_corks() {
    step "REMOVING INSTALLED CORKS"
    
    if [ ! -d "$CI5_DIR/state/corks" ]; then
        info "No corks to remove"
        return 0
    fi
    
    local corks=$(ls -1 "$CI5_DIR/state/corks" 2>/dev/null)
    
    if [ -z "$corks" ]; then
        info "No corks to remove"
        return 0
    fi
    
    # Use Pure if available, otherwise manual removal
    if [ -f "$CI5_DIR/../scripts/pure/pure.sh" ] || command -v ci5 >/dev/null 2>&1; then
        if $DRY_RUN; then
            dry "Would call: pure all"
        else
            # Try to source pure for its functions
            if [ -f "/etc/ci5/scripts/pure/pure.sh" ]; then
                # Execute pure in subshell
                sh /etc/ci5/scripts/pure/pure.sh all 2>/dev/null || true
            else
                # Manual cork removal
                for cork in $corks; do
                    info "Removing cork: $cork"
                    local cork_dir="$CI5_DIR/state/corks/$cork"
                    
                    # Run cork's uninstall script if exists
                    [ -x "$cork_dir/uninstall.sh" ] && "$cork_dir/uninstall.sh" 2>/dev/null || true
                    
                    # Docker cleanup from state
                    if [ -f "$cork_dir/docker.list" ]; then
                        while read -r type name; do
                            case "$type" in
                                container) docker rm -f "$name" 2>/dev/null || true ;;
                                volume)    docker volume rm "$name" 2>/dev/null || true ;;
                                network)   docker network rm "$name" 2>/dev/null || true ;;
                            esac
                        done < "$cork_dir/docker.list"
                    fi
                    
                    # Service cleanup
                    if [ -f "$cork_dir/services.list" ]; then
                        while read -r service; do
                            systemctl stop "$service" 2>/dev/null || true
                            systemctl disable "$service" 2>/dev/null || true
                            rm -f "/etc/systemd/system/$service"
                        done < "$cork_dir/services.list"
                    fi
                done
                systemctl daemon-reload 2>/dev/null || true
            fi
        fi
    fi
    
    info "Corks removed"
}

remove_infrastructure() {
    step "REMOVING CI5 INFRASTRUCTURE"
    
    # Stop and remove services
    for service in $CI5_SYSTEMD; do
        [ -f "$service" ] || continue
        local name=$(basename "$service")
        if $DRY_RUN; then
            dry "Would stop/remove: $name"
        else
            systemctl stop "$name" 2>/dev/null || true
            systemctl disable "$name" 2>/dev/null || true
            rm -f "$service"
        fi
    done
    
    $DRY_RUN || systemctl daemon-reload 2>/dev/null || true
    
    # Remove directories
    for dir in "$CI5_OPT" "$CI5_VAR"; do
        if [ -d "$dir" ]; then
            if $DRY_RUN; then
                dry "Would remove: $dir"
            else
                rm -rf "$dir"
                info "Removed: $dir"
            fi
        fi
    done
    
    # Handle /etc/ci5 based on --keep-state
    if [ -d "$CI5_DIR" ]; then
        if $KEEP_STATE; then
            info "Keeping state directory: $CI5_DIR"
        elif $DRY_RUN; then
            dry "Would remove: $CI5_DIR"
        else
            # Archive state before removal
            local archive="$HOME/ci5-state-$(date +%Y%m%d-%H%M%S).tar.gz"
            tar -czf "$archive" -C "$(dirname $CI5_DIR)" "$(basename $CI5_DIR)" 2>/dev/null || true
            info "State archived to: $archive"
            rm -rf "$CI5_DIR"
            info "Removed: $CI5_DIR"
        fi
    fi
    
    # Remove logs
    for log in $CI5_LOG; do
        if [ -f "$log" ]; then
            if $DRY_RUN; then
                dry "Would remove: $log"
            else
                rm -f "$log"
            fi
        fi
    done
    
    # Clean shell profiles
    if ! $DRY_RUN; then
        for profile in /root/.bashrc /root/.zshrc /home/*/.bashrc /home/*/.zshrc; do
            [ -f "$profile" ] || continue
            sed -i '/# CI5/d; /ci5\.run/d; /alias ci5=/d' "$profile" 2>/dev/null || true
        done
    fi
    
    # Clean Docker labels
    if command -v docker >/dev/null 2>&1; then
        if $DRY_RUN; then
            dry "Would remove CI5-labeled Docker resources"
        else
            docker ps -a --filter "label=ci5.managed=true" -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
            docker network ls --filter "label=ci5.managed=true" -q 2>/dev/null | xargs -r docker network rm 2>/dev/null || true
            docker volume ls --filter "label=ci5.managed=true" -q 2>/dev/null | xargs -r docker volume rm 2>/dev/null || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURE WIPE (--wipe mode)
# ─────────────────────────────────────────────────────────────────────────────

detect_storage_type() {
    local root_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
    local disk=$(echo "$root_dev" | sed 's/[0-9]*$//' | sed 's/p$//')
    local base=$(basename "$disk" 2>/dev/null)
    
    if [ -f "/sys/block/$base/queue/rotational" ]; then
        [ "$(cat /sys/block/$base/queue/rotational 2>/dev/null)" = "0" ] && echo "flash" || echo "hdd"
    else
        echo "flash"  # Assume flash (safer for SD cards)
    fi
}

secure_delete() {
    local target="$1"
    local storage=$(detect_storage_type)
    
    [ -e "$target" ] || return 0
    
    if $DRY_RUN; then
        dry "Would securely delete: $target"
        return 0
    fi
    
    if [ -f "$target" ]; then
        local size=$(stat -c%s "$target" 2>/dev/null || echo "0")
        
        # For flash: overwrite with random (best effort)
        # For HDD: shred works properly
        if [ "$storage" = "hdd" ]; then
            shred -u -z -n 3 "$target" 2>/dev/null || rm -f "$target"
        else
            [ "$size" -gt 0 ] && dd if=/dev/urandom of="$target" bs=1 count="$size" conv=notrunc 2>/dev/null || true
            sync
            rm -f "$target"
        fi
    elif [ -d "$target" ]; then
        find "$target" -type f 2>/dev/null | while read -r f; do
            secure_delete "$f"
        done
        rm -rf "$target"
    fi
}

wipe_sensitive() {
    step "SECURE WIPE: SENSITIVE DATA"
    
    local storage=$(detect_storage_type)
    warn "Storage type: $storage"
    [ "$storage" = "flash" ] && warn "Flash storage - using random overwrite (best effort)"
    
    # Stop sensitive services first
    for svc in wg-quick@mullvad wg-quick@wg0 tailscaled; do
        systemctl stop "$svc" 2>/dev/null || true
    done
    pkill -9 ssh-agent 2>/dev/null || true
    pkill -9 gpg-agent 2>/dev/null || true
    
    # Wipe sensitive paths
    for pattern in $WIPE_PATHS; do
        for target in $pattern; do
            [ -e "$target" ] || continue
            info "Wiping: $target"
            secure_delete "$target"
        done
    done
    
    # Clear memory caches
    if ! $DRY_RUN; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        # Clear swap if present
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            swapoff -a 2>/dev/null || true
            swapon -a 2>/dev/null || true
        fi
        
        # TRIM for flash storage
        [ "$storage" = "flash" ] && fstrim -av 2>/dev/null || true
    fi
    
    info "Sensitive data wiped"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    if $WIPE_MODE; then
    echo "║           CI5 AWAY — Complete Removal + Secure Wipe               ║"
    else
    echo "║              CI5 AWAY — Complete Ecosystem Removal                ║"
    fi
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    $DRY_RUN && warn "DRY RUN MODE - No changes will be made"
    
    show_plan
    confirm
    
    remove_corks
    remove_infrastructure
    
    $WIPE_MODE && wipe_sensitive
    
    if $DRY_RUN; then
        echo ""
        info "Dry run complete. No changes were made."
    else
        step "REMOVAL COMPLETE"
        
        info "CI5 has been completely removed."
        echo ""
        echo "To reinstall: curl -sL ci5.run | sh"
        echo ""
        
        if $WIPE_MODE && ! $NO_REBOOT; then
            warn "System will reboot in 5 seconds (Ctrl+C to cancel)..."
            sleep 5
            reboot
        fi
    fi
}

main "$@"
