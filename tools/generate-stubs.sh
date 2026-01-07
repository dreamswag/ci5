#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# CI5 STUB GENERATOR
# ══════════════════════════════════════════════════════════════════════════════
# Generates verify-stub-full.sh and verify-stub-lite.sh from the template.
# Run this as part of the release process or pre-commit hook.
# ══════════════════════════════════════════════════════════════════════════════
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEMPLATE="$REPO_ROOT/verify-stub.tpl"
OUTPUT_FULL="$REPO_ROOT/verify-stub-full.sh"
OUTPUT_LITE="$REPO_ROOT/verify-stub-lite.sh"

# Check template exists
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

echo "[*] Generating verification stubs from template..."

# Generate Full stub (maps to install-recommended.sh)
sed 's|__TARGET_INSTALLER_PLACEHOLDER__|install-recommended.sh|g' "$TEMPLATE" > "$OUTPUT_FULL"
chmod +x "$OUTPUT_FULL"
echo "[✓] Generated: verify-stub-full.sh → install-recommended.sh"

# Generate Lite stub (maps to install-minimal.sh)
sed 's|__TARGET_INSTALLER_PLACEHOLDER__|install-minimal.sh|g' "$TEMPLATE" > "$OUTPUT_LITE"
chmod +x "$OUTPUT_LITE"
echo "[✓] Generated: verify-stub-lite.sh → install-minimal.sh"

# Compute hashes for verification
HASH_FULL=$(sha256sum "$OUTPUT_FULL" | cut -d' ' -f1)
HASH_LITE=$(sha256sum "$OUTPUT_LITE" | cut -d' ' -f1)

echo ""
echo "Stub hashes (for auditing):"
echo "  verify-stub-full.sh: sha256:$HASH_FULL"
echo "  verify-stub-lite.sh: sha256:$HASH_LITE"
echo ""
echo "[✓] Done. Commit both generated files."
