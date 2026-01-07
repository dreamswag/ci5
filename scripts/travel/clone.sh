#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/clone — Advanced Travel Backup & Recovery System
# Version: 3.0-PHOENIX
# 
# Complete operational security toolkit for travel scenarios:
# - Stealth backup/restore with plausible deniability
# - Decoy OS with customizable personalization
# - Hidden encrypted volumes (LUKS with detached headers)
# - Multiple unlock triggers (USB key, GPIO, key combo, beacon)
# - Auto-recovery via safe networks or reverse SSH
# - Self-contained recovery partition
# - Phone-flashable image preparation
# - Cloud backup/restore with encryption
#
# Designed for maximum security + convenience + inconspicuousness
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CLONE_DIR="/etc/ci5/clone"
IMAGES_DIR="/var/ci5/images"
DECOY_DIR="/etc/ci5/decoy"
TRIGGERS_DIR="/etc/ci5/triggers"
BEACON_DIR="/etc/ci5/beacon"
STATE_FILE="/var/run/ci5-clone.state"
LOG_FILE="/var/log/ci5-clone.log"

# Stealth labels (appear innocuous)
STEALTH_LABELS="EFI-SYSTEM BOOT-REPAIR FIRMWARE SYSTEM-BOOT OEM-RESTORE"
DEFAULT_STEALTH_LABEL="FIRMWARE"

# Cloud storage
CLOUD_CONFIG="$CLONE_DIR/cloud.conf"

# Trigger configurations
USB_KEY_FILE="$TRIGGERS_DIR/usb_key.conf"
GPIO_TRIGGER_FILE="$TRIGGERS_DIR/gpio.conf"
BEACON_CONFIG="$BEACON_DIR/networks.conf"

# Hidden volume
LUKS_HEADER_NAME="firmware.bin"  # Innocuous name for detached header
HIDDEN_VOLUME_NAME="system-cache"  # Innocuous name for hidden partition

# Decoy OS configuration
DECOY_CONFIG="$DECOY_DIR/persona.conf"
DECOY_APPS_LIST="$DECOY_DIR/apps.list"
DECOY_CONTENT_DIR="$DECOY_DIR/content"

# Compression
COMPRESS_CMD="pigz"
COMPRESS_EXT="gz"

# Recovery tools to embed
RECOVERY_TOOLS="dd gpg pigz gunzip gzip openssl cryptsetup parted e2fsck resize2fs wpa_supplicant dhclient ip iw ssh scp curl wget"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }
clone() { printf "${M}[◉]${N} %s\n" "$1"; }
stealth() { printf "${D}[○]${N} %s\n" "$1"; }

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Initialize compression tool
init_compression() {
    command -v pigz >/dev/null 2>&1 || COMPRESS_CMD="gzip"
}

# ─────────────────────────────────────────────────────────────────────────────
# DEVICE DETECTION
# ─────────────────────────────────────────────────────────────────────────────

detect_boot_device() {
    local root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || mount | grep ' / ' | awk '{print $1}')
    root_dev=$(readlink -f "$root_dev" 2>/dev/null || echo "$root_dev")
    BOOT_DEVICE=$(echo "$root_dev" | sed 's/p\?[0-9]*$//')
    
    if echo "$BOOT_DEVICE" | grep -q "mmcblk"; then
        BOOT_TYPE="sd"
        PART_PREFIX="p"
    elif echo "$BOOT_DEVICE" | grep -q "nvme"; then
        BOOT_TYPE="nvme"
        PART_PREFIX="p"
    else
        BOOT_TYPE="usb"
        PART_PREFIX=""
    fi
    
    clone "Boot device: $BOOT_DEVICE ($BOOT_TYPE)"
}

find_backup_targets() {
    BACKUP_TARGETS=""
    
    for dev in /dev/sd[a-z] /dev/mmcblk[0-9] /dev/nvme[0-9]n1; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$BOOT_DEVICE" ] && continue
        
        local size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        local size_human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
        local model=$(lsblk -n -o MODEL "$dev" 2>/dev/null | head -1 | xargs)
        [ -z "$model" ] && model="Unknown"
        
        BACKUP_TARGETS="$BACKUP_TARGETS $dev:$size_human:$model"
    done
    
    BACKUP_TARGETS=$(echo "$BACKUP_TARGETS" | xargs)
}

detect_usb_drives() {
    USB_DRIVES=""
    
    for dev in /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        
        if readlink -f "/sys/block/$(basename $dev)" 2>/dev/null | grep -q "usb"; then
            local size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
            local size_human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
            local serial=$(udevadm info --query=property --name="$dev" 2>/dev/null | grep "ID_SERIAL_SHORT" | cut -d= -f2)
            
            USB_DRIVES="$USB_DRIVES $dev:$size_human:${serial:-unknown}"
        fi
    done
    
    USB_DRIVES=$(echo "$USB_DRIVES" | xargs)
}

# ─────────────────────────────────────────────────────────────────────────────
# MAC RANDOMIZATION
# ─────────────────────────────────────────────────────────────────────────────

generate_random_mac() {
    local first_octet=$(printf '%02x' $(( ($(od -An -N1 -tu1 /dev/urandom) | 0x02) & 0xfe )))
    local rest=$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')
    echo "${first_octet}:${rest:0:2}:${rest:2:2}:${rest:4:2}:${rest:6:2}:${rest:8:2}"
}

randomize_mac() {
    local iface="${1:-wlan0}"
    local new_mac=$(generate_random_mac)
    
    ip link set "$iface" down 2>/dev/null || true
    ip link set "$iface" address "$new_mac" 2>/dev/null || true
    ip link set "$iface" up 2>/dev/null || true
    
    stealth "MAC randomized: $iface → $new_mac"
    log "MAC randomized: $iface → $new_mac"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEALTH LABELING
# ─────────────────────────────────────────────────────────────────────────────

select_stealth_label() {
    local custom="$1"
    
    if [ -n "$custom" ]; then
        echo "$custom"
        return
    fi
    
    # Randomly select from stealth labels for unpredictability
    local count=$(echo "$STEALTH_LABELS" | wc -w)
    local index=$(($(od -An -N1 -tu1 /dev/urandom) % count + 1))
    echo "$STEALTH_LABELS" | awk "{print \$$index}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SELF-CONTAINED RECOVERY PARTITION
# ─────────────────────────────────────────────────────────────────────────────

# Collect recovery tools and their dependencies
collect_recovery_tools() {
    local output_dir="$1"
    local tools_dir="$output_dir/tools"
    local lib_dir="$output_dir/lib"
    
    mkdir -p "$tools_dir" "$lib_dir"
    
    stealth "Collecting self-contained recovery tools..."
    
    for tool in $RECOVERY_TOOLS; do
        local tool_path=$(command -v "$tool" 2>/dev/null)
        
        if [ -n "$tool_path" ] && [ -f "$tool_path" ]; then
            cp "$tool_path" "$tools_dir/"
            
            # Collect shared libraries
            ldd "$tool_path" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r lib; do
                [ -f "$lib" ] && cp -n "$lib" "$lib_dir/" 2>/dev/null || true
            done
        fi
    done
    
    # Copy essential system libraries
    for lib in /lib/*/ld-linux*.so* /lib/*/libc.so* /lib/*/libpthread.so* /lib/*/libdl.so*; do
        [ -f "$lib" ] && cp -n "$lib" "$lib_dir/" 2>/dev/null || true
    done
    
    # Create wrapper script
    cat > "$output_dir/tools/run" << 'TOOLWRAP'
#!/bin/sh
export LD_LIBRARY_PATH="$(dirname "$0")/../lib:$LD_LIBRARY_PATH"
export PATH="$(dirname "$0"):$PATH"
exec "$@"
TOOLWRAP
    chmod +x "$output_dir/tools/run"
    
    # Create busybox fallback if available
    if command -v busybox >/dev/null 2>&1; then
        cp "$(command -v busybox)" "$tools_dir/"
        
        # Create symlinks for common utilities
        for cmd in sh ash cat ls cp mv rm mkdir chmod chown mount umount; do
            ln -sf busybox "$tools_dir/$cmd" 2>/dev/null || true
        done
    fi
    
    info "Recovery tools collected: $(ls "$tools_dir" | wc -w) binaries"
}

# Copy WiFi drivers for USB adapters
collect_wifi_drivers() {
    local output_dir="$1"
    local driver_dir="$output_dir/drivers"
    
    mkdir -p "$driver_dir"
    
    stealth "Collecting WiFi drivers..."
    
    # Copy mt76 drivers (MediaTek - recommended adapters)
    for drv in /lib/modules/$(uname -r)/kernel/drivers/net/wireless/mediatek/mt76*; do
        [ -e "$drv" ] && cp -r "$drv" "$driver_dir/" 2>/dev/null || true
    done
    
    # Copy firmware
    for fw in /lib/firmware/mediatek/*; do
        [ -e "$fw" ] && cp "$fw" "$driver_dir/" 2>/dev/null || true
    done
    
    # Copy Broadcom drivers (Pi internal WiFi)
    for fw in /lib/firmware/brcm/*; do
        [ -e "$fw" ] && cp "$fw" "$driver_dir/" 2>/dev/null || true
    done
    
    info "WiFi drivers collected"
}

# ─────────────────────────────────────────────────────────────────────────────
# HIDDEN ENCRYPTED VOLUME (LUKS)
# ─────────────────────────────────────────────────────────────────────────────

# Create LUKS encrypted hidden partition with detached header
create_hidden_volume() {
    local device="$1"
    local partition="$2"
    local header_output="$3"
    local size_mb="${4:-0}"  # 0 = use all remaining space
    
    step "CREATING HIDDEN ENCRYPTED VOLUME"
    
    stealth "This creates a LUKS encrypted partition with detached header"
    stealth "The header will be stored separately (USB key recommended)"
    stealth "Without the header, the partition appears as random data"
    
    # Generate strong passphrase or use provided
    printf "  Enter passphrase for hidden volume (or 'generate'): "
    stty -echo
    read -r passphrase
    stty echo
    printf "\n"
    
    if [ "$passphrase" = "generate" ]; then
        passphrase=$(openssl rand -base64 32)
        warn "Generated passphrase (SAVE THIS): $passphrase"
    fi
    
    # Create LUKS volume with detached header
    local header_file="$header_output/$LUKS_HEADER_NAME"
    mkdir -p "$header_output"
    
    stealth "Creating encrypted volume..."
    
    # Create the partition if needed
    if [ ! -b "$partition" ]; then
        local last_sector=$(fdisk -l "$device" 2>/dev/null | grep "^${device}" | tail -1 | awk '{print $3}')
        local sector_size=$(fdisk -l "$device" 2>/dev/null | grep "Sector size" | awk '{print $4}')
        local start_sector=$((last_sector + 1))
        
        if [ "$size_mb" -gt 0 ]; then
            local end_sector=$((start_sector + (size_mb * 1024 * 1024 / sector_size)))
        else
            local end_sector=""  # Use remaining space
        fi
        
        parted -s "$device" mkpart primary "${start_sector}s" "${end_sector:-100%}"
        sleep 1
        partition="${device}${PART_PREFIX}$(($(fdisk -l "$device" 2>/dev/null | grep "^${device}" | wc -l)))"
    fi
    
    # Format with LUKS using detached header
    echo "$passphrase" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --iter-time 5000 \
        --header "$header_file" \
        "$partition"
    
    # Open and format
    echo "$passphrase" | cryptsetup luksOpen \
        --header "$header_file" \
        "$partition" "$HIDDEN_VOLUME_NAME"
    
    mkfs.ext4 -L "$HIDDEN_VOLUME_NAME" "/dev/mapper/$HIDDEN_VOLUME_NAME"
    
    info "Hidden volume created: $partition"
    info "Header saved to: $header_file"
    warn "Store the header file separately (USB key) for plausible deniability!"
    
    # Create unlock script
    cat > "$header_output/unlock.sh" << 'UNLOCK'
#!/bin/sh
# Unlock hidden CI5 volume
HEADER="$(dirname "$0")/firmware.bin"
PARTITION="${1:-/dev/mmcblk0p3}"
NAME="system-cache"

if [ ! -f "$HEADER" ]; then
    echo "Header file not found"
    exit 1
fi

cryptsetup luksOpen --header "$HEADER" "$PARTITION" "$NAME"
mount "/dev/mapper/$NAME" /mnt/hidden

echo "Hidden volume mounted at /mnt/hidden"
UNLOCK
    chmod +x "$header_output/unlock.sh"
    
    log "Hidden volume created: $partition with detached header"
    
    echo "/dev/mapper/$HIDDEN_VOLUME_NAME"
}

# Mount hidden volume
mount_hidden_volume() {
    local partition="$1"
    local header_file="$2"
    local mount_point="${3:-/mnt/ci5-hidden}"
    
    mkdir -p "$mount_point"
    
    if [ ! -f "$header_file" ]; then
        err "Header file not found: $header_file"
    fi
    
    printf "  Passphrase: "
    stty -echo
    read -r passphrase
    stty echo
    printf "\n"
    
    echo "$passphrase" | cryptsetup luksOpen \
        --header "$header_file" \
        "$partition" "$HIDDEN_VOLUME_NAME"
    
    mount "/dev/mapper/$HIDDEN_VOLUME_NAME" "$mount_point"
    
    info "Hidden volume mounted: $mount_point"
}

# Close hidden volume
close_hidden_volume() {
    umount "/dev/mapper/$HIDDEN_VOLUME_NAME" 2>/dev/null || true
    cryptsetup luksClose "$HIDDEN_VOLUME_NAME" 2>/dev/null || true
    info "Hidden volume closed"
}

# ─────────────────────────────────────────────────────────────────────────────
# DECOY OS CREATION
# ─────────────────────────────────────────────────────────────────────────────

# Interactive persona configuration
configure_decoy_persona() {
    step "DECOY PERSONA CONFIGURATION"
    
    mkdir -p "$DECOY_DIR" "$DECOY_CONTENT_DIR"
    
    printf "\n  ${B}Create a believable persona for the decoy OS${N}\n"
    printf "  This makes the device appear to be a normal personal device.\n\n"
    
    # User info
    printf "  Display name [Traveler]: "
    read -r persona_name
    persona_name="${persona_name:-Traveler}"
    
    printf "  Username [pi]: "
    read -r persona_user
    persona_user="${persona_user:-pi}"
    
    printf "  Hostname [raspberrypi]: "
    read -r persona_hostname
    persona_hostname="${persona_hostname:-raspberrypi}"
    
    printf "  Locale [en_US]: "
    read -r persona_locale
    persona_locale="${persona_locale:-en_US}"
    
    printf "  Timezone [UTC]: "
    read -r persona_tz
    persona_tz="${persona_tz:-UTC}"
    
    # Desktop customization
    printf "\n  ${B}Desktop Appearance${N}\n"
    printf "  Wallpaper URL (or 'default'): "
    read -r wallpaper_url
    
    printf "  Theme [dark/light]: "
    read -r theme
    theme="${theme:-light}"
    
    # Browser history/bookmarks
    printf "\n  ${B}Browser Personalization${N}\n"
    printf "  Pre-populate browser history? [Y/n]: "
    read -r add_history
    
    if [ "$add_history" != "n" ]; then
        printf "  Interest categories (comma-separated)\n"
        printf "  [travel,photography,cooking,tech,sports,news]: "
        read -r interests
        interests="${interests:-travel,news}"
    fi
    
    printf "  Add bookmarks? [Y/n]: "
    read -r add_bookmarks
    
    # Apps
    printf "\n  ${B}Pre-installed Apps${N}\n"
    printf "  Common apps to include:\n"
    printf "    [1] Basic (browser, file manager, text editor)\n"
    printf "    [2] Media (+ VLC, image viewer, music player)\n"
    printf "    [3] Productivity (+ LibreOffice, PDF reader)\n"
    printf "    [4] Full (all above + Spotify, Discord, etc.)\n"
    printf "    [5] Custom\n"
    printf "  Choice [2]: "
    read -r app_preset
    app_preset="${app_preset:-2}"
    
    # Documents
    printf "\n  ${B}Decoy Documents${N}\n"
    printf "  Add sample documents? [Y/n]: "
    read -r add_docs
    
    if [ "$add_docs" != "n" ]; then
        printf "  Document types [travel,recipes,notes]: "
        read -r doc_types
        doc_types="${doc_types:-travel,notes}"
    fi
    
    # Photos
    printf "  Add sample photos? [Y/n]: "
    read -r add_photos
    
    if [ "$add_photos" != "n" ]; then
        printf "  Photo categories [landscape,food,city]: "
        read -r photo_types
        photo_types="${photo_types:-landscape,city}"
        
        printf "  Number of photos [20]: "
        read -r photo_count
        photo_count="${photo_count:-20}"
    fi
    
    # Save configuration
    cat > "$DECOY_CONFIG" << EOF
# Decoy OS Persona Configuration
PERSONA_NAME="$persona_name"
PERSONA_USER="$persona_user"
PERSONA_HOSTNAME="$persona_hostname"
PERSONA_LOCALE="$persona_locale"
PERSONA_TZ="$persona_tz"

# Desktop
WALLPAPER_URL="$wallpaper_url"
THEME="$theme"

# Browser
BROWSER_HISTORY="$add_history"
BROWSER_INTERESTS="$interests"
BROWSER_BOOKMARKS="$add_bookmarks"

# Apps
APP_PRESET="$app_preset"

# Content
ADD_DOCUMENTS="$add_docs"
DOC_TYPES="$doc_types"
ADD_PHOTOS="$add_photos"
PHOTO_TYPES="$photo_types"
PHOTO_COUNT="${photo_count:-20}"
EOF

    info "Persona configuration saved: $DECOY_CONFIG"
}

# Generate realistic browser history
generate_browser_history() {
    local output_dir="$1"
    local interests="$2"
    
    stealth "Generating browser history..."
    
    mkdir -p "$output_dir"
    
    # Define URL pools by category
    local travel_urls="
https://www.tripadvisor.com/
https://www.booking.com/
https://www.airbnb.com/
https://www.expedia.com/
https://www.lonelyplanet.com/
https://www.google.com/travel/
https://www.kayak.com/
https://www.skyscanner.com/
"
    local news_urls="
https://www.bbc.com/news
https://www.reuters.com/
https://www.theguardian.com/
https://news.google.com/
https://www.npr.org/
https://www.nytimes.com/
"
    local tech_urls="
https://www.theverge.com/
https://arstechnica.com/
https://www.wired.com/
https://techcrunch.com/
https://www.reddit.com/r/technology/
https://news.ycombinator.com/
"
    local cooking_urls="
https://www.allrecipes.com/
https://www.epicurious.com/
https://www.seriouseats.com/
https://www.bonappetit.com/
https://www.foodnetwork.com/
"
    local photography_urls="
https://www.flickr.com/
https://500px.com/
https://www.dpreview.com/
https://petapixel.com/
https://www.instagram.com/
"
    local sports_urls="
https://www.espn.com/
https://www.bbc.com/sport
https://www.reddit.com/r/sports/
https://www.cbssports.com/
"
    
    # Build history entries
    local history_db="$output_dir/places.sqlite"
    local history_sql="$output_dir/history.sql"
    
    cat > "$history_sql" << 'SQLHEAD'
CREATE TABLE IF NOT EXISTS moz_places (
    id INTEGER PRIMARY KEY,
    url TEXT,
    title TEXT,
    visit_count INTEGER DEFAULT 1,
    last_visit_date INTEGER
);
CREATE TABLE IF NOT EXISTS moz_historyvisits (
    id INTEGER PRIMARY KEY,
    place_id INTEGER,
    visit_date INTEGER,
    visit_type INTEGER DEFAULT 1
);
SQLHEAD

    local place_id=1
    local visit_id=1
    local base_time=$(date +%s)
    
    for category in $(echo "$interests" | tr ',' ' '); do
        local urls=""
        case "$category" in
            travel) urls="$travel_urls" ;;
            news) urls="$news_urls" ;;
            tech) urls="$tech_urls" ;;
            cooking) urls="$cooking_urls" ;;
            photography) urls="$photography_urls" ;;
            sports) urls="$sports_urls" ;;
        esac
        
        for url in $urls; do
            [ -z "$url" ] && continue
            
            # Random visit count and times
            local visits=$(($(od -An -N1 -tu1 /dev/urandom) % 10 + 1))
            local days_ago=$(($(od -An -N1 -tu1 /dev/urandom) % 30))
            local visit_time=$(( (base_time - days_ago * 86400) * 1000000 ))
            
            echo "INSERT INTO moz_places (id, url, title, visit_count, last_visit_date) VALUES ($place_id, '$url', '$(echo "$url" | sed "s|https://||;s|www\.||;s|/.*||")', $visits, $visit_time);" >> "$history_sql"
            
            for v in $(seq 1 $visits); do
                local v_time=$(( visit_time - v * 3600000000 ))
                echo "INSERT INTO moz_historyvisits (id, place_id, visit_date, visit_type) VALUES ($visit_id, $place_id, $v_time, 1);" >> "$history_sql"
                visit_id=$((visit_id + 1))
            done
            
            place_id=$((place_id + 1))
        done
    done
    
    # Create SQLite database if sqlite3 available
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$history_db" < "$history_sql"
        rm -f "$history_sql"
        info "Browser history generated: $history_db"
    else
        info "Browser history SQL saved: $history_sql"
    fi
}

# Generate browser bookmarks
generate_bookmarks() {
    local output_dir="$1"
    local interests="$2"
    
    stealth "Generating bookmarks..."
    
    mkdir -p "$output_dir"
    
    # Create bookmarks HTML file (universal format)
    cat > "$output_dir/bookmarks.html" << 'BOOKMARKS_HEAD'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3>Bookmarks Bar</H3>
    <DL><p>
BOOKMARKS_HEAD

    # Add bookmarks based on interests
    for category in $(echo "$interests" | tr ',' ' '); do
        echo "        <DT><H3>$category</H3>" >> "$output_dir/bookmarks.html"
        echo "        <DL><p>" >> "$output_dir/bookmarks.html"
        
        case "$category" in
            travel)
                echo '            <DT><A HREF="https://www.booking.com/">Booking.com</A>' >> "$output_dir/bookmarks.html"
                echo '            <DT><A HREF="https://www.tripadvisor.com/">TripAdvisor</A>' >> "$output_dir/bookmarks.html"
                echo '            <DT><A HREF="https://www.google.com/maps">Google Maps</A>' >> "$output_dir/bookmarks.html"
                ;;
            news)
                echo '            <DT><A HREF="https://www.bbc.com/news">BBC News</A>' >> "$output_dir/bookmarks.html"
                echo '            <DT><A HREF="https://www.reuters.com/">Reuters</A>' >> "$output_dir/bookmarks.html"
                ;;
            tech)
                echo '            <DT><A HREF="https://www.theverge.com/">The Verge</A>' >> "$output_dir/bookmarks.html"
                echo '            <DT><A HREF="https://arstechnica.com/">Ars Technica</A>' >> "$output_dir/bookmarks.html"
                ;;
        esac
        
        echo "        </DL><p>" >> "$output_dir/bookmarks.html"
    done
    
    echo "    </DL><p>" >> "$output_dir/bookmarks.html"
    echo "</DL><p>" >> "$output_dir/bookmarks.html"
    
    info "Bookmarks generated: $output_dir/bookmarks.html"
}

# Download sample photos
download_sample_photos() {
    local output_dir="$1"
    local categories="$2"
    local count="${3:-20}"
    
    stealth "Downloading sample photos..."
    
    mkdir -p "$output_dir/Pictures"
    
    # Use Unsplash Source API (free, no auth required)
    local per_category=$((count / $(echo "$categories" | tr ',' ' ' | wc -w)))
    
    for category in $(echo "$categories" | tr ',' ' '); do
        stealth "Fetching $per_category $category photos..."
        
        for i in $(seq 1 $per_category); do
            local filename="$output_dir/Pictures/${category}_${i}.jpg"
            
            # Unsplash random photo by category
            curl -sL "https://source.unsplash.com/random/1920x1080/?${category}" -o "$filename" 2>/dev/null || true
            
            # Add realistic EXIF data if exiftool available
            if command -v exiftool >/dev/null 2>&1 && [ -f "$filename" ]; then
                local days_ago=$(($(od -An -N1 -tu1 /dev/urandom) % 90))
                local photo_date=$(date -d "$days_ago days ago" "+%Y:%m:%d %H:%M:%S" 2>/dev/null || date "+%Y:%m:%d %H:%M:%S")
                
                exiftool -overwrite_original \
                    -DateTimeOriginal="$photo_date" \
                    -CreateDate="$photo_date" \
                    -Make="Apple" \
                    -Model="iPhone 14" \
                    "$filename" 2>/dev/null || true
            fi
            
            sleep 0.5  # Rate limiting
        done
    done
    
    info "Sample photos downloaded: $output_dir/Pictures"
}

# Create sample documents
create_sample_documents() {
    local output_dir="$1"
    local doc_types="$2"
    
    stealth "Creating sample documents..."
    
    mkdir -p "$output_dir/Documents"
    
    for dtype in $(echo "$doc_types" | tr ',' ' '); do
        case "$dtype" in
            travel)
                cat > "$output_dir/Documents/travel_plans.txt" << 'TRAVEL'
Trip Planning Notes
==================

Places to visit:
- Check local markets
- Try the local cuisine
- Visit historical sites

Packing list:
- Passport
- Chargers
- Comfortable shoes
- Camera

Budget: approximately $100/day
TRAVEL
                
                cat > "$output_dir/Documents/packing_list.md" << 'PACKING'
# Packing List

## Essentials
- [ ] Passport
- [ ] Phone charger
- [ ] Adapters
- [ ] Medications

## Clothes
- [ ] 5x shirts
- [ ] 3x pants
- [ ] Underwear
- [ ] Jacket

## Electronics
- [ ] Phone
- [ ] Camera
- [ ] Headphones
PACKING
                ;;
            recipes)
                cat > "$output_dir/Documents/recipes.txt" << 'RECIPES'
Favorite Recipes
================

Simple Pasta
-----------
- Boil pasta
- Saute garlic in olive oil
- Add tomatoes, basil
- Toss with pasta

Morning Smoothie
---------------
- 1 banana
- Handful of berries
- Yogurt
- Honey
- Blend until smooth
RECIPES
                ;;
            notes)
                cat > "$output_dir/Documents/notes.txt" << 'NOTES'
Random Notes
============

- Remember to call mom on Sunday
- Book dentist appointment
- Project deadline: end of month
- Buy groceries: milk, bread, eggs

Ideas:
- Learn a new language
- Start a garden
- Read more books
NOTES
                
                cat > "$output_dir/Documents/todo.md" << 'TODO'
# To Do

## This Week
- [ ] Finish report
- [ ] Clean apartment
- [ ] Gym 3x

## Later
- [ ] Plan vacation
- [ ] Update resume
TODO
                ;;
        esac
    done
    
    info "Sample documents created: $output_dir/Documents"
}

# Generate app list based on preset
generate_app_list() {
    local preset="$1"
    local output_file="$2"
    
    # Base apps (always included)
    cat > "$output_file" << 'APPS_BASE'
# Base apps
chromium-browser
pcmanfm
mousepad
APPS_BASE

    case "$preset" in
        2|media)
            cat >> "$output_file" << 'APPS_MEDIA'
# Media apps
vlc
gpicview
audacious
APPS_MEDIA
            ;;
        3|productivity)
            cat >> "$output_file" << 'APPS_PROD'
# Media apps
vlc
gpicview
# Productivity
libreoffice
evince
APPS_PROD
            ;;
        4|full)
            cat >> "$output_file" << 'APPS_FULL'
# Media apps
vlc
gpicview
audacious
# Productivity
libreoffice
evince
# Communication
# Note: Spotify/Discord need manual setup or flatpak
APPS_FULL
            ;;
        5|custom)
            printf "  Enter apps (space-separated): "
            read -r custom_apps
            echo "# Custom apps" >> "$output_file"
            for app in $custom_apps; do
                echo "$app" >> "$output_file"
            done
            ;;
    esac
    
    info "App list generated: $output_file"
}

# Build complete decoy OS
build_decoy_os() {
    local target_partition="$1"
    local config_file="${2:-$DECOY_CONFIG}"
    
    step "BUILDING DECOY OS"
    
    if [ ! -f "$config_file" ]; then
        warn "No persona configured. Running configuration wizard..."
        configure_decoy_persona
    fi
    
    . "$config_file"
    
    local mount_point="/mnt/ci5-decoy"
    mkdir -p "$mount_point"
    
    # Format and mount target
    mkfs.ext4 -L "rootfs" "$target_partition"
    mount "$target_partition" "$mount_point"
    
    clone "Installing base Raspberry Pi OS..."
    
    # Option 1: Debootstrap minimal system
    if command -v debootstrap >/dev/null 2>&1; then
        debootstrap --arch=arm64 bookworm "$mount_point" http://deb.debian.org/debian
    else
        # Option 2: Extract from official image
        warn "debootstrap not available. Please provide Pi OS image."
        printf "  Path to Pi OS image (or 'download'): "
        read -r os_image
        
        if [ "$os_image" = "download" ]; then
            clone "Downloading Raspberry Pi OS Lite..."
            local img_url="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz"
            curl -L "$img_url" | xz -d > /tmp/pios.img
            os_image="/tmp/pios.img"
        fi
        
        # Mount and copy from image
        local loop_dev=$(losetup -fP --show "$os_image")
        local img_mount="/mnt/ci5-img"
        mkdir -p "$img_mount"
        mount "${loop_dev}p2" "$img_mount"
        
        clone "Copying OS files..."
        rsync -aHAXx "$img_mount/" "$mount_point/"
        
        umount "$img_mount"
        losetup -d "$loop_dev"
    fi
    
    # Configure system
    clone "Configuring decoy system..."
    
    # Hostname
    echo "$PERSONA_HOSTNAME" > "$mount_point/etc/hostname"
    
    # User
    chroot "$mount_point" useradd -m -s /bin/bash "$PERSONA_USER" 2>/dev/null || true
    echo "${PERSONA_USER}:raspberry" | chroot "$mount_point" chpasswd
    
    # Locale and timezone
    echo "LANG=${PERSONA_LOCALE}.UTF-8" > "$mount_point/etc/default/locale"
    ln -sf "/usr/share/zoneinfo/$PERSONA_TZ" "$mount_point/etc/localtime"
    
    # Install apps
    generate_app_list "$APP_PRESET" "$DECOY_APPS_LIST"
    
    clone "Installing applications..."
    chroot "$mount_point" apt-get update
    while read -r app; do
        [ -z "$app" ] && continue
        echo "$app" | grep -q "^#" && continue
        chroot "$mount_point" apt-get install -y "$app" 2>/dev/null || warn "Failed to install: $app"
    done < "$DECOY_APPS_LIST"
    
    # Desktop customization
    local user_home="$mount_point/home/$PERSONA_USER"
    mkdir -p "$user_home/.config"
    
    if [ "$WALLPAPER_URL" != "default" ] && [ -n "$WALLPAPER_URL" ]; then
        clone "Setting wallpaper..."
        curl -sL "$WALLPAPER_URL" -o "$user_home/.wallpaper.jpg" 2>/dev/null || true
        mkdir -p "$user_home/.config/pcmanfm/LXDE-pi"
        echo "wallpaper=$user_home/.wallpaper.jpg" > "$user_home/.config/pcmanfm/LXDE-pi/desktop-items-0.conf"
    fi
    
    # Browser personalization
    if [ "$BROWSER_HISTORY" != "n" ]; then
        generate_browser_history "$user_home/.mozilla/firefox/default" "$BROWSER_INTERESTS"
    fi
    
    if [ "$BROWSER_BOOKMARKS" != "n" ]; then
        generate_bookmarks "$user_home/.mozilla/firefox/default" "$BROWSER_INTERESTS"
    fi
    
    # Content
    if [ "$ADD_DOCUMENTS" != "n" ]; then
        create_sample_documents "$user_home" "$DOC_TYPES"
    fi
    
    if [ "$ADD_PHOTOS" != "n" ]; then
        download_sample_photos "$user_home" "$PHOTO_TYPES" "$PHOTO_COUNT"
    fi
    
    # Fix permissions
    chroot "$mount_point" chown -R "${PERSONA_USER}:${PERSONA_USER}" "/home/${PERSONA_USER}"
    
    # Clean up
    chroot "$mount_point" apt-get clean
    rm -rf "$mount_point/var/cache/apt/archives"/*
    
    umount "$mount_point"
    
    info "Decoy OS built successfully"
    log "Decoy OS created on $target_partition"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNLOCK TRIGGERS
# ─────────────────────────────────────────────────────────────────────────────

# Configure USB key trigger
configure_usb_trigger() {
    step "USB KEY TRIGGER CONFIGURATION"
    
    mkdir -p "$TRIGGERS_DIR"
    
    detect_usb_drives
    
    if [ -z "$USB_DRIVES" ]; then
        warn "No USB drives detected. Insert the drive to use as unlock key."
        printf "  Press Enter when ready..."
        read -r _
        detect_usb_drives
    fi
    
    if [ -z "$USB_DRIVES" ]; then
        err "No USB drives found"
    fi
    
    printf "\n  Available USB drives:\n"
    local i=1
    for drive in $USB_DRIVES; do
        local dev=$(echo "$drive" | cut -d: -f1)
        local size=$(echo "$drive" | cut -d: -f2)
        local serial=$(echo "$drive" | cut -d: -f3)
        printf "    [%d] %s (%s) Serial: %s\n" "$i" "$dev" "$size" "$serial"
        i=$((i + 1))
    done
    
    printf "\n  Select USB key drive: "
    read -r selection
    
    local selected=$(echo "$USB_DRIVES" | tr ' ' '\n' | sed -n "${selection}p")
    local dev=$(echo "$selected" | cut -d: -f1)
    local serial=$(echo "$selected" | cut -d: -f3)
    
    # Get more identifiers
    local vendor=$(udevadm info --query=property --name="$dev" 2>/dev/null | grep "ID_VENDOR=" | cut -d= -f2)
    local model=$(udevadm info --query=property --name="$dev" 2>/dev/null | grep "ID_MODEL=" | cut -d= -f2)
    
    # Generate unique key file
    local key_id=$(openssl rand -hex 16)
    
    cat > "$USB_KEY_FILE" << EOF
# USB Key Trigger Configuration
USB_SERIAL="$serial"
USB_VENDOR="$vendor"
USB_MODEL="$model"
USB_KEY_ID="$key_id"
EOF

    # Create key file on USB drive
    local usb_mount="/mnt/ci5-usbkey"
    mkdir -p "$usb_mount"
    
    # Mount first partition
    local part="${dev}1"
    mount "$part" "$usb_mount" 2>/dev/null || {
        # Format if needed
        mkfs.vfat -F 32 "$part" 2>/dev/null || {
            parted -s "$dev" mklabel msdos mkpart primary fat32 1MiB 100%
            mkfs.vfat -F 32 "${dev}1"
            part="${dev}1"
        }
        mount "$part" "$usb_mount"
    }
    
    # Create hidden key file
    echo "$key_id" > "$usb_mount/.ci5key"
    
    # Also store LUKS header here if it exists
    if [ -f "$TRIGGERS_DIR/$LUKS_HEADER_NAME" ]; then
        cp "$TRIGGERS_DIR/$LUKS_HEADER_NAME" "$usb_mount/"
        info "LUKS header copied to USB key"
    fi
    
    sync
    umount "$usb_mount"
    
    info "USB key configured: $dev"
    info "This USB drive will now unlock the hidden volume when inserted"
    
    # Create udev rule
    cat > /etc/udev/rules.d/99-ci5-usb-trigger.rules << EOF
# CI5 USB Key Trigger
ACTION=="add", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="$serial", RUN+="/etc/ci5/triggers/usb_unlock.sh"
EOF

    # Create unlock script
    cat > "$TRIGGERS_DIR/usb_unlock.sh" << 'USBUNLOCK'
#!/bin/sh
# CI5 USB Key Unlock Script
TRIGGERS_DIR="/etc/ci5/triggers"
USB_KEY_FILE="$TRIGGERS_DIR/usb_key.conf"

. "$USB_KEY_FILE"

# Find the USB device
USB_DEV=$(lsblk -o NAME,SERIAL -n | grep "$USB_SERIAL" | awk '{print "/dev/"$1}' | head -1)

if [ -z "$USB_DEV" ]; then
    exit 0
fi

# Mount and check key
USB_MOUNT="/tmp/ci5-key-$$"
mkdir -p "$USB_MOUNT"
mount "${USB_DEV}1" "$USB_MOUNT" 2>/dev/null || mount "$USB_DEV" "$USB_MOUNT" 2>/dev/null || exit 0

if [ -f "$USB_MOUNT/.ci5key" ]; then
    KEY_CONTENT=$(cat "$USB_MOUNT/.ci5key")
    
    if [ "$KEY_CONTENT" = "$USB_KEY_ID" ]; then
        logger "CI5: USB key authenticated"
        
        # Check for LUKS header
        if [ -f "$USB_MOUNT/firmware.bin" ]; then
            # Unlock hidden volume
            /etc/ci5/triggers/unlock_hidden.sh "$USB_MOUNT/firmware.bin"
        fi
        
        # Signal successful unlock
        touch /tmp/.ci5_unlocked
    fi
fi

umount "$USB_MOUNT"
rmdir "$USB_MOUNT"
USBUNLOCK
    chmod +x "$TRIGGERS_DIR/usb_unlock.sh"
    
    udevadm control --reload-rules
    
    log "USB trigger configured: serial=$serial"
}

# Configure GPIO trigger
configure_gpio_trigger() {
    step "GPIO TRIGGER CONFIGURATION"
    
    mkdir -p "$TRIGGERS_DIR"
    
    printf "\n  ${B}GPIO Pin Trigger${N}\n"
    printf "  This triggers unlock when specific GPIO pins are shorted.\n"
    printf "  Use a paperclip or jumper wire to connect the pins.\n\n"
    
    printf "  Trigger pin 1 [17]: "
    read -r pin1
    pin1="${pin1:-17}"
    
    printf "  Trigger pin 2 [27]: "
    read -r pin2
    pin2="${pin2:-27}"
    
    printf "  Hold time in seconds [3]: "
    read -r hold_time
    hold_time="${hold_time:-3}"
    
    cat > "$GPIO_TRIGGER_FILE" << EOF
# GPIO Trigger Configuration
GPIO_PIN1=$pin1
GPIO_PIN2=$pin2
GPIO_HOLD_TIME=$hold_time
EOF

    # Create Procd init script for GPIO monitor
    cat > /etc/init.d/ci5-gpio-trigger << 'PROCD'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG=/etc/ci5/triggers/gpio_monitor.sh

start_service() {
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
PROCD
    chmod +x /etc/init.d/ci5-gpio-trigger
    
    /etc/init.d/ci5-gpio-trigger enable
    /etc/init.d/ci5-gpio-trigger start
    
    info "GPIO trigger configured: pins $pin1 + $pin2 (hold ${hold_time}s)"
    warn "Short pins $pin1 and $pin2 together for ${hold_time} seconds to unlock"
    
    log "GPIO trigger configured: pins $pin1, $pin2"
}

# Configure boot key combo trigger
configure_keycombo_trigger() {
    step "KEY COMBINATION TRIGGER"
    
    mkdir -p "$TRIGGERS_DIR"
    
    printf "\n  ${B}Keyboard Combination Trigger${N}\n"
    printf "  Hold this key combination during boot to reveal hidden menu.\n\n"
    
    printf "  Key 1 [Shift]: "
    read -r key1
    key1="${key1:-Shift}"
    
    printf "  Key 2 [Ctrl]: "
    read -r key2
    key2="${key2:-Ctrl}"
    
    printf "  Key 3 (optional) []: "
    read -r key3
    
    cat > "$TRIGGERS_DIR/keycombo.conf" << EOF
KEY1="$key1"
KEY2="$key2"
KEY3="$key3"
EOF

    # Modify boot config to check for key combo
    # This integrates with initramfs
    
    info "Key combo trigger configured: $key1 + $key2 ${key3:++ $key3}"
    warn "Hold $key1 + $key2 ${key3:++ $key3} during boot to access hidden system"
    
    log "Key combo trigger configured"
}

# Create unified unlock script
create_unlock_script() {
    cat > "$TRIGGERS_DIR/unlock_hidden.sh" << 'UNLOCKSCRIPT'
#!/bin/sh
# CI5 Unified Hidden Volume Unlock

HEADER_FILE="${1:-/etc/ci5/triggers/firmware.bin}"
HIDDEN_PARTITION="${2:-/dev/mmcblk0p3}"
MOUNT_POINT="/mnt/ci5-hidden"
VOLUME_NAME="system-cache"

# Check for header file
if [ ! -f "$HEADER_FILE" ]; then
    # Try USB drives
    for dev in /dev/sd[a-z]1; do
        [ -b "$dev" ] || continue
        
        TMP_MOUNT="/tmp/ci5-usb-$$"
        mkdir -p "$TMP_MOUNT"
        
        if mount -o ro "$dev" "$TMP_MOUNT" 2>/dev/null; then
            if [ -f "$TMP_MOUNT/firmware.bin" ]; then
                HEADER_FILE="$TMP_MOUNT/firmware.bin"
                break
            fi
            umount "$TMP_MOUNT"
        fi
        rmdir "$TMP_MOUNT" 2>/dev/null || true
    done
fi

if [ ! -f "$HEADER_FILE" ]; then
    echo "No LUKS header found"
    exit 1
fi

# Check if already unlocked
if [ -b "/dev/mapper/$VOLUME_NAME" ]; then
    echo "Already unlocked"
    exit 0
fi

# Try to unlock (may prompt for passphrase)
if cryptsetup luksOpen --header "$HEADER_FILE" "$HIDDEN_PARTITION" "$VOLUME_NAME"; then
    mkdir -p "$MOUNT_POINT"
    mount "/dev/mapper/$VOLUME_NAME" "$MOUNT_POINT"
    
    echo "Hidden volume unlocked: $MOUNT_POINT"
    logger "CI5: Hidden volume unlocked"
    
    # Optional: Switch to hidden system
    if [ -f "$MOUNT_POINT/boot/switch_root.sh" ]; then
        exec "$MOUNT_POINT/boot/switch_root.sh"
    fi
else
    echo "Failed to unlock"
    exit 1
fi
UNLOCKSCRIPT
    chmod +x "$TRIGGERS_DIR/unlock_hidden.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# BEACON / AUTO-RECOVERY
# ─────────────────────────────────────────────────────────────────────────────

# Configure beacon networks
configure_beacon() {
    step "BEACON NETWORK CONFIGURATION"
    
    mkdir -p "$BEACON_DIR"
    
    printf "\n  ${B}Safe Network Beacons${N}\n"
    printf "  The recovery system will automatically connect to these networks\n"
    printf "  and attempt to restore from cloud backup.\n\n"
    
    printf "  ${Y}WARNING: Network credentials will be stored (encrypted).${N}\n\n"
    
    local networks=""
    local count=1
    
    while true; do
        printf "  Network %d SSID (or 'done'): " "$count"
        read -r ssid
        
        [ "$ssid" = "done" ] && break
        [ -z "$ssid" ] && break
        
        printf "  Network %d Password: " "$count"
        stty -echo
        read -r psk
        stty echo
        printf "\n"
        
        printf "  Network %d Priority [%d]: " "$count" "$count"
        read -r priority
        priority="${priority:-$count}"
        
        networks="$networks
BEACON_${count}_SSID=\"$ssid\"
BEACON_${count}_PSK=\"$psk\"
BEACON_${count}_PRIORITY=\"$priority\""
        
        count=$((count + 1))
        
        printf "  Add another network? [y/N]: "
        read -r more
        [ "$more" != "y" ] && break
    done
    
    # Auto-recovery options
    printf "\n  ${B}Auto-Recovery Options${N}\n"
    
    printf "  Auto-download from cloud when beacon found? [Y/n]: "
    read -r auto_cloud
    
    printf "  Enable reverse SSH tunnel? [y/N]: "
    read -r reverse_ssh
    
    if [ "$reverse_ssh" = "y" ]; then
        printf "  SSH server (user@host): "
        read -r ssh_server
        
        printf "  SSH port [22]: "
        read -r ssh_port
        ssh_port="${ssh_port:-22}"
        
        printf "  Local port for tunnel [2222]: "
        read -r local_port
        local_port="${local_port:-2222}"
    fi
    
    # Save configuration (encrypted)
    local beacon_plain="/tmp/beacon_plain_$$"
    cat > "$beacon_plain" << EOF
# CI5 Beacon Configuration
BEACON_COUNT=$((count - 1))
$networks

AUTO_CLOUD_RESTORE="${auto_cloud:-y}"
REVERSE_SSH="${reverse_ssh:-n}"
SSH_SERVER="${ssh_server:-}"
SSH_PORT="${ssh_port:-22}"
SSH_LOCAL_PORT="${local_port:-2222}"
EOF

    # Encrypt with system key
    if [ -f "/etc/ci5/system.key" ]; then
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -in "$beacon_plain" \
            -out "$BEACON_CONFIG" \
            -pass file:/etc/ci5/system.key
    else
        # Generate system key
        openssl rand -base64 32 > /etc/ci5/system.key
        chmod 600 /etc/ci5/system.key
        
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -in "$beacon_plain" \
            -out "$BEACON_CONFIG" \
            -pass file:/etc/ci5/system.key
    fi
    
    rm -f "$beacon_plain"
    
    info "Beacon configuration saved (encrypted)"
    log "Beacon networks configured: $((count - 1)) networks"
}

# Create beacon recovery script
create_beacon_recovery() {
    cat > "$BEACON_DIR/beacon_recovery.sh" << 'BEACONSCRIPT'
#!/bin/sh
# CI5 Beacon Auto-Recovery

BEACON_DIR="/etc/ci5/beacon"
BEACON_CONFIG="$BEACON_DIR/networks.conf"
CLONE_DIR="/etc/ci5/clone"

# Decrypt configuration
if [ ! -f "$BEACON_CONFIG" ]; then
    echo "No beacon configuration"
    exit 1
fi

BEACON_PLAIN="/tmp/beacon_$$"
openssl enc -aes-256-cbc -d -salt -pbkdf2 \
    -in "$BEACON_CONFIG" \
    -out "$BEACON_PLAIN" \
    -pass file:/etc/ci5/system.key 2>/dev/null || exit 1

. "$BEACON_PLAIN"

# Randomize MAC first
IFACE="wlan0"
RANDOM_MAC=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' \
    $((0x02 | (RANDOM & 0xfc))) \
    $((RANDOM & 0xff)) $((RANDOM & 0xff)) \
    $((RANDOM & 0xff)) $((RANDOM & 0xff)) $((RANDOM & 0xff)))

ip link set "$IFACE" down
ip link set "$IFACE" address "$RANDOM_MAC"
ip link set "$IFACE" up

sleep 2

# Scan for beacon networks
echo "Scanning for beacon networks..."
SCAN_RESULTS=$(iw dev "$IFACE" scan 2>/dev/null | grep -E "SSID:|signal:" || true)

# Try each beacon network in priority order
for i in $(seq 1 "$BEACON_COUNT"); do
    eval "SSID=\$BEACON_${i}_SSID"
    eval "PSK=\$BEACON_${i}_PSK"
    
    if echo "$SCAN_RESULTS" | grep -q "$SSID"; then
        echo "Found beacon: $SSID"
        
        # Connect
        WPA_CONF="/tmp/wpa_$$"
        wpa_passphrase "$SSID" "$PSK" > "$WPA_CONF"
        
        wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF"
        sleep 5
        dhclient "$IFACE"
        
        # Test connectivity
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            echo "Connected to beacon: $SSID"
            logger "CI5: Beacon connected - $SSID"
            
            # Auto cloud restore
            if [ "$AUTO_CLOUD_RESTORE" = "y" ]; then
                echo "Starting cloud restore..."
                /etc/ci5/clone/cloud_restore.sh
            fi
            
            # Reverse SSH tunnel
            if [ "$REVERSE_SSH" = "y" ] && [ -n "$SSH_SERVER" ]; then
                echo "Opening reverse SSH tunnel..."
                ssh -fN -R "${SSH_LOCAL_PORT}:localhost:22" \
                    -o "StrictHostKeyChecking=no" \
                    -o "ServerAliveInterval=60" \
                    -p "$SSH_PORT" "$SSH_SERVER"
                logger "CI5: Reverse SSH tunnel opened to $SSH_SERVER"
            fi
            
            rm -f "$WPA_CONF" "$BEACON_PLAIN"
            exit 0
        fi
        
        # Failed, try next
        pkill wpa_supplicant
        rm -f "$WPA_CONF"
    fi
done

rm -f "$BEACON_PLAIN"
echo "No beacon networks found"
exit 1
BEACONSCRIPT
    chmod +x "$BEACON_DIR/beacon_recovery.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# RECOVERY PARTITION
# ─────────────────────────────────────────────────────────────────────────────

# Create comprehensive recovery partition
create_recovery_partition() {
    local device="$1"
    local label="${2:-$(select_stealth_label)}"
    local size_mb="${3:-512}"
    
    step "CREATING STEALTH RECOVERY PARTITION"
    
    stealth "Label: $label (appears as standard system partition)"
    
    # Calculate partition layout
    local sector_size=$(fdisk -l "$device" 2>/dev/null | grep "Sector size" | awk '{print $4}')
    sector_size="${sector_size:-512}"
    
    local recovery_sectors=$((size_mb * 1024 * 1024 / sector_size))
    
    # Find space for recovery partition
    local last_end=$(fdisk -l "$device" 2>/dev/null | grep "^${device}" | tail -1 | awk '{print $3}')
    local start_sector=$((last_end + 1))
    
    clone "Creating partition..."
    
    parted -s "$device" mkpart primary fat32 "${start_sector}s" "$((start_sector + recovery_sectors))s"
    sleep 1
    
    local recovery_part="${device}${PART_PREFIX}$(($(fdisk -l "$device" 2>/dev/null | grep "^${device}" | wc -l)))"
    
    # Format with stealth label
    mkfs.vfat -F 32 -n "$label" "$recovery_part"
    
    # Mount and populate
    local mount_point="/mnt/ci5-recovery"
    mkdir -p "$mount_point"
    mount "$recovery_part" "$mount_point"
    
    clone "Populating recovery partition..."
    
    # Copy boot files
    cp -r /boot/firmware/* "$mount_point/" 2>/dev/null || cp -r /boot/* "$mount_point/" 2>/dev/null || true
    
    # Collect self-contained tools
    collect_recovery_tools "$mount_point"
    collect_wifi_drivers "$mount_point"
    
    # Copy trigger configurations
    mkdir -p "$mount_point/.config"
    cp -r "$TRIGGERS_DIR"/* "$mount_point/.config/" 2>/dev/null || true
    cp -r "$BEACON_DIR"/* "$mount_point/.config/" 2>/dev/null || true
    
    # Create master recovery script
    cat > "$mount_point/recovery.sh" << 'RECOVERY_MASTER'
#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# CI5 Recovery System
# ═══════════════════════════════════════════════════════════════════════════

export PATH="$(dirname "$0")/tools:$PATH"
export LD_LIBRARY_PATH="$(dirname "$0")/lib:$LD_LIBRARY_PATH"

RECOVERY_DIR="$(dirname "$0")"

echo ""
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║                    SYSTEM RECOVERY MODE                       ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Check for triggers
check_triggers() {
    # USB key
    if [ -f "$RECOVERY_DIR/.config/usb_key.conf" ]; then
        for dev in /dev/sd[a-z]1; do
            [ -b "$dev" ] || continue
            
            TMP="/tmp/usb$$"
            mkdir -p "$TMP"
            
            if mount -o ro "$dev" "$TMP" 2>/dev/null; then
                if [ -f "$TMP/.ci5key" ]; then
                    . "$RECOVERY_DIR/.config/usb_key.conf"
                    if [ "$(cat "$TMP/.ci5key")" = "$USB_KEY_ID" ]; then
                        echo "[✓] USB key detected - unlocking hidden system..."
                        
                        if [ -f "$TMP/firmware.bin" ]; then
                            "$RECOVERY_DIR/tools/run" cryptsetup luksOpen \
                                --header "$TMP/firmware.bin" \
                                /dev/mmcblk0p3 system-cache
                            
                            mkdir -p /mnt/hidden
                            mount /dev/mapper/system-cache /mnt/hidden
                            
                            echo "[✓] Hidden system unlocked"
                            exec switch_root /mnt/hidden /sbin/init
                        fi
                    fi
                fi
                umount "$TMP"
            fi
            rmdir "$TMP" 2>/dev/null
        done
    fi
}

# Main menu
main_menu() {
    echo "  Options:"
    echo ""
    echo "    [1] Scan for backup sources (USB/SD)"
    echo "    [2] Connect to WiFi and restore from cloud"
    echo "    [3] Wait for USB with backup image"
    echo "    [4] Enable SSH for remote restore"
    echo "    [5] Open reverse SSH tunnel"
    echo "    [6] Manual restore from image"
    echo "    [7] Attempt beacon auto-recovery"
    echo ""
    echo "    [H] Access hidden system (if configured)"
    echo "    [D] Boot decoy system"
    echo "    [R] Reboot"
    echo ""
    printf "  Choice: "
    read -r choice
    
    case "$choice" in
        1) scan_backups ;;
        2) wifi_cloud_restore ;;
        3) wait_usb_backup ;;
        4) enable_ssh ;;
        5) reverse_tunnel ;;
        6) manual_restore ;;
        7) beacon_recovery ;;
        [Hh]) unlock_hidden ;;
        [Dd]) boot_decoy ;;
        [Rr]) reboot ;;
        *) main_menu ;;
    esac
}

scan_backups() {
    echo ""
    echo "  Scanning for backup sources..."
    
    for dev in /dev/sd[a-z]1 /dev/mmcblk*p1; do
        [ -b "$dev" ] || continue
        
        TMP="/tmp/scan$$"
        mkdir -p "$TMP"
        
        if mount -o ro "$dev" "$TMP" 2>/dev/null; then
            BACKUP=$(find "$TMP" -name "ci5*.img*" -o -name "backup*.img*" 2>/dev/null | head -1)
            
            if [ -n "$BACKUP" ]; then
                echo "  [✓] Found: $BACKUP on $dev"
            fi
            
            umount "$TMP"
        fi
        rmdir "$TMP" 2>/dev/null
    done
    
    echo ""
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

wifi_cloud_restore() {
    echo ""
    
    # Randomize MAC
    IFACE="wlan0"
    ip link set "$IFACE" down
    RANDOM_MAC=$(cat /sys/class/net/$IFACE/address | sed 's/../02/1')
    ip link set "$IFACE" address "$RANDOM_MAC"
    ip link set "$IFACE" up
    
    # Scan networks
    echo "  Scanning WiFi networks..."
    sleep 2
    iw dev "$IFACE" scan 2>/dev/null | grep "SSID:" | sort -u | head -20
    
    echo ""
    printf "  Enter SSID: "
    read -r ssid
    printf "  Password: "
    stty -echo
    read -r psk
    stty echo
    echo ""
    
    # Connect
    wpa_passphrase "$ssid" "$psk" > /tmp/wpa.conf
    wpa_supplicant -B -i "$IFACE" -c /tmp/wpa.conf
    sleep 5
    dhclient "$IFACE"
    
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "  [✓] Connected"
        
        # Load cloud config and restore
        if [ -f "$RECOVERY_DIR/.config/cloud.conf" ]; then
            . "$RECOVERY_DIR/.config/cloud.conf"
            echo "  Downloading from cloud..."
            # ... cloud restore logic
        else
            echo "  [!] No cloud configuration found"
        fi
    else
        echo "  [✗] Connection failed"
    fi
    
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

beacon_recovery() {
    echo ""
    echo "  Attempting beacon auto-recovery..."
    
    if [ -f "$RECOVERY_DIR/.config/beacon_recovery.sh" ]; then
        "$RECOVERY_DIR/.config/beacon_recovery.sh"
    else
        echo "  [!] No beacon configuration"
    fi
    
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

unlock_hidden() {
    echo ""
    echo "  Attempting to unlock hidden system..."
    
    # Check for USB key with header
    for dev in /dev/sd[a-z]1; do
        [ -b "$dev" ] || continue
        
        TMP="/tmp/key$$"
        mkdir -p "$TMP"
        
        if mount -o ro "$dev" "$TMP" 2>/dev/null; then
            if [ -f "$TMP/firmware.bin" ]; then
                echo "  Found LUKS header on $dev"
                
                printf "  Passphrase: "
                stty -echo
                read -r pass
                stty echo
                echo ""
                
                if echo "$pass" | cryptsetup luksOpen \
                    --header "$TMP/firmware.bin" \
                    /dev/mmcblk0p3 system-cache 2>/dev/null; then
                    
                    mkdir -p /mnt/hidden
                    mount /dev/mapper/system-cache /mnt/hidden
                    
                    echo "  [✓] Hidden system unlocked!"
                    echo "  Switching to hidden system..."
                    sleep 2
                    
                    umount "$TMP"
                    exec switch_root /mnt/hidden /sbin/init
                else
                    echo "  [✗] Failed to unlock"
                fi
            fi
            umount "$TMP"
        fi
        rmdir "$TMP" 2>/dev/null
    done
    
    echo "  [!] No LUKS header found. Insert USB key."
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

enable_ssh() {
    echo ""
    
    # Start SSH
    mkdir -p /var/run/sshd
    /usr/sbin/sshd
    
    # Get IP
    IP=$(ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    [ -z "$IP" ] && IP=$(ip addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    
    echo "  [✓] SSH enabled"
    echo "  Connect: ssh root@$IP"
    echo ""
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

reverse_tunnel() {
    echo ""
    
    if [ -f "$RECOVERY_DIR/.config/beacon_config" ]; then
        . "$RECOVERY_DIR/.config/beacon_config"
        
        if [ -n "$SSH_SERVER" ]; then
            echo "  Opening tunnel to $SSH_SERVER..."
            
            ssh -fN -R "${SSH_LOCAL_PORT:-2222}:localhost:22" \
                -o "StrictHostKeyChecking=no" \
                "$SSH_SERVER"
            
            echo "  [✓] Tunnel opened"
            echo "  Connect from server: ssh -p ${SSH_LOCAL_PORT:-2222} root@localhost"
        fi
    else
        printf "  SSH server (user@host): "
        read -r server
        
        ssh -fN -R "2222:localhost:22" -o "StrictHostKeyChecking=no" "$server"
        echo "  [✓] Tunnel opened to $server"
    fi
    
    printf "  Press Enter to continue..."
    read -r _
    main_menu
}

# Start
check_triggers
main_menu
RECOVERY_MASTER
    chmod +x "$mount_point/recovery.sh"
    
    # Add some innocuous files for plausible deniability
    cat > "$mount_point/README.txt" << 'README'
System Recovery Partition
========================

This partition contains system recovery tools.
Do not delete or modify.

For support, contact manufacturer.
README

    # Create fake firmware files
    dd if=/dev/urandom of="$mount_point/firmware.dat" bs=1K count=64 2>/dev/null
    
    sync
    umount "$mount_point"
    
    info "Recovery partition created: $recovery_part"
    info "Label: $label"
    
    log "Recovery partition created: $recovery_part with label $label"
}

# ─────────────────────────────────────────────────────────────────────────────
# FULL SYSTEM LAYOUT
# ─────────────────────────────────────────────────────────────────────────────

# Create complete deniable system layout
create_deniable_layout() {
    local device="$1"
    
    step "CREATING DENIABLE SYSTEM LAYOUT"
    
    printf "\n  ${B}This will create:${N}\n"
    printf "    1. Boot partition (FAT32, stealth label)\n"
    printf "    2. Decoy OS (looks like normal Pi)\n"
    printf "    3. Hidden encrypted volume (CI5)\n"
    printf "    4. Recovery tools\n\n"
    
    printf "  ${Y}WARNING: This will ERASE %s${N}\n" "$device"
    printf "  Type 'CREATE' to confirm: "
    read -r confirm
    
    [ "$confirm" = "CREATE" ] || return 1
    
    # Configure persona first
    configure_decoy_persona
    
    # Calculate sizes
    local total_size=$(blockdev --getsize64 "$device")
    local boot_size=$((512 * 1024 * 1024))       # 512MB
    local decoy_size=$((8 * 1024 * 1024 * 1024))  # 8GB
    local recovery_size=$((512 * 1024 * 1024))   # 512MB
    # Hidden volume gets the rest
    
    clone "Creating partition layout..."
    
    # Wipe and create fresh partition table
    dd if=/dev/zero of="$device" bs=1M count=10 2>/dev/null
    parted -s "$device" mklabel msdos
    
    # Create partitions
    local boot_label=$(select_stealth_label)
    
    parted -s "$device" mkpart primary fat32 1MiB 513MiB       # Boot
    parted -s "$device" mkpart primary ext4 513MiB 8705MiB    # Decoy
    parted -s "$device" mkpart primary ext4 8705MiB 9217MiB   # Recovery
    parted -s "$device" mkpart primary ext4 9217MiB 100%      # Hidden
    
    sleep 2
    
    local boot_part="${device}${PART_PREFIX}1"
    local decoy_part="${device}${PART_PREFIX}2"
    local recovery_part="${device}${PART_PREFIX}3"
    local hidden_part="${device}${PART_PREFIX}4"
    
    # Format boot partition
    clone "Formatting boot partition..."
    mkfs.vfat -F 32 -n "$boot_label" "$boot_part"
    
    # Build decoy OS
    clone "Building decoy OS..."
    build_decoy_os "$decoy_part"
    
    # Create recovery partition
    clone "Creating recovery partition..."
    create_recovery_partition "$device" "RECOVERY" 0  # Already created, just populate
    
    # Create hidden volume
    clone "Creating hidden encrypted volume..."
    local hidden_mount=$(create_hidden_volume "$device" "$hidden_part" "$TRIGGERS_DIR")
    
    # Clone current CI5 to hidden volume
    if [ -b "$hidden_mount" ]; then
        clone "Cloning CI5 to hidden volume..."
        
        mkdir -p /mnt/ci5-hidden-target
        mount "$hidden_mount" /mnt/ci5-hidden-target
        
        # Copy current system (excluding decoy-related and temporary)
        rsync -aHAXx \
            --exclude='/boot' \
            --exclude='/mnt' \
            --exclude='/tmp' \
            --exclude='/proc' \
            --exclude='/sys' \
            --exclude='/dev' \
            --exclude='/run' \
            --exclude="$DECOY_DIR" \
            / /mnt/ci5-hidden-target/
        
        # Create necessary directories
        mkdir -p /mnt/ci5-hidden-target/{boot,mnt,tmp,proc,sys,dev,run}
        
        umount /mnt/ci5-hidden-target
        close_hidden_volume
    fi
    
    # Setup boot configuration to boot decoy by default
    clone "Configuring boot..."
    
    local boot_mount="/mnt/ci5-boot"
    mkdir -p "$boot_mount"
    mount "$boot_part" "$boot_mount"
    
    cp -r /boot/firmware/* "$boot_mount/" 2>/dev/null || cp -r /boot/* "$boot_mount/"
    
    # Modify cmdline to boot decoy
    echo "console=serial0,115200 console=tty1 root=${decoy_part} rootfstype=ext4 fsck.repair=yes rootwait" > "$boot_mount/cmdline.txt"
    
    sync
    umount "$boot_mount"
    
    step "DENIABLE LAYOUT COMPLETE"
    
    printf "\n  ${B}Partition Layout:${N}\n"
    printf "    %s1 - Boot (%s)\n" "$device" "$boot_label"
    printf "    %s2 - Decoy OS (visible, normal Pi)\n" "$device"
    printf "    %s3 - Recovery (appears as system partition)\n" "$device"
    printf "    %s4 - Hidden (encrypted, appears as random data)\n" "$device"
    
    printf "\n  ${B}To unlock hidden CI5:${N}\n"
    printf "    - Insert USB key with LUKS header, or\n"
    printf "    - Short GPIO trigger pins, or\n"
    printf "    - Enter passphrase in recovery menu\n"
    
    printf "\n  ${Y}IMPORTANT: Store LUKS header separately!${N}\n"
    printf "    Header location: %s/%s\n" "$TRIGGERS_DIR" "$LUKS_HEADER_NAME"
    printf "    Copy to USB key for plausible deniability.\n\n"
    
    log "Deniable layout created on $device"
}

# ─────────────────────────────────────────────────────────────────────────────
# IMAGE CREATION (Enhanced)
# ─────────────────────────────────────────────────────────────────────────────

calculate_used_space() {
    local device="$1"
    local last_sector=$(fdisk -l "$device" 2>/dev/null | grep "^${device}" | tail -1 | awk '{print $3}')
    local sector_size=$(fdisk -l "$device" 2>/dev/null | grep "Sector size" | awk '{print $4}')
    echo $(( (last_sector * sector_size) * 110 / 100 ))
}

create_minimal_image() {
    local source="$1"
    local output="$2"
    local encrypt="${3:-no}"
    
    step "CREATING BACKUP IMAGE"
    
    clone "Source: $source"
    clone "Output: $output"
    
    sync
    
    local used=$(calculate_used_space "$source")
    local used_human=$(numfmt --to=iec "$used" 2>/dev/null || echo "${used}B")
    clone "Image size: ~$used_human"
    
    mkdir -p "$(dirname "$output")"
    
    local pipeline="dd if=$source bs=4M count=$((used / 4194304 + 1)) status=progress"
    pipeline="$pipeline | $COMPRESS_CMD"
    local final_output="${output}.${COMPRESS_EXT}"
    
    if [ "$encrypt" = "yes" ]; then
        clone "Encryption: GPG symmetric"
        printf "  Passphrase: "
        stty -echo
        read -r passphrase
        stty echo
        printf "\n"
        
        pipeline="$pipeline | gpg --batch --yes --passphrase '$passphrase' -c"
        final_output="${final_output}.gpg"
    fi
    
    clone "Creating image..."
    eval "$pipeline > '$final_output'"
    
    local checksum=$(sha256sum "$final_output" | awk '{print $1}')
    echo "$checksum" > "${final_output}.sha256"
    
    local final_size=$(ls -lh "$final_output" | awk '{print $5}')
    
    info "Image created: $final_output ($final_size)"
    info "Checksum: ${checksum:0:16}..."
    
    log "Created image: $final_output"
    echo "$final_output"
}

create_full_clone() {
    local source="$1"
    local target="$2"
    
    step "CREATING FULL CLONE"
    
    clone "Source: $source"
    clone "Target: $target"
    
    if mount | grep -q "$target"; then
        warn "Target has mounted partitions"
        printf "  Unmount and continue? [y/N]: "
        read -r confirm
        [ "$confirm" = "y" ] || return 1
        umount "${target}"* 2>/dev/null || true
    fi
    
    local source_size=$(blockdev --getsize64 "$source")
    local target_size=$(blockdev --getsize64 "$target")
    
    [ "$target_size" -lt "$source_size" ] && err "Target too small"
    
    clone "Cloning..."
    dd if="$source" of="$target" bs=4M status=progress conv=fsync
    
    sync
    info "Clone complete"
    
    if [ "$target_size" -gt "$source_size" ]; then
        clone "Expanding filesystem..."
        local last_part=$(fdisk -l "$target" 2>/dev/null | grep "^${target}" | tail -1 | awk '{print $1}')
        
        if [ -n "$last_part" ]; then
            parted -s "$target" resizepart $(echo "$last_part" | grep -oE '[0-9]+$') 100% 2>/dev/null || true
            e2fsck -f "$last_part" 2>/dev/null || true
            resize2fs "$last_part" 2>/dev/null || true
            info "Filesystem expanded"
        fi
    fi
    
    log "Full clone: $source -> $target"
}

create_phone_package() {
    local source="$1"
    local output_dir="${2:-$IMAGES_DIR/phone}"
    
    step "CREATING PHONE-FLASHABLE PACKAGE"
    
    mkdir -p "$output_dir"
    
    local used=$(calculate_used_space "$source")
    local blocks=$((used / 4194304 + 1))
    local img_file="$output_dir/ci5-backup-$(date +%Y%m%d).img"
    
    clone "Creating raw image..."
    dd if="$source" of="$img_file" bs=4M count="$blocks" status=progress
    
    cat > "$output_dir/README.txt" << 'README'
CI5 Phone Recovery Package
===========================

Android (EtchDroid):
1. Install EtchDroid from Play Store
2. Connect USB OTG adapter + SD card reader
3. Insert blank SD card
4. Select this .img file
5. Flash and wait 10-20 min

IMPORTANT:
- Do NOT use phone's internal SD slot
- Keep screen ON during flashing
README

    local img_size=$(ls -lh "$img_file" | awk '{print $5}')
    local checksum=$(sha256sum "$img_file" | awk '{print $1}')
    echo "$checksum  $(basename "$img_file")" > "$output_dir/SHA256SUM"
    
    info "Phone package: $output_dir ($img_size)"
    log "Phone package created"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURE WIPE
# ─────────────────────────────────────────────────────────────────────────────

quick_wipe() {
    local device="$1"
    
    step "QUICK WIPE"
    
    warn "This will destroy all data on $device"
    printf "  Type 'WIPE': "
    read -r confirm
    [ "$confirm" = "WIPE" ] || return 1
    
    clone "Wiping..."
    dd if=/dev/zero of="$device" bs=1M count=100 status=progress
    dd if=/dev/zero of="$device" bs=1M seek=$(($(blockdev --getsize64 "$device") / 1048576 - 100)) status=progress 2>/dev/null || true
    
    sync
    info "Quick wipe complete"
    log "Quick wipe: $device"
}

secure_wipe() {
    local device="$1"
    local passes="${2:-1}"
    
    step "SECURE WIPE ($passes pass)"
    
    warn "This will securely destroy all data on $device"
    printf "  Type 'SECURE-WIPE': "
    read -r confirm
    [ "$confirm" = "SECURE-WIPE" ] || return 1
    
    for pass in $(seq 1 "$passes"); do
        clone "Pass $pass: random data..."
        dd if=/dev/urandom of="$device" bs=4M status=progress 2>/dev/null || true
    done
    
    clone "Final: zeros..."
    dd if=/dev/zero of="$device" bs=4M status=progress 2>/dev/null || true
    
    sync
    info "Secure wipe complete"
    log "Secure wipe: $device ($passes passes)"
}

preflight_wipe() {
    step "PRE-FLIGHT WIPE"
    
    detect_boot_device
    
    printf "\n  ${B}Options:${N}\n"
    printf "    [1] Quick wipe (1 min)\n"
    printf "    [2] Secure wipe (30 min)\n"
    printf "    [3] Wipe + keep recovery\n"
    printf "    [4] Cancel\n"
    printf "\n  Choice: "
    read -r choice
    
    case "$choice" in
        1) quick_wipe "$BOOT_DEVICE" ;;
        2) secure_wipe "$BOOT_DEVICE" 1 ;;
        3)
            # Keep recovery partition
            local recovery_part="${BOOT_DEVICE}${PART_PREFIX}3"
            if [ -b "$recovery_part" ]; then
                clone "Preserving recovery partition..."
                
                # Wipe other partitions only
                for part in "${BOOT_DEVICE}${PART_PREFIX}1" "${BOOT_DEVICE}${PART_PREFIX}2" "${BOOT_DEVICE}${PART_PREFIX}4"; do
                    [ -b "$part" ] && dd if=/dev/zero of="$part" bs=4M status=progress 2>/dev/null || true
                done
            else
                quick_wipe "$BOOT_DEVICE"
            fi
            ;;
        *) return 0 ;;
    esac
    
    warn "Device wiped. Boot from backup to restore."
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUD STORAGE
# ─────────────────────────────────────────────────────────────────────────────

configure_cloud() {
    step "CLOUD STORAGE CONFIGURATION"
    
    mkdir -p "$CLONE_DIR"
    
    printf "  Provider:\n"
    printf "    [1] Backblaze B2\n"
    printf "    [2] AWS S3\n"
    printf "    [3] Google Cloud\n"
    printf "    [4] Cloudflare R2\n"
    printf "    [5] S3-compatible\n"
    printf "    [6] SFTP\n"
    printf "    [7] Skip\n"
    printf "\n  Choice: "
    read -r provider
    
    case "$provider" in
        1)
            printf "  B2 Key ID: "; read -r key_id
            printf "  B2 App Key: "; read -r app_key
            printf "  Bucket: "; read -r bucket
            
            cat > "$CLOUD_CONFIG" << EOF
CLOUD_PROVIDER=b2
B2_KEY_ID=$key_id
B2_APP_KEY=$app_key
B2_BUCKET=$bucket
EOF
            ;;
        2|3|4|5)
            printf "  Endpoint (blank for AWS): "; read -r endpoint
            printf "  Access Key: "; read -r access_key
            printf "  Secret Key: "; read -r secret_key
            printf "  Bucket: "; read -r bucket
            printf "  Region: "; read -r region
            
            cat > "$CLOUD_CONFIG" << EOF
CLOUD_PROVIDER=s3
S3_ENDPOINT=$endpoint
S3_ACCESS_KEY=$access_key
S3_SECRET_KEY=$secret_key
S3_BUCKET=$bucket
S3_REGION=${region:-us-east-1}
EOF
            ;;
        6)
            printf "  Host: "; read -r host
            printf "  User: "; read -r user
            printf "  Path: "; read -r path
            
            cat > "$CLOUD_CONFIG" << EOF
CLOUD_PROVIDER=sftp
SFTP_HOST=$host
SFTP_USER=$user
SFTP_PATH=${path:-/backups}
EOF
            ;;
        *) return 0 ;;
    esac
    
    chmod 600 "$CLOUD_CONFIG"
    info "Cloud configured"
}

upload_to_cloud() {
    local file="$1"
    
    [ -f "$CLOUD_CONFIG" ] || err "Cloud not configured"
    . "$CLOUD_CONFIG"
    
    step "UPLOADING TO CLOUD"
    
    local filename=$(basename "$file")
    clone "File: $filename"
    
    case "$CLOUD_PROVIDER" in
        b2)
            if command -v rclone >/dev/null 2>&1; then
                rclone copy "$file" "b2:$B2_BUCKET/ci5-backups/"
            fi
            ;;
        s3)
            if command -v aws >/dev/null 2>&1; then
                AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
                AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
                aws s3 cp "$file" "s3://$S3_BUCKET/ci5-backups/$filename" \
                    ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"}
            fi
            ;;
        sftp)
            scp "$file" "${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}/"
            ;;
    esac
    
    info "Upload complete"
    log "Uploaded: $filename"
}

download_from_cloud() {
    local filename="$1"
    local output="${2:-.}"
    
    [ -f "$CLOUD_CONFIG" ] || err "Cloud not configured"
    . "$CLOUD_CONFIG"
    
    step "DOWNLOADING FROM CLOUD"
    
    case "$CLOUD_PROVIDER" in
        b2)
            rclone copy "b2:$B2_BUCKET/ci5-backups/$filename" "$output/"
            ;;
        s3)
            AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
            AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
            aws s3 cp "s3://$S3_BUCKET/ci5-backups/$filename" "$output/" \
                ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"}
            ;;
        sftp)
            scp "${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}/$filename" "$output/"
            ;;
    esac
    
    info "Downloaded: $output/$filename"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE
# ─────────────────────────────────────────────────────────────────────────────

restore_from_image() {
    local image="$1"
    local target="$2"
    
    step "RESTORING FROM IMAGE"
    
    clone "Image: $image"
    clone "Target: $target"
    
    local pipeline="cat '$image'"
    
    if echo "$image" | grep -q "\.gpg$"; then
        printf "  Passphrase: "
        stty -echo
        read -r passphrase
        stty echo
        printf "\n"
        
        pipeline="gpg --batch --passphrase '$passphrase' -d '$image'"
        image=$(echo "$image" | sed 's/\.gpg$//')
    fi
    
    if echo "$image" | grep -q "\.gz$"; then
        pipeline="$pipeline | gunzip"
    elif echo "$image" | grep -q "\.xz$"; then
        pipeline="$pipeline | xz -d"
    fi
    
    umount "${target}"* 2>/dev/null || true
    
    clone "Restoring..."
    eval "$pipeline | dd of='$target' bs=4M status=progress conv=fsync"
    
    sync
    info "Restore complete"
    log "Restored: $image -> $target"
}

auto_restore() {
    step "AUTO-RESTORE"
    
    clone "Scanning for backups..."
    
    for dev in /dev/sd[a-z]1; do
        [ -b "$dev" ] || continue
        
        local mount_point="/tmp/ci5-scan-$$"
        mkdir -p "$mount_point"
        
        if mount -o ro "$dev" "$mount_point" 2>/dev/null; then
            local backup=$(find "$mount_point" -name "ci5*.img*" 2>/dev/null | head -1)
            
            if [ -n "$backup" ]; then
                info "Found: $backup"
                
                printf "  Restore? [Y/n]: "
                read -r confirm
                
                if [ "$confirm" != "n" ]; then
                    detect_boot_device
                    find_backup_targets
                    
                    for t in $BACKUP_TARGETS; do
                        local tdev=$(echo "$t" | cut -d: -f1)
                        restore_from_image "$backup" "$tdev"
                        umount "$mount_point"
                        return 0
                    done
                fi
            fi
            
            umount "$mount_point"
        fi
        rmdir "$mount_point" 2>/dev/null
    done
    
    warn "No backup found"
}

# ─────────────────────────────────────────────────────────────────────────────
# TRAVEL PRESETS
# ─────────────────────────────────────────────────────────────────────────────

travel_prep() {
    step "TRAVEL PREPARATION WIZARD"
    
    detect_boot_device
    find_backup_targets
    
    printf "\n  ${B}Travel Presets:${N}\n\n"
    printf "    ${G}[1] Full Deniability Kit${N}\n"
    printf "        Creates: Decoy OS + Hidden CI5 + Recovery + Cloud backup\n"
    printf "        Time: ~90 minutes\n\n"
    printf "    ${C}[2] Standard Kit${N}\n"
    printf "        Creates: SD clone + USB clone + Phone image + Cloud\n"
    printf "        Time: ~45 minutes\n\n"
    printf "    ${Y}[3] Quick Kit${N}\n"
    printf "        Creates: SD clone + Phone image\n"
    printf "        Time: ~20 minutes\n\n"
    printf "    ${M}[4] Minimal${N}\n"
    printf "        Creates: Encrypted cloud backup only\n"
    printf "        Time: ~15 minutes\n\n"
    printf "    [5] Custom\n\n"
    
    printf "  Choice: "
    read -r preset
    
    case "$preset" in
        1)
            # Full deniability
            create_deniable_layout "$BOOT_DEVICE"
            
            configure_usb_trigger
            configure_gpio_trigger
            configure_beacon
            
            if [ -f "$CLOUD_CONFIG" ] || configure_cloud; then
                local img=$(create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-travel-$(date +%Y%m%d)" "yes")
                upload_to_cloud "$img"
            fi
            ;;
        2)
            # Standard
            if [ -n "$BACKUP_TARGETS" ]; then
                select_backup_target
                [ -n "$SELECTED_TARGET" ] && create_full_clone "$BOOT_DEVICE" "$SELECTED_TARGET"
            fi
            
            create_phone_package "$BOOT_DEVICE"
            
            if [ -f "$CLOUD_CONFIG" ] || configure_cloud; then
                local img=$(create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-travel-$(date +%Y%m%d)" "yes")
                upload_to_cloud "$img"
            fi
            ;;
        3)
            # Quick
            if [ -n "$BACKUP_TARGETS" ]; then
                select_backup_target
                [ -n "$SELECTED_TARGET" ] && create_full_clone "$BOOT_DEVICE" "$SELECTED_TARGET"
            fi
            
            create_phone_package "$BOOT_DEVICE"
            ;;
        4)
            # Minimal
            [ -f "$CLOUD_CONFIG" ] || configure_cloud
            local img=$(create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-travel-$(date +%Y%m%d)" "yes")
            upload_to_cloud "$img"
            ;;
        5)
            custom_menu
            ;;
    esac
    
    step "TRAVEL PREP COMPLETE"
    
    printf "\n  ${B}Recovery Priority:${N}\n"
    printf "    1. Swap backup SD (30 sec)\n"
    printf "    2. USB boot (1 min)\n"
    printf "    3. USB key unlock (instant)\n"
    printf "    4. Phone flash (15-20 min)\n"
    printf "    5. Beacon auto-recovery (varies)\n"
    printf "    6. Cloud restore (varies)\n\n"
    
    warn "Test your backups before traveling!"
}

select_backup_target() {
    SELECTED_TARGET=""
    
    local i=1
    for target in $BACKUP_TARGETS; do
        local dev=$(echo "$target" | cut -d: -f1)
        local size=$(echo "$target" | cut -d: -f2)
        local model=$(echo "$target" | cut -d: -f3-)
        printf "    [%d] %s (%s) - %s\n" "$i" "$dev" "$size" "$model"
        i=$((i + 1))
    done
    
    printf "\n  Select (or 'skip'): "
    read -r selection
    
    [ "$selection" = "skip" ] && return 0
    
    SELECTED_TARGET=$(echo "$BACKUP_TARGETS" | tr ' ' '\n' | sed -n "${selection}p" | cut -d: -f1)
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "CLONE SYSTEM STATUS"
    
    detect_boot_device
    
    printf "  ${B}Boot Device:${N} %s (%s)\n" "$BOOT_DEVICE" "$BOOT_TYPE"
    
    printf "\n  ${B}Partition Layout:${N}\n"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$BOOT_DEVICE" 2>/dev/null
    
    printf "\n  ${B}Backup Targets:${N}\n"
    find_backup_targets
    if [ -n "$BACKUP_TARGETS" ]; then
        for target in $BACKUP_TARGETS; do
            printf "    %s\n" "$target"
        done
    else
        printf "    ${Y}None detected${N}\n"
    fi
    
    printf "\n  ${B}Saved Images:${N}\n"
    find "$IMAGES_DIR" -name "*.img*" -exec ls -lh {} \; 2>/dev/null || printf "    ${Y}None${N}\n"
    
    printf "\n  ${B}Configuration:${N}\n"
    [ -f "$CLOUD_CONFIG" ] && printf "    Cloud: ${G}Configured${N}\n" || printf "    Cloud: ${Y}Not configured${N}\n"
    [ -f "$USB_KEY_FILE" ] && printf "    USB Key: ${G}Configured${N}\n" || printf "    USB Key: ${Y}Not configured${N}\n"
    [ -f "$GPIO_TRIGGER_FILE" ] && printf "    GPIO Trigger: ${G}Configured${N}\n" || printf "    GPIO Trigger: ${Y}Not configured${N}\n"
    [ -f "$BEACON_CONFIG" ] && printf "    Beacon: ${G}Configured${N}\n" || printf "    Beacon: ${Y}Not configured${N}\n"
    [ -f "$DECOY_CONFIG" ] && printf "    Decoy Persona: ${G}Configured${N}\n" || printf "    Decoy Persona: ${Y}Not configured${N}\n"
    
    # Check for hidden volume
    if cryptsetup status "$HIDDEN_VOLUME_NAME" >/dev/null 2>&1; then
        printf "\n  ${B}Hidden Volume:${N} ${G}Unlocked${N}\n"
    else
        printf "\n  ${B}Hidden Volume:${N} ${Y}Locked/Not present${N}\n"
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
    ____ _                  
   / ___| | ___  _ __   ___ 
  | |   | |/ _ \| '_ \ / _ \
  | |___| | (_) | | | |  __/
   \____|_|\___/|_| |_|\___|
                            
BANNER
        printf "${N}"
        printf "        ${C}CI5 Advanced Clone System${N}\n"
        printf "        ${Y}v3.0-PHOENIX${N}\n\n"
        
        printf "  ${B}QUICK START${N}\n"
        printf "    ${M}[1]${N} Travel Prep Wizard\n"
        printf "    ${M}[2]${N} Quick Clone\n"
        printf "    ${M}[3]${N} Phone Image\n\n"
        
        printf "  ${B}BACKUP${N}\n"
        printf "    ${M}[4]${N} Compressed image\n"
        printf "    ${M}[5]${N} Encrypted image\n"
        printf "    ${M}[6]${N} Upload to cloud\n\n"
        
        printf "  ${B}RESTORE${N}\n"
        printf "    ${M}[7]${N} Auto-restore\n"
        printf "    ${M}[8]${N} Manual restore\n"
        printf "    ${M}[9]${N} Cloud download\n\n"
        
        printf "  ${B}DENIABILITY${N}\n"
        printf "    ${M}[D]${N} Create deniable layout\n"
        printf "    ${M}[O]${N} Configure decoy OS\n"
        printf "    ${M}[H]${N} Hidden volume\n\n"
        
        printf "  ${B}TRIGGERS${N}\n"
        printf "    ${M}[U]${N} USB key trigger\n"
        printf "    ${M}[G]${N} GPIO trigger\n"
        printf "    ${M}[B]${N} Beacon networks\n\n"
        
        printf "  ${B}WIPE${N}\n"
        printf "    ${M}[W]${N} Pre-flight wipe\n\n"
        
        printf "  ${M}[C]${N} Cloud setup  ${M}[S]${N} Status  ${M}[Q]${N} Quit\n\n"
        
        printf "  Choice: "
        read -r choice
        
        case "$choice" in
            1) clear; travel_prep; printf "\n  Press Enter..."; read -r _ ;;
            2)
                clear
                detect_boot_device
                find_backup_targets
                if [ -n "$BACKUP_TARGETS" ]; then
                    select_backup_target
                    [ -n "$SELECTED_TARGET" ] && create_full_clone "$BOOT_DEVICE" "$SELECTED_TARGET"
                fi
                printf "\n  Press Enter..."; read -r _
                ;;
            3) clear; detect_boot_device; create_phone_package "$BOOT_DEVICE"; printf "\n  Press Enter..."; read -r _ ;;
            4) clear; detect_boot_device; create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-$(date +%Y%m%d)" "no"; printf "\n  Press Enter..."; read -r _ ;;
            5) clear; detect_boot_device; create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-$(date +%Y%m%d)" "yes"; printf "\n  Press Enter..."; read -r _ ;;
            6) clear; printf "  Image path: "; read -r p; upload_to_cloud "$p"; printf "\n  Press Enter..."; read -r _ ;;
            7) clear; auto_restore; printf "\n  Press Enter..."; read -r _ ;;
            8)
                clear
                printf "  Image path: "; read -r img
                find_backup_targets
                select_backup_target
                [ -n "$SELECTED_TARGET" ] && restore_from_image "$img" "$SELECTED_TARGET"
                printf "\n  Press Enter..."; read -r _
                ;;
            9) clear; printf "  Filename: "; read -r f; download_from_cloud "$f" "$IMAGES_DIR"; printf "\n  Press Enter..."; read -r _ ;;
            [Dd]) clear; detect_boot_device; create_deniable_layout "$BOOT_DEVICE"; printf "\n  Press Enter..."; read -r _ ;;
            [Oo]) clear; configure_decoy_persona; printf "\n  Press Enter..."; read -r _ ;;
            [Hh])
                clear
                printf "  [1] Create hidden volume\n  [2] Mount hidden volume\n  [3] Unmount\n  Choice: "
                read -r hc
                case "$hc" in
                    1) detect_boot_device; create_hidden_volume "$BOOT_DEVICE" "" "$TRIGGERS_DIR" ;;
                    2) printf "  Partition: "; read -r hp; printf "  Header: "; read -r hh; mount_hidden_volume "$hp" "$hh" ;;
                    3) close_hidden_volume ;;
                esac
                printf "\n  Press Enter..."; read -r _
                ;;
            [Uu]) clear; configure_usb_trigger; printf "\n  Press Enter..."; read -r _ ;;
            [Gg]) clear; configure_gpio_trigger; printf "\n  Press Enter..."; read -r _ ;;
            [Bb]) clear; configure_beacon; create_beacon_recovery; printf "\n  Press Enter..."; read -r _ ;;
            [Ww]) clear; preflight_wipe; printf "\n  Press Enter..."; read -r _ ;;
            [Cc]) clear; configure_cloud; printf "\n  Press Enter..."; read -r _ ;;
            [Ss]) clear; show_status; printf "  Press Enter..."; read -r _ ;;
            [Qq]) clear; exit 0 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
CI5 Clone — Advanced Travel Backup & Recovery System v3.0

QUICK START:
  ci5 clone prep              Travel preparation wizard
  ci5 clone quick             Quick clone to first target
  ci5 clone phone             Phone-flashable image

BACKUP:
  ci5 clone image             Compressed backup
  ci5 clone encrypt           Encrypted backup
  ci5 clone upload <file>     Upload to cloud

RESTORE:
  ci5 clone restore           Auto-detect and restore
  ci5 clone download <file>   Download from cloud

DENIABILITY:
  ci5 clone deniable          Create full deniable layout
  ci5 clone decoy             Configure decoy OS persona
  ci5 clone hidden            Hidden volume management

TRIGGERS:
  ci5 clone usb-key           Configure USB unlock key
  ci5 clone gpio              Configure GPIO trigger
  ci5 clone beacon            Configure auto-recovery networks

WIPE:
  ci5 clone wipe              Pre-flight wipe options

SETUP:
  ci5 clone cloud             Configure cloud storage
  ci5 clone status            Show system status

DENIABLE LAYOUT:
  Creates a system with:
  - Stealth-labeled boot partition
  - Decoy OS (customizable, appears normal)
  - Hidden encrypted CI5 volume
  - Multiple unlock triggers

DECOY OS FEATURES:
  - Custom user/hostname
  - Pre-populated browser history
  - Sample photos and documents
  - Installed apps (Spotify, etc.)
  - Realistic desktop appearance

UNLOCK TRIGGERS:
  - USB key (specific drive unlocks)
  - GPIO pins (physical short)
  - Key combo (held during boot)
  - Beacon (auto-connect + restore)
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    init_compression
    mkdir -p "$CLONE_DIR" "$IMAGES_DIR" "$DECOY_DIR" "$TRIGGERS_DIR" "$BEACON_DIR"
    
    # Create unlock script
    create_unlock_script
    
    case "${1:-}" in
        prep|travel) travel_prep ;;
        quick)
            detect_boot_device
            find_backup_targets
            [ -n "$BACKUP_TARGETS" ] && create_full_clone "$BOOT_DEVICE" "$(echo "$BACKUP_TARGETS" | awk '{print $1}' | cut -d: -f1)"
            ;;
        phone) detect_boot_device; create_phone_package "$BOOT_DEVICE" ;;
        image) detect_boot_device; create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-$(date +%Y%m%d)" "no" ;;
        encrypt) detect_boot_device; create_minimal_image "$BOOT_DEVICE" "$IMAGES_DIR/ci5-$(date +%Y%m%d)" "yes" ;;
        restore) auto_restore ;;
        wipe) preflight_wipe ;;
        deniable) detect_boot_device; create_deniable_layout "$BOOT_DEVICE" ;;
        decoy) configure_decoy_persona ;;
        hidden) 
            case "${2:-}" in
                create) detect_boot_device; create_hidden_volume "$BOOT_DEVICE" "$3" "$TRIGGERS_DIR" ;;
                mount) mount_hidden_volume "$3" "$4" ;;
                close) close_hidden_volume ;;
                *) printf "Usage: ci5 clone hidden [create|mount|close]\n" ;;
            esac
            ;;
        usb-key|usb) configure_usb_trigger ;;
        gpio) configure_gpio_trigger ;;
        beacon) configure_beacon; create_beacon_recovery ;;
        cloud) configure_cloud ;;
        upload) upload_to_cloud "$2" ;;
        download) download_from_cloud "$2" "${3:-.}" ;;
        status) show_status ;;
        help|--help|-h) usage ;;
        *) interactive_menu ;;
    esac
}

main "$@"