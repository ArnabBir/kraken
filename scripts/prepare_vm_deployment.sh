#!/bin/bash

# Kraken VM Deployment Preparation Script
# This script builds cross-platform images and prepares them for VM deployment

set -e

echo "========================================="
echo "Kraken VM Deployment Preparation"
echo "========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VM_USER="${VM_USER:-root}"
VM_HOST="${VM_HOST:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./vm-deployment}"

# Check if VM_HOST is provided
if [ -z "$VM_HOST" ]; then
    echo -e "${RED}Error: VM_HOST not set${NC}"
    echo "Usage: VM_HOST=your-vm-hostname ./scripts/prepare_vm_deployment.sh"
    echo "   or: VM_HOST=your-vm-hostname VM_USER=devsudo ./scripts/prepare_vm_deployment.sh"
    exit 1
fi

echo "Target VM: $VM_USER@$VM_HOST"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Step 1: Clean old binaries
echo -e "${YELLOW}Step 1: Cleaning old binaries...${NC}"
make clean || true
rm -rf agent/agent build-index/build-index origin/origin proxy/proxy tools/bin/testfs/testfs tracker/tracker

# Step 2: Build x86_64 binaries
echo -e "${YELLOW}Step 2: Building x86_64 binaries (this may take a few minutes)...${NC}"
make bins

# Verify binary architecture
echo -e "${YELLOW}Step 3: Verifying binary architecture...${NC}"
ARCH_CHECK=$(docker run --rm -v $(pwd):/app --platform linux/amd64 alpine:latest file /app/agent/agent 2>/dev/null | grep -o "x86-64" || echo "")
if [ -z "$ARCH_CHECK" ]; then
    echo -e "${RED}Error: Binaries are not x86_64 architecture${NC}"
    docker run --rm -v $(pwd):/app --platform linux/amd64 alpine:latest file /app/agent/agent
    exit 1
fi
echo -e "${GREEN}✓ Binaries are x86_64${NC}"

# Step 4: Build Docker images
echo -e "${YELLOW}Step 4: Building Docker images...${NC}"
make images

# Step 5: Create output directory
echo -e "${YELLOW}Step 5: Preparing deployment package...${NC}"
mkdir -p "$OUTPUT_DIR"

# Step 6: Save Docker images
echo -e "${YELLOW}Step 6: Saving Docker images...${NC}"
docker save kraken-herd:dev -o "$OUTPUT_DIR/kraken-herd.tar"
docker save kraken-agent:dev -o "$OUTPUT_DIR/kraken-agent.tar"

# Step 7: Compress images
echo -e "${YELLOW}Step 7: Compressing images...${NC}"
gzip -f "$OUTPUT_DIR/kraken-herd.tar"
gzip -f "$OUTPUT_DIR/kraken-agent.tar"

# Step 8: Copy configuration
echo -e "${YELLOW}Step 8: Copying configuration files...${NC}"
cp -r examples/devcluster "$OUTPUT_DIR/"

# Step 9: Update configuration for Linux
echo -e "${YELLOW}Step 9: Updating configuration for Linux (replacing host.docker.internal with 0.0.0.0)...${NC}"
find "$OUTPUT_DIR/devcluster/config" -type f -name "*.yaml" -exec sed -i.bak 's/host\.docker\.internal/0.0.0.0/g' {} \;
find "$OUTPUT_DIR/devcluster/config" -type f -name "*.bak" -delete

# Step 10: Create deployment scripts for VM
echo -e "${YELLOW}Step 10: Creating VM deployment scripts...${NC}"

cat > "$OUTPUT_DIR/vm_herd_start.sh" << 'EOFHERD'
#!/bin/bash

# Stop any existing containers
docker rm -f kraken-herd 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/devcluster"

# Source parameters
source ./herd_param.sh

# Get VM hostname/IP for Docker networking
VM_IP=$(hostname -I | awk '{print $1}')

echo "Starting Kraken Herd on $VM_IP"
echo "Ports: TestFS=$TESTFS_PORT, Origin=$ORIGIN_SERVER_PORT, Tracker=$TRACKER_PORT, Build-Index=$BUILD_INDEX_PORT, Proxy=$PROXY_PORT"

# Start kraken herd with network=host for simplicity
docker run -d \
    --name kraken-herd \
    --network host \
    -v "$(pwd)/config/origin/development.yaml":/etc/kraken/config/origin/development.yaml \
    -v "$(pwd)/config/tracker/development.yaml":/etc/kraken/config/tracker/development.yaml \
    -v "$(pwd)/config/build-index/development.yaml":/etc/kraken/config/build-index/development.yaml \
    -v "$(pwd)/config/proxy/development.yaml":/etc/kraken/config/proxy/development.yaml \
    -v "$(pwd)/herd_param.sh":/etc/kraken/herd_param.sh \
    -v "$(pwd)/herd_start_processes.sh":/etc/kraken/herd_start_processes.sh \
    kraken-herd:dev ./herd_start_processes.sh

echo "Waiting for services to start..."
sleep 5

echo "Checking herd logs:"
docker logs kraken-herd | tail -20
EOFHERD

cat > "$OUTPUT_DIR/vm_agents_start.sh" << 'EOFAGENTS'
#!/bin/bash

# Stop any existing agent containers
docker rm -f kraken-agent-one kraken-agent-two 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/devcluster"

# Source parameters for agent one
source ./agent_one_param.sh

VM_IP=$(hostname -I | awk '{print $1}')

echo "Starting Kraken Agent One on $VM_IP"
echo "Ports: Registry=$AGENT_REGISTRY_PORT, Peer=$AGENT_PEER_PORT, Server=$AGENT_SERVER_PORT"

# Start agent one with network=host
docker run -d \
    --name kraken-agent-one \
    --network host \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_one_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

sleep 2

# Source parameters for agent two
source ./agent_two_param.sh

echo "Starting Kraken Agent Two on $VM_IP"
echo "Ports: Registry=$AGENT_REGISTRY_PORT, Peer=$AGENT_PEER_PORT, Server=$AGENT_SERVER_PORT"

# Start agent two with network=host
docker run -d \
    --name kraken-agent-two \
    --network host \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_two_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

echo "Waiting for agents to start..."
sleep 3

echo "Checking agent one logs:"
docker logs kraken-agent-one | tail -10

echo "Checking agent two logs:"
docker logs kraken-agent-two | tail -10
EOFAGENTS

cat > "$OUTPUT_DIR/start_kraken_cluster.sh" << 'EOFSTART'
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Starting Kraken P2P Docker Registry"
echo "========================================="

# Start the herd (central services)
echo ""
echo "Step 1: Starting Kraken Herd (Origin, Tracker, Build-Index, Proxy, TestFS)"
"$SCRIPT_DIR/vm_herd_start.sh"

# Wait for herd to stabilize
echo ""
echo "Waiting for herd services to stabilize..."
sleep 10

# Start the agents
echo ""
echo "Step 2: Starting Kraken Agents"
"$SCRIPT_DIR/vm_agents_start.sh"

# Verify everything is running
echo ""
echo "========================================="
echo "Cluster Status"
echo "========================================="
docker ps --filter name=kraken

echo ""
echo "========================================="
echo "Service Health Checks"
echo "========================================="

# Test endpoints
echo "Testing Proxy (push endpoint):"
curl -s http://localhost:15000/v2/ && echo "✓ Proxy OK" || echo "✗ Proxy Failed"

echo "Testing Agent One (pull endpoint):"
curl -s http://localhost:16000/v2/ && echo "✓ Agent One OK" || echo "✗ Agent One Failed"

echo "Testing Agent Two (pull endpoint):"
curl -s http://localhost:17000/v2/ && echo "✓ Agent Two OK" || echo "✗ Agent Two Failed"

echo "Testing TestFS (storage backend):"
curl -s http://localhost:14000/health && echo " ✓ TestFS OK" || echo "✗ TestFS Failed"

echo ""
echo "========================================="
echo "Kraken Cluster Started Successfully!"
echo "========================================="
echo ""
echo "Next Steps:"
echo "1. Push images to: localhost:15000"
echo "2. Pull images from agents: localhost:16000 or localhost:17000"
echo ""
echo "Example:"
echo "  docker tag hello-world localhost:15000/test/hello-world:latest"
echo "  docker push localhost:15000/test/hello-world:latest"
echo "  docker pull localhost:16000/test/hello-world:latest"
echo ""
EOFSTART

cat > "$OUTPUT_DIR/stop_kraken_cluster.sh" << 'EOFSTOP'
#!/bin/bash

echo "Stopping Kraken cluster..."

docker rm -f kraken-herd kraken-agent-one kraken-agent-two 2>/dev/null || true

echo "Kraken cluster stopped."
docker ps -a | grep kraken || echo "No kraken containers running."
EOFSTOP

chmod +x "$OUTPUT_DIR/vm_herd_start.sh"
chmod +x "$OUTPUT_DIR/vm_agents_start.sh"
chmod +x "$OUTPUT_DIR/start_kraken_cluster.sh"
chmod +x "$OUTPUT_DIR/stop_kraken_cluster.sh"

# Step 11: Create deployment instructions
cat > "$OUTPUT_DIR/DEPLOY_README.md" << 'EOFDEPLOY'
# Kraken VM Deployment Package

This package contains everything needed to deploy Kraken on your VM.

## Files Included

- `kraken-herd.tar.gz` - Herd Docker image (Origin, Tracker, Build-Index, Proxy, TestFS)
- `kraken-agent.tar.gz` - Agent Docker image
- `devcluster/` - Configuration files (pre-configured for Linux)
- `start_kraken_cluster.sh` - Main startup script
- `stop_kraken_cluster.sh` - Shutdown script
- `vm_herd_start.sh` - Herd startup script
- `vm_agents_start.sh` - Agents startup script

## Quick Start

### 1. Load Docker Images

```bash
gunzip kraken-herd.tar.gz kraken-agent.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar
```

### 2. Start Cluster

```bash
./start_kraken_cluster.sh
```

### 3. Test

```bash
# Push an image
docker pull hello-world
docker tag hello-world localhost:15000/test/hello-world:latest
docker push localhost:15000/test/hello-world:latest

# Pull from agents
docker pull localhost:16000/test/hello-world:latest
docker pull localhost:17000/test/hello-world:latest
```

### 4. Stop Cluster

```bash
./stop_kraken_cluster.sh
```

## Port Reference

| Service | Port | Purpose |
|---------|------|---------|
| Proxy | 15000 | Push images |
| Agent One | 16000 | Pull images |
| Agent Two | 17000 | Pull images |
| TestFS | 14000 | Storage backend |

## Troubleshooting

### View Logs
```bash
docker logs kraken-herd
docker logs kraken-agent-one
docker logs kraken-agent-two
```

### Check Status
```bash
docker ps --filter name=kraken
```

### Test Endpoints
```bash
curl http://localhost:15000/v2/  # Should return {}
curl http://localhost:16000/v2/  # Should return {}
curl http://localhost:17000/v2/  # Should return {}
curl http://localhost:14000/health  # Should return OK
```

For detailed documentation, see KRAKEN_VM_DEPLOYMENT.md in the main repository.
EOFDEPLOY

# Step 12: Create transfer script
cat > "$OUTPUT_DIR/transfer_to_vm.sh" << EOFTRANSFER
#!/bin/bash

VM_USER="$VM_USER"
VM_HOST="$VM_HOST"
REMOTE_DIR="/root/kraken"

echo "Transferring deployment package to \$VM_USER@\$VM_HOST:\$REMOTE_DIR"

# Create remote directory
ssh "\$VM_USER@\$VM_HOST" "mkdir -p \$REMOTE_DIR"

# Transfer files
scp -r ./* "\$VM_USER@\$VM_HOST:\$REMOTE_DIR/"

echo ""
echo "Transfer complete!"
echo ""
echo "To deploy on VM, run:"
echo "  ssh \$VM_USER@\$VM_HOST"
echo "  cd \$REMOTE_DIR"
echo "  ./start_kraken_cluster.sh"
EOFTRANSFER

chmod +x "$OUTPUT_DIR/transfer_to_vm.sh"

# Step 13: Calculate sizes
echo ""
echo -e "${YELLOW}Package Summary:${NC}"
ls -lh "$OUTPUT_DIR"/*.tar.gz 2>/dev/null || echo "No compressed images found"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Deployment Package Ready!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Location: $OUTPUT_DIR"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Transfer to VM:"
echo "   cd $OUTPUT_DIR"
echo "   ./transfer_to_vm.sh"
echo ""
echo "   Or manually:"
echo "   scp -r $OUTPUT_DIR/* $VM_USER@$VM_HOST:/root/kraken/"
echo ""
echo "2. On VM, run:"
echo "   ssh $VM_USER@$VM_HOST"
echo "   cd /root/kraken"
echo "   gunzip *.tar.gz"
echo "   docker load -i kraken-herd.tar"
echo "   docker load -i kraken-agent.tar"
echo "   ./start_kraken_cluster.sh"
echo ""
echo -e "${GREEN}For detailed instructions, see:${NC}"
echo "   - $OUTPUT_DIR/DEPLOY_README.md"
echo "   - KRAKEN_VM_DEPLOYMENT.md"
echo ""
