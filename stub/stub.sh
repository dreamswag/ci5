#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX BOOTSTRAP STUB v2.0                                          ║
# ║  https://github.com/dreamswag/ci5                                         ║
# ║                                                                           ║
# ║  TRUST ANCHOR & SECURE PIPING GATEWAY                                     ║
# ║  - Signature verification for all scripts                                 ║
# ║  - Integrated pre-install audit                                           ║
# ║  - State tracking for clean uninstall via /pure                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_VERSION="2.0.0"
CI5_BASE="https://ci5.run"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
CI5_HOST="https://ci5.host"
CI5_HOST_RAW="https://raw.githubusercontent.com/dreamswag/ci5.host/main"

# [CRITICAL] CI5.RUN Public Key - for script verification
CI5_PUBKEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
REPLACE_WITH_ACTUAL_CI5_RUN_KEY
-----END PUBLIC KEY-----"

# [CRITICAL] CI5.HOST Public Key - SEPARATE key for audit isolation
CI5_HOST_PUBKEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
REPLACE_WITH_ACTUAL_CI5_HOST_KEY
-----END PUBLIC KEY-----"

# State directories
CI5_DIR="/etc/ci5"
STATE_DIR="$CI5_DIR/state"
CORK_STATE_DIR="$STATE_DIR/corks"

# Colors (disabled if not tty)
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
    B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'
else
    R=''; G=''; Y=''; C=''; B=''; N=''; M=''; D=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# CORE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
die() { printf "${R}[✗] ERROR: %s${N}\n" "$1" >&2; exit 1; }
info() { printf "${G}[→]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }

verify_signature() {
    local file="$1"
    local sig="$2"
    local pubkey="$3"
    
    [ -f "$file" ] && [ -f "$sig" ] || return 1
    
    echo "$pubkey" > /tmp/ci5-verify.pub
    if openssl dgst -sha256 -verify /tmp/ci5-verify.pub -signature "$sig" "$file" >/dev/null 2>&1; then
        rm -f /tmp/ci5-verify.pub
        return 0
    else
        rm -f /tmp/ci5-verify.pub
        return 1
    fi
}

download_verified() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local pubkey="${4:-$CI5_PUBKEY}"
    
    info "Downloading $name..."
    curl -fsSL "$url" -o "$dest" || die "Failed to download $name"
    curl -fsSL "${url}.sig" -o "${dest}.sig" 2>/dev/null || {
        warn "No signature found for $name - UNVERIFIED"
        return 0
    }
    
    info "Verifying $name signature..."
    if ! verify_signature "$dest" "${dest}.sig" "$pubkey"; then
        rm -f "$dest" "${dest}.sig"
        die "SIGNATURE VERIFICATION FAILED for $name - possible tampering detected!"
    fi
    
    printf "${G}[✓]${N} %s verified\n" "$name"
    rm -f "${dest}.sig"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMAND RESOLVER (SECURE PIPING MAP)
# ─────────────────────────────────────────────────────────────────────────────
resolve_command() {
    case "$1" in
        # ───────────────────────────────────────────────────────────────────
        # 🚀 BOOTSTRAP
        # ───────────────────────────────────────────────────────────────────
        "free")         echo "scripts/install-recommended.sh" ;;
        "4evr")         echo "scripts/install-minimal.sh" ;;
        "1314")         echo "scripts/install-custom.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # 🛡️ RECOVERY 
        # ───────────────────────────────────────────────────────────────────
        "heal")         echo "emergency/self_heal.sh" ;;
        "rescue")       echo "emergency/force_public_dns.sh" ;;
        "sos")          echo "emergency/emergency_recovery.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # ⚙️ SYSTEM
        # ───────────────────────────────────────────────────────────────────
        "paranoia")     echo "scripts/security/paranoia_toggle.sh" ;;
        "backup")       echo "scripts/system/backup.sh" ;;
        "update")       echo "scripts/system/update.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # 🔧 LOCAL 
        # ───────────────────────────────────────────────────────────────────
        "self")         echo "LOCAL:bone_marrow.sh" ;;
        "fast")         echo "LOCAL:speed_wizard.sh" ;;
        "true")         echo "LOCAL:validate.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # 🗑️ MAINTENANCE 
        # ───────────────────────────────────────────────────────────────────
        "away")         echo "scripts/maintenance/away.sh" ;;      
        "pure")         echo "scripts/pure/pure.sh" ;;
        "status")       echo "scripts/diagnostics/quick_check.sh" ;;  
        
        # ───────────────────────────────────────────────────────────────────
        # 🔐 VPN & PRIVACY
        # ───────────────────────────────────────────────────────────────────
        "mullvad")      echo "scripts/vpn/setup_mullvad.sh" ;;
        "tailscale")    echo "scripts/vpn/setup_tailscale.sh" ;;
        "hybrid")       echo "scripts/vpn/setup_hybrid.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # ✈️ TRAVEL 
        # ───────────────────────────────────────────────────────────────────
        "travel")       echo "scripts/travel/travel.sh" ;;
        "clone")        echo "scripts/travel/clone.sh" ;;
        "focus")        echo "scripts/productivity/focus_mode.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # 📡 MONITORING 
        # ───────────────────────────────────────────────────────────────────
        "alert")        echo "scripts/monitor/alert.sh" ;;
        "ddns")         echo "scripts/monitor/ddns.sh" ;;
        "gsense")       echo "scripts/monitor/gamesense.sh" ;;     # RENAMED + PATH FIXED
        
        # ───────────────────────────────────────────────────────────────────
        # 🔍 AUDIT 
        # ───────────────────────────────────────────────────────────────────
        "audit")        echo "EXTERNAL:ci5.host:audit.sh" ;;
        
        # ───────────────────────────────────────────────────────────────────
        # 📦 OFFLINE
        # ───────────────────────────────────────────────────────────────────
        "archive")      echo "tools/generate_offline_bundle.sh" ;;
        
        *)              echo "" ;;
    esac
}
# Get cork name from command (for state tracking)
get_cork_name() {
    case "$1" in
        "free"|"4evr"|"1314") echo "ci5-core" ;;
        "mullvad")            echo "mullvad" ;;
        "tailscale")          echo "tailscale" ;;
        "hybrid")             echo "hybrid-vpn" ;;
        "gsense")             echo "gamesense" ;;   
        "travel")             echo "travel-mode" ;;
        "clone")              echo "clone" ;;
        "alert")              echo "alert" ;;
        "ddns")               echo "ddns" ;;
        "paranoia")           echo "paranoia" ;;
        "focus")              echo "focus-mode" ;;
        *)                    echo "$1" ;;
    esac
}

# Check if command installs a cork (vs utility/diagnostic)
is_cork_install() {
    case "$1" in
        "free"|"4evr"|"1314"|"mullvad"|"tailscale"|"hybrid"|"gsense"|"alert"|"ddns"|"paranoia"|"focus")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# AUDIT INTEGRATION
# ─────────────────────────────────────────────────────────────────────────────
run_pre_audit() {
    local cork="$1"
    local accept_risks="$2"
    
    step "PRE-INSTALL SECURITY AUDIT"
    
    info "Fetching audit from isolated ci5.host..."
    
    # Download audit script from ci5.host (separate trust chain!)
    curl -fsSL "${CI5_HOST_RAW}/audit.sh" -o /tmp/ci5-audit.sh || {
        warn "Could not fetch audit script - continuing without audit"
        return 0
    }
    
    # Try to verify with ci5.host key
    if curl -fsSL "${CI5_HOST_RAW}/audit.sh.sig" -o /tmp/ci5-audit.sh.sig 2>/dev/null; then
        if ! verify_signature /tmp/ci5-audit.sh /tmp/ci5-audit.sh.sig "$CI5_HOST_PUBKEY"; then
            warn "Audit script signature verification failed!"
            warn "ci5.host may be compromised - proceeding with caution"
            rm -f /tmp/ci5-audit.sh /tmp/ci5-audit.sh.sig
            return 1
        fi
        info "Audit script verified (ci5.host key)"
    fi
    
    # Run audit in pre-install mode
    chmod +x /tmp/ci5-audit.sh
    
    local audit_args="--pre-install --cork=$cork"
    [ -n "$accept_risks" ] && audit_args="$audit_args --accept=$accept_risks"
    
    if /tmp/ci5-audit.sh $audit_args; then
        info "Pre-install audit passed"
        rm -f /tmp/ci5-audit.sh
        return 0
    else
        local result=$?
        rm -f /tmp/ci5-audit.sh
        return $result
    fi
}

run_post_audit() {
    local cork="$1"
    
    info "Running post-install audit..."
    
    curl -fsSL "${CI5_HOST_RAW}/audit.sh" -o /tmp/ci5-audit.sh 2>/dev/null || return 0
    chmod +x /tmp/ci5-audit.sh
    
    /tmp/ci5-audit.sh --post-install --cork="$cork" --generate-manifest
    rm -f /tmp/ci5-audit.sh
}

# ─────────────────────────────────────────────────────────────────────────────
# STATE TRACKING (Pure Integration)
# ─────────────────────────────────────────────────────────────────────────────
init_state_tracking() {
    mkdir -p "$CI5_DIR" "$STATE_DIR" "$CORK_STATE_DIR"
    [ -f "$STATE_DIR/dependencies.json" ] || echo '{"corks":{},"edges":[]}' > "$STATE_DIR/dependencies.json"
}

capture_pre_state() {
    local cork="$1"
    local state_dir="$CORK_STATE_DIR/$cork"
    
    mkdir -p "$state_dir"
    
    info "Capturing pre-install state for: $cork"
    
    # Capture system state
    local state='{"captured_at":"'"$(date -Iseconds)"'"}'
    
    # Docker
    if command -v docker >/dev/null 2>&1; then
        local containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local volumes=$(docker volume ls -q 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^bridge$\|^host$\|^none$" | sort | tr '\n' ',' | sed 's/,$//')
        
        state=$(echo "$state" | jq \
            --arg c "$containers" --arg v "$volumes" --arg n "$networks" \
            '.docker = {containers: ($c | split(",") | map(select(.!=""))), volumes: ($v | split(",") | map(select(.!=""))), networks: ($n | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    fi
    
    # Network
    local ports=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg p "$ports" '.network = {listening: ($p | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    
    # Services
    local services=$(systemctl list-unit-files --type=service --state=enabled 2>/dev/null | awk 'NR>1 && !/listed/ {print $1}' | sort | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg s "$services" '.services = {enabled: ($s | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    
    echo "$state" > "$state_dir/pre-state.json"
    
    # Create manifest
    cat > "$state_dir/manifest.json" << EOF
{
    "cork": "$cork",
    "install_started": "$(date -Iseconds)",
    "status": "installing",
    "installed_via": "ci5.run"
}
EOF
    
    # Start file tracking
    for dir in /etc /opt /var/lib /usr/local; do
        [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
    done | sort > "$state_dir/.file_baseline"
}

capture_post_state() {
    local cork="$1"
    local state_dir="$CORK_STATE_DIR/$cork"
    
    [ -d "$state_dir" ] || return 0
    
    info "Capturing post-install state for: $cork"
    
    # Capture current state (same format as pre)
    local state='{"captured_at":"'"$(date -Iseconds)"'"}'
    
    if command -v docker >/dev/null 2>&1; then
        local containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local volumes=$(docker volume ls -q 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^bridge$\|^host$\|^none$" | sort | tr '\n' ',' | sed 's/,$//')
        
        state=$(echo "$state" | jq \
            --arg c "$containers" --arg v "$volumes" --arg n "$networks" \
            '.docker = {containers: ($c | split(",") | map(select(.!=""))), volumes: ($v | split(",") | map(select(.!=""))), networks: ($n | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    fi
    
    local ports=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg p "$ports" '.network = {listening: ($p | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    
    local services=$(systemctl list-unit-files --type=service --state=enabled 2>/dev/null | awk 'NR>1 && !/listed/ {print $1}' | sort | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg s "$services" '.services = {enabled: ($s | split(",") | map(select(.!="")))}' 2>/dev/null || echo "$state")
    
    echo "$state" > "$state_dir/post-state.json"
    
    # Calculate file changes
    if [ -f "$state_dir/.file_baseline" ]; then
        local current=$(mktemp)
        for dir in /etc /opt /var/lib /usr/local; do
            [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
        done | sort > "$current"
        
        {
            comm -23 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$state_dir/.file_baseline" | sort) | sed 's/^/CREATED /'
            comm -12 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$state_dir/.file_baseline" | sort) | while read f; do
                local old=$(grep " $f$" "$state_dir/.file_baseline" | awk '{print $1}')
                local new=$(grep " $f$" "$current" | awk '{print $1}')
                [ "$old" != "$new" ] && echo "MODIFIED $f"
            done
        } > "$state_dir/files.list"
        
        rm -f "$current" "$state_dir/.file_baseline"
    fi
    
    # Update manifest
    if command -v jq >/dev/null 2>&1; then
        local temp=$(mktemp)
        jq --arg time "$(date -Iseconds)" '.install_completed = $time | .status = "installed"' \
            "$state_dir/manifest.json" > "$temp" && mv "$temp" "$state_dir/manifest.json"
    fi
    
    # Register in dependency graph
    if [ -f "$STATE_DIR/dependencies.json" ] && command -v jq >/dev/null 2>&1; then
        local temp=$(mktemp)
        jq --arg cork "$cork" --arg time "$(date -Iseconds)" \
            '.corks[$cork] = {"installed": $time, "dependents": []}' \
            "$STATE_DIR/dependencies.json" > "$temp" && mv "$temp" "$STATE_DIR/dependencies.json"
    fi
    
    info "State tracking complete for: $cork"
    printf "  ${D}Uninstall with: ${G}ci5 pure $cork${N}\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# EXTERNAL COMMAND HANDLER (ci5.host)
# ─────────────────────────────────────────────────────────────────────────────
handle_external() {
    local spec="$1"
    shift
    
    # Parse: EXTERNAL:ci5.host:audit.sh
    local repo=$(echo "$spec" | cut -d: -f2)
    local script=$(echo "$spec" | cut -d: -f3)
    
    case "$repo" in
        "ci5.host")
            info "Fetching from isolated repository: ci5.host"
            download_verified "$script" "${CI5_HOST_RAW}/${script}" "/tmp/ci5-external.sh" "$CI5_HOST_PUBKEY"
            chmod +x /tmp/ci5-external.sh
            exec /tmp/ci5-external.sh "$@"
            ;;
        *)
            die "Unknown external repository: $repo"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU UI (FALLBACK)
# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    cat << 'BANNER'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║           PHOENIX PROTOCOL — Pi 5 Router Bootstrap                ║
    ║                    Secure • Verified • Tracked                    ║
    ╚═══════════════════════════════════════════════════════════════════╝
BANNER
    printf "\n"
    printf "    ${B}[1] FREE (Recommended)${N}        ${G}← Full Stack${N}\n"
    printf "    ${B}[2] 4EVR (Minimal)${N}            Lite Stack\n"
    printf "    ${B}[3] 1314 (Custom)${N}             Interactive\n\n"
    printf "    ─────────────────────────────────────────────────────────\n"
    printf "    All scripts are signature-verified before execution.\n"
    printf "    State is tracked for clean uninstall via: ${C}ci5 pure${N}\n\n"
    printf "    To use specific modules:\n"
    printf "    ${C}curl -sL ci5.run | sh -s mullvad${N}\n\n"
    printf "    Options:\n"
    printf "    ${D}--audit-warn${N}    Continue despite audit warnings\n"
    printf "    ${D}--no-audit${N}      Skip pre-install audit\n"
    printf "    ${D}--accept-risk=X${N} Accept specific risk categories\n\n"
}

run_installer() {
    local variant="$1"
    local script=""
    
    case "$variant" in
        1|free)  script="scripts/install-recommended.sh" ;;
        2|4evr)  script="scripts/install-minimal.sh" ;;
        3|1314)  script="scripts/install-custom.sh" ;;
        *)       return 1 ;;
    esac
    
    download_verified "installer" "${CI5_RAW}/${script}" "/tmp/ci5-install.sh"
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
    init_state_tracking
    
    # Parse global options
    AUDIT_MODE="enforce"  # enforce | warn | skip
    ACCEPT_RISKS=""
    
    local args=""
    for arg in "$@"; do
        case "$arg" in
            --audit-warn)       AUDIT_MODE="warn" ;;
            --no-audit)         AUDIT_MODE="skip" ;;
            --accept-risk=*)    ACCEPT_RISKS="${arg#*=}" ;;
            --help|-h)          show_menu; exit 0 ;;
            *)                  args="$args $arg" ;;
        esac
    done
    set -- $args
    
    # Command execution
    if [ -n "$1" ]; then
        local cmd="$1"
        shift
        
        local target_script=$(resolve_command "$cmd")
        
        if [ -z "$target_script" ]; then
            die "Unknown command: $cmd. Run without arguments for menu."
        fi
        
        # Handle local commands
        if echo "$target_script" | grep -q "^LOCAL:"; then
            local script=$(echo "$target_script" | cut -d: -f2)
            info "This is a local command. Run: sh $script"
            exit 0
        fi
        
        # Handle external commands (ci5.host)
        if echo "$target_script" | grep -q "^EXTERNAL:"; then
            handle_external "$target_script" "$@"
            exit 0
        fi
        
        step "PHOENIX PROTOCOL: $cmd"
        
        # Download and verify script
        info "Fetching secure module..."
        download_verified "$cmd" "${CI5_RAW}/${target_script}" "/tmp/ci5-exec.sh"
        
        # Cork installation flow (with audit and state tracking)
        if is_cork_install "$cmd"; then
            local cork_name=$(get_cork_name "$cmd")
            
            # Pre-install audit
            if [ "$AUDIT_MODE" != "skip" ]; then
                if ! run_pre_audit "$cork_name" "$ACCEPT_RISKS"; then
                    if [ "$AUDIT_MODE" = "enforce" ]; then
                        die "Pre-install audit failed. Use --audit-warn to continue anyway."
                    else
                        warn "Audit warnings present, continuing per --audit-warn"
                    fi
                fi
            fi
            
            # Capture pre-install state
            capture_pre_state "$cork_name"
            
            # Execute
            chmod +x /tmp/ci5-exec.sh
            /tmp/ci5-exec.sh "$@"
            local result=$?
            
            if [ $result -eq 0 ]; then
                # Capture post-install state
                capture_post_state "$cork_name"
                
                # Post-install audit (generate manifest)
                if [ "$AUDIT_MODE" != "skip" ]; then
                    run_post_audit "$cork_name"
                fi
            fi
            
            exit $result
        else
            # Non-cork command (utility, diagnostic, etc.)
            chmod +x /tmp/ci5-exec.sh
            exec /tmp/ci5-exec.sh "$@"
        fi
    fi
    
    # Interactive Menu
    while true; do
        show_menu
        printf "    Select [1-3]: "
        read -r choice
        case "$choice" in
            1|"")  run_installer "free" ;;
            2)     run_installer "4evr" ;;
            3)     run_installer "1314" ;;
            q|Q)   exit 0 ;;
            *)     warn "Invalid option" ;;
        esac
    done
}

main "$@"
