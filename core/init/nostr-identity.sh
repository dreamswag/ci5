#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# CI5 Nostr Identity (TrustZone Backed)
# ═══════════════════════════════════════════════════════════════════════════
#
# This script coordinates between the user and the TrustZone Enclave.
# It NEVER handles private keys - all signing happens in Secure World.
#
# Commands:
#   ci5 whoami              - Display identity info
#   ci5 verify <code>       - Hardware attestation for web auth
#   ci5 rate <id> <rating>  - Rate a cork (CORK/DORK)
#   ci5 submit <name>       - Submit a new cork
#   ci5 install <name>      - Install a cork
#   ci5 thread <category>   - Create forum thread
#   ci5 reply <event_id>    - Reply to a thread
#
# ═══════════════════════════════════════════════════════════════════════════

set -e

# Configuration
CI5_TEE_BIN="/usr/local/bin/ci5-tee-client"
CI5_RELAYS=("wss://relay.ci5.network" "wss://relay.damus.io" "wss://nos.lol")
CI5_API="https://api.ci5.network"
CI5_ALIAS_FILE="/etc/ci5/nostr/.alias"
CI5_CONFIG_DIR="/etc/ci5/nostr"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════

require_tee() {
    if ! command -v "$CI5_TEE_BIN" &> /dev/null; then
        echo -e "${R}Error: TrustZone Client ($CI5_TEE_BIN) not found.${N}"
        echo "  Ensure OP-TEE is enabled in /boot/firmware/config.txt"
        echo "  Build and install: cd /root/ci5/src/ci5-tee && make && sudo make install"
        exit 1
    fi
}

require_nak() {
    if ! command -v nak &> /dev/null; then
        echo -e "${R}Error: nak (Nostr Army Knife) not found.${N}"
        echo "  Install: wget -O /usr/local/bin/nak https://github.com/fiatjaf/nak/releases/latest/download/nak-linux-arm64 && chmod +x /usr/local/bin/nak"
        exit 1
    fi
}

get_npub() {
    # Ask TEE for the public key derived from Silicon HUK
    $CI5_TEE_BIN pubkey
}

get_timestamp() {
    date +%s
}

# Sign event via TEE and publish to relays
sign_and_publish() {
    local PAYLOAD="$1"
    local MSG="$2"

    # 1. Hardware Signing (Secure World)
    # The TEE generates the ID, signs it with the HUK-derived key,
    # and returns the full signed event object.
    local SIGNED_EVENT
    SIGNED_EVENT=$($CI5_TEE_BIN sign --payload "$PAYLOAD")

    if [ -z "$SIGNED_EVENT" ]; then
        echo -e "${R}Hardware Signing Failed.${N}"
        exit 1
    fi

    # 2. Publish to relays via nak
    local SUCCESS=0
    for RELAY in "${CI5_RELAYS[@]}"; do
        echo -e "${C}Publishing to $RELAY...${N}"
        if echo "$SIGNED_EVENT" | nak event "$RELAY" 2>/dev/null; then
            SUCCESS=1
            echo -e "${G}  ✓ Published${N}"
        else
            echo -e "${Y}  ✗ Failed${N}"
        fi
    done

    if [ $SUCCESS -eq 1 ]; then
        echo -e "\n${G}$MSG${N}"
    else
        echo -e "\n${R}Failed to broadcast to any relay.${N}"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════════

cmd_whoami() {
    require_tee

    local NPUB
    NPUB=$(get_npub)
    local ALIAS
    ALIAS=$( [ -f "$CI5_ALIAS_FILE" ] && cat "$CI5_ALIAS_FILE" || echo "(none)" )

    # Convert hex to bech32 npub using nak if available
    local NPUB_BECH32=""
    if command -v nak &> /dev/null; then
        NPUB_BECH32=$(echo "$NPUB" | nak encode npub 2>/dev/null || echo "")
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                CI5-ASH (Hardware TrustZone)                      ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║ %-64s ║\n" "PUBKEY: ${NPUB:0:16}...${NPUB:48}"
    if [ -n "$NPUB_BECH32" ]; then
        printf "║ %-64s ║\n" "NPUB:   ${NPUB_BECH32:0:24}..."
    fi
    printf "║ %-64s ║\n" "ALIAS:  $ALIAS"
    echo "║                                                                  ║"
    echo "║ 🔒 Key is locked to this physical CPU (ARM HUK).                 ║"
    echo "║    Cannot be exported, cloned, or migrated.                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

cmd_verify() {
    require_tee

    local CHALLENGE="$1"
    [ -z "$CHALLENGE" ] && { echo "Usage: ci5 verify <code>"; exit 1; }

    echo -e "${C}🔒 Requesting Hardware Attestation from TrustZone...${N}"

    # Generate Attestation Event via TEE
    local EVENT_JSON
    EVENT_JSON=$($CI5_TEE_BIN attest --challenge "$CHALLENGE")

    if [ -z "$EVENT_JSON" ]; then
        echo -e "${R}Hardware attestation failed.${N}"
        exit 1
    fi

    echo -e "${C}📡 Transmitting Proof to API...${N}"

    # Submit to API for verification
    local RESPONSE
    RESPONSE=$(curl -s -X POST "$CI5_API/v1/nostr/verify" \
        -H "Content-Type: application/json" \
        -d "{\"event\":$EVENT_JSON}")

    if echo "$RESPONSE" | grep -q '"verified"'; then
        echo -e "${G}✅ Session Verified. Hardware Authentic.${N}"
        echo ""
        echo "You can now use authenticated features on ci5.dev and ci5.network"
    elif echo "$RESPONSE" | grep -q '"banned"'; then
        echo -e "${R}❌ This hardware has been banned from the CI5 ecosystem.${N}"
        exit 1
    else
        echo -e "${R}❌ Verification Failed.${N}"
        echo "   Server Response: $RESPONSE"
        exit 1
    fi
}

cmd_alias() {
    require_tee

    local NEW_ALIAS="$1"
    [ -z "$NEW_ALIAS" ] && { echo "Usage: ci5 alias <name>"; exit 1; }

    # Validate alias (alphanumeric, 3-20 chars)
    if ! echo "$NEW_ALIAS" | grep -qE '^[a-zA-Z0-9_-]{3,20}$'; then
        echo -e "${R}Invalid alias. Use 3-20 alphanumeric characters.${N}"
        exit 1
    fi

    local NPUB
    NPUB=$(get_npub)
    local TIMESTAMP
    TIMESTAMP=$(get_timestamp)

    # Create Kind 0 (Metadata) event
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg name "$NEW_ALIAS" \
        --arg about "CI5-ASH Hardware Identity" \
        '{kind: 0, content: ({name: $name, about: $about, ci5_ash: true} | tostring), tags: [["ci5", "ash", "v1"]]}')

    echo -e "${C}Publishing alias '$NEW_ALIAS' to Nostr...${N}"
    sign_and_publish "$PAYLOAD" "✅ Alias set to: $NEW_ALIAS"

    # Save locally
    mkdir -p "$CI5_CONFIG_DIR"
    echo "$NEW_ALIAS" > "$CI5_ALIAS_FILE"
}

cmd_rate() {
    require_tee
    require_nak

    local ID="$1"
    local RATING="$2"

    [ -z "$RATING" ] && { echo "Usage: ci5 rate <cork_id> <CORK|DORK>"; exit 1; }

    # Validate rating
    RATING=$(echo "$RATING" | tr '[:lower:]' '[:upper:]')
    if [ "$RATING" != "CORK" ] && [ "$RATING" != "DORK" ]; then
        echo -e "${R}Rating must be CORK (good) or DORK (bad).${N}"
        exit 1
    fi

    echo -e "${C}Rating cork '$ID' as $RATING...${N}"

    # Construct Kind 30078 rating event
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg id "$ID" \
        --arg rating "$RATING" \
        '{kind: 30078, content: ({cork: $id, rating: $rating} | tostring), tags: [["d", ("cork:" + $id)], ["ci5", "dev", "rating"], ["e", $id]]}')

    sign_and_publish "$PAYLOAD" "✅ Rating recorded on ledger."
}

cmd_submit() {
    require_tee
    require_nak

    local NAME="$1"
    local REPO="$2"
    local DESC="$3"
    local RAM="$4"

    [ -z "$NAME" ] && { echo "Usage: ci5 submit <name> [repo] [description] [ram]"; exit 1; }

    echo -e "${C}Submitting cork '$NAME'...${N}"

    # Construct Kind 30078 submission event
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg name "$NAME" \
        --arg repo "${REPO:-}" \
        --arg desc "${DESC:-No description}" \
        --arg ram "${RAM:-unknown}" \
        '{kind: 30078, content: ({name: $name, repo: $repo, description: $desc, ram: $ram} | tostring), tags: [["d", ("cork:" + $name)], ["ci5", "dev", "submission"]]}')

    sign_and_publish "$PAYLOAD" "✅ Cork submission published."
}

cmd_install() {
    local NAME="$1"
    local AUTHOR="$2"

    [ -z "$NAME" ] && { echo "Usage: ci5 install <cork_name> [--author <npub>]"; exit 1; }

    echo -e "${C}Installing cork '$NAME'...${N}"

    # Query relay for cork manifest
    require_nak

    local FILTER="[{\"kinds\":[30078],\"#d\":[\"cork:$NAME\"],\"limit\":1}]"
    local EVENT
    EVENT=$(nak req "${CI5_RELAYS[0]}" "$FILTER" 2>/dev/null | head -1)

    if [ -z "$EVENT" ]; then
        echo -e "${R}Cork '$NAME' not found on relay.${N}"
        echo "Try: ci5 cork search $NAME"
        exit 1
    fi

    # Extract install command from event content
    local CONTENT
    CONTENT=$(echo "$EVENT" | jq -r '.content // empty')

    if [ -n "$CONTENT" ]; then
        local INSTALL_CMD
        INSTALL_CMD=$(echo "$CONTENT" | jq -r '.install // empty')

        if [ -n "$INSTALL_CMD" ]; then
            echo -e "${G}Running install command...${N}"
            echo "  $INSTALL_CMD"
            eval "$INSTALL_CMD"
        else
            echo -e "${Y}No install command specified. Manual install required.${N}"
        fi
    fi
}

cmd_thread() {
    require_tee
    require_nak

    local CATEGORY="$1"
    local TITLE="$2"
    local CONTENT="$3"

    [ -z "$TITLE" ] && { echo "Usage: ci5 thread <category> <title> [content]"; exit 1; }

    echo -e "${C}Creating thread in '$CATEGORY': $TITLE${N}"

    # Construct Kind 1 thread event
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg title "$TITLE" \
        --arg content "${CONTENT:-}" \
        --arg category "$CATEGORY" \
        '{kind: 1, content: (if $content != "" then ($title + "\n\n" + $content) else $title end), tags: [["ci5", "network", "post"], ["t", $category], ["subject", $title]]}')

    sign_and_publish "$PAYLOAD" "✅ Thread created."
}

cmd_reply() {
    require_tee
    require_nak

    local EVENT_ID="$1"
    local CONTENT="$2"

    [ -z "$CONTENT" ] && { echo "Usage: ci5 reply <event_id> <content>"; exit 1; }

    echo -e "${C}Replying to $EVENT_ID...${N}"

    # Construct Kind 1 reply event
    local PAYLOAD
    PAYLOAD=$(jq -n \
        --arg eventId "$EVENT_ID" \
        --arg content "$CONTENT" \
        '{kind: 1, content: $content, tags: [["ci5", "network", "reply"], ["e", $eventId, "", "reply"]]}')

    sign_and_publish "$PAYLOAD" "✅ Reply posted."
}

cmd_help() {
    echo ""
    echo "CI5 Nostr Identity Commands"
    echo "==========================="
    echo ""
    echo "  whoami              Display your hardware-bound identity"
    echo "  verify <code>       Verify hardware for web authentication"
    echo "  alias <name>        Set your public alias (Kind 0)"
    echo ""
    echo "  rate <id> <CORK|DORK>  Rate a cork"
    echo "  submit <name> ...      Submit a new cork"
    echo "  install <name>         Install a cork from registry"
    echo ""
    echo "  thread <cat> <title>   Create a forum thread"
    echo "  reply <id> <text>      Reply to a thread"
    echo ""
    echo "All commands use hardware signing via ARM TrustZone."
    echo "Your private key never leaves the Secure World."
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    whoami)   cmd_whoami ;;
    verify)   cmd_verify "$2" ;;
    alias)    cmd_alias "$2" ;;
    rate)     cmd_rate "$2" "$3" ;;
    submit)   cmd_submit "$2" "$3" "$4" "$5" ;;
    install)  cmd_install "$2" "$3" ;;
    thread)   cmd_thread "$2" "$3" "$4" ;;
    reply)    cmd_reply "$2" "$3" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Usage: ci5 <whoami|verify|alias|rate|submit|install|thread|reply|help>"
        echo "Run 'ci5 help' for more information."
        ;;
esac
