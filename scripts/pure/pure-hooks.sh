#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/pure-hooks — State Tracking Hooks for Cork Installers
# Version: 3.0-PHOENIX
# 
# Source this in your cork install script to enable automatic state tracking:
#
#   . <(curl -sSL ci5.run/pure-hooks)
#   
#   pre_install_hook "mycork" "adguard,unbound"
#   
#   # ... your install logic here ...
#   
#   post_install_hook "mycork"
#
# This enables clean uninstall via: ci5 pure mycork
# ═══════════════════════════════════════════════════════════════════════════

# Configuration
CI5_DIR="/etc/ci5"
STATE_DIR="$CI5_DIR/state"
CORK_STATE_DIR="$STATE_DIR/corks"
DEPS_FILE="$STATE_DIR/dependencies.json"

# Ensure directories exist
mkdir -p "$CI5_DIR" "$STATE_DIR" "$CORK_STATE_DIR"
[ -f "$DEPS_FILE" ] || echo '{"corks":{},"edges":[]}' > "$DEPS_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# STATE CAPTURE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Capture system state to JSON
_capture_state() {
    local output="$1"
    local state='{"captured_at":"'"$(date -Iseconds)"'"}'
    
    # Docker
    if command -v docker >/dev/null 2>&1; then
        local containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local volumes=$(docker volume ls -q 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
        local networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v "^bridge$\|^host$\|^none$" | sort | tr '\n' ',' | sed 's/,$//')
        
        state=$(echo "$state" | jq \
            --arg c "$containers" --arg i "$images" --arg v "$volumes" --arg n "$networks" \
            '.docker = {containers: ($c | split(",") | map(select(.!=""))), images: ($i | split(",") | map(select(.!=""))), volumes: ($v | split(",") | map(select(.!=""))), networks: ($n | split(",") | map(select(.!="")))}')
    fi
    
    # Network
    local ports=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg p "$ports" '.network = {listening: ($p | split(",") | map(select(.!="")))}')
    
    # Services
    local services=$(systemctl list-unit-files --type=service --state=enabled 2>/dev/null | awk 'NR>1 && !/listed/ {print $1}' | sort | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg s "$services" '.services = {enabled: ($s | split(",") | map(select(.!="")))}')
    
    echo "$state" > "$output"
}

# Calculate state diff
_calc_diff() {
    local pre="$1" post="$2" output="$3"
    local diff='{}'
    
    # Docker additions
    if jq -e '.docker' "$pre" >/dev/null 2>&1; then
        local new_c=$(jq -r '.docker.containers[]' "$post" 2>/dev/null | while read c; do
            jq -e --arg c "$c" '.docker.containers | index($c)' "$pre" >/dev/null 2>&1 || echo "$c"
        done | tr '\n' ',' | sed 's/,$//')
        
        local new_v=$(jq -r '.docker.volumes[]' "$post" 2>/dev/null | while read v; do
            jq -e --arg v "$v" '.docker.volumes | index($v)' "$pre" >/dev/null 2>&1 || echo "$v"
        done | tr '\n' ',' | sed 's/,$//')
        
        local new_n=$(jq -r '.docker.networks[]' "$post" 2>/dev/null | while read n; do
            jq -e --arg n "$n" '.docker.networks | index($n)' "$pre" >/dev/null 2>&1 || echo "$n"
        done | tr '\n' ',' | sed 's/,$//')
        
        local new_i=$(jq -r '.docker.images[]' "$post" 2>/dev/null | while read i; do
            jq -e --arg i "$i" '.docker.images | index($i)' "$pre" >/dev/null 2>&1 || echo "$i"
        done | tr '\n' ',' | sed 's/,$//')
        
        diff=$(echo "$diff" | jq \
            --arg c "$new_c" --arg v "$new_v" --arg n "$new_n" --arg i "$new_i" \
            '.docker = {added_containers: ($c | split(",") | map(select(.!=""))), added_volumes: ($v | split(",") | map(select(.!=""))), added_networks: ($n | split(",") | map(select(.!=""))), added_images: ($i | split(",") | map(select(.!="")))}')
    fi
    
    # Service additions
    local new_svc=$(jq -r '.services.enabled[]' "$post" 2>/dev/null | while read s; do
        jq -e --arg s "$s" '.services.enabled | index($s)' "$pre" >/dev/null 2>&1 || echo "$s"
    done | tr '\n' ',' | sed 's/,$//')
    
    diff=$(echo "$diff" | jq --arg s "$new_svc" '.services = {added: ($s | split(",") | map(select(.!="")))}')
    
    echo "$diff" > "$output"
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE TRACKING
# ─────────────────────────────────────────────────────────────────────────────

_TRACK_DIRS="/etc /opt /var/lib /usr/local"

_start_tracking() {
    local cork="$1"
    local track_file="$CORK_STATE_DIR/$cork/.file_baseline"
    
    for dir in $_TRACK_DIRS; do
        [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
    done | sort > "$track_file"
}

_stop_tracking() {
    local cork="$1"
    local baseline="$CORK_STATE_DIR/$cork/.file_baseline"
    local changes="$CORK_STATE_DIR/$cork/files.list"
    
    [ -f "$baseline" ] || return
    
    local current=$(mktemp)
    for dir in $_TRACK_DIRS; do
        [ -d "$dir" ] && find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null
    done | sort > "$current"
    
    {
        comm -23 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) | sed 's/^/CREATED /'
        comm -12 <(awk '{print $2}' "$current" | sort) <(awk '{print $2}' "$baseline" | sort) | while read f; do
            local old=$(grep " $f$" "$baseline" | awk '{print $1}')
            local new=$(grep " $f$" "$current" | awk '{print $1}')
            [ "$old" != "$new" ] && echo "MODIFIED $f"
        done
    } > "$changes"
    
    rm -f "$baseline" "$current"
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

_register_deps() {
    local cork="$1"
    local deps="$2"
    
    local temp=$(mktemp)
    jq --arg cork "$cork" --arg time "$(date -Iseconds)" \
        '.corks[$cork] = {"installed": $time, "dependents": []}' \
        "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"
    
    if [ -n "$deps" ]; then
        for dep in $(echo "$deps" | tr ',' ' '); do
            jq --arg cork "$cork" --arg dep "$dep" \
                '.edges += [{"from": $cork, "to": $dep}] | .corks[$dep].dependents += [$cork]' \
                "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

# Call before installing cork
# Usage: pre_install_hook <cork_name> [depends_on]
pre_install_hook() {
    local cork="$1"
    local depends_on="$2"
    
    echo "[ci5] Pre-install hook: $cork"
    
    mkdir -p "$CORK_STATE_DIR/$cork"
    
    # Check dependencies exist
    if [ -n "$depends_on" ]; then
        for dep in $(echo "$depends_on" | tr ',' ' '); do
            if [ ! -d "$CORK_STATE_DIR/$dep" ]; then
                echo "[ci5] Warning: Dependency not installed: $dep"
            fi
        done
    fi
    
    # Capture pre-state
    _capture_state "$CORK_STATE_DIR/$cork/pre-state.json"
    
    # Start file tracking
    _start_tracking "$cork"
    
    # Create manifest
    cat > "$CORK_STATE_DIR/$cork/manifest.json" << EOF
{
    "cork": "$cork",
    "install_started": "$(date -Iseconds)",
    "depends_on": $(echo "$depends_on" | awk -F, '{printf "["; for(i=1;i<=NF;i++) printf "\"%s\"%s", $i, (i<NF?",":""); printf "]"}'),
    "status": "installing"
}
EOF
    
    # Register dependencies
    _register_deps "$cork" "$depends_on"
}

# Call after installing cork
# Usage: post_install_hook <cork_name> [uninstall_script_path]
post_install_hook() {
    local cork="$1"
    local uninstall_script="$2"
    
    echo "[ci5] Post-install hook: $cork"
    
    # Capture post-state
    _capture_state "$CORK_STATE_DIR/$cork/post-state.json"
    
    # Stop file tracking
    _stop_tracking "$cork"
    
    # Calculate diff
    _calc_diff \
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
    jq -r '.services.added[]' "$CORK_STATE_DIR/$cork/changes.json" 2>/dev/null | \
        grep -v '^$' > "$CORK_STATE_DIR/$cork/services.list"
    
    # Save uninstall script
    if [ -n "$uninstall_script" ] && [ -f "$uninstall_script" ]; then
        cp "$uninstall_script" "$CORK_STATE_DIR/$cork/uninstall.sh"
        chmod +x "$CORK_STATE_DIR/$cork/uninstall.sh"
    fi
    
    # Update manifest
    local temp=$(mktemp)
    jq --arg time "$(date -Iseconds)" '.install_completed = $time | .status = "installed"' \
        "$CORK_STATE_DIR/$cork/manifest.json" > "$temp" && mv "$temp" "$CORK_STATE_DIR/$cork/manifest.json"
    
    echo "[ci5] Cork installed: $cork"
    echo "[ci5] Uninstall with: ci5 pure $cork"
}

# Backup a config file before modifying
# Usage: backup_config <cork_name> <file_path>
backup_config() {
    local cork="$1"
    local file="$2"
    local backup_dir="$CORK_STATE_DIR/$cork/config-backup"
    
    mkdir -p "$backup_dir"
    
    if [ -f "$file" ]; then
        local rel=$(echo "$file" | sed 's|^/||')
        mkdir -p "$backup_dir/$(dirname "$rel")"
        cp -a "$file" "$backup_dir/$rel"
        echo "[ci5] Backed up: $file"
    fi
}

# Declare a dependency relationship (can call multiple times)
# Usage: declare_dependency <cork_name> <depends_on>
declare_dependency() {
    local cork="$1"
    local dep="$2"
    
    local temp=$(mktemp)
    jq --arg cork "$cork" --arg dep "$dep" \
        '.edges += [{"from": $cork, "to": $dep}] | .corks[$dep].dependents += [$cork]' \
        "$DEPS_FILE" > "$temp" && mv "$temp" "$DEPS_FILE"
}

# Record custom uninstall action
# Usage: record_uninstall_action <cork_name> <action_description>
record_uninstall_action() {
    local cork="$1"
    local action="$2"
    
    echo "$action" >> "$CORK_STATE_DIR/$cork/custom_actions.list"
}

# ─────────────────────────────────────────────────────────────────────────────
# EXAMPLE USAGE
# ─────────────────────────────────────────────────────────────────────────────

# Example cork install script:
#
# #!/bin/sh
# # my-cork install script
# 
# # Source hooks
# . <(curl -sSL ci5.run/pure-hooks)
# 
# # Declare this cork and its dependencies
# pre_install_hook "my-cork" "adguard,unbound"
# 
# # Backup any configs we'll modify
# backup_config "my-cork" "/etc/resolv.conf"
# backup_config "my-cork" "/etc/systemd/resolved.conf"
# 
# # Your actual install logic
# docker run -d --name my-container ...
# cp my-config /etc/my-cork/
# systemctl enable my-service
# 
# # Complete the install (auto-tracks all changes)
# post_install_hook "my-cork"
#
# # Or with custom uninstall script:
# post_install_hook "my-cork" "/path/to/my-uninstall.sh"
