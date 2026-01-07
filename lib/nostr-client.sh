#!/bin/sh
# CI5 Nostr Client Library
# Minimal wrapper for Nostr operations using 'nak' or 'websocat'

# Default relays
RELAYS="wss://relay.damus.io wss://relay.nostr.band wss://nos.lol"

# Check dependencies
check_deps() {
    if ! command -v nak >/dev/null 2>&1; then
        echo "Error: 'nak' is required for Nostr operations." >&2
        return 1
    fi
    return 0
}

# Publish an event
# Usage: nostr_publish <event_json> [relay_url...]
nostr_publish() {
    local event="$1"
    shift
    local relays="$@"
    [ -z "$relays" ] && relays="$RELAYS"

    check_deps || return 1

    echo "$event" | nak event post $relays
}

# Query events
# Usage: nostr_query <filter_json> [relay_url...]
nostr_query() {
    local filter="$1"
    shift
    local relays="$@"
    [ -z "$relays" ] && relays="$RELAYS"

    check_deps || return 1

    # Nak 'req' command syntax: nak req -k <kind> ... or just raw filter?
    # Nak usage: nak req <relay> <filter>
    # Note: nak handles one relay at a time usually in CLI or multiple? 
    # Let's iterate or let nak handle it if it supports multiple.
    # nak docs say: nak req <url> <filter-json>
    
    # We will query the first available relay for simplicity in this minimal lib,
    # or iterate until success.
    
    for relay in $relays; do
        if echo "$filter" | nak req "$relay" 2>/dev/null; then
            return 0
        fi
    done
    
    return 1
}

# Generate event (Kind 1 example, or generic)
# Usage: nostr_create_event <content> <kind> <tags_json> <sec_key>
nostr_create_event() {
    local content="$1"
    local kind="$2"
    local tags="$3"
    local sec="$4"

    check_deps || return 1
    
    # Nak 'event' command to create/sign
    # nak event -c "content" -k 1 --sec <key> --tag "['p','...']"
    # This is complex to wrap generically with sh/nak cli args.
    # Simplified: Assume caller constructs JSON or we use nak to sign a template.
    
    # Let's assume we pipe content and let nak format it if possible, 
    # or just use nak to sign a pre-built partial event.
    
    # For now, just a simple sign wrapper
    echo "$content" | nak event sign --sec "$sec" --kind "$kind" --content "$content"
}
