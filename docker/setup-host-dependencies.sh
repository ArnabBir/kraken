#!/bin/bash

# Setup script for air-gapped environment
# This script should be run on the host VM to prepare dependencies
# that will be copied into Docker containers

set -e

echo "Setting up host dependencies for Kraken in air-gapped environment..."

# Create a directory to hold binaries that will be copied to containers
mkdir -p ./docker/host-binaries

# Check if redis-server is available on the host
if command -v redis-server >/dev/null 2>&1; then
    echo "✓ Redis found on host, copying binary..."
    cp $(which redis-server) ./docker/host-binaries/
else
    echo "⚠ Redis not found on host. You need to manually install redis-server on the host VM."
    echo "  On Ubuntu: sudo apt-get install redis-server"
    echo "  Or manually download and install Redis"
fi

# Check for other required tools
echo "Checking for other required tools..."

if command -v nginx >/dev/null 2>&1; then
    echo "✓ Nginx found on host"
else
    echo "⚠ Nginx not found. You need to manually install nginx on the host VM."
fi

if command -v sqlite3 >/dev/null 2>&1; then
    echo "✓ SQLite3 found on host"
    cp $(which sqlite3) ./docker/host-binaries/ 2>/dev/null || echo "  (Could not copy sqlite3 binary)"
else
    echo "⚠ SQLite3 not found. You need to manually install sqlite3 on the host VM."
fi

if command -v curl >/dev/null 2>&1; then
    echo "✓ curl found on host"
    cp $(which curl) ./docker/host-binaries/ 2>/dev/null || echo "  (Could not copy curl binary)"
else
    echo "⚠ curl not found. Will use wget fallback in container."
fi

# Create a simple envsubst replacement
echo "Creating envsubst replacement..."
cat > ./docker/host-binaries/envsubst << 'EOF'
#!/bin/bash
# Simple envsubst replacement using perl
perl -pe 's/\$\{([^}]+)\}/$ENV{$1}/g' "$@"
EOF
chmod +x ./docker/host-binaries/envsubst

echo ""
echo "Host dependency setup complete!"
echo "Files created in ./docker/host-binaries/ will be copied into containers during build."
echo ""
echo "Next steps:"
echo "1. If any tools are missing, install them manually on the host VM"
echo "2. Re-run this script to copy newly installed tools"
echo "3. Run: docker build -t kraken-herd:v0.1.4-104-g263d19c8 -f docker/herd/Dockerfile ./"
