#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# Ci5 Offline Bundle Generator (v7.4-RC-1)
# ══════════════════════════════════════════════════════════════════════════════
# Downloads all on-demand scripts for offline/air-gapped operation.
# After running: no more curl pipes needed, everything runs locally.
# ══════════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_BASE="${CI5_BASE:-/opt/ci5}"
[ ! -d "$CI5_BASE" ] && CI5_BASE="/root/ci5"

OFFLINE_DIR="${CI5_BASE}/offline"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
CI5_HOST_RAW="https://raw.githubusercontent.com/dreamswag/ci5.host/main"
CI5_WRAPPER="/usr/bin/ci5"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "${RED}[✗]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT MANIFEST (all on-demand scripts)
# ─────────────────────────────────────────────────────────────────────────────
# Format: "route:path"
SCRIPTS="
mullvad:scripts/vpn/setup_mullvad.sh
tailscale:scripts/vpn/setup_tailscale.sh
hybrid:scripts/vpn/routing_policy_hybrid.sh
travel:scripts/travel/hotel_bypass.sh
focus:scripts/productivity/temp_block.sh
wipe:scripts/privacy/deep_clean.sh
alert:scripts/monitor/log_to_ntfy.sh
ddns:scripts/monitor/ddns_monitor.sh
paranoia:scripts/security/paranoia_toggle.sh
backup:scripts/system/config_backup.sh
update:scripts/system/safe_update.sh
pure:scripts/maintenance/partial_uninstall.sh
away:scripts/maintenance/uninstall.sh
status:scripts/diagnostics/quick_check.sh
fast:scripts/diagnostics/speed_test.sh
"

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
┌──────────────────────────────────────────────────────────────────────────────┐
│  Ci5 Offline Bundle Generator                                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Downloads all ci5.run scripts for offline/air-gapped operation.             │
│  After running, use `ci5 <command>` instead of `curl ci5.run/<command>`.     │
│                                                                              │
│  USAGE:                                                                      │
│    curl ci5.run/archive | sh              # Download all scripts             │
│    curl ci5.run/archive | sh -s verify    # Verify existing bundle           │
│    curl ci5.run/archive | sh -s remove    # Remove offline bundle            │
│                                                                              │
│  AFTER INSTALL:                                                              │
│    ci5 mullvad setup -c /tmp/mullvad.conf  # Runs from local cache           │
│    ci5 paranoia enable                     # No network needed               │
│    ci5 status                              # All commands work offline       │
│                                                                              │
│  BUNDLE SIZE: ~150-200KB (tiny!)                                             │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD SCRIPTS
# ─────────────────────────────────────────────────────────────────────────────
download_scripts() {
    log_info "Creating offline bundle directory..."
    mkdir -p "$OFFLINE_DIR/scripts"
    
    local TOTAL=0
    local SUCCESS=0
    local FAILED=""
    
    log_info "Downloading scripts from ci5 repository..."
    echo ""
    
    for entry in $SCRIPTS; do
        [ -z "$entry" ] && continue
        
        local ROUTE=$(echo "$entry" | cut -d':' -f1)
        local PATH=$(echo "$entry" | cut -d':' -f2)
        local DIR=$(dirname "$PATH")
        local FILE=$(basename "$PATH")
        
        TOTAL=$((TOTAL + 1))
        
        mkdir -p "$OFFLINE_DIR/$DIR"
        
        printf "    %-12s " "/$ROUTE"
        
        if curl -fsSL "${CI5_RAW}/${PATH}" -o "$OFFLINE_DIR/$PATH" 2>/dev/null; then
            chmod +x "$OFFLINE_DIR/$PATH"
            echo -e "${GREEN}✓${NC}"
            SUCCESS=$((SUCCESS + 1))
        else
            echo -e "${RED}✗${NC}"
            FAILED="$FAILED $ROUTE"
        fi
    done
    
    # Download audit.sh from ci5.host
    echo ""
    log_info "Downloading audit script from ci5.host..."
    printf "    %-12s " "/audit"
    if curl -fsSL "${CI5_HOST_RAW}/audit.sh" -o "$OFFLINE_DIR/audit.sh" 2>/dev/null; then
        chmod +x "$OFFLINE_DIR/audit.sh"
        echo -e "${GREEN}✓${NC}"
        SUCCESS=$((SUCCESS + 1))
        TOTAL=$((TOTAL + 1))
    else
        echo -e "${RED}✗${NC}"
        FAILED="$FAILED audit"
        TOTAL=$((TOTAL + 1))
    fi
    
    echo ""
    log_ok "Downloaded $SUCCESS/$TOTAL scripts"
    
    if [ -n "$FAILED" ]; then
        log_warn "Failed to download:$FAILED"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CREATE CI5 WRAPPER COMMAND
# ─────────────────────────────────────────────────────────────────────────────
install_wrapper() {
    log_info "Installing ci5 command wrapper..."
    
    cat > "$CI5_WRAPPER" << 'WRAPPER'
#!/bin/sh
# Ci5 Command Wrapper - Offline-first execution
# Usage: ci5 <command> [args...]

CI5_BASE="${CI5_BASE:-/opt/ci5}"
[ ! -d "$CI5_BASE" ] && CI5_BASE="/root/ci5"
OFFLINE_DIR="${CI5_BASE}/offline"

# Command-to-path mapping
get_script_path() {
    case "$1" in
        mullvad)   echo "scripts/vpn/setup_mullvad.sh" ;;
        tailscale) echo "scripts/vpn/setup_tailscale.sh" ;;
        hybrid)    echo "scripts/vpn/routing_policy_hybrid.sh" ;;
        travel)    echo "scripts/travel/hotel_bypass.sh" ;;
        focus)     echo "scripts/productivity/temp_block.sh" ;;
        wipe)      echo "scripts/privacy/deep_clean.sh" ;;
        alert)     echo "scripts/monitor/log_to_ntfy.sh" ;;
        ddns)      echo "scripts/monitor/ddns_monitor.sh" ;;
        paranoia)  echo "scripts/security/paranoia_toggle.sh" ;;
        backup)    echo "scripts/system/config_backup.sh" ;;
        update)    echo "scripts/system/safe_update.sh" ;;
        pure)      echo "scripts/maintenance/partial_uninstall.sh" ;;
        away)      echo "scripts/maintenance/uninstall.sh" ;;
        status)    echo "scripts/diagnostics/quick_check.sh" ;;
        fast)      echo "scripts/diagnostics/speed_test.sh" ;;
        audit)     echo "audit.sh" ;;
        # Emergency scripts (always local in main install)
        heal)      echo "../emergency/self_heal.sh" ;;
        rescue)    echo "../emergency/force_public_dns.sh" ;;
        sos)       echo "../emergency/emergency_recovery.sh" ;;
        # Validation (in core)
        true)      echo "../core/validate.sh" ;;
        *)         echo "" ;;
    esac
}

# Show help
if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
    echo ""
    echo "Ci5 Command Line Interface"
    echo "────────────────────────────"
    echo ""
    echo "USAGE: ci5 <command> [options]"
    echo ""
    echo "COMMANDS:"
    echo "  mullvad     Mullvad VPN setup with VLAN routing & failover"
    echo "  tailscale   Tailscale mesh network setup"
    echo "  hybrid      Split tunnel routing (VPN + WAN)"
    echo "  paranoia    IDS dead-man switch toggle"
    echo "  status      System status report"
    echo "  fast        Speed test & SQM tuning"
    echo "  backup      Export encrypted configuration"
    echo "  travel      Hotel/captive portal bypass"
    echo "  focus       Temporary domain blocking"
    echo "  wipe        Secure data destruction"
    echo "  alert       Push notification setup"
    echo "  ddns        Dynamic DNS configuration"
    echo "  update      Check for ci5 updates"
    echo "  audit       Cork security audit (CURE)"
    echo ""
    echo "EMERGENCY (always available offline):"
    echo "  heal        Self-repair from manifest"
    echo "  rescue      Force public DNS bypass"
    echo "  sos         Emergency recovery"
    echo ""
    echo "Each command supports --help for detailed usage."
    echo ""
    exit 0
fi

CMD="$1"
shift

SCRIPT_PATH=$(get_script_path "$CMD")

if [ -z "$SCRIPT_PATH" ]; then
    echo "Unknown command: $CMD"
    echo "Run 'ci5 help' for available commands."
    exit 1
fi

# Check offline bundle first
if [ -f "$OFFLINE_DIR/.enabled" ] && [ -f "$OFFLINE_DIR/$SCRIPT_PATH" ]; then
    exec "$OFFLINE_DIR/$SCRIPT_PATH" "$@"
fi

# Check if script exists in main install (emergency/core scripts)
if [ -f "$CI5_BASE/$SCRIPT_PATH" ]; then
    exec "$CI5_BASE/$SCRIPT_PATH" "$@"
fi

# Fallback: fetch from network
echo "Script not cached locally, fetching from ci5.run..."
ROUTE="$CMD"
exec curl -fsSL "https://ci5.run/$ROUTE" | sh -s -- "$@"
WRAPPER

    chmod +x "$CI5_WRAPPER"
    log_ok "Installed: $CI5_WRAPPER"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENABLE OFFLINE MODE
# ─────────────────────────────────────────────────────────────────────────────
enable_offline() {
    touch "$OFFLINE_DIR/.enabled"
    
    # Create version file
    echo "$(date -Iseconds)" > "$OFFLINE_DIR/.downloaded"
    
    log_ok "Offline mode enabled"
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY BUNDLE
# ─────────────────────────────────────────────────────────────────────────────
verify_bundle() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Ci5 Offline Bundle Verification                                │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    if [ ! -d "$OFFLINE_DIR" ]; then
        log_err "Offline bundle not found"
        echo "    Run: curl ci5.run/archive | sh"
        exit 1
    fi
    
    local TOTAL=0
    local FOUND=0
    
    for entry in $SCRIPTS; do
        [ -z "$entry" ] && continue
        
        local ROUTE=$(echo "$entry" | cut -d':' -f1)
        local PATH=$(echo "$entry" | cut -d':' -f2)
        
        TOTAL=$((TOTAL + 1))
        
        printf "    %-12s " "/$ROUTE"
        
        if [ -f "$OFFLINE_DIR/$PATH" ]; then
            echo -e "${GREEN}✓ present${NC}"
            FOUND=$((FOUND + 1))
        else
            echo -e "${RED}✗ missing${NC}"
        fi
    done
    
    # Check audit.sh
    printf "    %-12s " "/audit"
    if [ -f "$OFFLINE_DIR/audit.sh" ]; then
        echo -e "${GREEN}✓ present${NC}"
        FOUND=$((FOUND + 1))
    else
        echo -e "${RED}✗ missing${NC}"
    fi
    TOTAL=$((TOTAL + 1))
    
    echo ""
    
    if [ "$FOUND" -eq "$TOTAL" ]; then
        log_ok "Bundle complete: $FOUND/$TOTAL scripts"
    else
        log_warn "Bundle incomplete: $FOUND/$TOTAL scripts"
        echo "    Run: curl ci5.run/archive | sh  (to update)"
    fi
    
    # Check if enabled
    echo ""
    if [ -f "$OFFLINE_DIR/.enabled" ]; then
        echo -e "    Offline mode: ${GREEN}ENABLED${NC}"
    else
        echo -e "    Offline mode: ${YELLOW}DISABLED${NC}"
        echo "    Enable with: touch $OFFLINE_DIR/.enabled"
    fi
    
    # Show download date
    if [ -f "$OFFLINE_DIR/.downloaded" ]; then
        echo "    Downloaded:   $(cat "$OFFLINE_DIR/.downloaded")"
    fi
    
    # Show bundle size
    local SIZE=$(du -sh "$OFFLINE_DIR" 2>/dev/null | cut -f1)
    echo "    Bundle size:  $SIZE"
    
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# REMOVE BUNDLE
# ─────────────────────────────────────────────────────────────────────────────
remove_bundle() {
    log_warn "Removing offline bundle..."
    
    rm -rf "$OFFLINE_DIR"
    rm -f "$CI5_WRAPPER"
    
    log_ok "Offline bundle removed"
    echo "    Commands will now fetch from ci5.run"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local CMD="${1:-download}"
    
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Ci5 Offline Bundle Generator (v7.4-RC-1)                       │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    case "$CMD" in
        download|install)
            download_scripts
            install_wrapper
            enable_offline
            
            echo ""
            log_ok "Offline bundle ready!"
            echo ""
            echo "    Usage:  ci5 <command> [options]"
            echo "    Help:   ci5 help"
            echo "    Verify: ci5 status"
            echo ""
            echo "    All ci5.run commands now work offline."
            echo ""
            ;;
        verify|check|status)
            verify_bundle
            ;;
        remove|uninstall)
            remove_bundle
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_err "Unknown command: $CMD"
            usage
            ;;
    esac
}

main "$@"
