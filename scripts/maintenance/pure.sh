#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/pure — Intelligent Uninstall & State Rollback System
# Version: 4.0-PHOENIX (Merged - Procd + Full State Tracking)
#
# Comprehensive system for tracking, managing, and cleanly removing CI5 corks:
# - Automatic state capture at install time
# - Dependency chain awareness and safe removal order
# - Pre-install baseline restoration
# - Cork-provided uninstall hooks
# - Interactive and automated modes
#
# Philosophy: "Leave no trace" — restore system to exact pre-install state
# ═══════════════════════════════════════════════════════════════════════════
#
# Usage:
#   ci5 pure baseline      Create initial system baseline
#   ci5 pure snapshot NAME Create named snapshot
#   ci5 pure snapshots     List available snapshots
#   ci5 pure restore       Restore to baseline
#   ci5 pure restore NAME  Restore to named snapshot
#   ci5 pure detect        Detect installed corks
#   ci5 pure status        Show current state
#   ci5 pure <cork>        Uninstall specific cork
#   ci5 pure all           Uninstall all corks (restore baseline)

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CI5_DIR="/etc/ci5"
STATE_DIR="$CI5_DIR/state"
CORK_STATE_DIR="$STATE_DIR/corks"
BASELINE_DIR="$STATE_DIR/baseline"
SNAPSHOTS_DIR="$STATE_DIR/snapshots"
HOOKS_DIR="$CI5_DIR/hooks"
UNINSTALL_HOOKS="$HOOKS_DIR/uninstall"
DEPS_FILE="$STATE_DIR/dependencies.json"
INSTALL_LOG="$STATE_DIR/install.log"
PURE_LOG="/var/log/ci5-pure.log"

# State tracking files per cork
# $CORK_STATE_DIR/<cork>/
#   ├── manifest.json       # Cork metadata + install time
#   ├── pre-state.json      # System state before install
#   ├── post-state.json     # System state after install
#   ├── changes.json        # Delta between pre/post
#   ├── docker.list         # Docker resources created
#   ├── files.list          # Files created/modified
#   ├── packages.list       # System packages installed
#   ├── services.list       # Procd services created
#   ├── network.json        # Network changes (ports, interfaces)
#   ├── config-backup/      # Original config file backups
#   └── uninstall.sh        # Cork-provided or generated uninstall script

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }
pure() { printf "${M}[◈]${N} %s\n" "$1"; }

log() {
    mkdir -p "$(dirname "$PURE_LOG")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$PURE_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────────────────────

init_deps() {
    # Ensure jq is available
    if ! command -v jq >/dev/null 2>&1; then
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            opkg install jq >/dev/null 2>&1 || warn "jq install failed"
        fi
    fi

    # Create directories
    mkdir -p "$CI5_DIR" "$STATE_DIR" "$CORK_STATE_DIR" "$BASELINE_DIR" "$SNAPSHOTS_DIR" "$HOOKS_DIR" "$UNINSTALL_HOOKS"

    # Initialize deps file if missing
    if [ ! -f "$DEPS_FILE" ]; then
        echo '{"corks":{},"edges":[]}' > "$DEPS_FILE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Add cork to dependency graph
register_cork() {
    local cork="$1"
    local depends_on="$2"  # Comma-separated list

    init_deps

    # Add cork node
    local temp=$(mktemp)
    jq --arg cork "$cork" --arg time "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" \
        '.corks[$cork] = {"installed": $time, "dependents": []}' \
        "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"

    # Add dependency edges
    if [ -n "$depends_on" ]; then
        for dep in $(echo "$depends_on" | tr ',' ' '); do
            jq --arg cork "$cork" --arg dep "$dep" \
                '.edges += [{"from": $cork, "to": $dep}] | .corks[$dep].dependents += [$cork]' \
                "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"
        done
    fi

    log "Registered cork: $cork (depends on: ${depends_on:-none})"
}

# Get corks that depend on this one
get_dependents() {
    local cork="$1"
    jq -r --arg cork "$cork" '.corks[$cork].dependents // [] | .[]' "$DEPS_FILE" 2>/dev/null
}

# Get corks this one depends on
get_dependencies() {
    local cork="$1"
    jq -r --arg cork "$cork" '.edges[] | select(.from == $cork) | .to' "$DEPS_FILE" 2>/dev/null
}

# Remove cork from dependency graph
unregister_cork() {
    local cork="$1"
    local temp=$(mktemp)

    jq --arg cork "$cork" \
        'del(.corks[$cork]) | .edges = [.edges[] | select(.from != $cork and .to != $cork)]' \
        "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"

    # Update dependents lists
    jq --arg cork "$cork" \
        '.corks |= with_entries(.value.dependents -= [$cork])' \
        "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATE CAPTURE
# ─────────────────────────────────────────────────────────────────────────────

capture_system_state() {
    local output_file="$1"
    local state_type="${2:-full}"

    pure "Capturing system state..."

    local state='{}'

    # Docker state (full capture including networks)
    if [ "$state_type" = "full" ] || [ "$state_type" = "docker" ]; then
        if command -v docker >/dev/null 2>&1; then
            local containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local volumes=$(docker volume ls -q 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^bridge$\|^host$\|^none$" | sort | tr '\n' ',' | sed 's/,$//')

            if command -v jq >/dev/null 2>&1; then
                state=$(echo "$state" | jq \
                    --arg c "$containers" \
                    --arg i "$images" \
                    --arg v "$volumes" \
                    --arg n "$networks" \
                    '.docker = {
                        containers: ($c | split(",") | map(select(. != ""))),
                        images: ($i | split(",") | map(select(. != ""))),
                        volumes: ($v | split(",") | map(select(. != ""))),
                        networks: ($n | split(",") | map(select(. != "")))
                    }')
            fi
        fi
    fi

    # Network state
    if [ "$state_type" = "full" ] || [ "$state_type" = "network" ]; then
        local listening=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
        local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sort | tr '\n' ',' | sed 's/,$//')

        if command -v jq >/dev/null 2>&1; then
            state=$(echo "$state" | jq \
                --arg l "$listening" \
                --arg n "$interfaces" \
                '.network = {
                    listening_ports: ($l | split(",") | map(select(. != ""))),
                    interfaces: ($n | split(",") | map(select(. != "")))
                }')
        fi
    fi

    # Services state (Procd - OpenWrt)
    if [ "$state_type" = "full" ] || [ "$state_type" = "services" ]; then
        local enabled=""
        if [ -d /etc/rc.d ]; then
            enabled=$(ls /etc/rc.d/S* 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/^S[0-9]*//' | sort -u | tr '\n' ',' | sed 's/,$//')
        fi

        if command -v jq >/dev/null 2>&1; then
            state=$(echo "$state" | jq --arg e "$enabled" '.services = {enabled: ($e | split(",") | map(select(. != "")))}')
        fi
    fi

    # Installed packages
    if [ "$state_type" = "full" ] || [ "$state_type" = "packages" ]; then
        local packages=""
        if command -v opkg >/dev/null 2>&1; then
            packages=$(opkg list-installed 2>/dev/null | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//')
        fi

        if command -v jq >/dev/null 2>&1; then
            state=$(echo "$state" | jq --arg p "$packages" '.packages = ($p | split(",") | map(select(. != "")))')
        fi
    fi

    # Firewall rules count
    if [ "$state_type" = "full" ]; then
        local fw_rules=0
        if command -v nft >/dev/null 2>&1; then
            fw_rules=$(nft list ruleset 2>/dev/null | grep -c "rule" || echo "0")
        elif command -v iptables >/dev/null 2>&1; then
            fw_rules=$(iptables -S 2>/dev/null | wc -l || echo "0")
        fi

        if command -v jq >/dev/null 2>&1; then
            state=$(echo "$state" | jq --arg f "$fw_rules" '.firewall = {rules_count: ($f | tonumber)}')
        fi
    fi

    # Timestamp
    if command -v jq >/dev/null 2>&1; then
        state=$(echo "$state" | jq --arg ts "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" '.captured_at = $ts')
        echo "$state" | jq '.' > "$output_file"
    else
        echo "$state" > "$output_file"
    fi

    info "State captured: $output_file"
    log "State captured to $output_file"
}

# Calculate state difference
calculate_state_diff() {
    local pre_state="$1"
    local post_state="$2"
    local output_file="$3"

    pure "Calculating state changes..."

    local diff='{}'

    # Docker changes
    if jq -e '.docker' "$pre_state" >/dev/null 2>&1 && jq -e '.docker' "$post_state" >/dev/null 2>&1; then
        local new_containers=$(jq -r '.docker.containers[]' "$post_state" 2>/dev/null | while read c; do
            jq -e --arg c "$c" '.docker.containers | index($c)' "$pre_state" >/dev/null 2>&1 || echo "$c"
        done | tr '\n' ',' | sed 's/,$//')

        local new_volumes=$(jq -r '.docker.volumes[]' "$post_state" 2>/dev/null | while read v; do
            jq -e --arg v "$v" '.docker.volumes | index($v)' "$pre_state" >/dev/null 2>&1 || echo "$v"
        done | tr '\n' ',' | sed 's/,$//')

        local new_networks=$(jq -r '.docker.networks[]' "$post_state" 2>/dev/null | while read n; do
            jq -e --arg n "$n" '.docker.networks | index($n)' "$pre_state" >/dev/null 2>&1 || echo "$n"
        done | tr '\n' ',' | sed 's/,$//')

        local new_images=$(jq -r '.docker.images[]' "$post_state" 2>/dev/null | while read i; do
            jq -e --arg i "$i" '.docker.images | index($i)' "$pre_state" >/dev/null 2>&1 || echo "$i"
        done | tr '\n' ',' | sed 's/,$//')

        diff=$(echo "$diff" | jq \
            --arg c "$new_containers" \
            --arg v "$new_volumes" \
            --arg n "$new_networks" \
            --arg i "$new_images" \
            '.docker = {
                added_containers: ($c | split(",") | map(select(. != ""))),
                added_volumes: ($v | split(",") | map(select(. != ""))),
                added_networks: ($n | split(",") | map(select(. != ""))),
                added_images: ($i | split(",") | map(select(. != "")))
            }')
    fi

    # Network changes
    if jq -e '.network' "$pre_state" >/dev/null 2>&1 && jq -e '.network' "$post_state" >/dev/null 2>&1; then
        local new_ports=$(jq -r '.network.listening_ports[]' "$post_state" 2>/dev/null | while read p; do
            jq -e --arg p "$p" '.network.listening_ports | index($p)' "$pre_state" >/dev/null 2>&1 || echo "$p"
        done | tr '\n' ',' | sed 's/,$//')

        diff=$(echo "$diff" | jq \
            --arg p "$new_ports" \
            '.network = {new_listening_ports: ($p | split(",") | map(select(. != "")))}')
    fi

    # Service changes
    if jq -e '.services' "$pre_state" >/dev/null 2>&1 && jq -e '.services' "$post_state" >/dev/null 2>&1; then
        local new_services=$(jq -r '.services.enabled[]' "$post_state" 2>/dev/null | while read s; do
            jq -e --arg s "$s" '.services.enabled | index($s)' "$pre_state" >/dev/null 2>&1 || echo "$s"
        done | tr '\n' ',' | sed 's/,$//')

        diff=$(echo "$diff" | jq \
            --arg s "$new_services" \
            '.services = {added_services: ($s | split(",") | map(select(. != "")))}')
    fi

    echo "$diff" | jq '.' > "$output_file"
    info "Changes recorded: $output_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE TRACKING
# ─────────────────────────────────────────────────────────────────────────────

# Track files created/modified during install
start_file_tracking() {
    local cork="$1"
    local track_dirs="${2:-/etc /opt /var/lib /usr/local}"
    local track_file="$CORK_STATE_DIR/$cork/file_tracking.baseline"

    mkdir -p "$CORK_STATE_DIR/$cork"

    # Create baseline of file mtimes
    for dir in $track_dirs; do
        [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
    done | sort > "$track_file"

    pure "File tracking started for: $cork"
}

# Capture files changed since tracking started
stop_file_tracking() {
    local cork="$1"
    local track_dirs="${2:-/etc /opt /var/lib /usr/local}"
    local baseline="$CORK_STATE_DIR/$cork/file_tracking.baseline"
    local changes="$CORK_STATE_DIR/$cork/files.list"

    [ -f "$baseline" ] || return 1

    # Get current state
    local current=$(mktemp)
    for dir in $track_dirs; do
        [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
    done | sort > "$current"

    # Find new and modified files
    {
        # New files (in current but not in baseline)
        comm -23 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) 2>/dev/null | while read f; do
            echo "CREATED $f"
        done

        # Modified files (different mtime)
        comm -12 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) 2>/dev/null | while read f; do
            local old_mtime=$(grep " $f$" "$baseline" | awk '{print $1}')
            local new_mtime=$(grep " $f$" "$current" | awk '{print $1}')
            [ "$old_mtime" != "$new_mtime" ] && echo "MODIFIED $f"
        done
    } > "$changes"

    rm -f "$baseline" "$current"

    local count=$(wc -l < "$changes")
    info "File tracking complete: $count files changed"
}

# Backup config files before modification
backup_config_file() {
    local cork="$1"
    local file="$2"
    local backup_dir="$CORK_STATE_DIR/$cork/config-backup"

    mkdir -p "$backup_dir"

    if [ -f "$file" ]; then
        local rel_path=$(echo "$file" | sed 's|^/||')
        mkdir -p "$backup_dir/$(dirname "$rel_path")"
        cp -a "$file" "$backup_dir/$rel_path"
        pure "Backed up: $file"
    fi
}

# Restore config files from backup
restore_config_files() {
    local cork="$1"
    local backup_dir="$CORK_STATE_DIR/$cork/config-backup"

    [ -d "$backup_dir" ] || return 0

    pure "Restoring config files..."

    find "$backup_dir" -type f 2>/dev/null | while read backup; do
        local original=$(echo "$backup" | sed "s|$backup_dir||")
        if [ -f "$original" ]; then
            cp -a "$backup" "$original"
            pure "Restored: $original"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# CORK INSTALL HOOKS
# ─────────────────────────────────────────────────────────────────────────────

# Pre-install hook - call before cork install
# Usage: pre_install_hook <cork_name> [depends_on]
pre_install_hook() {
    local cork="$1"
    local depends_on="$2"

    mkdir -p "$CORK_STATE_DIR/$cork"

    step "PRE-INSTALL: $cork"

    # Check dependencies exist
    if [ -n "$depends_on" ]; then
        for dep in $(echo "$depends_on" | tr ',' ' '); do
            if [ ! -d "$CORK_STATE_DIR/$dep" ]; then
                warn "Dependency not installed: $dep"
            fi
        done
    fi

    # Capture pre-install state
    capture_system_state "$CORK_STATE_DIR/$cork/pre-state.json"

    # Start file tracking
    start_file_tracking "$cork"

    # Record install start
    cat > "$CORK_STATE_DIR/$cork/manifest.json" << EOF
{
    "cork": "$cork",
    "install_started": "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')",
    "depends_on": $(echo "$depends_on" | awk -F, '{printf "["; for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i<NF?",":""); printf "]"}'),
    "status": "installing"
}
EOF

    # Register in dependency graph
    register_cork "$cork" "$depends_on"

    log "Pre-install hook: $cork"
}

# Post-install hook - call after cork install completes
# Usage: post_install_hook <cork_name> [uninstall_script]
post_install_hook() {
    local cork="$1"
    local uninstall_script="$2"

    step "POST-INSTALL: $cork"

    # Capture post-install state
    capture_system_state "$CORK_STATE_DIR/$cork/post-state.json"

    # Stop file tracking and record changes
    stop_file_tracking "$cork"

    # Calculate state diff
    calculate_state_diff \
        "$CORK_STATE_DIR/$cork/pre-state.json" \
        "$CORK_STATE_DIR/$cork/post-state.json" \
        "$CORK_STATE_DIR/$cork/changes.json"

    # Record Docker resources
    if jq -e '.docker' "$CORK_STATE_DIR/$cork/changes.json" >/dev/null 2>&1; then
        {
            jq -r '.docker.added_containers[]' "$CORK_STATE_DIR/$cork/changes.json" 2>/dev/null
            jq -r '.docker.added_volumes[]' "$CORK_STATE_DIR/$cork/changes.json" 2>/dev/null
            jq -r '.docker.added_networks[]' "$CORK_STATE_DIR/$cork/changes.json" 2>/dev/null
            jq -r '.docker.added_images[]' "$CORK_STATE_DIR/$cork/changes.json" 2>/dev/null
        } | grep -v '^$' > "$CORK_STATE_DIR/$cork/docker.list"
    fi

    # Record services
    if jq -e '.services.added_services | length > 0' "$CORK_STATE_DIR/$cork/changes.json" >/dev/null 2>&1; then
        jq -r '.services.added_services[]' "$CORK_STATE_DIR/$cork/changes.json" > "$CORK_STATE_DIR/$cork/services.list"
    fi

    # Save uninstall script if provided
    if [ -n "$uninstall_script" ] && [ -f "$uninstall_script" ]; then
        cp "$uninstall_script" "$CORK_STATE_DIR/$cork/uninstall.sh"
        chmod +x "$CORK_STATE_DIR/$cork/uninstall.sh"
    fi

    # Update manifest
    local temp=$(mktemp)
    jq --arg time "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" \
        '.install_completed = $time | .status = "installed"' \
        "$CORK_STATE_DIR/$cork/manifest.json" > "$temp" && mv "$temp" "$CORK_STATE_DIR/$cork/manifest.json"

    info "Cork installed: $cork"
    log "Post-install hook: $cork"

    # Show summary
    echo ""
    echo "  Changes recorded:"
    [ -f "$CORK_STATE_DIR/$cork/docker.list" ] && echo "    Docker resources: $(wc -l < "$CORK_STATE_DIR/$cork/docker.list")"
    [ -f "$CORK_STATE_DIR/$cork/files.list" ] && echo "    Files changed: $(wc -l < "$CORK_STATE_DIR/$cork/files.list")"
    [ -f "$CORK_STATE_DIR/$cork/services.list" ] && echo "    Services: $(wc -l < "$CORK_STATE_DIR/$cork/services.list")"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# BASELINE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

create_baseline() {
    step "CREATING SYSTEM BASELINE"

    pure "This captures the current system state as the 'clean' baseline"
    pure "All future uninstalls will aim to restore to this state"

    # Capture full state
    capture_system_state "$BASELINE_DIR/system.json" "full"

    # Backup critical configs
    mkdir -p "$BASELINE_DIR/configs"

    for cfg in /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/wireless; do
        [ -f "$cfg" ] && cp "$cfg" "$BASELINE_DIR/configs/" 2>/dev/null || true
    done

    # Capture firewall rules
    nft list ruleset > "$BASELINE_DIR/nftables.rules" 2>/dev/null || true
    iptables-save > "$BASELINE_DIR/iptables.rules" 2>/dev/null || true

    # Record timestamp
    date '+%Y-%m-%d %H:%M:%S' > "$BASELINE_DIR/created"

    info "Baseline created at $BASELINE_DIR"
    log "Baseline created"
}

restore_baseline() {
    step "RESTORING TO BASELINE"

    if [ ! -f "$BASELINE_DIR/system.json" ]; then
        err "No baseline found. Run 'ci5 pure baseline' first."
    fi

    warn "This will uninstall ALL corks and restore system to baseline state"
    printf "  Type 'RESTORE' to confirm: "
    read -r confirm
    [ "$confirm" = "RESTORE" ] || { echo "Aborted."; return 1; }

    # First uninstall all corks
    local corks=$(list_installed_corks)
    if [ -n "$corks" ]; then
        for cork in $corks; do
            uninstall_cork "$cork" "yes"
        done
    fi

    # Restore configs if backed up
    if [ -d "$BASELINE_DIR/configs" ]; then
        for cfg in "$BASELINE_DIR/configs"/*; do
            [ -f "$cfg" ] || continue
            local name=$(basename "$cfg")
            if [ -f "/etc/config/$name" ]; then
                cp "$cfg" "/etc/config/$name"
                info "Restored: /etc/config/$name"
            fi
        done

        # Reload services
        /etc/init.d/network reload 2>/dev/null || true
        /etc/init.d/firewall reload 2>/dev/null || true
    fi

    # Restore firewall rules
    if [ -f "$BASELINE_DIR/nftables.rules" ]; then
        pure "Restoring nftables rules..."
        nft -f "$BASELINE_DIR/nftables.rules" 2>/dev/null || true
    fi

    if [ -f "$BASELINE_DIR/iptables.rules" ]; then
        pure "Restoring iptables rules..."
        iptables-restore < "$BASELINE_DIR/iptables.rules" 2>/dev/null || true
    fi

    info "Baseline restored"
    log "Baseline restored"
}

# ─────────────────────────────────────────────────────────────────────────────
# SNAPSHOT MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

create_snapshot() {
    local name="${1:-$(date +%Y%m%d_%H%M%S)}"

    step "CREATING SNAPSHOT: $name"

    local snap_dir="$SNAPSHOTS_DIR/$name"
    mkdir -p "$snap_dir/configs"

    # Capture state
    capture_system_state "$snap_dir/system.json" "full"

    # Backup configs
    for cfg in /etc/config/*; do
        [ -f "$cfg" ] && cp "$cfg" "$snap_dir/configs/" 2>/dev/null || true
    done

    # Record cork state
    if [ -d "$CORK_STATE_DIR" ]; then
        cp -r "$CORK_STATE_DIR" "$snap_dir/corks" 2>/dev/null || true
    fi

    # Copy dependency graph
    cp "$DEPS_FILE" "$snap_dir/dependencies.json" 2>/dev/null || true

    date '+%Y-%m-%d %H:%M:%S' > "$snap_dir/created"

    info "Snapshot '$name' created"
    log "Snapshot created: $name"
}

list_snapshots() {
    step "AVAILABLE SNAPSHOTS"

    if [ ! -d "$SNAPSHOTS_DIR" ] || [ -z "$(ls -A "$SNAPSHOTS_DIR" 2>/dev/null)" ]; then
        warn "No snapshots found"
        return
    fi

    printf "  ${B}%-25s %-20s %s${N}\n" "NAME" "DATE" "CORKS"
    printf "  %-25s %-20s %s\n" "-------------------------" "--------------------" "-----"

    for snap in "$SNAPSHOTS_DIR"/*; do
        [ -d "$snap" ] || continue
        local name=$(basename "$snap")
        local created="unknown"
        [ -f "$snap/created" ] && created=$(cat "$snap/created")
        local corks=$(ls "$snap/corks" 2>/dev/null | wc -l)
        printf "  ${M}◈${N} %-23s %-20s %s\n" "$name" "$created" "$corks"
    done
}

restore_snapshot() {
    local name="$1"

    if [ -z "$name" ]; then
        err "Usage: ci5 pure restore-snap <name>"
    fi

    local snap_dir="$SNAPSHOTS_DIR/$name"

    if [ ! -d "$snap_dir" ]; then
        err "Snapshot '$name' not found"
    fi

    step "RESTORING SNAPSHOT: $name"

    warn "This will restore system to snapshot state"
    printf "  Confirm? [y/N]: "
    read -r confirm
    [ "$confirm" = "y" ] || { echo "Aborted."; return 1; }

    # Restore configs
    if [ -d "$snap_dir/configs" ]; then
        for cfg in "$snap_dir/configs"/*; do
            [ -f "$cfg" ] || continue
            local cfg_name=$(basename "$cfg")
            cp "$cfg" "/etc/config/$cfg_name" 2>/dev/null || true
            info "Restored: /etc/config/$cfg_name"
        done
    fi

    # Reload services
    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true

    info "Snapshot '$name' restored"
    log "Snapshot restored: $name"
}

# ─────────────────────────────────────────────────────────────────────────────
# CORK MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

list_installed_corks() {
    if [ -d "$CORK_STATE_DIR" ]; then
        ls -1 "$CORK_STATE_DIR" 2>/dev/null | grep -v "^$"
    fi
}

detect_installed() {
    step "DETECTING INSTALLED CORKS"

    local corks=$(list_installed_corks)

    if [ -z "$corks" ]; then
        info "No corks installed"

        # Check for untracked components
        pure "Scanning for untracked components..."

        if command -v docker >/dev/null 2>&1; then
            local ci5_containers=$(docker ps -a --filter "label=ci5" --format '{{.Names}}' 2>/dev/null)
            if [ -n "$ci5_containers" ]; then
                echo "  Found CI5-labeled containers:"
                echo "$ci5_containers" | while read c; do
                    echo "    - $c"
                done
            fi
        fi
        return
    fi

    printf "  ${B}%-20s  %-15s  %-20s${N}\n" "CORK" "STATUS" "DEPENDENCIES"
    printf "  %-20s  %-15s  %-20s\n" "--------------------" "---------------" "--------------------"

    for cork in $corks; do
        local cork_dir="$CORK_STATE_DIR/$cork"
        local status="installed"
        local deps=$(get_dependencies "$cork" | tr '\n' ',' | sed 's/,$//')
        local dependents=$(get_dependents "$cork" | tr '\n' ',' | sed 's/,$//')

        # Check if docker container exists
        if [ -f "$cork_dir/docker.list" ]; then
            local first_container=$(head -1 "$cork_dir/docker.list" 2>/dev/null)
            if [ -n "$first_container" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$first_container"; then
                status="running"
            else
                status="stopped"
            fi
        fi

        printf "  ${M}◈${N} %-18s  %-15s  %s\n" "$cork" "$status" "${deps:-none}"
        [ -n "$dependents" ] && printf "     ${Y}(required by: %s)${N}\n" "$dependents"
    done
}

uninstall_cork() {
    local cork="$1"
    local force="${2:-no}"
    local cork_dir="$CORK_STATE_DIR/$cork"

    if [ ! -d "$cork_dir" ]; then
        warn "Cork '$cork' not found"
        return 1
    fi

    step "UNINSTALLING CORK: $cork"
    log "Uninstalling cork: $cork"

    # Check dependencies (don't uninstall if others depend on this)
    if [ "$force" != "yes" ] && command -v jq >/dev/null 2>&1 && [ -f "$DEPS_FILE" ]; then
        local dependents=$(get_dependents "$cork")
        if [ -n "$dependents" ]; then
            warn "The following corks depend on '$cork':"
            echo "$dependents" | while read dep; do
                echo "    - $dep"
            done
            printf "\n  Options:\n"
            printf "    [1] Uninstall $cork and all dependents\n"
            printf "    [2] Cancel\n"
            printf "    [3] Force remove (may break dependents)\n"
            printf "\n  Choice: "
            read -r choice

            case "$choice" in
                1)
                    echo "$dependents" | while read dep; do
                        uninstall_cork "$dep" "yes"
                    done
                    ;;
                3)
                    warn "Force removing - dependents may break!"
                    ;;
                *)
                    info "Cancelled"
                    return 0
                    ;;
            esac
        fi
    fi

    # Run custom uninstall script if exists
    if [ -x "$cork_dir/uninstall.sh" ]; then
        info "Running custom uninstall script..."
        "$cork_dir/uninstall.sh" || warn "Custom uninstall had errors"
    fi

    # Stop and remove Docker containers
    if [ -f "$cork_dir/docker.list" ]; then
        while read -r resource; do
            [ -z "$resource" ] && continue
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "$resource"; then
                info "Stopping container: $resource"
                docker stop "$resource" 2>/dev/null || true
                docker rm "$resource" 2>/dev/null || true
            elif docker volume ls -q 2>/dev/null | grep -qw "$resource"; then
                info "Removing volume: $resource"
                docker volume rm "$resource" 2>/dev/null || true
            elif docker network ls --format '{{.Name}}' 2>/dev/null | grep -qw "$resource"; then
                info "Removing network: $resource"
                docker network rm "$resource" 2>/dev/null || true
            fi
        done < "$cork_dir/docker.list"
    fi

    # Stop and remove services (Procd)
    if [ -f "$cork_dir/services.list" ]; then
        while read -r service; do
            [ -z "$service" ] && continue
            if [ -x "/etc/init.d/$service" ]; then
                info "Stopping service: $service"
                /etc/init.d/"$service" stop 2>/dev/null || true
                /etc/init.d/"$service" disable 2>/dev/null || true
                rm -f "/etc/init.d/$service"
            fi
        done < "$cork_dir/services.list"
    fi

    # Remove packages
    if [ -f "$cork_dir/packages.list" ]; then
        while read -r package; do
            [ -z "$package" ] && continue
            info "Removing package: $package"
            opkg remove "$package" 2>/dev/null || true
        done < "$cork_dir/packages.list"
    fi

    # Restore config files
    restore_config_files "$cork"

    # Remove files created by cork
    if [ -f "$cork_dir/files.list" ]; then
        grep "^CREATED " "$cork_dir/files.list" 2>/dev/null | cut -d' ' -f2- | while read file; do
            [ -z "$file" ] && continue
            [ -e "$file" ] && rm -rf "$file" && info "Removed: $file"
        done
    fi

    # Update dependency graph
    unregister_cork "$cork"

    # Archive state (for potential recovery)
    local archive_dir="$STATE_DIR/archive/$(date +%Y%m%d-%H%M%S)-$cork"
    mkdir -p "$archive_dir"
    mv "$cork_dir" "$archive_dir/" 2>/dev/null || rm -rf "$cork_dir"

    info "Cork '$cork' uninstalled"
    log "Cork uninstalled: $cork"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS & INFO
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "CI5 PURE STATUS"

    # Baseline status
    printf "  ${B}Baseline:${N} "
    if [ -f "$BASELINE_DIR/system.json" ]; then
        local baseline_date=$(cat "$BASELINE_DIR/created" 2>/dev/null || echo "unknown")
        printf "${G}Created${N} ($baseline_date)\n"
    else
        printf "${Y}Not created${N}\n"
    fi

    # Snapshot count
    local snap_count=$(ls -1 "$SNAPSHOTS_DIR" 2>/dev/null | wc -l)
    printf "  ${B}Snapshots:${N} %s\n" "$snap_count"

    # Installed corks
    printf "\n  ${B}Installed Corks:${N}\n"
    local corks=$(list_installed_corks)
    if [ -n "$corks" ]; then
        for cork in $corks; do
            local deps=$(get_dependencies "$cork" | tr '\n' ',' | sed 's/,$//')
            local dependents=$(get_dependents "$cork" | tr '\n' ',' | sed 's/,$//')

            printf "    ${M}◈${N} %s" "$cork"
            [ -n "$deps" ] && printf " (depends: %s)" "$deps"
            [ -n "$dependents" ] && printf " ${Y}(required by: %s)${N}" "$dependents"
            printf "\n"
        done
    else
        printf "    ${D}None${N}\n"
    fi

    # Docker state
    if command -v docker >/dev/null 2>&1; then
        printf "\n  ${B}Docker:${N}\n"
        printf "    Containers: %s running / %s total\n" "$(docker ps -q 2>/dev/null | wc -l)" "$(docker ps -aq 2>/dev/null | wc -l)"
        printf "    Volumes: %s\n" "$(docker volume ls -q 2>/dev/null | wc -l)"
        printf "    Networks: %s\n" "$(docker network ls -q 2>/dev/null | wc -l)"
    fi

    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

interactive_menu() {
    while true; do
        clear
        printf "${M}"
        cat << 'BANNER'
   ___
  / _ \_   _ _ __ ___
 / /_)/ | | | '__/ _ \
/ ___/| |_| | | |  __/
\/     \__,_|_|  \___|

BANNER
        printf "${N}"
        printf "        ${C}CI5 Uninstall & Rollback${N}\n"
        printf "        ${Y}v4.0-PHOENIX${N}\n\n"

        local corks=$(list_installed_corks)
        local cork_count=$(echo "$corks" | grep -c "^" 2>/dev/null || echo "0")

        printf "  ${B}Installed Corks:${N} %d\n\n" "$cork_count"

        printf "  ${B}UNINSTALL${N}\n"
        printf "    ${M}[1]${N} Uninstall cork\n"
        printf "    ${M}[2]${N} Uninstall all corks\n"
        printf "    ${M}[3]${N} Restore to baseline\n\n"

        printf "  ${B}STATE${N}\n"
        printf "    ${M}[4]${N} Create baseline\n"
        printf "    ${M}[5]${N} Create snapshot\n"
        printf "    ${M}[6]${N} List snapshots\n"
        printf "    ${M}[7]${N} Restore snapshot\n\n"

        printf "  ${B}DETECT${N}\n"
        printf "    ${M}[8]${N} Detect installed components\n"
        printf "    ${M}[9]${N} Show dependency graph\n\n"

        printf "  ${M}[S]${N} Status  ${M}[Q]${N} Quit\n\n"

        printf "  Choice: "
        read -r choice

        case "$choice" in
            1)
                clear
                if [ -n "$corks" ]; then
                    printf "  Installed corks:\n"
                    local i=1
                    for cork in $corks; do
                        printf "    [%d] %s\n" "$i" "$cork"
                        i=$((i + 1))
                    done
                    printf "\n  Select cork (number or name): "
                    read -r sel

                    if echo "$sel" | grep -q '^[0-9]*$'; then
                        local cork_name=$(echo "$corks" | sed -n "${sel}p")
                    else
                        local cork_name="$sel"
                    fi

                    [ -n "$cork_name" ] && uninstall_cork "$cork_name"
                else
                    warn "No corks installed"
                fi
                ;;
            2|3)
                clear
                restore_baseline
                ;;
            4)
                clear
                create_baseline
                ;;
            5)
                clear
                printf "  Snapshot name (or Enter for timestamp): "
                read -r name
                create_snapshot "$name"
                ;;
            6)
                clear
                list_snapshots
                ;;
            7)
                clear
                list_snapshots
                printf "\n  Snapshot name: "
                read -r name
                restore_snapshot "$name"
                ;;
            8)
                clear
                detect_installed
                ;;
            9)
                clear
                step "DEPENDENCY GRAPH"
                if [ -f "$DEPS_FILE" ] && command -v jq >/dev/null 2>&1; then
                    jq '.' "$DEPS_FILE"
                else
                    warn "No dependency data"
                fi
                ;;
            [Ss])
                clear
                show_status
                ;;
            [Qq])
                exit 0
                ;;
        esac

        printf "\n  Press Enter to continue..."
        read -r _
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
CI5 Pure — Intelligent Uninstall & State Rollback v4.0

UNINSTALL:
  ci5 pure                     Interactive menu
  ci5 pure <cork>              Uninstall specific cork
  ci5 pure all                 Uninstall all corks
  ci5 pure restore             Restore to baseline

STATE MANAGEMENT:
  ci5 pure baseline            Create system baseline
  ci5 pure snapshot [name]     Create named snapshot
  ci5 pure snapshots           List snapshots
  ci5 pure restore-snap <name> Restore from snapshot

DETECTION:
  ci5 pure detect              Detect installed components
  ci5 pure status              Show current status
  ci5 pure deps                Show dependency graph

FOR CORK DEVELOPERS:
  Include in your install script:
    . <(curl -sSL ci5.run/pure-hooks)
    pre_install_hook "mycork" "dependency1,dependency2"
    # ... your install logic ...
    post_install_hook "mycork" "/path/to/uninstall.sh"

UNINSTALL SCRIPT FORMAT:
  Cork submissions should include uninstall.sh with:
    - Docker container/volume/network removal
    - Service disable/removal
    - Config file restoration
    - Dependency cleanup notes

DEPENDENCY HANDLING:
  - Corks declare dependencies at install time
  - Pure prevents removing corks with dependents
  - Cascade uninstall removes dependents first
  - Force mode available but warns about breakage
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"

    init_deps

    case "${1:-}" in
        baseline)
            create_baseline
            ;;
        snapshot)
            create_snapshot "$2"
            ;;
        snapshots|list-snapshots)
            list_snapshots
            ;;
        restore-snap|restore-snapshot)
            restore_snapshot "$2"
            ;;
        restore)
            restore_baseline
            ;;
        all)
            restore_baseline
            ;;
        detect)
            detect_installed
            ;;
        status)
            show_status
            ;;
        deps|dependencies)
            step "DEPENDENCY GRAPH"
            if [ -f "$DEPS_FILE" ] && command -v jq >/dev/null 2>&1; then
                jq '.' "$DEPS_FILE"
            else
                warn "No dependency data available"
            fi
            ;;
        help|--help|-h)
            usage
            ;;
        "")
            interactive_menu
            ;;
        *)
            # Assume cork name
            if [ -d "$CORK_STATE_DIR/$1" ]; then
                uninstall_cork "$1"
            else
                err "Unknown cork or command: $1"
            fi
            ;;
    esac
}

main "$@"
