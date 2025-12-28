# CI5 PHOENIX PROTOCOL — Deployment Kit

## Overview

This kit contains everything needed to deploy the CI5 router bootstrap system.

```
                    ONLINE ←───────────────→ OFFLINE
                       │                        │
         ECOSYSTEM     │   curl | sh    Sovereign│
              ↑        │  Full CLI      Full CLI │
              │        ├────────────────────────┤
              ↓        │   Scripts     Baremetal │
         SCRIPTS       │    Only                 │
           ONLY        │                        │
```

## Directory Structure

```
ci5-phoenix/
├── stub/
│   └── stub.sh                    # Main curl target (ci5.run)
├── scripts/
│   ├── install-recommended.sh     # [1] Full stack
│   ├── install-minimal.sh         # [2] Bufferbloat only
│   └── install-custom.sh          # [3] Toggle menu
├── modules/
│   ├── core/                      # Sysctl, IRQ, SQM
│   ├── security/                  # Suricata, CrowdSec, Firewall
│   ├── dns/                       # Unbound, AdGuard
│   ├── monitoring/                # ntopng, Homepage
│   ├── vpn/                       # WireGuard, OpenVPN
│   └── ecosystem/                 # HWID, CLI, Corks
├── offline/
│   └── install-offline.sh         # Offline installer
├── web/
│   ├── index.html                 # ci5.run landing
│   └── downloads/
│       └── index.html             # ci5.run/downloads
├── keys/                          # (Generate your own)
└── README.md
```

## Deployment Checklist

### 1. Generate Signing Keys

```bash
# Generate key pair (DO THIS ONCE, keep private key SAFE)
openssl genrsa -out ci5-private.pem 2048
openssl rsa -in ci5-private.pem -pubout -out ci5-public.pem

# Update stub.sh with your public key
# Replace the CI5_PUBKEY variable
```

### 2. Sign All Scripts

```bash
# Sign each script
for script in stub/stub.sh scripts/*.sh; do
    openssl dgst -sha256 -sign ci5-private.pem -out "${script}.sig" "$script"
done

# Generate SHA256SUMS
sha256sum stub/stub.sh scripts/*.sh > SHA256SUMS
openssl dgst -sha256 -sign ci5-private.pem -out SHA256SUMS.sig SHA256SUMS
```

### 3. Deploy to ci5.run (Cloudflare Pages)

```bash
# Structure for Pages
ci5.run/
├── index.html                # from web/index.html
├── stub.sh                   # Served as response to curl ci5.run
├── SHA256SUMS
├── SHA256SUMS.sig
├── ci5-public.pem
├── scripts/
│   ├── install-recommended.sh
│   ├── install-recommended.sh.sig
│   ├── install-minimal.sh
│   ├── install-minimal.sh.sig
│   ├── install-custom.sh
│   └── install-custom.sh.sig
└── downloads/
    └── index.html
```

**Cloudflare Pages `_headers` file:**
```
/stub.sh
  Content-Type: text/plain; charset=utf-8
  Content-Disposition: inline

/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
```

**Cloudflare Pages `_redirects` file:**
```
/ /stub.sh 200
```

This makes `curl ci5.run` return the stub directly.

### 4. Build Offline Archives

#### ci5-sovereign.tar.gz (Full Ecosystem Offline)

```bash
mkdir -p ci5-sovereign/{ecosystem,docker,images,modules/core,debs}

# Copy scripts
cp scripts/install-recommended.sh ci5-sovereign/
cp offline/install-offline.sh ci5-sovereign/install.sh
cp -r modules/core/* ci5-sovereign/modules/core/

# Copy ecosystem files
cp tools/ci5-cli ci5-sovereign/ecosystem/
cp -r docker/ ci5-sovereign/ecosystem/docker/

# Bundle Docker images (run on a machine with Docker)
docker pull adguard/adguardhome:latest
docker pull jasonish/suricata:latest
docker pull crowdsecurity/crowdsec:latest
docker pull mvance/unbound:latest
docker pull ghcr.io/gethomepage/homepage:latest
docker pull redis:alpine
docker pull ntop/ntopng:stable

docker save adguard/adguardhome:latest > ci5-sovereign/images/adguard.tar
docker save jasonish/suricata:latest > ci5-sovereign/images/suricata.tar
# ... etc

# Bundle debs (for Debian/Ubuntu)
apt-get download docker-ce docker-ce-cli containerd.io
mv *.deb ci5-sovereign/debs/

# Generate checksums
cd ci5-sovereign
sha256sum -r . > SHA256SUMS
cd ..

# Create archive
tar czvf ci5-sovereign.tar.gz ci5-sovereign/
```

#### ci5-baremetal.tar.gz (Scripts Only Offline)

```bash
mkdir -p ci5-baremetal/{modules/{core,vpn,firewall,docker}}

# Copy installer
cp offline/install-offline.sh ci5-baremetal/install.sh

# Copy core modules
cat > ci5-baremetal/modules/core/99-ci5-network.conf << 'EOF'
# (sysctl contents)
EOF
cp scripts/ci5-irq-balance ci5-baremetal/modules/core/
cp scripts/ci5-sqm ci5-baremetal/modules/core/

# Copy optional modules
cp -r modules/vpn/* ci5-baremetal/modules/vpn/
cp -r modules/firewall/* ci5-baremetal/modules/firewall/

# Create AUDIT.md
cat > ci5-baremetal/AUDIT.md << 'EOF'
# CI5 Baremetal Audit Guide

Every file in this archive is a plain text shell script.
Audit them all before running.

## File Listing
(list all files with descriptions)
EOF

# Checksums
cd ci5-baremetal
sha256sum -r . > SHA256SUMS
cd ..

tar czvf ci5-baremetal.tar.gz ci5-baremetal/
```

### 5. Upload to GitHub Releases

```bash
# Create release
gh release create v1.0.0 \
    ci5-sovereign.tar.gz \
    ci5-baremetal.tar.gz \
    ci5-scripts.tar.gz \
    ci5-full.tar.gz \
    --title "CI5 Phoenix v1.0.0" \
    --notes "Initial release"
```

### 6. Deploy ci5.host (Optional Mirror)

For large files (images, sovereign pack), consider Cloudflare R2:

```bash
# Upload to R2
wrangler r2 object put ci5-files/ci5-sovereign.tar.gz --file ci5-sovereign.tar.gz
```

## User Flows

### Flow 1: One-Line Install (Most Users)
```bash
curl -fsSL https://ci5.run | sh
# Select [1], [2], or [3]
# Done
```

### Flow 2: Audit First (Paranoid)
```bash
curl -fsSL https://ci5.run -o stub.sh
cat stub.sh
sha256sum stub.sh
# Compare hash to GitHub
sh stub.sh
```

### Flow 3: Offline Install (Airgapped)
```bash
# On internet machine:
wget https://github.com/dreamswag/ci5/releases/latest/download/ci5-sovereign.tar.gz

# Transfer to airgapped Pi via USB

# On Pi:
tar xzf ci5-sovereign.tar.gz
cd ci5-sovereign
sudo ./install.sh
```

### Flow 4: Minimal Schizo (Just Bufferbloat)
```bash
curl -fsSL https://ci5.run | sh
# Select [2]
# Done in 30 seconds
# No Docker, no services, no ecosystem
```

## Component Reference

| Component | RAM | Default | Purpose |
|-----------|-----|---------|---------|
| sysctl tuning | 0 | Always | TCP/UDP buffers, BBR |
| IRQ balancing | 0 | Always | USB NIC optimization |
| SQM/CAKE | ~10MB | Always | Bufferbloat fix |
| Suricata | ~500MB | Recommended | IDS/IPS |
| CrowdSec | ~100MB | Recommended | Threat intel |
| Unbound | ~50MB | Recommended | Local DNS |
| AdGuard Home | ~100MB | Recommended | DNS filtering |
| ntopng | ~300MB | Recommended | Traffic analysis |
| Homepage | ~100MB | Recommended | Dashboard |
| ci5 CLI | ~50MB | Ecosystem | Cork management |

## Verification

All scripts are signed. Users can verify:

```bash
# Download public key
curl -fsSL https://ci5.run/ci5-public.pem -o ci5.pub

# Verify signature
openssl dgst -sha256 -verify ci5.pub -signature script.sh.sig script.sh
```

## Testing

Before release, test all paths:

1. `curl ci5.run | sh` → Option 1 → Full stack works
2. `curl ci5.run | sh` → Option 2 → Minimal works
3. `curl ci5.run | sh` → Option 3 → Custom toggles work
4. Sovereign tarball → Offline install works
5. Baremetal tarball → Scripts-only works
6. Signature verification → All pass

## Maintenance

### Updating Scripts
1. Edit script
2. Re-sign: `openssl dgst -sha256 -sign ci5-private.pem -out script.sh.sig script.sh`
3. Update SHA256SUMS
4. Push to GitHub → ci5.run auto-deploys

### Updating Docker Images
1. Rebuild sovereign archive with new images
2. Create new GitHub release
3. Update download links if versioned
