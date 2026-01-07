#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# CI5 Identity Initialization (Goldilocks Lite Wrapper)
# Wraps the new hardware-bound identity system
# ═══════════════════════════════════════════════════════════════════════════

GOLDILOCKS_SCRIPT="/root/ci5/scripts/identity/goldilocks-lite.sh"

# Fallback path if running from source/repo structure
[ ! -f "$GOLDILOCKS_SCRIPT" ] && GOLDILOCKS_SCRIPT="$(dirname "$0")/identity/goldilocks-lite.sh"

if [ ! -x "$GOLDILOCKS_SCRIPT" ]; then
    echo "❌ Critical Error: Identity script not found at $GOLDILOCKS_SCRIPT"
    exit 1
fi

echo "🦴 Initializing Ci5 Hardware Identity (Goldilocks Lite)..."

# Execute the new identity logic
"$GOLDILOCKS_SCRIPT" init

RET=$?
if [ $RET -eq 0 ]; then
    NPUB=$("$GOLDILOCKS_SCRIPT" npub)
    echo ""
    echo "✅ Identity Initialized: $NPUB"
    echo "   Hardware binding active (Serial + MAC + Salt)"
    echo ""
    echo "   To verify hardware integrity, run: $GOLDILOCKS_SCRIPT verify"
else
    echo "❌ Identity Initialization Failed!"
    exit $RET
fi