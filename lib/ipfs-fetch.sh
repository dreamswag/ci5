#!/bin/sh
# CI5 IPFS Fetch Library
# Downloads files from IPFS using public gateways with fallback

GATEWAYS="
https://ipfs.io/ipfs/
https://dweb.link/ipfs/
https://cloudflare-ipfs.com/ipfs/
https://gateway.pinata.cloud/ipfs/
"

# Download file from IPFS
# Usage: ipfs_fetch <cid> <output_file>
ipfs_fetch() {
    local cid="$1"
    local output="$2"
    
    if [ -z "$cid" ] || [ -z "$output" ]; then
        echo "Usage: ipfs_fetch <cid> <output_file>"
        return 1
    fi

    for gateway in $GATEWAYS; do
        local url="${gateway}${cid}"
        echo "[*] Trying $gateway..."
        
        if command -v curl >/dev/null 2>&1; then
            if curl -L -s -f -o "$output" "$url"; then
                echo "[+] Download successful from $gateway"
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q -O "$output" "$url"; then
                echo "[+] Download successful from $gateway"
                return 0
            fi
        else
            echo "Error: curl or wget required."
            return 1
        fi
    done

    echo "[!] Failed to download $cid from any gateway."
    rm -f "$output"
    return 1
}
