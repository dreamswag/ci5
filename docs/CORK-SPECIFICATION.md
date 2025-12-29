# CI5 Cork Submission Specification v3.0

## Overview

This document defines the standard for submitting corks to the CI5 ecosystem. Following these guidelines ensures your cork integrates seamlessly with CI5's state tracking, dependency management, and clean uninstall capabilities.

## Required Files

Every cork submission must include:

```
my-cork/
├── install.sh          # Main install script (required)
├── uninstall.sh        # Uninstall script (required)
├── manifest.json       # Cork metadata (required)
├── README.md           # Documentation (required)
├── config/             # Default configurations (optional)
│   └── ...
└── hooks/              # Custom hooks (optional)
    ├── pre-install.sh
    ├── post-install.sh
    ├── pre-uninstall.sh
    └── post-uninstall.sh
```

## manifest.json Specification

```json
{
    "name": "my-cork",
    "version": "1.0.0",
    "description": "Brief description of what this cork does",
    "author": "Your Name <email@example.com>",
    "license": "MIT",
    "homepage": "https://github.com/user/my-cork",
    
    "ci5": {
        "min_version": "3.0",
        "category": "dns|security|vpn|monitoring|utility|ecosystem",
        "tags": ["docker", "networking", "privacy"]
    },
    
    "dependencies": {
        "corks": ["adguard", "unbound"],
        "system": ["docker", "curl", "jq"],
        "optional": ["wireguard"]
    },
    
    "provides": {
        "services": ["dns-filtering", "ad-blocking"],
        "ports": [53, 80, 443, 3000],
        "interfaces": ["web-ui", "api", "dns"]
    },
    
    "conflicts": ["pihole"],
    
    "resources": {
        "containers": ["my-cork-main", "my-cork-db"],
        "volumes": ["my-cork-data", "my-cork-config"],
        "networks": ["my-cork-net"]
    },
    
    "install": {
        "method": "docker|native|hybrid",
        "duration_estimate": "2-5 minutes",
        "requires_reboot": false,
        "interactive": false
    },
    
    "uninstall": {
        "preserves_data": true,
        "backup_location": "/var/backups/ci5/my-cork",
        "cleanup_level": "full|containers|config"
    }
}
```

## install.sh Requirements

### Minimum Structure

```bash
#!/bin/sh
set -e

CORK_NAME="my-cork"
CORK_VERSION="1.0.0"

# ═══════════════════════════════════════════════════════════════════════════
# Source CI5 hooks for state tracking
# ═══════════════════════════════════════════════════════════════════════════
if curl -sSf "ci5.run/pure-hooks" >/dev/null 2>&1; then
    . <(curl -sSL ci5.run/pure-hooks)
    CI5_HOOKS=true
else
    CI5_HOOKS=false
fi

# ═══════════════════════════════════════════════════════════════════════════
# Pre-install hook (declare dependencies)
# ═══════════════════════════════════════════════════════════════════════════
if [ "$CI5_HOOKS" = "true" ]; then
    pre_install_hook "$CORK_NAME" "adguard,unbound"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Backup configs before modification
# ═══════════════════════════════════════════════════════════════════════════
if [ "$CI5_HOOKS" = "true" ]; then
    backup_config "$CORK_NAME" "/etc/resolv.conf"
    backup_config "$CORK_NAME" "/etc/some-other-config"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Your install logic here
# ═══════════════════════════════════════════════════════════════════════════

# Check dependencies
command -v docker >/dev/null 2>&1 || { echo "Docker required"; exit 1; }

# Create directories
mkdir -p /etc/my-cork /var/lib/my-cork

# Deploy Docker containers
docker network create my-cork-net 2>/dev/null || true

docker run -d \
    --name my-cork-main \
    --network my-cork-net \
    --restart unless-stopped \
    --label ci5.cork="$CORK_NAME" \
    --label ci5.version="$CORK_VERSION" \
    -v my-cork-data:/data \
    -p 8080:8080 \
    my-image:latest

# Configure services
cat > /etc/systemd/system/my-cork.service << EOF
[Unit]
Description=My Cork Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start my-cork-main
ExecStop=/usr/bin/docker stop my-cork-main

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable my-cork.service

# ═══════════════════════════════════════════════════════════════════════════
# Post-install hook (completes state tracking)
# ═══════════════════════════════════════════════════════════════════════════
if [ "$CI5_HOOKS" = "true" ]; then
    # Option 1: Auto-generate uninstall from tracked changes
    post_install_hook "$CORK_NAME"
    
    # Option 2: Provide custom uninstall script
    # post_install_hook "$CORK_NAME" "/path/to/uninstall.sh"
fi

echo ""
echo "═══ $CORK_NAME installed successfully ═══"
echo ""
echo "Web UI: http://$(hostname -I | awk '{print $1}'):8080"
echo "Uninstall: ci5 pure $CORK_NAME"
```

### Required Labels for Docker Resources

All Docker containers must include these labels:

```bash
docker run \
    --label ci5.cork="$CORK_NAME" \
    --label ci5.version="$CORK_VERSION" \
    --label ci5.component="main|db|cache|proxy" \
    ...
```

This enables automatic detection and management.

## uninstall.sh Requirements

### Minimum Structure

```bash
#!/bin/sh
set -e

CORK_NAME="my-cork"

# ═══════════════════════════════════════════════════════════════════════════
# Docker cleanup
# ═══════════════════════════════════════════════════════════════════════════

# Stop and remove containers
for container in my-cork-main my-cork-db; do
    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true
done

# Remove volumes (with confirmation or flag)
if [ "$PRESERVE_DATA" != "true" ]; then
    docker volume rm my-cork-data my-cork-config 2>/dev/null || true
fi

# Remove network
docker network rm my-cork-net 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
# Service cleanup
# ═══════════════════════════════════════════════════════════════════════════

systemctl stop my-cork.service 2>/dev/null || true
systemctl disable my-cork.service 2>/dev/null || true
rm -f /etc/systemd/system/my-cork.service
systemctl daemon-reload

# ═══════════════════════════════════════════════════════════════════════════
# File cleanup
# ═══════════════════════════════════════════════════════════════════════════

rm -rf /etc/my-cork
rm -rf /var/lib/my-cork
rm -f /var/log/my-cork.log

# ═══════════════════════════════════════════════════════════════════════════
# Config restoration (handled by pure, but document here)
# ═══════════════════════════════════════════════════════════════════════════

# The pure system will restore these from backup:
# - /etc/resolv.conf
# - /etc/some-other-config

echo "Uninstalled: $CORK_NAME"
```

## Dependency Declaration

### Hard Dependencies

Corks that MUST be installed for your cork to function:

```bash
pre_install_hook "my-cork" "adguard,unbound"
```

### Soft Dependencies

Corks that enhance functionality but aren't required:

```bash
# Check and configure if present
if [ -d "/etc/ci5/state/corks/wireguard" ]; then
    # Configure WireGuard integration
    declare_dependency "my-cork" "wireguard"
fi
```

### Conflict Declaration

In manifest.json, declare corks that conflict:

```json
{
    "conflicts": ["pihole"]
}
```

The installer should check and warn:

```bash
if [ -d "/etc/ci5/state/corks/pihole" ]; then
    echo "Warning: This cork conflicts with pihole"
    echo "Please uninstall pihole first: ci5 pure pihole"
    exit 1
fi
```

## Failover Configuration Pattern

When configuring one cork to use another as upstream (e.g., AdGuard → Unbound):

```bash
# In adguard's install.sh after configuring unbound as upstream:

# Record the failover relationship
if [ "$CI5_HOOKS" = "true" ]; then
    record_uninstall_action "adguard" "FAILOVER:unbound:53:If unbound is removed, reconfigure AdGuard upstream DNS"
fi

# Create failover config
cat > /etc/ci5/failover/adguard-unbound.json << EOF
{
    "primary": "adguard",
    "upstream": "unbound",
    "service": "dns",
    "port": 5335,
    "fallback": {
        "action": "reconfigure",
        "target_config": "/opt/AdGuardHome/AdGuardHome.yaml",
        "fallback_upstream": "1.1.1.1"
    }
}
EOF
```

## State Tracking Integration

### What Gets Tracked Automatically

When using `pre_install_hook` and `post_install_hook`:

1. **Docker resources**: Containers, volumes, networks, images created
2. **Files**: New files created, existing files modified
3. **Services**: Systemd units created/enabled
4. **Network**: New listening ports
5. **Dependencies**: Relationship to other corks

### What You Should Track Manually

```bash
# Backup configs before modifying
backup_config "my-cork" "/etc/resolv.conf"

# Record custom cleanup actions
record_uninstall_action "my-cork" "Run: /opt/my-cork/cleanup-db.sh"

# Declare runtime dependencies
declare_dependency "my-cork" "redis"
```

## Testing Requirements

Before submission, verify:

1. **Fresh install**: Install on clean system
2. **With dependencies**: Install after dependencies
3. **Clean uninstall**: `ci5 pure my-cork` removes everything
4. **Reinstall**: Install again after uninstall
5. **Dependency removal**: What happens when upstream cork is removed?

### Test Script

```bash
#!/bin/sh
# test-cork.sh

echo "=== Testing: my-cork ==="

# Test fresh install
echo "Test 1: Fresh install"
ci5 install my-cork
[ $? -eq 0 ] || exit 1

# Verify running
echo "Test 2: Verify running"
docker ps | grep -q my-cork || exit 1

# Test uninstall
echo "Test 3: Uninstall"
ci5 pure my-cork
[ $? -eq 0 ] || exit 1

# Verify clean
echo "Test 4: Verify clean"
docker ps -a | grep -q my-cork && exit 1
[ ! -d /etc/my-cork ] || exit 1

echo "=== All tests passed ==="
```

## Submission Checklist

- [ ] `manifest.json` with all required fields
- [ ] `install.sh` using CI5 hooks
- [ ] `uninstall.sh` with complete cleanup
- [ ] `README.md` with usage documentation
- [ ] Docker labels on all containers
- [ ] Dependencies declared properly
- [ ] Conflicts documented
- [ ] Failover patterns documented (if applicable)
- [ ] Tested on clean system
- [ ] Tested uninstall/reinstall cycle

## Example Corks

See these reference implementations:

- `adguard` - DNS filtering with web UI
- `unbound` - Recursive DNS resolver
- `wireguard` - VPN with CI5 integration
- `suricata` - IDS/IPS monitoring

## Questions?

Open an issue at: https://github.com/ci5/corks/issues
