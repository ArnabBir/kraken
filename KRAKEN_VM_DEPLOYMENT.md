# Kraken P2P Docker Registry - VM Deployment Guide

This guide shows you how to build Kraken Docker images on your local Mac (ARM64) and deploy them to a remote x86_64 VM for testing.

## Architecture Overview

- **Local Machine**: Mac ARM64 (used for building cross-platform images)
- **Target VM**: x86_64 Linux (where Kraken will run)

## Prerequisites

### On Your Local Mac:
- Docker Desktop with buildx support
- Go (for building binaries)
- Make
- SSH access to your VM

### On Your VM:
- Docker installed
- SSH access
- Sufficient disk space (5-10GB recommended)

## Part 1: Build Cross-Platform Images Locally

### Step 1: Clone and Setup Repository

```bash
# On your local Mac
git clone https://github.com/uber/kraken.git
cd kraken
```

### Step 2: Clean and Build for x86_64

The Makefile has been updated to build binaries inside a `linux/amd64` container, ensuring compatibility with your x86_64 VM.

```bash
# Clean any existing binaries
make clean
rm -rf agent/agent build-index/build-index origin/origin proxy/proxy tools/bin/testfs/testfs tracker/tracker

# Build x86_64 binaries
make bins

# Verify binary architecture (should show x86-64)
docker run --rm -v $(pwd):/app --platform linux/amd64 alpine:latest sh -c "apk add --no-cache file && file /app/agent/agent"
```

**Expected output:**
```
/app/agent/agent: ELF 64-bit LSB executable, x86-64, ...
```

### Step 3: Build Docker Images

```bash
# Build all images with x86_64 architecture
make images

# Verify you have the required images
docker images | grep kraken
```

You should see:
- `kraken-herd:dev`
- `kraken-agent:dev`
- `kraken-build-index:dev`
- `kraken-origin:dev`
- `kraken-proxy:dev`
- `kraken-testfs:dev`
- `kraken-tracker:dev`

### Step 4: Save Images for Transfer

```bash
# Save the main images you need
docker save kraken-herd:dev -o kraken-herd.tar
docker save kraken-agent:dev -o kraken-agent.tar

# Optional: Compress to reduce transfer size
gzip kraken-herd.tar kraken-agent.tar
```

### Step 5: Transfer to VM

```bash
# Transfer images
scp kraken-herd.tar.gz root@stg-droveexeckraken001:/root/
scp kraken-agent.tar.gz root@stg-droveexeckraken001:/root/

# Transfer configuration and scripts
scp -r examples/devcluster root@stg-droveexeckraken001:/root/kraken-config/
```

## Part 2: Deploy on VM

### Step 1: Load Docker Images

SSH into your VM and load the images:

```bash
# SSH to VM
ssh root@stg-droveexeckraken001

# Decompress and load images
cd /root
gunzip kraken-herd.tar.gz kraken-agent.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar

# Verify images loaded
docker images | grep kraken
```

### Step 2: Update Configuration for VM

The devcluster configuration uses `host.docker.internal` which works on Mac but not on Linux. We need to update it:

```bash
# Get your VM's IP address
VM_IP=$(hostname -I | awk '{print $1}')
echo "VM IP: $VM_IP"

# Update all config files to use the VM IP instead of host.docker.internal
cd /root/kraken-config/devcluster/config

# Update build-index config
sed -i "s/host\.docker\.internal/$VM_IP/g" build-index/development.yaml

# Update origin config  
sed -i "s/host\.docker\.internal/$VM_IP/g" origin/development.yaml

# Update tracker config
sed -i "s/host\.docker\.internal/$VM_IP/g" tracker/development.yaml

# Update proxy config
sed -i "s/host\.docker\.internal/$VM_IP/g" proxy/development.yaml

# Update agent config
sed -i "s/host\.docker\.internal/$VM_IP/g" agent/development.yaml
```

### Step 3: Create VM Deployment Scripts

Create a script to run the herd container:

```bash
cat > /root/kraken-config/devcluster/vm_herd_start.sh << 'EOF'
#!/bin/bash

# Stop any existing containers
docker rm -f kraken-herd 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source parameters
source ./herd_param.sh

# Get VM hostname/IP for Docker networking
VM_IP=$(hostname -I | awk '{print $1}')

echo "Starting Kraken Herd on $VM_IP"
echo "Ports: TestFS=$TESTFS_PORT, Origin=$ORIGIN_SERVER_PORT, Tracker=$TRACKER_PORT, Build-Index=$BUILD_INDEX_PORT, Proxy=$PROXY_PORT"

# Start kraken herd with network=host and pass VM_IP as environment variable
docker run -d \
    --name kraken-herd \
    --network host \
    -e VM_IP="$VM_IP" \
    -v "$(pwd)/config/origin/development.yaml":/etc/kraken/config/origin/development.yaml \
    -v "$(pwd)/config/tracker/development.yaml":/etc/kraken/config/tracker/development.yaml \
    -v "$(pwd)/config/build-index/development.yaml":/etc/kraken/config/build-index/development.yaml \
    -v "$(pwd)/config/proxy/development.yaml":/etc/kraken/config/proxy/development.yaml \
    -v "$(pwd)/herd_param.sh":/etc/kraken/herd_param.sh \
    -v "$(pwd)/herd_start_processes.sh":/etc/kraken/herd_start_processes.sh:ro \
    kraken-herd:dev bash -c 'cp /etc/kraken/herd_start_processes.sh /tmp/herd_start.sh && sed -i "s/--peer-ip=\${HOSTNAME}/--peer-ip=$VM_IP/g" /tmp/herd_start.sh && sed -i "s/--blobserver-hostname=\${HOSTNAME}/--blobserver-hostname=$VM_IP/g" /tmp/herd_start.sh && chmod +x /tmp/herd_start.sh && /tmp/herd_start.sh'

echo "Waiting for services to start..."
sleep 5

echo "Checking herd logs:"
docker logs kraken-herd | tail -20
EOF

chmod +x /root/kraken-config/devcluster/vm_herd_start.sh
```

Create a script to run the agent containers:

```bash
cat > /root/kraken-config/devcluster/vm_agents_start.sh << 'EOF'
#!/bin/bash

# Stop any existing agent containers
docker rm -f kraken-agent-one kraken-agent-two 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source parameters for agent one
source ./agent_one_param.sh

VM_IP=$(hostname -I | awk '{print $1}')

echo "Starting Kraken Agent One on $VM_IP"
echo "Ports: Registry=$AGENT_REGISTRY_PORT, Peer=$AGENT_PEER_PORT, Server=$AGENT_SERVER_PORT"

# Start agent one with network=host and explicit peer IP
docker run -d \
    --name kraken-agent-one \
    --network host \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_one_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

sleep 2

# Source parameters for agent two
source ./agent_two_param.sh

echo "Starting Kraken Agent Two on $VM_IP"
echo "Ports: Registry=$AGENT_REGISTRY_PORT, Peer=$AGENT_PEER_PORT, Server=$AGENT_SERVER_PORT"

# Start agent two with network=host and explicit peer IP
docker run -d \
    --name kraken-agent-two \
    --network host \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_two_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

echo "Waiting for agents to start..."
sleep 3

echo "Checking agent one logs:"
docker logs kraken-agent-one | tail -10

echo "Checking agent two logs:"
docker logs kraken-agent-two | tail -10
EOF

chmod +x /root/kraken-config/devcluster/vm_agents_start.sh
```

Create a master startup script:

```bash
cat > /root/start_kraken_cluster.sh << 'EOF'
#!/bin/bash

set -e

echo "========================================="
echo "Starting Kraken P2P Docker Registry"
echo "========================================="

# Start the herd (central services)
echo ""
echo "Step 1: Starting Kraken Herd (Origin, Tracker, Build-Index, Proxy, TestFS)"
/root/kraken-config/devcluster/vm_herd_start.sh

# Wait for herd to stabilize
echo ""
echo "Waiting for herd services to stabilize..."
sleep 10

# Start the agents
echo ""
echo "Step 2: Starting Kraken Agents"
/root/kraken-config/devcluster/vm_agents_start.sh

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
EOF

chmod +x /root/start_kraken_cluster.sh
```

Create a cleanup script:

```bash
cat > /root/stop_kraken_cluster.sh << 'EOF'
#!/bin/bash

echo "Stopping Kraken cluster..."

docker rm -f kraken-herd kraken-agent-one kraken-agent-two 2>/dev/null || true

echo "Kraken cluster stopped."
docker ps -a | grep kraken || echo "No kraken containers running."
EOF

chmod +x /root/stop_kraken_cluster.sh
```

### Step 4: Start the Kraken Cluster

```bash
# Start the entire cluster
/root/start_kraken_cluster.sh
```

## Part 3: Test the POC

### Test 1: Verify Services are Running

```bash
# Check all containers
docker ps --filter name=kraken

# Check logs
docker logs kraken-herd | tail -50
docker logs kraken-agent-one | tail -20
docker logs kraken-agent-two | tail -20
```

### Test 2: Push an Image

```bash
# Pull a test image
docker pull hello-world

# Tag for Kraken
docker tag hello-world localhost:15000/test/hello-world:latest

# Push to Kraken
docker push localhost:15000/test/hello-world:latest
```

### Test 3: Pull from Agents (P2P)

```bash
# Remove local image to force download
docker rmi hello-world localhost:15000/test/hello-world:latest

# Pull from agent one
docker pull localhost:16000/test/hello-world:latest

# Tag and pull from agent two
docker tag localhost:16000/test/hello-world:latest localhost:17000/test/hello-world:latest
docker pull localhost:17000/test/hello-world:latest
```

### Test 4: Test with Larger Image (See P2P in Action)

```bash
# Pull a larger image
docker pull nginx:latest

# Push to Kraken
docker tag nginx:latest localhost:15000/test/nginx:latest
docker push localhost:15000/test/nginx:latest

# Remove local copies
docker rmi nginx:latest localhost:15000/test/nginx:latest

# Pull from both agents simultaneously to see P2P
docker pull localhost:16000/test/nginx:latest &
docker pull localhost:17000/test/nginx:latest &
wait

# Monitor logs to see P2P transfers
docker logs kraken-agent-one | grep -i "peer\|transfer" | tail -20
docker logs kraken-agent-two | grep -i "peer\|transfer" | tail -20
```

## Part 4: Monitoring and Debugging

### View Real-time Logs

```bash
# Follow herd logs
docker logs -f kraken-herd

# Follow agent logs (in separate terminals)
docker logs -f kraken-agent-one
docker logs -f kraken-agent-two
```

### Check Service Endpoints

```bash
# Proxy (for pushing)
curl http://localhost:15000/v2/

# Agent One (for pulling)
curl http://localhost:16000/v2/

# Agent Two (for pulling)
curl http://localhost:17000/v2/

# TestFS health
curl http://localhost:14000/health

# Origin server (internal)
curl http://localhost:15002/health

# Tracker (internal)
curl http://localhost:15003/health

# Build-Index (internal)
curl http://localhost:15004/health
```

### Common Issues and Solutions

#### Issue 1: "Exec format error"

**Problem**: Binary architecture mismatch.

**Solution**: 
```bash
# On local Mac, rebuild with correct platform
make clean
make bins  # This now builds with --platform linux/amd64
make images
# Re-transfer images to VM
```

#### Issue 2: Services Can't Connect

**Problem**: Using `host.docker.internal` on Linux.

**Solution**: 
```bash
# On VM, update configs to use localhost
cd /root/kraken-config/devcluster/config
find . -type f -name "*.yaml" -exec sed -i 's/host.docker.internal/localhost/g' {} \;
# Restart cluster
/root/stop_kraken_cluster.sh
/root/start_kraken_cluster.sh
```

#### Issue 3: Port Conflicts

**Problem**: Ports already in use.

**Solution**:
```bash
# Check what's using the ports
netstat -tuln | grep -E ':(14000|15000|15001|15002|15003|15004|15005|16000|17000)'

# Stop conflicting services or change ports in param.sh files
```

#### Issue 4: Docker Network Issues

**Problem**: Containers can't communicate.

**Solution**: We use `--network host` to simplify networking on Linux. If you need container isolation:
```bash
# Create a custom bridge network
docker network create kraken-net

# Modify startup scripts to use:
# --network kraken-net
# And replace localhost with container names
```

## Part 5: Advanced Configuration

### Enable External Access

To access Kraken from other machines:

```bash
# Open firewall ports
sudo firewall-cmd --permanent --add-port=14000-17000/tcp
sudo firewall-cmd --reload

# Or using ufw
sudo ufw allow 14000:17000/tcp

# Use VM's external IP for Docker configuration
VM_EXTERNAL_IP="<your-vm-external-ip>"
docker tag hello-world $VM_EXTERNAL_IP:15000/test/hello-world:latest
docker push $VM_EXTERNAL_IP:15000/test/hello-world:latest
```

### Persistent Storage

To persist data across container restarts:

```bash
# Create data directories
mkdir -p /var/kraken/data/{testfs,cache,logs}

# Update vm_herd_start.sh to add volume mounts:
# -v /var/kraken/data/testfs:/data \
# -v /var/kraken/data/cache:/cache \
# -v /var/kraken/data/logs:/var/log/kraken \
```

### Resource Limits

To set resource limits:

```bash
# Update startup scripts to add:
# --memory="2g" \
# --cpus="1.5" \
```

## Port Reference

| Component | Port | Purpose |
|-----------|------|---------|
| **Proxy** | 15000 | Push images here |
| **Proxy Server** | 15005 | Internal proxy server |
| **Origin Server** | 15002 | Blob storage server |
| **Origin Peer** | 15001 | Origin P2P port |
| **Tracker** | 15003 | Peer coordination |
| **Build-Index** | 15004 | Tag mapping service |
| **TestFS** | 14000 | File storage backend |
| **Agent One Registry** | 16000 | Pull endpoint |
| **Agent One Peer** | 16001 | P2P transfers |
| **Agent One Server** | 16002 | Internal server |
| **Agent Two Registry** | 17000 | Pull endpoint |
| **Agent Two Peer** | 17001 | P2P transfers |
| **Agent Two Server** | 17002 | Internal server |

## Quick Reference Commands

```bash
# Start cluster
/root/start_kraken_cluster.sh

# Stop cluster
/root/stop_kraken_cluster.sh

# Check status
docker ps --filter name=kraken

# View logs
docker logs kraken-herd
docker logs kraken-agent-one
docker logs kraken-agent-two

# Test endpoints
curl http://localhost:15000/v2/  # Proxy
curl http://localhost:16000/v2/  # Agent One
curl http://localhost:17000/v2/  # Agent Two
curl http://localhost:14000/health  # TestFS

# Push/Pull test
docker pull hello-world
docker tag hello-world localhost:15000/test/hello-world:latest
docker push localhost:15000/test/hello-world:latest
docker pull localhost:16000/test/hello-world:latest
```

## Summary

You've successfully deployed Kraken P2P Docker Registry on your x86_64 VM! The setup includes:

✅ Cross-platform build from Mac ARM64 to Linux x86_64  
✅ Complete herd deployment (Origin, Tracker, Build-Index, Proxy, TestFS)  
✅ Two agent instances for P2P testing  
✅ Automated startup/shutdown scripts  
✅ Health monitoring and debugging tools  

The POC demonstrates:
- Image push through proxy
- P2P distribution between agents
- Scalable architecture for Docker registry

## Next Steps

1. **Production Deployment**: Move to Kubernetes using `examples/k8s/`
2. **Cloud Storage**: Configure S3/GCS backends instead of TestFS
3. **Monitoring**: Set up metrics collection (Prometheus/Grafana)
4. **Security**: Enable TLS and authentication
5. **Scale**: Add more agents to see P2P benefits

For production configuration, refer to the main [CONFIGURATION.md](docs/CONFIGURATION.md) documentation.
