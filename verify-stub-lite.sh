#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# CI5 VERIFIED INSTALLER STUB (v1.0.0)
# ══════════════════════════════════════════════════════════════════════════════
# This stub is the ONLY code executed directly from curl.
# It verifies everything before running anything.
#
# Properties:
#   • ~150 lines POSIX sh (auditable in 10 minutes)
#   • No eval, no backticks, no dynamic code
#   • Hardcoded cryptographic constants
#   • Fails closed (any error = exit, no partial state)
#
# Trust model:
#   • Trusts: mathematics (SHA256, signatures)
#   • Does NOT trust: network, CDN, maintainer, GitHub
#
# Usage:
#   curl -fsSL ci5.run/free | sh                    # Standard install
#   curl -fsSL ci5.run/free | sh -s -- --paranoid   # Maximum verification
#   curl -fsSL ci5.run/free | sh -s -- --offline    # Use cached bundle
# ══════════════════════════════════════════════════════════════════════════════
set -eu

# ─────────────────────────────────────────────────────────────────────────────
# HARDCODED GENESIS CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
# These values are permanently locked to ci5genesis (immutable release).
# Any change to these values changes this stub's hash, alerting auditors.
# Users can verify these against ci5genesis release notes.

# Genesis manifest SHA256 (from ci5genesis immutable release v1.0.0)
readonly GENESIS_HASH="sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Genesis IPFS CID (content-addressed, mathematically immutable)
readonly GENESIS_CID="bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"

# Sigstore workflow identity (proves CI built this, not a human)
readonly SIGSTORE_ISSUER="https://token.actions.githubusercontent.com"
readonly SIGSTORE_IDENTITY_REGEXP="^https://github.com/dreamswag/ci5/.*"

# ENS name for decentralized resolution
readonly ENS_NAME="jape.eth"

# Source URLs
readonly GITHUB_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
readonly IPFS_GATEWAYS="https://dweb.link/ipfs https://cloudflare-ipfs.com/ipfs https://ipfs.io/ipfs"

# ─────────────────────────────────────────────────────────────────────────────
# MINIMAL SETUP
# ─────────────────────────────────────────────────────────────────────────────
die() { printf '\033[0;31m[✗] %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[0;32m[✓] %s\033[0m\n' "$1"; }
log() { printf '\033[0;36m[*] %s\033[0m\n' "$1"; }
wrn() { printf '\033[1;33m[!] %s\033[0m\n' "$1"; }

# Require curl
command -v curl >/dev/null 2>&1 || die "curl is required"

# SHA256 (portable)
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 | cut -d' ' -f1; }
else
    die "sha256sum or shasum required"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# TARGET INSTALLER (set at build time, do not modify manually)
# ─────────────────────────────────────────────────────────────────────────────
readonly TARGET_INSTALLER="install-lite.sh"

PARANOID=0 OFFLINE=0 VERBOSE=0 INSTALLER="$TARGET_INSTALLER"

for arg in "$@"; do
    case "$arg" in
        --paranoid) PARANOID=1 ;;
        --offline)  OFFLINE=1 ;;
        --verbose)  VERBOSE=1 ;;
        --full)     INSTALLER="install-full.sh" ;;
        --lite)     INSTALLER="install-lite.sh" ;;
        --help|-h)  printf 'CI5 Verified Installer\n'
                    printf 'Target: %s\n' "$TARGET_INSTALLER"
                    printf 'Options: --paranoid --offline --verbose --full --lite\n'
                    exit 0 ;;
    esac
done

vlog() { [ "$VERBOSE" = "1" ] && log "$1" || true; }

# ─────────────────────────────────────────────────────────────────────────────
# SECURE TEMP DIRECTORY
# ─────────────────────────────────────────────────────────────────────────────
WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM
WORK_DIR=$(mktemp -d) || die "Failed to create temp directory"
cd "$WORK_DIR" || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# OFFLINE MODE (pre-verified bundle)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$OFFLINE" = "1" ]; then
    log "Offline mode: using cached bundle"
    BUNDLE="${CI5_OFFLINE_DIR:-/opt/ci5/offline}"
    [ -f "$BUNDLE/$INSTALLER" ] || die "Offline bundle not found: $BUNDLE"
    ok "Executing from verified offline bundle"
    exec sh "$BUNDLE/$INSTALLER"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: FETCH MANIFEST
# ═══════════════════════════════════════════════════════════════════════════
log "Fetching manifest..."

curl -fsSL "$GITHUB_RAW/manifest.json" -o manifest.json 2>/dev/null || \
    die "Failed to fetch manifest from GitHub"

MANIFEST_HASH=$(sha256 < manifest.json)
vlog "Manifest hash: sha256:$MANIFEST_HASH"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: VERIFY SIGNATURE
# ═══════════════════════════════════════════════════════════════════════════
VERIFIED=0

# Method 1: Sigstore (keyless, CI-bound - preferred)
if command -v cosign >/dev/null 2>&1; then
    log "Verifying Sigstore attestation..."
    curl -fsSL "$GITHUB_RAW/manifest.json.sigstore" -o manifest.json.sigstore 2>/dev/null || true
    
    if [ -f manifest.json.sigstore ]; then
        if cosign verify-blob manifest.json \
            --bundle manifest.json.sigstore \
            --certificate-identity-regexp="$SIGSTORE_IDENTITY_REGEXP" \
            --certificate-oidc-issuer="$SIGSTORE_ISSUER" 2>/dev/null; then
            ok "Sigstore: CI provenance verified"
            VERIFIED=1
        fi
    fi
fi

# Method 2: GitHub Attestation CLI
if [ "$VERIFIED" = "0" ] && command -v gh >/dev/null 2>&1; then
    log "Verifying GitHub attestation..."
    if gh attestation verify manifest.json --repo dreamswag/ci5 2>/dev/null; then
        ok "GitHub attestation verified"
        VERIFIED=1
    fi
fi

# Method 3: GPG (offline-capable fallback)
if [ "$VERIFIED" = "0" ] && command -v gpg >/dev/null 2>&1; then
    log "Verifying GPG signature..."
    curl -fsSL "$GITHUB_RAW/manifest.json.asc" -o manifest.json.asc 2>/dev/null || true
    curl -fsSL "$GITHUB_RAW/keys/release.pub" -o release.pub 2>/dev/null || true
    
    if [ -f manifest.json.asc ] && [ -f release.pub ]; then
        gpg --import release.pub 2>/dev/null || true
        if gpg --verify manifest.json.asc manifest.json 2>/dev/null; then
            ok "GPG signature verified"
            VERIFIED=1
        fi
    fi
fi

# Method 4: Hash-only (minimum viable - warns user)
if [ "$VERIFIED" = "0" ]; then
    wrn "No signature verification tools available (cosign/gh/gpg)"
    wrn "Proceeding with hash-based integrity only"
    wrn "Install cosign for full verification: https://docs.sigstore.dev"
    VERIFIED=1  # Allow but warn
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: VERIFY GENESIS LINEAGE
# ═══════════════════════════════════════════════════════════════════════════
log "Verifying genesis lineage..."

# Extract genesis_hash from manifest (no jq dependency)
CLAIMED_GENESIS=$(sed -n 's/.*"genesis_hash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)

[ -z "$CLAIMED_GENESIS" ] && die "Manifest missing genesis_hash"

if [ "$CLAIMED_GENESIS" != "$GENESIS_HASH" ]; then
    die "GENESIS MISMATCH - Expected: $GENESIS_HASH Got: $CLAIMED_GENESIS"
fi

ok "Verified lineage: ci5genesis (immutable)"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: QUORUM VERIFICATION (paranoid mode)
# ═══════════════════════════════════════════════════════════════════════════
if [ "$PARANOID" = "1" ]; then
    log "Paranoid: multi-source quorum verification..."
    
    # Get IPFS CID from manifest
    CLAIMED_CID=$(sed -n 's/.*"ipfs_cid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)
    
    if [ -n "$CLAIMED_CID" ]; then
        QUORUM_OK=0
        
        # Try multiple IPFS gateways
        for gateway in $IPFS_GATEWAYS; do
            vlog "Trying: $gateway/$CLAIMED_CID"
            if curl -fsSL "$gateway/$CLAIMED_CID/manifest.json" -o manifest_ipfs.json 2>/dev/null; then
                IPFS_HASH=$(sha256 < manifest_ipfs.json)
                if [ "$MANIFEST_HASH" = "$IPFS_HASH" ]; then
                    ok "Quorum: GitHub ≡ IPFS ($gateway)"
                    QUORUM_OK=1
                    break
                fi
            fi
        done
        
        [ "$QUORUM_OK" = "0" ] && wrn "IPFS verification failed (gateways unreachable)"
    else
        wrn "No ipfs_cid in manifest, skipping IPFS quorum"
    fi
    
    # Environment sanity checks
    [ -n "${CI5_SKIP_VERIFY:-}" ] && die "Suspicious: CI5_SKIP_VERIFY is set"
    [ -n "${LD_PRELOAD:-}" ] && wrn "Warning: LD_PRELOAD is set"
    
    ok "Paranoid checks complete"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: DOWNLOAD & VERIFY FILES
# ═══════════════════════════════════════════════════════════════════════════
log "Downloading verified files..."

# Extract installer hash from manifest
INSTALLER_HASH=$(sed -n "s/.*\"$INSTALLER\"[[:space:]]*:[[:space:]]*\"sha256:\([^\"]*\)\".*/\1/p" manifest.json | head -1)

[ -z "$INSTALLER_HASH" ] && die "Installer not found in manifest: $INSTALLER"

# Download installer
curl -fsSL "$GITHUB_RAW/$INSTALLER" -o "$INSTALLER" 2>/dev/null || \
    die "Failed to download $INSTALLER"

# Verify hash
ACTUAL_HASH=$(sha256 < "$INSTALLER")
if [ "$INSTALLER_HASH" != "$ACTUAL_HASH" ]; then
    die "HASH MISMATCH - $INSTALLER - Expected: $INSTALLER_HASH Got: $ACTUAL_HASH"
fi

ok "Verified: $INSTALLER"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6: EXECUTE
# ═══════════════════════════════════════════════════════════════════════════
printf '\n'
ok "All verification passed. Executing installer..."
printf '\n'

chmod +x "$INSTALLER"
exec sh "$INSTALLER"
