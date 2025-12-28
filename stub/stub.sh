#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX BOOTSTRAP STUB v1.2                                          ║
# ║  https://github.com/dreamswag/ci5                                         ║
# ║                                                                           ║
# ║  TRUST ANCHOR & SECURE PIPING GATEWAY                                     ║
# ║  Verifies all signatures against embedded public key before execution.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_BASE="https://ci5.run"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
CI5_VERSION="1.2.0"

# [CRITICAL] REPLACE THIS BLOCK WITH YOUR ACTUAL GENERATED PUBLIC KEY
CI5_PUBKEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
REPLACE_WITH_ACTUAL_KEY_ON_GENERATION
-----END PUBLIC KEY-----"

# Colors (disabled if not tty)
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
    R=''; G=''; Y=''; C=''; B=''; N=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# CORE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
die() { printf "${R}ERROR: %s${N}\n" "$1" >&2; exit 1; }
info() { printf "${G}→${N} %s\n" "$1"; }
warn() { printf "${Y}⚠${N} %s\n" "$1"; }

verify_signature() {
    local file="$1"
    local sig="$2"
    
    if [ ! -f "$file" ] || [ ! -f "$sig" ]; then
        return 1
    fi
    
    echo "$CI5_PUBKEY" > /tmp/ci5.pub
    if openssl dgst -sha256 -verify /tmp/ci5.pub -signature "$sig" "$file" >/dev/null 2>&1; then
        rm -f /tmp/ci5.pub
        return 0
    else
        rm -f /tmp/ci5.pub
        return 1
    fi
}

download_verified() {
    local name="$1"
    local url="$2"
    local dest="$3"
    
    info "Downloading $name..."
    curl -fsSL "$url" -o "$dest" || die "Failed to download $name"
    curl -fsSL "${url}.sig" -o "${dest}.sig" || die "Failed to download $name signature"
    
    info "Verifying $name signature..."
    if ! verify_signature "$dest" "${dest}.sig"; then
        rm -f "$dest" "${dest}.sig"
        die "SIGNATURE VERIFICATION FAILED for $name - possible tampering detected"
    fi
    
    printf "${G}✓${N} %s verified\n" "$name"
    rm -f "${dest}.sig"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND RESOLVER (SECURE PIPING MAP)
# ─────────────────────────────────────────────────────────────────────────────
resolve_command() {
    case "$1" in
        # 🚀 BOOTSTRAP
        "free")         echo "scripts/install-recommended.sh" ;;
        "4evr")         echo "scripts/install-minimal.sh" ;;
        "1314")         echo "scripts/install-custom.sh" ;;
        
        # 🛡️ RECOVERY
        "heal")         echo "emergency/self_heal.sh" ;;
        "rescue")       echo "emergency/force_public_dns.sh" ;;
        "status")       echo "scripts/diagnostics/quick_check.sh" ;;
        
        # ⚙️ SYSTEM
        "paranoia")     echo "scripts/security/paranoia_toggle.sh" ;;
        "backup")       echo "scripts/system/backup.sh" ;;
        "update")       echo "scripts/system/update.sh" ;;
        
        # 🔧 LOCAL
        "self")         echo "core/bone_marrow.sh" ;;
        "fast")         echo "scripts/diagnostics/speed_test.sh" ;;
        "true")         echo "core/validate.sh" ;;
        
        # 🗑️ MAINTENANCE
        "away")         echo "scripts/maintenance/uninstall-all.sh" ;;
        "pure")         echo "scripts/maintenance/partial-uninstall.sh" ;;
        
        # 🔐 VPN & PRIVACY
        "mullvad")      echo "scripts/vpn/setup_mullvad.sh" ;;
        "tailscale")    echo "scripts/vpn/setup_tailscale.sh" ;;
        "hybrid")       echo "scripts/vpn/setup_hybrid.sh" ;;
        
        # ✈️ TRAVEL
        "travel")       echo "scripts/travel/captive-portal-bypass.sh" ;;
        "focus")        echo "scripts/travel/focus_mode.sh" ;;
        "wipe")         echo "scripts/security/secure_wipe.sh" ;;
        
        # 📡 MONITORING
        "alert")        echo "scripts/monitor/alert.sh" ;;
        "ddns")         echo "scripts/monitor/ddns.sh" ;;
        
        *)              echo "" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU UI (FALLBACK)
# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    cat << 'BANNER'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║              PHOENIX PROTOCOL — Pi 5 Router Bootstrap             ║
    ╚═══════════════════════════════════════════════════════════════════╝
BANNER
    printf "\n"
    printf "    ${B}[1] FREE (Recommended)${N}        ${G}← Full Stack${N}\n"
    printf "    ${B}[2] 4EVR (Minimal)${N}            Lite Stack\n"
    printf "    ${B}[3] 1314 (Custom)${N}             Customise\n\n"
    printf "    ─────────────────────────────────────────────────────────\n"
    printf "    To use specific modules, pipe commands like:\n"
    printf "    ${C}curl -sL ci5.run | sh -s mullvad${N}\n\n"
}

run_recommended() {
    download_verified "installer" "${CI5_BASE}/scripts/install-recommended.sh" "/tmp/ci5-install.sh"
    chmod +x /tmp/ci5-install.sh
    exec /tmp/ci5-install.sh
}

run_minimal() {
    download_verified "installer" "${CI5_BASE}/scripts/install-minimal.sh" "/tmp/ci5-install.sh"
    chmod +x /tmp/ci5-install.sh
    exec /tmp/ci5-install.sh
}

run_custom() {
    download_verified "installer" "${CI5_BASE}/scripts/install-custom.sh" "/tmp/ci5-install.sh"
    chmod +x /tmp/ci5-install.sh
    exec /tmp/ci5-install.sh
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
check_requirements() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root"
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v openssl >/dev/null 2>&1 || die "openssl not found"
}

main() {
    check_requirements
    
    # [SECURE PIPING LOGIC]
    if [ -n "$1" ]; then
        local target_script=$(resolve_command "$1")
        
        if [ -n "$target_script" ]; then
            info "Phoenix Protocol: Fetching secure module [$1]..."
            download_verified "$1" "${CI5_BASE}/${target_script}" "/tmp/ci5-exec.sh"
            chmod +x /tmp/ci5-exec.sh
            shift # Remove command name, pass remaining args
            exec /tmp/ci5-exec.sh "$@"
        else
            die "Unknown command: $1. Run without arguments for menu."
        fi
        exit 0
    fi
    
    # Interactive Menu
    while true; do
        show_menu
        printf "    Select [1-3]: "
        read -r choice
        case "$choice" in
            1|"")  run_recommended ;;
            2)     run_minimal ;;
            3)     run_custom ;;
            q|Q)   exit 0 ;;
            *)     warn "Invalid option" ;;
        esac
    done
}

main "$@"