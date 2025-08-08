#!/bin/bash
# build-kraken.sh - Smart build script for air-gapped environments

echo "🔍 Detecting build environment..."

# Test if we can pull from docker.phonepe.com
if ! docker pull docker.phonepe.com/ubuntu >/dev/null 2>&1; then
    echo "❌ Cannot access docker.phonepe.com/ubuntu"
    exit 1
fi

echo "✅ Base image accessible"

# Test if we can pull Redis image
if docker pull redis:6-alpine >/dev/null 2>&1; then
    echo "✅ External images accessible - using multi-stage build"
    echo "🏗️  Building with external Redis image..."
    docker build -q -t kraken-herd:dev -f docker/herd/Dockerfile ./
    BUILD_RESULT=$?
else
    echo "⚠️  External images not accessible - using fallback approach"
    echo "🏗️  Building with fallback Dockerfile..."
    docker build -q -t kraken-herd:dev -f docker/herd/Dockerfile.fallback ./
    BUILD_RESULT=$?
fi

if [ $BUILD_RESULT -eq 0 ]; then
    echo "✅ Herd image built successfully"
    
    # Test if essential tools are available
    echo "🔍 Testing essential tools..."
    
    if docker run --rm kraken-herd:dev which redis-server >/dev/null 2>&1; then
        echo "✅ redis-server available"
    else
        echo "⚠️  redis-server not found - may need manual setup"
    fi
    
    if docker run --rm kraken-herd:dev which envsubst >/dev/null 2>&1; then
        echo "✅ envsubst available"
    else
        echo "⚠️  envsubst not found - using replacement script"
    fi
    
    echo "🚀 Building remaining images..."
    make images
    
else
    echo "❌ Build failed. Try manual approach:"
    echo ""
    echo "1. Install tools on host:"
    echo "   sudo apt-get install -y redis-server gettext-base"
    echo ""
    echo "2. Run with volume mounts:"
    echo "   docker run -d --name kraken-herd-multihost \\"
    echo "     -v /usr/bin/redis-server:/usr/bin/redis-server:ro \\"
    echo "     -v /usr/bin/envsubst:/usr/bin/envsubst:ro \\"
    echo "     -p 14000-15005:14000-15005 \\"
    echo "     kraken-herd:dev"
fi
