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
    echo "✓ Redis found on host"
    
    # Check architecture compatibility
    HOST_ARCH=$(uname -m)
    REDIS_BINARY=$(which redis-server)
    
    echo "  Host architecture: $HOST_ARCH"
    
    # Only copy if we're on the same architecture as target (x86_64/amd64)
    if [[ "$HOST_ARCH" == "x86_64" ]]; then
        echo "  Copying Redis binary (compatible architecture)..."
        cp "$REDIS_BINARY" ./docker/host-binaries/
    else
        echo "  ⚠ Architecture mismatch ($HOST_ARCH != x86_64)"
        echo "  Cannot copy Redis binary - will create minimal Redis simulation instead"
        
        # Create a minimal Redis server simulation for development/testing
        cat > ./docker/host-binaries/redis-server << 'EOF'
#!/bin/bash
# Minimal Redis server simulation for air-gapped development
# This is NOT a full Redis implementation - just enough to prevent startup errors

# Parse command line arguments to extract port and bind address
REDIS_PORT=6379
BIND_ADDRESS=127.0.0.1

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            REDIS_PORT="$2"
            shift 2
            ;;
        --bind)
            BIND_ADDRESS="$2"
            shift 2
            ;;
        --version)
            echo "Redis server simulation v1.0.0 (for air-gapped development)"
            exit 0
            ;;
        *)
            # Skip unknown arguments
            shift
            ;;
    esac
done

echo "Starting Redis simulation on ${BIND_ADDRESS}:${REDIS_PORT}"
echo "WARNING: This is a development stub, not a real Redis server!"
echo "Redis simulation PID: $$"

# Create log directory if it doesn't exist
mkdir -p /var/log/kraken/redis-server

# Simulate Redis server running
{
    echo "Redis simulation started at $(date)"
    echo "Listening on ${BIND_ADDRESS}:${REDIS_PORT}"
    while true; do
        echo "$(date): Redis simulation heartbeat (PID: $$)"
        sleep 60
    done
} > /var/log/kraken/redis-server/stdout.log 2>&1 &

# Keep the main process running
wait
EOF
        chmod +x ./docker/host-binaries/redis-server
        echo "  Created Redis simulation script"
    fi
else
    echo "⚠ Redis not found on host."
    echo "  Creating minimal Redis simulation for development..."
    
    # Create the same minimal simulation
    cat > ./docker/host-binaries/redis-server << 'EOF'
#!/bin/bash
# Minimal Redis server simulation for air-gapped development
# This is NOT a full Redis implementation - just enough to prevent startup errors

# Parse command line arguments to extract port and bind address
REDIS_PORT=6379
BIND_ADDRESS=127.0.0.1

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            REDIS_PORT="$2"
            shift 2
            ;;
        --bind)
            BIND_ADDRESS="$2"
            shift 2
            ;;
        --version)
            echo "Redis server simulation v1.0.0 (for air-gapped development)"
            exit 0
            ;;
        *)
            # Skip unknown arguments
            shift
            ;;
    esac
done

echo "Starting Redis simulation on ${BIND_ADDRESS}:${REDIS_PORT}"
echo "WARNING: This is a development stub, not a real Redis server!"
echo "Redis simulation PID: $$"

# Create log directory if it doesn't exist
mkdir -p /var/log/kraken/redis-server

# Simulate Redis server running
{
    echo "Redis simulation started at $(date)"
    echo "Listening on ${BIND_ADDRESS}:${REDIS_PORT}"
    while true; do
        echo "$(date): Redis simulation heartbeat (PID: $$)"
        sleep 60
    done
} > /var/log/kraken/redis-server/stdout.log 2>&1 &

# Keep the main process running
wait
EOF
    chmod +x ./docker/host-binaries/redis-server
    echo "  Created Redis simulation script"
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
