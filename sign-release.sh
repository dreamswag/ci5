#!/bin/bash
# 🔐 Ci5 Release Signing Helper (v7.5-HARDENED)
#
# This script helps maintainers sign releases with GPG.
# Run this on a secure machine before publishing releases.
#
# Usage:
#   ./sign-release.sh generate-key     # One-time: create signing key
#   ./sign-release.sh sign <file>      # Sign a release file
#   ./sign-release.sh verify <file>    # Verify a signed file
#   ./sign-release.sh export-pubkey    # Export public key for repo

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Configuration
CI5_KEY_NAME="Ci5 Release Signing Key"
CI5_KEY_EMAIL="releases@ci5.network"
CI5_KEY_COMMENT="Official Ci5 Release Signing Key"
PUBKEY_FILE="ci5-release.pub"
FINGERPRINT_FILE="ci5-release.fingerprint"

show_help() {
    echo "Ci5 Release Signing Helper"
    echo ""
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  generate-key     Generate a new GPG signing key (one-time setup)"
    echo "  sign <file>      Create a detached signature for a file"
    echo "  verify <file>    Verify a file's signature"
    echo "  export-pubkey    Export public key to $PUBKEY_FILE"
    echo "  list-keys        Show available signing keys"
    echo ""
    echo "Workflow:"
    echo "  1. Run 'generate-key' once on a secure machine"
    echo "  2. Run 'export-pubkey' and commit to repository"
    echo "  3. For each release, run 'sign ci5-factory.img.gz'"
    echo "  4. Upload both .img.gz and .img.gz.sig to GitHub releases"
}

generate_key() {
    echo -e "${CYAN}[*] Generating Ci5 Release Signing Key...${NC}"
    
    # Check if key already exists
    if gpg --list-secret-keys "$CI5_KEY_EMAIL" &>/dev/null; then
        echo -e "${YELLOW}[!] Key for $CI5_KEY_EMAIL already exists${NC}"
        gpg --list-secret-keys "$CI5_KEY_EMAIL"
        echo ""
        echo -n "Generate a NEW key anyway? This won't delete the old one. [y/N]: "
        read -r CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            echo "Aborted."
            return 1
        fi
    fi
    
    # Generate key with strong parameters
    cat > /tmp/ci5-key-params <<EOF
%echo Generating Ci5 Release Signing Key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $CI5_KEY_NAME
Name-Comment: $CI5_KEY_COMMENT
Name-Email: $CI5_KEY_EMAIL
Expire-Date: 2y
%commit
%echo Done
EOF

    echo ""
    echo -e "${YELLOW}You will be prompted to create a passphrase.${NC}"
    echo -e "${YELLOW}Store this passphrase securely - it protects your signing key.${NC}"
    echo ""
    
    gpg --batch --generate-key /tmp/ci5-key-params
    rm -f /tmp/ci5-key-params
    
    # Get the fingerprint
    FINGERPRINT=$(gpg --list-keys --fingerprint "$CI5_KEY_EMAIL" | grep -A1 "pub " | tail -1 | tr -d ' ')
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ KEY GENERATED SUCCESSFULLY                                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Key Fingerprint: $FINGERPRINT"
    echo ""
    echo "Next steps:"
    echo "  1. Run: $0 export-pubkey"
    echo "  2. Commit $PUBKEY_FILE to the ci5 repository"
    echo "  3. Update CI5_PUBKEY_FINGERPRINT in bootstrap.sh"
    echo ""
    echo -e "${RED}IMPORTANT: Back up your private key securely!${NC}"
    echo "  gpg --export-secret-keys $CI5_KEY_EMAIL > ci5-release-private.gpg"
}

sign_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: File not found: $file${NC}"
        return 1
    fi
    
    echo -e "${CYAN}[*] Signing: $file${NC}"
    
    # Check for signing key
    if ! gpg --list-secret-keys "$CI5_KEY_EMAIL" &>/dev/null; then
        echo -e "${RED}Error: No signing key found for $CI5_KEY_EMAIL${NC}"
        echo "Run: $0 generate-key"
        return 1
    fi
    
    # Create detached signature
    gpg --armor --detach-sign --local-user "$CI5_KEY_EMAIL" --output "${file}.sig" "$file"
    
    echo -e "${GREEN}[✓] Signature created: ${file}.sig${NC}"
    
    # Show signature info
    echo ""
    echo "Signature details:"
    gpg --verify "${file}.sig" "$file" 2>&1 | head -5
    
    # Calculate checksums for reference
    echo ""
    echo "Checksums (for documentation):"
    echo "  SHA256: $(sha256sum "$file" | awk '{print $1}')"
    echo "  MD5:    $(md5sum "$file" | awk '{print $1}')"
}

verify_file() {
    local file="$1"
    local sig_file="${file}.sig"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: File not found: $file${NC}"
        return 1
    fi
    
    if [ ! -f "$sig_file" ]; then
        echo -e "${RED}Error: Signature not found: $sig_file${NC}"
        return 1
    fi
    
    echo -e "${CYAN}[*] Verifying: $file${NC}"
    
    if gpg --verify "$sig_file" "$file" 2>&1; then
        echo ""
        echo -e "${GREEN}[✓] Signature VALID${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}[✗] Signature INVALID or key not trusted${NC}"
        return 1
    fi
}

export_pubkey() {
    echo -e "${CYAN}[*] Exporting public key...${NC}"
    
    if ! gpg --list-keys "$CI5_KEY_EMAIL" &>/dev/null; then
        echo -e "${RED}Error: No key found for $CI5_KEY_EMAIL${NC}"
        echo "Run: $0 generate-key"
        return 1
    fi
    
    # Export ASCII-armored public key
    gpg --armor --export "$CI5_KEY_EMAIL" > "$PUBKEY_FILE"
    
    # Get fingerprint
    FINGERPRINT=$(gpg --list-keys --fingerprint "$CI5_KEY_EMAIL" | grep -A1 "pub " | tail -1 | tr -d ' ')
    echo "$FINGERPRINT" > "$FINGERPRINT_FILE"
    
    echo -e "${GREEN}[✓] Public key exported to: $PUBKEY_FILE${NC}"
    echo -e "${GREEN}[✓] Fingerprint saved to: $FINGERPRINT_FILE${NC}"
    echo ""
    echo "Fingerprint: $FINGERPRINT"
    echo ""
    echo "Add this to your repository:"
    echo "  git add $PUBKEY_FILE $FINGERPRINT_FILE"
    echo "  git commit -m 'Add release signing public key'"
    echo ""
    echo "Update bootstrap.sh with:"
    echo "  CI5_PUBKEY_FINGERPRINT=\"$FINGERPRINT\""
}

list_keys() {
    echo -e "${CYAN}[*] Available signing keys:${NC}"
    echo ""
    gpg --list-secret-keys --keyid-format LONG 2>/dev/null || echo "No keys found"
    echo ""
    echo "Ci5 release key email: $CI5_KEY_EMAIL"
}

# Main
case "${1:-help}" in
    generate-key)
        generate_key
        ;;
    sign)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 sign <file>"
            exit 1
        fi
        sign_file "$2"
        ;;
    verify)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 verify <file>"
            exit 1
        fi
        verify_file "$2"
        ;;
    export-pubkey)
        export_pubkey
        ;;
    list-keys)
        list_keys
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
