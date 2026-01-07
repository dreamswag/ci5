#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/focus — Distraction-Free Mode (Site Blocker)
# Version: 1.0-PHOENIX
#
# Temporarily blocks distracting websites at the DNS level for focused work.
# Works by modifying /etc/hosts to redirect sites to 0.0.0.0.
#
# Features:
#   - Configurable block duration
#   - Preset categories (social, video, news, gaming)
#   - Custom domain lists
#   - Automatic cleanup via background timer
#   - Manual early exit option
#
# Usage:
#   curl -sL ci5.run | sh -s focus              # Default 1 hour, standard sites
#   curl -sL ci5.run | sh -s focus 2h           # 2 hours
#   curl -sL ci5.run | sh -s focus 30m social   # 30 mins, social only
#   curl -sL ci5.run | sh -s focus stop         # Remove blocks early
#   curl -sL ci5.run | sh -s focus status       # Show current blocks
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CI5_DIR="/etc/ci5"
FOCUS_DIR="$CI5_DIR/focus"
FOCUS_STATE="$FOCUS_DIR/state"
FOCUS_TIMER="$FOCUS_DIR/timer.pid"
HOSTS_FILE="/etc/hosts"

# Block marker (used to identify our additions)
BLOCK_START="### CI5 FOCUS MODE START ###"
BLOCK_END="### CI5 FOCUS MODE END ###"

# Site categories
SOCIAL_SITES="
facebook.com www.facebook.com m.facebook.com
twitter.com www.twitter.com mobile.twitter.com
x.com www.x.com
instagram.com www.instagram.com
tiktok.com www.tiktok.com
snapchat.com www.snapchat.com
linkedin.com www.linkedin.com
pinterest.com www.pinterest.com
reddit.com www.reddit.com old.reddit.com
threads.net www.threads.net
mastodon.social
bsky.app
discord.com www.discord.com
"

VIDEO_SITES="
youtube.com www.youtube.com m.youtube.com youtu.be
netflix.com www.netflix.com
twitch.tv www.twitch.tv
hulu.com www.hulu.com
disneyplus.com www.disneyplus.com
primevideo.com www.primevideo.com
vimeo.com www.vimeo.com
dailymotion.com www.dailymotion.com
"

NEWS_SITES="
news.google.com
news.ycombinator.com
cnn.com www.cnn.com
bbc.com www.bbc.com bbc.co.uk www.bbc.co.uk
foxnews.com www.foxnews.com
nytimes.com www.nytimes.com
washingtonpost.com www.washingtonpost.com
theguardian.com www.theguardian.com
"

GAMING_SITES="
steampowered.com store.steampowered.com
epicgames.com www.epicgames.com
origin.com www.origin.com
gog.com www.gog.com
itch.io www.itch.io
roblox.com www.roblox.com
minecraft.net www.minecraft.net
"

# Default is social + video
DEFAULT_SITES="$SOCIAL_SITES $VIDEO_SITES"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

DURATION="1h"
CATEGORIES=""
ACTION="start"

parse_duration() {
    local input="$1"
    local num="${input%[hHmMsS]}"
    local unit="${input#$num}"
    
    case "$unit" in
        h|H) echo "$((num * 3600))" ;;
        m|M) echo "$((num * 60))" ;;
        s|S) echo "$num" ;;
        *)   echo "$((num * 60))" ;;  # Default to minutes
    esac
}

for arg in "$@"; do
    case "$arg" in
        stop|off|disable)
            ACTION="stop"
            ;;
        status)
            ACTION="status"
            ;;
        social|video|news|gaming|all)
            CATEGORIES="$CATEGORIES $arg"
            ;;
        *[0-9][hHmMsS])
            DURATION="$arg"
            ;;
        --help|-h)
            cat << 'HELP'
CI5 Focus Mode — Distraction Blocker

Usage: curl -sL ci5.run | sh -s focus [DURATION] [CATEGORIES]

Duration (default: 1h):
  30m, 1h, 2h, etc.    Minutes or hours

Categories:
  social               Facebook, Twitter/X, Instagram, TikTok, Reddit, etc.
  video                YouTube, Netflix, Twitch, etc.
  news                 CNN, BBC, NYT, HackerNews, etc.
  gaming               Steam, Epic, GOG, etc.
  all                  All of the above

  Default (no category): social + video

Commands:
  stop                 Remove blocks early
  status               Show current block status

Examples:
  curl -sL ci5.run | sh -s focus              # 1h, social+video
  curl -sL ci5.run | sh -s focus 2h           # 2 hours
  curl -sL ci5.run | sh -s focus 30m social   # 30 min social only
  curl -sL ci5.run | sh -s focus all          # 1h, everything
  curl -sL ci5.run | sh -s focus stop         # Remove blocks

Note: Focus mode modifies /etc/hosts. Changes persist until timer
expires or you run 'focus stop'.
HELP
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || err "Must run as root"

mkdir -p "$FOCUS_DIR"

get_sites_for_categories() {
    local sites=""
    
    # Default if no categories specified
    if [ -z "$CATEGORIES" ]; then
        echo "$DEFAULT_SITES"
        return
    fi
    
    for cat in $CATEGORIES; do
        case "$cat" in
            social) sites="$sites $SOCIAL_SITES" ;;
            video)  sites="$sites $VIDEO_SITES" ;;
            news)   sites="$sites $NEWS_SITES" ;;
            gaming) sites="$sites $GAMING_SITES" ;;
            all)    sites="$SOCIAL_SITES $VIDEO_SITES $NEWS_SITES $GAMING_SITES" ;;
        esac
    done
    
    echo "$sites"
}

is_focus_active() {
    grep -q "$BLOCK_START" "$HOSTS_FILE" 2>/dev/null
}

format_time_remaining() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    
    if [ "$hours" -gt 0 ]; then
        printf "%dh %dm" "$hours" "$minutes"
    else
        printf "%dm" "$minutes"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                     CI5 FOCUS MODE STATUS                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if ! is_focus_active; then
        printf "${D}●${N} Focus mode: ${D}INACTIVE${N}\n"
        echo ""
        echo "To start focus mode:"
        echo "  curl -sL ci5.run | sh -s focus"
        return
    fi
    
    printf "${G}●${N} Focus mode: ${G}ACTIVE${N}\n"
    
    # Check timer
    if [ -f "$FOCUS_STATE" ]; then
        local end_time=$(cat "$FOCUS_STATE" 2>/dev/null)
        local now=$(date +%s)
        local remaining=$((end_time - now))
        
        if [ "$remaining" -gt 0 ]; then
            printf "  Time remaining: ${Y}%s${N}\n" "$(format_time_remaining $remaining)"
        else
            printf "  Timer expired (cleanup pending)\n"
        fi
    fi
    
    # Count blocked sites
    local count=$(sed -n "/$BLOCK_START/,/$BLOCK_END/p" "$HOSTS_FILE" 2>/dev/null | grep "^0.0.0.0" | wc -l)
    printf "  Blocked sites: ${R}%d${N}\n" "$count"
    
    echo ""
    echo "To end early:"
    echo "  curl -sL ci5.run | sh -s focus stop"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENABLE FOCUS
# ─────────────────────────────────────────────────────────────────────────────

enable_focus() {
    local duration_seconds=$(parse_duration "$DURATION")
    local sites=$(get_sites_for_categories)
    
    # Check if already active
    if is_focus_active; then
        warn "Focus mode already active!"
        echo "Run 'ci5 focus stop' to disable first, or wait for timer to expire."
        show_status
        exit 1
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    CI5 FOCUS MODE — ENGAGE                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    info "Duration: $DURATION (${duration_seconds}s)"
    info "Categories: ${CATEGORIES:-social video (default)}"
    echo ""
    
    # Backup hosts file
    cp "$HOSTS_FILE" "$FOCUS_DIR/hosts.backup"
    
    # Add block entries
    {
        echo ""
        echo "$BLOCK_START"
        echo "# Added: $(date)"
        echo "# Duration: $DURATION"
        echo "# Expires: $(date -d "@$(($(date +%s) + duration_seconds))" 2>/dev/null || date -r "$(($(date +%s) + duration_seconds))" 2>/dev/null || echo "in $DURATION")"
        for site in $sites; do
            site=$(echo "$site" | tr -d ' ')
            [ -n "$site" ] && echo "0.0.0.0 $site"
        done
        echo "$BLOCK_END"
    } >> "$HOSTS_FILE"
    
    # Count unique sites
    local count=$(echo "$sites" | tr ' ' '\n' | grep -v '^$' | wc -l)
    info "Blocked $count domains"
    
    # Flush DNS cache
    if command -v systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches 2>/dev/null || true
    fi
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches 2>/dev/null || true
    fi
    # For dnsmasq (common on Pi routers)
    if [ -x /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart
    fi
    
    # Save end time
    local end_time=$(($(date +%s) + duration_seconds))
    echo "$end_time" > "$FOCUS_STATE"
    
    # Start background timer for cleanup
    (
        sleep "$duration_seconds"
        # Auto-cleanup when timer expires
        if [ -f "$FOCUS_STATE" ]; then
            # Remove block from hosts
            sed -i "/$BLOCK_START/,/$BLOCK_END/d" "$HOSTS_FILE"
            rm -f "$FOCUS_STATE" "$FOCUS_TIMER"
            
            # Flush DNS again
            systemd-resolve --flush-caches 2>/dev/null || true
            resolvectl flush-caches 2>/dev/null || true
            killall -HUP dnsmasq 2>/dev/null || true
            
            # Optional: notify (if running interactively)
            logger "CI5 Focus Mode: Timer expired, sites unblocked"
        fi
    ) &
    
    echo "$!" > "$FOCUS_TIMER"
    
    echo ""
    printf "${G}╔═══════════════════════════════════════════════════════════════════╗${N}\n"
    printf "${G}║${N}            🎯 ${B}FOCUS MODE ACTIVE${N} — Time to do deep work!           ${G}║${N}\n"
    printf "${G}╚═══════════════════════════════════════════════════════════════════╝${N}\n"
    echo ""
    echo "Sites will be automatically unblocked in $DURATION"
    echo "To end early: curl -sL ci5.run | sh -s focus stop"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE FOCUS
# ─────────────────────────────────────────────────────────────────────────────

disable_focus() {
    echo ""
    
    if ! is_focus_active; then
        info "Focus mode is not active"
        return 0
    fi
    
    # Kill timer if running
    if [ -f "$FOCUS_TIMER" ]; then
        local pid=$(cat "$FOCUS_TIMER")
        kill "$pid" 2>/dev/null || true
        rm -f "$FOCUS_TIMER"
    fi
    
    # Remove block from hosts file
    # Use temp file for safety
    local temp=$(mktemp)
    sed "/$BLOCK_START/,/$BLOCK_END/d" "$HOSTS_FILE" > "$temp"
    mv "$temp" "$HOSTS_FILE"
    chmod 644 "$HOSTS_FILE"
    
    # Clean state
    rm -f "$FOCUS_STATE"
    
    # Flush DNS
    if command -v systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches 2>/dev/null || true
    fi
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches 2>/dev/null || true
    fi
    if [ -x /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart
    fi
    
    info "Focus mode disabled"
    info "All sites are now accessible"
    echo ""
    
    # Calculate how much focus time was achieved
    if [ -f "$FOCUS_DIR/hosts.backup" ]; then
        local started=$(stat -c %Y "$FOCUS_DIR/hosts.backup" 2>/dev/null || stat -f %m "$FOCUS_DIR/hosts.backup" 2>/dev/null)
        if [ -n "$started" ]; then
            local elapsed=$(($(date +%s) - started))
            info "You focused for: $(format_time_remaining $elapsed)"
        fi
    fi
    
    # Cleanup backup
    rm -f "$FOCUS_DIR/hosts.backup"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

case "$ACTION" in
    start)   enable_focus ;;
    stop)    disable_focus ;;
    status)  show_status ;;
esac
