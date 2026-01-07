#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/pure-hooks — Procd Compliant Hooks
# ═══════════════════════════════════════════════════════════════════════════

# Configuration
CI5_DIR="/etc/ci5"
STATE_DIR="$CI5_DIR/state"
CORK_STATE_DIR="$STATE_DIR/corks"
DEPS_FILE="$STATE_DIR/dependencies.json"

_capture_state() {
    local output="$1"
    local state='{"captured_at":"'"$(date -Iseconds)"'"}'
    
    # Services (Procd)
    local services=$(ls /etc/rc.d/S* 2>/dev/null | awk -F'S[0-9]+' '{print $2}' | sort | tr '\n' ',' | sed 's/,$//')
    state=$(echo "$state" | jq --arg s "$services" '.services = {enabled: ($s | split(",") | map(select(.!="")))}')
    
    echo "$state" > "$output"
}

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

pre_install_hook() {
    local cork="$1"
    local depends_on="$2"
    
    mkdir -p "$CORK_STATE_DIR/$cork"
    _capture_state "$CORK_STATE_DIR/$cork/pre-state.json"
}

post_install_hook() {
    local cork="$1"
    _capture_state "$CORK_STATE_DIR/$cork/post-state.json"
}