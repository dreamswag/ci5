#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/pure — Intelligent Uninstall & State Rollback System
# Version: 3.0-PHOENIX
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
#   ├── services.list       # Systemd services created
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
# DEPENDENCY MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Initialize dependency graph
init_deps() {
    mkdir -p "$STATE_DIR"
    [ -f "$DEPS_FILE" ] || echo '{"corks":{},"edges":[]}' > "$DEPS_FILE"
}

# Add cork to dependency graph
register_cork() {
    local cork="$1"
    local depends_on="$2"  # Comma-separated list
    
    init_deps
    
    # Add cork node
    local temp=$(mktemp)
    jq --arg cork "$cork" --arg time "$(date -Iseconds)" \
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

# Check if cork can be safely removed
can_remove_cork() {
    local cork="$1"
    local dependents=$(get_dependents "$cork")
    
    if [ -n "$dependents" ]; then
        echo "$dependents"
        return 1
    fi
    return 0
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

# Capture complete system state
capture_system_state() {
    local output_file="$1"
    local state_type="${2:-full}"  # full, docker, network, files, services
    
    pure "Capturing system state..."
    
    local state='{}'
    
    # Docker state
    if [ "$state_type" = "full" ] || [ "$state_type" = "docker" ]; then
        if command -v docker >/dev/null 2>&1; then
            local containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local volumes=$(docker volume ls -q 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
            local networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^bridge$\|^host$\|^none$" | sort | tr '\n' ',' | sed 's/,$//')
            
            state=$(echo "$state" | jq \
                --arg containers "$containers" \
                --arg images "$images" \
                --arg volumes "$volumes" \
                --arg networks "$networks" \
                '.docker = {
                    "containers": ($containers | split(",") | map(select(. != ""))),
                    "images": ($images | split(",") | map(select(. != ""))),
                    "volumes": ($volumes | split(",") | map(select(. != ""))),
                    "networks": ($networks | split(",") | map(select(. != "")))
                }')
        fi
    fi
    
    # Network state
    if [ "$state_type" = "full" ] || [ "$state_type" = "network" ]; then
        local listening=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
        local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sort | tr '\n' ',' | sed 's/,$//')
        local iptables_rules=$(iptables-save 2>/dev/null | wc -l)
        local nftables_rules=$(nft list ruleset 2>/dev/null | wc -l)
        
        state=$(echo "$state" | jq \
            --arg listening "$listening" \
            --arg interfaces "$interfaces" \
            --argjson iptables "$iptables_rules" \
            --argjson nftables "$nftables_rules" \
            '.network = {
                "listening_ports": ($listening | split(",") | map(select(. != ""))),
                "interfaces": ($interfaces | split(",") | map(select(. != ""))),
                "iptables_rule_count": $iptables,
                "nftables_rule_count": $nftables
            }')
    fi
    
    # Services state
    if [ "$state_type" = "full" ] || [ "$state_type" = "services" ]; then
        local services=$(systemctl list-unit-files --type=service --state=enabled 2>/dev/null | awk 'NR>1 && !/listed/ {print $1}' | sort | tr '\n' ',' | sed 's/,$//')
        local running=$(systemctl list-units --type=service --state=running 2>/dev/null | awk 'NR>1 && /running/ {print $1}' | sort | tr '\n' ',' | sed 's/,$//')
        
        state=$(echo "$state" | jq \
            --arg services "$services" \
            --arg running "$running" \
            '.services = {
                "enabled": ($services | split(",") | map(select(. != ""))),
                "running": ($running | split(",") | map(select(. != "")))
            }')
    fi
    
    # Packages state (apt)
    if [ "$state_type" = "full" ] || [ "$state_type" = "packages" ]; then
        if command -v dpkg >/dev/null 2>&1; then
            local packages=$(dpkg --get-selections 2>/dev/null | awk '$2=="install" {print $1}' | wc -l)
            state=$(echo "$state" | jq --argjson count "$packages" '.packages = {"apt_count": $count}')
        fi
    fi
    
    # Files state (CI5-specific directories)
    if [ "$state_type" = "full" ] || [ "$state_type" = "files" ]; then
        local ci5_files=$(find "$CI5_DIR" -type f 2>/dev/null | wc -l)
        local etc_files=$(find /etc -maxdepth 2 -name "*ci5*" -o -name "*adguard*" -o -name "*unbound*" -o -name "*wireguard*" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        
        state=$(echo "$state" | jq \
            --argjson ci5_count "$ci5_files" \
            --arg etc_files "$etc_files" \
            '.files = {
                "ci5_file_count": $ci5_count,
                "etc_configs": ($etc_files | split(",") | map(select(. != "")))
            }')
    fi
    
    # Timestamp
    state=$(echo "$state" | jq --arg ts "$(date -Iseconds)" '.captured_at = $ts')
    
    echo "$state" | jq '.' > "$output_file"
    info "State captured: $output_file"
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
        
        local new_images=$(jq -r '.docker.images[]' "$post_state" 2>/dev/null | while read i; do
            jq -e --arg i "$i" '.docker.images | index($i)' "$pre_state" >/dev/null 2>&1 || echo "$i"
        done | tr '\n' ',' | sed 's/,$//')
        
        local new_volumes=$(jq -r '.docker.volumes[]' "$post_state" 2>/dev/null | while read v; do
            jq -e --arg v "$v" '.docker.volumes | index($v)' "$pre_state" >/dev/null 2>&1 || echo "$v"
        done | tr '\n' ',' | sed 's/,$//')
        
        local new_networks=$(jq -r '.docker.networks[]' "$post_state" 2>/dev/null | while read n; do
            jq -e --arg n "$n" '.docker.networks | index($n)' "$pre_state" >/dev/null 2>&1 || echo "$n"
        done | tr '\n' ',' | sed 's/,$//')
        
        diff=$(echo "$diff" | jq \
            --arg containers "$new_containers" \
            --arg images "$new_images" \
            --arg volumes "$new_volumes" \
            --arg networks "$new_networks" \
            '.docker = {
                "added_containers": ($containers | split(",") | map(select(. != ""))),
                "added_images": ($images | split(",") | map(select(. != ""))),
                "added_volumes": ($volumes | split(",") | map(select(. != ""))),
                "added_networks": ($networks | split(",") | map(select(. != "")))
            }')
    fi
    
    # Network changes
    if jq -e '.network' "$pre_state" >/dev/null 2>&1 && jq -e '.network' "$post_state" >/dev/null 2>&1; then
        local new_ports=$(jq -r '.network.listening_ports[]' "$post_state" 2>/dev/null | while read p; do
            jq -e --arg p "$p" '.network.listening_ports | index($p)' "$pre_state" >/dev/null 2>&1 || echo "$p"
        done | tr '\n' ',' | sed 's/,$//')
        
        diff=$(echo "$diff" | jq \
            --arg ports "$new_ports" \
            '.network = {
                "new_listening_ports": ($ports | split(",") | map(select(. != "")))
            }')
    fi
    
    # Service changes
    if jq -e '.services' "$pre_state" >/dev/null 2>&1 && jq -e '.services' "$post_state" >/dev/null 2>&1; then
        local new_services=$(jq -r '.services.enabled[]' "$post_state" 2>/dev/null | while read s; do
            jq -e --arg s "$s" '.services.enabled | index($s)' "$pre_state" >/dev/null 2>&1 || echo "$s"
        done | tr '\n' ',' | sed 's/,$//')
        
        diff=$(echo "$diff" | jq \
            --arg services "$new_services" \
            '.services = {
                "added_services": ($services | split(",") | map(select(. != "")))
            }')
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
        comm -23 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) | while read f; do
            echo "CREATED $f"
        done
        
        # Modified files (different mtime)
        comm -12 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) | while read f; do
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
    
    find "$backup_dir" -type f | while read backup; do
        local original=$(echo "$backup" | sed "s|$backup_dir||")
        if [ -f "$original" ]; then
            cp -a "$backup" "$original"
            pure "Restored: $original"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# CORK INSTALL WRAPPER
# ─────────────────────────────────────────────────────────────────────────────

# This should be called by the cork installer to wrap the actual install
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
                printf "  Install $dep first? [Y/n]: "
                read -r install_dep
                if [ "$install_dep" != "n" ]; then
                    curl -sSL "ci5.run/$dep" | sh
                else
                    err "Cannot install $cork without $dep"
                fi
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
    "install_started": "$(date -Iseconds)",
    "depends_on": "$(echo "$depends_on" | tr ',' '", "' | sed 's/^/["/;s/$/"]/' | sed 's/\[" *"\]/[]/')",
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
    if jq -e '.docker.added_containers | length > 0' "$CORK_STATE_DIR/$cork/changes.json" >/dev/null 2>&1; then
        jq -r '.docker.added_containers[]' "$CORK_STATE_DIR/$cork/changes.json" > "$CORK_STATE_DIR/$cork/docker.list"
        jq -r '.docker.added_images[]' "$CORK_STATE_DIR/$cork/changes.json" >> "$CORK_STATE_DIR/$cork/docker.list"
        jq -r '.docker.added_volumes[]' "$CORK_STATE_DIR/$cork/changes.json" >> "$CORK_STATE_DIR/$cork/docker.list"
        jq -r '.docker.added_networks[]' "$CORK_STATE_DIR/$cork/changes.json" >> "$CORK_STATE_DIR/$cork/docker.list"
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
    jq --arg time "$(date -Iseconds)" \
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
# UNINSTALL FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Generate uninstall script from tracked changes
generate_uninstall_script() {
    local cork="$1"
    local output="$CORK_STATE_DIR/$cork/uninstall.sh"
    
    pure "Generating uninstall script for: $cork"
    
    cat > "$output" << 'HEADER'
#!/bin/sh
# Auto-generated uninstall script
# Generated by ci5.run/pure
set -e

info() { printf "\033[0;32m[✓]\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$1"; }

HEADER

    echo "CORK=\"$cork\"" >> "$output"
    echo "" >> "$output"
    
    # Docker cleanup
    if [ -f "$CORK_STATE_DIR/$cork/docker.list" ]; then
        cat >> "$output" << 'DOCKER'
# Stop and remove Docker containers
info "Stopping containers..."
for container in $(grep -v ':' CORK_STATE_DIR/CORK/docker.list 2>/dev/null | head -20); do
    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true
done

# Remove volumes
info "Removing volumes..."
for volume in $(grep '^[^:]*$' CORK_STATE_DIR/CORK/docker.list 2>/dev/null | tail -10); do
    docker volume rm "$volume" 2>/dev/null || true
done

# Remove networks (except defaults)
info "Removing networks..."
for network in $(grep '^[^:]*$' CORK_STATE_DIR/CORK/docker.list 2>/dev/null); do
    [ "$network" = "bridge" ] || [ "$network" = "host" ] || [ "$network" = "none" ] && continue
    docker network rm "$network" 2>/dev/null || true
done

DOCKER
        # Replace placeholders
        sed -i "s|CORK_STATE_DIR|$CORK_STATE_DIR|g; s|/CORK/|/$cork/|g" "$output"
    fi
    
    # Systemd services
    if [ -f "$CORK_STATE_DIR/$cork/services.list" ]; then
        cat >> "$output" << 'SERVICES'
# Disable and remove services
info "Removing services..."
while read service; do
    [ -z "$service" ] && continue
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$service" 2>/dev/null || true
done < CORK_STATE_DIR/CORK/services.list
systemctl daemon-reload

SERVICES
        sed -i "s|CORK_STATE_DIR|$CORK_STATE_DIR|g; s|/CORK/|/$cork/|g" "$output"
    fi
    
    # Created files
    if [ -f "$CORK_STATE_DIR/$cork/files.list" ]; then
        cat >> "$output" << 'FILES'
# Remove created files
info "Removing created files..."
grep "^CREATED " CORK_STATE_DIR/CORK/files.list | cut -d' ' -f2- | while read file; do
    [ -f "$file" ] && rm -f "$file"
done

FILES
        sed -i "s|CORK_STATE_DIR|$CORK_STATE_DIR|g; s|/CORK/|/$cork/|g" "$output"
    fi
    
    # Config restoration
    cat >> "$output" << 'RESTORE'
# Restore original configs
info "Restoring config files..."
BACKUP_DIR="CORK_STATE_DIR/CORK/config-backup"
if [ -d "$BACKUP_DIR" ]; then
    find "$BACKUP_DIR" -type f | while read backup; do
        original=$(echo "$backup" | sed "s|$BACKUP_DIR||")
        [ -f "$original" ] && cp -a "$backup" "$original"
    done
fi

info "Uninstall complete: CORK"
RESTORE
    sed -i "s|CORK_STATE_DIR|$CORK_STATE_DIR|g; s|CORK|$cork|g" "$output"
    
    chmod +x "$output"
    info "Generated: $output"
}

# Uninstall a single cork
uninstall_cork() {
    local cork="$1"
    local force="${2:-no}"
    
    step "UNINSTALLING: $cork"
    
    # Check if cork is installed
    if [ ! -d "$CORK_STATE_DIR/$cork" ]; then
        err "Cork not installed: $cork"
    fi
    
    # Check dependencies
    local dependents=$(get_dependents "$cork")
    if [ -n "$dependents" ]; then
        warn "Other corks depend on $cork:"
        echo "$dependents" | while read dep; do
            echo "    - $dep"
        done
        
        if [ "$force" != "yes" ]; then
            printf "\n  Options:\n"
            printf "    [1] Uninstall $cork and all dependents\n"
            printf "    [2] Cancel\n"
            printf "    [3] Force remove (may break dependents)\n"
            printf "\n  Choice: "
            read -r choice
            
            case "$choice" in
                1)
                    # Uninstall dependents first (reverse order)
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
    
    # Run cork-provided uninstall script if exists
    if [ -f "$CORK_STATE_DIR/$cork/uninstall.sh" ]; then
        pure "Running cork uninstall script..."
        sh "$CORK_STATE_DIR/$cork/uninstall.sh"
    else
        # Generate and run uninstall script
        generate_uninstall_script "$cork"
        sh "$CORK_STATE_DIR/$cork/uninstall.sh"
    fi
    
    # Restore config files
    restore_config_files "$cork"
    
    # Remove from dependency graph
    unregister_cork "$cork"
    
    # Archive state (for potential recovery)
    local archive_dir="$STATE_DIR/archive/$(date +%Y%m%d-%H%M%S)-$cork"
    mkdir -p "$archive_dir"
    mv "$CORK_STATE_DIR/$cork" "$archive_dir/"
    
    info "Uninstalled: $cork"
    log "Uninstalled cork: $cork"
}

# ─────────────────────────────────────────────────────────────────────────────
# BASELINE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Create system baseline (before any corks)
create_baseline() {
    step "CREATING SYSTEM BASELINE"
    
    mkdir -p "$BASELINE_DIR"
    
    pure "This captures the current system state as the 'clean' baseline"
    pure "All future uninstalls will aim to restore to this state"
    
    capture_system_state "$BASELINE_DIR/system.json" "full"
    
    # Also capture package list
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --get-selections > "$BASELINE_DIR/packages.list"
    fi
    
    # Capture iptables/nftables
    iptables-save > "$BASELINE_DIR/iptables.rules" 2>/dev/null || true
    nft list ruleset > "$BASELINE_DIR/nftables.rules" 2>/dev/null || true
    
    # Capture systemd state
    systemctl list-unit-files --type=service > "$BASELINE_DIR/services.list"
    
    info "Baseline created: $BASELINE_DIR"
    log "System baseline created"
}

# Restore to baseline
restore_baseline() {
    step "RESTORING TO BASELINE"
    
    if [ ! -f "$BASELINE_DIR/system.json" ]; then
        err "No baseline found. Create one first with: ci5 pure baseline"
    fi
    
    warn "This will uninstall ALL corks and restore system to baseline state"
    printf "  Type 'RESTORE' to confirm: "
    read -r confirm
    [ "$confirm" = "RESTORE" ] || return 1
    
    # Get all installed corks in reverse dependency order
    local corks=$(ls -1 "$CORK_STATE_DIR" 2>/dev/null | sort -r)
    
    for cork in $corks; do
        uninstall_cork "$cork" "yes"
    done
    
    # Restore firewall rules
    if [ -f "$BASELINE_DIR/iptables.rules" ]; then
        pure "Restoring iptables rules..."
        iptables-restore < "$BASELINE_DIR/iptables.rules"
    fi
    
    if [ -f "$BASELINE_DIR/nftables.rules" ]; then
        pure "Restoring nftables rules..."
        nft -f "$BASELINE_DIR/nftables.rules"
    fi
    
    info "System restored to baseline"
    log "System restored to baseline"
}

# ─────────────────────────────────────────────────────────────────────────────
# SNAPSHOT MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Create named snapshot
create_snapshot() {
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"
    local snapshot_dir="$SNAPSHOTS_DIR/$name"
    
    step "CREATING SNAPSHOT: $name"
    
    mkdir -p "$snapshot_dir"
    
    # Capture current state
    capture_system_state "$snapshot_dir/system.json" "full"
    
    # Copy current cork states
    cp -r "$CORK_STATE_DIR" "$snapshot_dir/corks" 2>/dev/null || true
    
    # Copy dependency graph
    cp "$DEPS_FILE" "$snapshot_dir/dependencies.json" 2>/dev/null || true
    
    # Capture configs
    mkdir -p "$snapshot_dir/configs"
    for conf in /etc/ci5 /etc/wireguard /etc/unbound /etc/systemd/resolved.conf; do
        [ -e "$conf" ] && cp -r "$conf" "$snapshot_dir/configs/" 2>/dev/null || true
    done
    
    info "Snapshot created: $name"
    log "Snapshot created: $name"
}

# List snapshots
list_snapshots() {
    step "AVAILABLE SNAPSHOTS"
    
    if [ ! -d "$SNAPSHOTS_DIR" ] || [ -z "$(ls -A "$SNAPSHOTS_DIR" 2>/dev/null)" ]; then
        warn "No snapshots found"
        return
    fi
    
    printf "  %-25s %-20s %s\n" "NAME" "DATE" "CORKS"
    printf "  %-25s %-20s %s\n" "----" "----" "-----"
    
    for snap in "$SNAPSHOTS_DIR"/*; do
        [ -d "$snap" ] || continue
        local name=$(basename "$snap")
        local date=$(jq -r '.captured_at' "$snap/system.json" 2>/dev/null | cut -d'T' -f1)
        local corks=$(ls "$snap/corks" 2>/dev/null | wc -l)
        printf "  %-25s %-20s %s\n" "$name" "$date" "$corks"
    done
}

# Restore from snapshot
restore_snapshot() {
    local name="$1"
    local snapshot_dir="$SNAPSHOTS_DIR/$name"
    
    if [ ! -d "$snapshot_dir" ]; then
        err "Snapshot not found: $name"
    fi
    
    step "RESTORING SNAPSHOT: $name"
    
    warn "This will restore system to snapshot state"
    printf "  Confirm? [y/N]: "
    read -r confirm
    [ "$confirm" = "y" ] || return 1
    
    # TODO: Implement snapshot restoration
    # This would involve comparing current state to snapshot
    # and applying necessary changes
    
    info "Snapshot restoration not yet implemented"
}

# ─────────────────────────────────────────────────────────────────────────────
# AUTO-DETECT INSTALLED COMPONENTS
# ─────────────────────────────────────────────────────────────────────────────

detect_installed() {
    step "DETECTING INSTALLED COMPONENTS"
    
    local found=""
    
    # Check Docker containers
    if command -v docker >/dev/null 2>&1; then
        pure "Scanning Docker..."
        
        # Known CI5 container patterns
        local ci5_containers="adguard unbound suricata wireguard pihole nginx-proxy sqm"
        
        for pattern in $ci5_containers; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi "$pattern"; then
                local container=$(docker ps -a --format '{{.Names}}' | grep -i "$pattern" | head -1)
                echo "  Found container: $container"
                found="$found docker:$container"
            fi
        done
        
        # Check for CI5-labeled containers
        docker ps -a --filter "label=ci5" --format '{{.Names}}' 2>/dev/null | while read c; do
            echo "  Found CI5 container: $c"
            found="$found docker:$c"
        done
    fi
    
    # Check systemd services
    pure "Scanning services..."
    
    local ci5_services="ci5 adguard unbound wireguard wg-quick suricata sqm"
    
    for pattern in $ci5_services; do
        if systemctl list-units --type=service --all 2>/dev/null | grep -qi "$pattern"; then
            local service=$(systemctl list-units --type=service --all | grep -i "$pattern" | awk '{print $1}' | head -1)
            echo "  Found service: $service"
            found="$found service:$service"
        fi
    done
    
    # Check known config files
    pure "Scanning configs..."
    
    local ci5_configs="/etc/ci5 /etc/wireguard /etc/unbound /etc/adguardhome"
    
    for conf in $ci5_configs; do
        if [ -e "$conf" ]; then
            echo "  Found config: $conf"
            found="$found config:$conf"
        fi
    done
    
    # Check if we have state tracking
    if [ -d "$CORK_STATE_DIR" ]; then
        pure "Found tracked corks:"
        for cork in "$CORK_STATE_DIR"/*; do
            [ -d "$cork" ] || continue
            local name=$(basename "$cork")
            local status=$(jq -r '.status' "$cork/manifest.json" 2>/dev/null)
            printf "    %-20s %s\n" "$name" "($status)"
        done
    fi
    
    echo ""
    info "Detection complete"
    
    # Offer to register untracked components
    if [ -n "$found" ]; then
        printf "\n  Register untracked components? [y/N]: "
        read -r register
        
        if [ "$register" = "y" ]; then
            for item in $found; do
                local type=$(echo "$item" | cut -d: -f1)
                local name=$(echo "$item" | cut -d: -f2)
                
                # Create minimal state tracking
                local cork_name=$(echo "$name" | sed 's/[^a-zA-Z0-9]/-/g')
                mkdir -p "$CORK_STATE_DIR/$cork_name"
                
                cat > "$CORK_STATE_DIR/$cork_name/manifest.json" << EOF
{
    "cork": "$cork_name",
    "type": "$type",
    "original_name": "$name",
    "registered": "$(date -Iseconds)",
    "status": "registered",
    "note": "Auto-detected, not installed via ci5.run"
}
EOF
                
                register_cork "$cork_name" ""
                info "Registered: $cork_name"
            done
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "CI5 PURE STATUS"
    
    # Baseline
    printf "  ${B}Baseline:${N} "
    [ -f "$BASELINE_DIR/system.json" ] && printf "${G}Created${N}\n" || printf "${Y}Not created${N}\n"
    
    # Installed corks
    printf "\n  ${B}Installed Corks:${N}\n"
    if [ -d "$CORK_STATE_DIR" ] && [ -n "$(ls -A "$CORK_STATE_DIR" 2>/dev/null)" ]; then
        for cork in "$CORK_STATE_DIR"/*; do
            [ -d "$cork" ] || continue
            local name=$(basename "$cork")
            local status=$(jq -r '.status' "$cork/manifest.json" 2>/dev/null)
            local deps=$(get_dependencies "$name" | tr '\n' ',' | sed 's/,$//')
            local dependents=$(get_dependents "$name" | tr '\n' ',' | sed 's/,$//')
            
            printf "    ${M}%s${N}" "$name"
            [ -n "$deps" ] && printf " (depends: %s)" "$deps"
            [ -n "$dependents" ] && printf " ${Y}(required by: %s)${N}" "$dependents"
            printf "\n"
        done
    else
        printf "    ${D}None${N}\n"
    fi
    
    # Snapshots
    printf "\n  ${B}Snapshots:${N} "
    local snap_count=$(ls -1 "$SNAPSHOTS_DIR" 2>/dev/null | wc -l)
    printf "%s\n" "$snap_count"
    
    # Docker state
    if command -v docker >/dev/null 2>&1; then
        printf "\n  ${B}Docker:${N}\n"
        printf "    Containers: %s\n" "$(docker ps -q 2>/dev/null | wc -l) running / $(docker ps -aq 2>/dev/null | wc -l) total"
        printf "    Volumes: %s\n" "$(docker volume ls -q 2>/dev/null | wc -l)"
        printf "    Networks: %s\n" "$(docker network ls -q 2>/dev/null | wc -l)"
    fi
    
    printf "\n"
}

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
        printf "        ${Y}v3.0-PHOENIX${N}\n\n"
        
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
                if [ -d "$CORK_STATE_DIR" ] && [ -n "$(ls -A "$CORK_STATE_DIR" 2>/dev/null)" ]; then
                    printf "  Installed corks:\n"
                    local i=1
                    for cork in "$CORK_STATE_DIR"/*; do
                        [ -d "$cork" ] || continue
                        printf "    [%d] %s\n" "$i" "$(basename "$cork")"
                        i=$((i + 1))
                    done
                    printf "\n  Select cork (or name): "
                    read -r sel
                    
                    if echo "$sel" | grep -q '^[0-9]*$'; then
                        local cork_name=$(ls -1 "$CORK_STATE_DIR" | sed -n "${sel}p")
                    else
                        local cork_name="$sel"
                    fi
                    
                    [ -n "$cork_name" ] && uninstall_cork "$cork_name"
                else
                    warn "No corks installed"
                fi
                ;;
            2)
                clear
                restore_baseline
                ;;
            3)
                clear
                restore_baseline
                ;;
            4)
                clear
                create_baseline
                ;;
            5)
                clear
                printf "  Snapshot name: "
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
                if [ -f "$DEPS_FILE" ]; then
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
        
        printf "\n  Press Enter..."
        read -r _
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
CI5 Pure — Intelligent Uninstall & State Rollback v3.0

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
    
    mkdir -p "$CI5_DIR" "$STATE_DIR" "$CORK_STATE_DIR" "$BASELINE_DIR" "$SNAPSHOTS_DIR" "$HOOKS_DIR" "$UNINSTALL_HOOKS"
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
            [ -f "$DEPS_FILE" ] && jq '.' "$DEPS_FILE" || warn "No data"
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
