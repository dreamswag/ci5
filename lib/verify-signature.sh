#!/bin/sh
# 🔐 Ci5 Signature Verification Library (v7.5-HARDENED)
# 
# Source this file in other scripts to add GPG verification:
#   . /path/to/lib/verify-signature.sh
#
# Then call:
#   ci5_verify_signature "file.gz" "file.gz.sig"

# Configuration - UPDATE THIS AFTER GENERATING YOUR KEY
CI5_PUBKEY_URL="https://raw.githubusercontent.com/dreamswag/ci5/main/ci5-release.pub"
CI5_PUBKEY_FINGERPRINT="A55D5AF93D765BAAB25DB61D2E0890ED64109351"

# Colors (if terminal supports it)
if [ -t 1 ]; then
    _RED='\033[0;31m'
    _GREEN='\033[0;32m'
    _YELLOW='\033[1;33m'
    _CYAN='\033[0;36m'
    _NC='\033[0m'
else
    _RED=''
    _GREEN=''
    _YELLOW=''
    _CYAN=''
    _NC=''
fi

# Check if GPG is available
ci5_check_gpg() {
    if command -v gpg >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Install GPG if possible
ci5_install_gpg() {
    echo "${_CYAN}[SECURITY] GPG not found, attempting install...${_NC}"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y gnupg >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install gnupg >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache gnupg >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y gnupg2 >/dev/null 2>&1
    fi
    
    ci5_check_gpg
}

# Import the Ci5 public key
ci5_import_pubkey() {
    # Check if already imported
    if gpg --list-keys "$CI5_PUBKEY_FINGERPRINT" >/dev/null 2>&1; then
        return 0
    fi
    
    echo "${_CYAN}[SECURITY] Importing Ci5 release public key...${_NC}"
    
    # Try to download and import
    local tmp_key="/tmp/ci5-release-$$.pub"
    
    if curl -sfL "$CI5_PUBKEY_URL" -o "$tmp_key" 2>/dev/null; then
        if gpg --import "$tmp_key" 2>/dev/null; then
            rm -f "$tmp_key"
            echo "${_GREEN}    ✓ Public key imported${_NC}"
            return 0
        fi
    fi
    
    rm -f "$tmp_key" 2>/dev/null
    echo "${_YELLOW}    ! Could not import public key${_NC}"
    return 1
}

# Main verification function
# Usage: ci5_verify_signature "file" "signature_file"
# Returns: 0 = valid, 1 = invalid/error, 2 = skipped (no gpg)
ci5_verify_signature() {
    local file="$1"
    local sig_file="$2"
    
    echo "${_CYAN}[SECURITY] Verifying GPG signature...${_NC}"
    
    # Check file exists
    if [ ! -f "$file" ]; then
        echo "${_RED}    ✗ File not found: $file${_NC}"
        return 1
    fi
    
    # Check/install GPG
    if ! ci5_check_gpg; then
        if ! ci5_install_gpg; then
            echo "${_YELLOW}╔══════════════════════════════════════════════════════════════════╗${_NC}"
            echo "${_YELLOW}║  ⚠️  GPG NOT AVAILABLE - SIGNATURE VERIFICATION SKIPPED          ║${_NC}"
            echo "${_YELLOW}╚══════════════════════════════════════════════════════════════════╝${_NC}"
            return 2
        fi
    fi
    
    # Import public key
    ci5_import_pubkey || true
    
    # Check signature file exists
    if [ ! -f "$sig_file" ]; then
        # Try to download it
        local sig_url="${file}.sig"
        if echo "$file" | grep -q "^http"; then
            sig_url="${file}.sig"
        fi
        
        echo "${_YELLOW}    ! Signature file not found locally${_NC}"
        return 2
    fi
    
    # Perform verification
    if gpg --verify "$sig_file" "$file" 2>/dev/null; then
        echo "${_GREEN}    ✓ Signature VALID - Image authenticated${_NC}"
        return 0
    else
        echo "${_RED}╔══════════════════════════════════════════════════════════════════╗${_NC}"
        echo "${_RED}║  🚨 SIGNATURE VERIFICATION FAILED                                ║${_NC}"
        echo "${_RED}╠══════════════════════════════════════════════════════════════════╣${_NC}"
        echo "${_RED}║  The file may have been tampered with or is corrupted.           ║${_NC}"
        echo "${_RED}╚══════════════════════════════════════════════════════════════════╝${_NC}"
        return 1
    fi
}

# Interactive verification with user prompts
# Usage: ci5_verify_interactive "file" "signature_file"
# Returns: 0 = proceed, 1 = abort
ci5_verify_interactive() {
    local file="$1"
    local sig_file="$2"
    
    local result
    ci5_verify_signature "$file" "$sig_file"
    result=$?
    
    case $result in
        0)
            # Valid signature
            return 0
            ;;
        1)
            # Invalid signature
            echo ""
            printf "Override and proceed anyway? (DANGEROUS) [y/N]: "
            read -r override
            if [ "$override" = "y" ] || [ "$override" = "Y" ]; then
                echo "${_RED}[!] Proceeding with unverified file at user's risk${_NC}"
                return 0
            fi
            echo "Aborted - signature verification failed."
            return 1
            ;;
        2)
            # Skipped (no GPG or no signature)
            echo ""
            printf "Proceed WITHOUT signature verification? [y/N]: "
            read -r skip
            if [ "$skip" = "y" ] || [ "$skip" = "Y" ]; then
                echo "${_YELLOW}[!] Proceeding without verification${_NC}"
                return 0
            fi
            echo "Aborted."
            return 1
            ;;
    esac
}

# Verify checksum (fallback when GPG unavailable)
# Usage: ci5_verify_checksum "file" "expected_sha256"
ci5_verify_checksum() {
    local file="$1"
    local expected="$2"
    
    if [ -z "$expected" ]; then
        echo "${_YELLOW}[CHECKSUM] No expected hash provided${_NC}"
        return 2
    fi
    
    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        echo "${_YELLOW}[CHECKSUM] No sha256 tool available${_NC}"
        return 2
    fi
    
    if [ "$actual" = "$expected" ]; then
        echo "${_GREEN}[CHECKSUM] ✓ SHA256 matches${_NC}"
        return 0
    else
        echo "${_RED}[CHECKSUM] ✗ SHA256 mismatch${_NC}"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        return 1
    fi
}
