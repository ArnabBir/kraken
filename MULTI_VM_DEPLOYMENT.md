# Kraken P2P Docker Registry - Multi-VM Deployment Guide

This guide walks you through deploying Kraken across **3 separate VMs** for a distributed P2P Docker Registry setup.

## Architecture Overview

### VM Distribution

| VM Hostname                        | IP Address    | Role                  | Components                                      |
|------------------------------------|---------------|-----------------------|-------------------------------------------------|
| stg-droveexeckraken001.phonepe.nb6 | 172.24.24.49  | **Herd (Control)**    | Origin, Tracker, Build-Index, Proxy, TestFS    |
| stg-droveexeckraken002.phonepe.nb6 | 172.24.24.50  | **Agent One (Pull)**  | Kraken Agent (registry pull endpoint)          |
| stg-droveexeckraken003.phonepe.nb6 | 172.24.24.51  | **Agent Two (Pull)**  | Kraken Agent (registry pull endpoint)          |

**Note:** Replace IP addresses with your actual VM IPs.

### Port Allocation

#### VM1 - Herd (stg-droveexeckraken001)
| Service       | Port  | Purpose                    |
|---------------|-------|----------------------------|
| TestFS        | 14000 | File storage backend       |
| Redis         | 14001 | Cache                      |
| Origin Server | 15002 | Blob storage server        |
| Origin Peer   | 15001 | P2P transfers              |
| Tracker       | 15003 | Peer coordination          |
| Build-Index   | 15004 | Tag mapping service        |
| Proxy         | 15000 | **Push endpoint (public)** |
| Proxy Server  | 15005 | Internal proxy server      |

#### VM2 - Agent One (stg-droveexeckraken002)
| Service         | Port  | Purpose                    |
|-----------------|-------|----------------------------|
| Agent Registry  | 16000 | **Pull endpoint (public)** |
| Agent Peer      | 16001 | P2P transfers              |
| Agent Server    | 16002 | Internal agent server      |

#### VM3 - Agent Two (stg-droveexeckraken003)
| Service         | Port  | Purpose                    |
|-----------------|-------|----------------------------|
| Agent Registry  | 17000 | **Pull endpoint (public)** |
| Agent Peer      | 17001 | P2P transfers              |
| Agent Server    | 17002 | Internal agent server      |

## Prerequisites

### On Your Local Mac (Build Machine)
- Docker Desktop with buildx support
- Go (for building binaries)
- Make
- SSH access to all 3 VMs

### On All VMs
- Docker installed and running
- SSH access (root user)
- Sufficient disk space (5-10GB per VM)
- Network connectivity between all VMs
- Ports listed above open in firewall

## Phase 1: Build Images Locally (Mac)

### Step 1: Build Cross-Platform Images

On your local Mac, build the x86_64 compatible images:

```bash
cd /path/to/kraken

# Clean previous builds
make clean
rm -rf agent/agent build-index/build-index origin/origin proxy/proxy tools/bin/testfs/testfs tracker/tracker

# Build binaries for x86_64
make bins

# Verify architecture
docker run --rm -v $(pwd):/app --platform linux/amd64 alpine:latest sh -c "apk add --no-cache file && file /app/agent/agent"
# Expected: /app/agent/agent: ELF 64-bit LSB executable, x86-64...

# Build Docker images
make images

# Verify images
docker images | grep kraken
```

### Step 2: Save and Compress Images

```bash
# Save the required images
docker save kraken-herd:dev -o kraken-herd.tar
docker save kraken-agent:dev -o kraken-agent.tar

# Compress for faster transfer
gzip kraken-herd.tar kraken-agent.tar
```

## Phase 2: Transfer Images to VMs

### Step 3: Transfer to All VMs

```bash
# Set VM hostnames
VM1="stg-droveexeckraken001.phonepe.nb6"
VM2="stg-droveexeckraken002.phonepe.nb6"
VM3="stg-droveexeckraken003.phonepe.nb6"

# Transfer herd image to VM1
scp kraken-herd.tar.gz root@${VM1}:/root/

# Transfer agent image to VM2 and VM3
scp kraken-agent.tar.gz root@${VM2}:/root/
scp kraken-agent.tar.gz root@${VM3}:/root/

# Transfer configs to all VMs
scp -r examples/devcluster root@${VM1}:/root/kraken-config/
scp -r examples/devcluster root@${VM2}:/root/kraken-config/
scp -r examples/devcluster root@${VM3}:/root/kraken-config/
```

## Phase 3: Configure Each VM

### Step 4: Configure Docker for Insecure Registry

**IMPORTANT:** Docker requires HTTPS by default. Since we're using HTTP for testing, we need to configure Docker to allow insecure registries.

**On VM1 (Herd) - Allow pushing to local registry:**
```bash
ssh root@stg-droveexeckraken001.phonepe.nb6

# Add insecure registry configuration
cat > /etc/docker/daemon.json << EOF
{
  "insecure-registries": ["172.24.24.49:15000", "localhost:15000"]
}
EOF

# Restart Docker
systemctl restart docker

# Verify
docker info | grep -A 5 "Insecure Registries"
```

**On VM2 (Agent One) - Allow pulling from all registries:**
```bash
ssh root@stg-droveexeckraken002.phonepe.nb6

# Add insecure registry configuration
cat > /etc/docker/daemon.json << EOF
{
  "insecure-registries": [
    "172.24.24.49:15000",
    "172.24.24.67:16000",
    "localhost:16000"
  ]
}
EOF

# Restart Docker
systemctl restart docker

# Verify
docker info | grep -A 5 "Insecure Registries"
```

**On VM3 (Agent Two) - Allow pulling from all registries:**
```bash
ssh root@stg-droveexeckraken003.phonepe.nb6

# Add insecure registry configuration
cat > /etc/docker/daemon.json << EOF
{
  "insecure-registries": [
    "172.24.24.49:15000",
    "172.24.24.51:17000",
    "localhost:17000"
  ]
}
EOF

# Restart Docker
systemctl restart docker

# Verify
docker info | grep -A 5 "Insecure Registries"
```

**On Your Local Machine (for testing push/pull):**
```bash
# Add to /etc/docker/daemon.json (Linux) or Docker Desktop settings (Mac/Windows)
{
  "insecure-registries": [
    "172.24.24.49:15000",
    "172.24.24.50:16000",
    "172.24.24.51:17000"
  ]
}

# Restart Docker Desktop (Mac) or systemctl restart docker (Linux)
```

### Step 5: Load Images on Each VM

**On VM1 (Herd):**
```bash
ssh root@stg-droveexeckraken001.phonepe.nb6

cd /root
gunzip kraken-herd.tar.gz
docker load -i kraken-herd.tar
docker images | grep kraken-herd
```

**On VM2 (Agent One):**
```bash
ssh root@stg-droveexeckraken002.phonepe.nb6

cd /root
gunzip kraken-agent.tar.gz
docker load -i kraken-agent.tar
docker images | grep kraken-agent
```

**On VM3 (Agent Two):**
```bash
ssh root@stg-droveexeckraken003.phonepe.nb6

cd /root
gunzip kraken-agent.tar.gz
docker load -i kraken-agent.tar
docker images | grep kraken-agent
```

### Step 6: Update Configuration Files

**IMPORTANT:** You need to update the configuration files on each VM to use the correct IP addresses for inter-VM communication.

**On VM1 (Herd) - Update all configs:**
```bash
cd /root/kraken-config/devcluster/config

# Get the IPs of all VMs
VM1_IP="172.24.24.49"  # Replace with actual IP
VM2_IP="172.24.24.67"  # Replace with actual IP
VM3_IP="172.24.24.140"  # Replace with actual IP

# Update all config files to use VM1 IP instead of host.docker.internal
find . -type f -name "*.yaml" -exec sed -i "s/host\.docker\.internal/$VM1_IP/g" {} \;

echo "VM1 configs updated to use IP: $VM1_IP"
```

**On VM2 (Agent One) - Update agent config:**
```bash
cd /root/kraken-config/devcluster/config

VM1_IP="172.24.24.49"  # Herd IP
VM2_IP="172.24.24.67"  # This VM's IP

# Update agent config to point to herd services on VM1
sed -i "s/host\.docker\.internal/$VM1_IP/g" agent/development.yaml

echo "VM2 agent config updated to use Herd IP: $VM1_IP"
```

**On VM3 (Agent Two) - Update agent config:**
```bash
cd /root/kraken-config/devcluster/config

VM1_IP="172.24.24.49"  # Herd IP
VM3_IP="172.24.24.140"  # This VM's IP

# Update agent config to point to herd services on VM1
sed -i "s/host\.docker\.internal/$VM1_IP/g" agent/development.yaml

echo "VM3 agent config updated to use Herd IP: $VM1_IP"
```

## Phase 4: Create Startup Scripts

### Step 7: Create Herd Startup Script on VM1

**On VM1 (stg-droveexeckraken001.phonepe.nb6):**

```bash
cat > /root/kraken-config/devcluster/vm1_herd_start.sh << 'EOF'
#!/bin/bash

# Stop any existing containers
docker rm -f kraken-herd 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source parameters
source ./herd_param.sh

# Get this VM's IP
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Herd on VM1"
echo "VM IP: $VM_IP"
echo "========================================="
echo "Ports:"
echo "  TestFS:      $TESTFS_PORT"
echo "  Origin:      $ORIGIN_SERVER_PORT (peer: $ORIGIN_PEER_PORT)"
echo "  Tracker:     $TRACKER_PORT"
echo "  Build-Index: $BUILD_INDEX_PORT"
echo "  Proxy:       $PROXY_PORT (server: 15005)"
echo "========================================="

# Start kraken herd with network=host
docker run -d \
    --name kraken-herd \
    --network host \
    --restart unless-stopped \
    -e VM_IP="$VM_IP" \
    -v "$(pwd)/config/origin/development.yaml":/etc/kraken/config/origin/development.yaml \
    -v "$(pwd)/config/tracker/development.yaml":/etc/kraken/config/tracker/development.yaml \
    -v "$(pwd)/config/build-index/development.yaml":/etc/kraken/config/build-index/development.yaml \
    -v "$(pwd)/config/proxy/development.yaml":/etc/kraken/config/proxy/development.yaml \
    -v "$(pwd)/herd_param.sh":/etc/kraken/herd_param.sh \
    -v "$(pwd)/herd_start_processes.sh":/etc/kraken/herd_start_processes.sh:ro \
    kraken-herd:dev bash -c 'cp /etc/kraken/herd_start_processes.sh /tmp/herd_start.sh && sed -i "s/--peer-ip=\${HOSTNAME}/--peer-ip=$VM_IP/g" /tmp/herd_start.sh && sed -i "s/--blobserver-hostname=\${HOSTNAME}/--blobserver-hostname=$VM_IP/g" /tmp/herd_start.sh && chmod +x /tmp/herd_start.sh && /tmp/herd_start.sh'

echo ""
echo "Waiting for services to start..."
sleep 8

echo ""
echo "Checking herd container status:"
docker ps --filter name=kraken-herd

echo ""
echo "Recent herd logs:"
docker logs kraken-herd | tail -30

echo ""
echo "========================================="
echo "Herd startup complete!"
echo "========================================="
EOF

chmod +x /root/kraken-config/devcluster/vm1_herd_start.sh
```

### Step 8: Create Agent One Startup Script on VM2

**On VM2 (stg-droveexeckraken002.phonepe.nb6):**

```bash
cat > /root/kraken-config/devcluster/vm2_agent_one_start.sh << 'EOF'
#!/bin/bash

# Stop any existing containers
docker rm -f kraken-agent-one 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source parameters
source ./agent_one_param.sh

# Get this VM's IP
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Agent One on VM2"
echo "VM IP: $VM_IP"
echo "========================================="
echo "Ports:"
echo "  Registry: $AGENT_REGISTRY_PORT"
echo "  Peer:     $AGENT_PEER_PORT"
echo "  Server:   $AGENT_SERVER_PORT"
echo "========================================="

# Start agent one with network=host
docker run -d \
    --name kraken-agent-one \
    --network host \
    --restart unless-stopped \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_one_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

echo ""
echo "Waiting for agent to start..."
sleep 5

echo ""
echo "Checking agent container status:"
docker ps --filter name=kraken-agent-one

echo ""
echo "Recent agent logs:"
docker logs kraken-agent-one | tail -20

echo ""
echo "========================================="
echo "Agent One startup complete!"
echo "Pull images from: $VM_IP:$AGENT_REGISTRY_PORT"
echo "========================================="
EOF

chmod +x /root/kraken-config/devcluster/vm2_agent_one_start.sh
```

### Step 9: Create Agent Two Startup Script on VM3

**On VM3 (stg-droveexeckraken003.phonepe.nb6):**

```bash
cat > /root/kraken-config/devcluster/vm3_agent_two_start.sh << 'EOF'
#!/bin/bash

# Stop any existing containers
docker rm -f kraken-agent-two 2>/dev/null || true

# Get script directory and navigate to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source parameters
source ./agent_two_param.sh

# Get this VM's IP
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Agent Two on VM3"
echo "VM IP: $VM_IP"
echo "========================================="
echo "Ports:"
echo "  Registry: $AGENT_REGISTRY_PORT"
echo "  Peer:     $AGENT_PEER_PORT"
echo "  Server:   $AGENT_SERVER_PORT"
echo "========================================="

# Start agent two with network=host
docker run -d \
    --name kraken-agent-two \
    --network host \
    --restart unless-stopped \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_two_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

echo ""
echo "Waiting for agent to start..."
sleep 5

echo ""
echo "Checking agent container status:"
docker ps --filter name=kraken-agent-two

echo ""
echo "Recent agent logs:"
docker logs kraken-agent-two | tail -20

echo ""
echo "========================================="
echo "Agent Two startup complete!"
echo "Pull images from: $VM_IP:$AGENT_REGISTRY_PORT"
echo "========================================="
EOF

chmod +x /root/kraken-config/devcluster/vm3_agent_two_start.sh
```

## Phase 5: Deploy the Cluster

### Step 10: Start Services in Order

**IMPORTANT:** Start services in this order to ensure dependencies are met.

#### 1. Start Herd on VM1

```bash
# On VM1
ssh root@stg-droveexeckraken001.phonepe.nb6
/root/kraken-config/devcluster/vm1_herd_start.sh
```

**Verify Herd is Running:**
```bash
# Check container
docker ps --filter name=kraken-herd

# Check logs
docker logs kraken-herd | tail -50

# Test endpoints
curl http://localhost:15000/v2/     # Proxy
curl http://localhost:14000/health  # TestFS
curl http://localhost:15002/health  # Origin
curl http://localhost:15003/health  # Tracker
curl http://localhost:15004/health  # Build-Index
```

#### 2. Start Agent One on VM2

```bash
# On VM2
ssh root@stg-droveexeckraken002.phonepe.nb6
/root/kraken-config/devcluster/vm2_agent_one_start.sh
```

**Verify Agent One is Running:**
```bash
# Check container
docker ps --filter name=kraken-agent-one

# Check logs
docker logs kraken-agent-one | tail -30

# Test endpoint
curl http://localhost:16000/v2/
```

#### 3. Start Agent Two on VM3

```bash
# On VM3
ssh root@stg-droveexeckraken003.phonepe.nb6
/root/kraken-config/devcluster/vm3_agent_two_start.sh
```

**Verify Agent Two is Running:**
```bash
# Check container
docker ps --filter name=kraken-agent-two

# Check logs
docker logs kraken-agent-two | tail -30

# Test endpoint
curl http://localhost:17000/v2/
```

## Phase 6: Testing the Cluster

### Step 11: Push a Test Image

**From VM1 or any machine with network access to VM1:**

```bash
# Pull a test image
docker pull hello-world

# Tag for Kraken (use VM1's IP or hostname)
docker tag hello-world 172.24.24.49:15000/test/hello-world:latest

# Push to Kraken
docker push 172.24.24.49:15000/test/hello-world:latest
```

### Step 12: Pull from Agent One (VM2)

**From VM2 or any machine with network access to VM2:**

```bash
# Remove local image to force download
docker rmi hello-world 172.24.24.49:15000/test/hello-world:latest 2>/dev/null || true

# Pull from Agent One
docker pull 172.24.24.50:16000/test/hello-world:latest

# Verify
docker images | grep hello-world
```

### Step 13: Pull from Agent Two (VM3)

**From VM3 or any machine with network access to VM3:**

```bash
# Remove local image to force download
docker rmi hello-world 172.24.24.50:16000/test/hello-world:latest 2>/dev/null || true

# Pull from Agent Two
docker pull 172.24.24.51:17000/test/hello-world:latest

# Verify
docker images | grep hello-world
```

### Step 14: Test P2P Distribution

**Test with a larger image to see P2P in action:**

```bash
# On VM1 - Push nginx image
docker pull nginx:latest
docker tag nginx:latest 172.24.24.49:15000/test/nginx:latest
docker push 172.24.24.49:15000/test/nginx:latest

# On VM2 and VM3 simultaneously - Pull from both agents
# VM2:
docker pull 172.24.24.50:16000/test/nginx:latest

# VM3:
docker pull 172.24.24.51:17000/test/nginx:latest

# Check P2P transfer logs
# On VM2:
docker logs kraken-agent-one | grep -i "peer\|transfer" | tail -30

# On VM3:
docker logs kraken-agent-two | grep -i "peer\|transfer" | tail -30
```

## Phase 7: Monitoring and Management

### Health Check Script

Create a health check script to verify all services:

```bash
cat > /root/check_kraken_cluster.sh << 'EOF'
#!/bin/bash

VM1_IP="172.24.24.49"
VM2_IP="172.24.24.50"
VM3_IP="172.24.24.51"

echo "========================================="
echo "Kraken Cluster Health Check"
echo "========================================="
echo ""

echo "VM1 - Herd Services:"
echo "  Proxy:       $(curl -s http://$VM1_IP:15000/v2/ && echo '✓ OK' || echo '✗ FAIL')"
echo "  TestFS:      $(curl -s http://$VM1_IP:14000/health && echo '✓ OK' || echo '✗ FAIL')"
echo "  Origin:      $(curl -s http://$VM1_IP:15002/health && echo '✓ OK' || echo '✗ FAIL')"
echo "  Tracker:     $(curl -s http://$VM1_IP:15003/health && echo '✓ OK' || echo '✗ FAIL')"
echo "  Build-Index: $(curl -s http://$VM1_IP:15004/health && echo '✓ OK' || echo '✗ FAIL')"
echo ""

echo "VM2 - Agent One:"
echo "  Registry:    $(curl -s http://$VM2_IP:16000/v2/ && echo '✓ OK' || echo '✗ FAIL')"
echo ""

echo "VM3 - Agent Two:"
echo "  Registry:    $(curl -s http://$VM3_IP:17000/v2/ && echo '✓ OK' || echo '✗ FAIL')"
echo ""

echo "========================================="
EOF

chmod +x /root/check_kraken_cluster.sh
```

Run the health check:
```bash
/root/check_kraken_cluster.sh
```

### Stop Scripts

**On VM1:**
```bash
cat > /root/kraken-config/devcluster/vm1_stop.sh << 'EOF'
#!/bin/bash
echo "Stopping Kraken Herd on VM1..."
docker rm -f kraken-herd 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm1_stop.sh
```

**On VM2:**
```bash
cat > /root/kraken-config/devcluster/vm2_stop.sh << 'EOF'
#!/bin/bash
echo "Stopping Kraken Agent One on VM2..."
docker rm -f kraken-agent-one 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm2_stop.sh
```

**On VM3:**
```bash
cat > /root/kraken-config/devcluster/vm3_stop.sh << 'EOF'
#!/bin/bash
echo "Stopping Kraken Agent Two on VM3..."
docker rm -f kraken-agent-two 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm3_stop.sh
```

## Troubleshooting

### Issue 1: Agents Can't Connect to Herd

**Symptom:** Agents fail to start or can't find tracker/origin.

**Solution:**
1. Verify network connectivity between VMs:
   ```bash
   # From VM2/VM3
   ping -c 3 172.24.24.49
   telnet 172.24.24.49 15003  # Tracker port
   ```

2. Check firewall rules on VM1:
   ```bash
   # On VM1
   sudo firewall-cmd --list-all
   # Ensure ports 14000-15005 are open
   ```

3. Verify config files have correct VM1 IP:
   ```bash
   # On VM2/VM3
   cat /root/kraken-config/devcluster/config/agent/development.yaml | grep -i "host\|addr"
   ```

### Issue 2: P2P Not Working

**Symptom:** Agents download directly from origin instead of from each other.

**Solution:**
1. Verify agents are registered with tracker:
   ```bash
   # On VM1, check tracker logs
   docker logs kraken-herd | grep -i "agent\|peer" | tail -50
   ```

2. Ensure peer ports are accessible:
   ```bash
   # From VM3, test VM2's peer port
   telnet 172.24.24.50 16001
   ```

3. Check agent peer IPs are set correctly:
   ```bash
   # On VM2/VM3
   docker logs kraken-agent-one | grep -i "peer\|announce"
   ```

### Issue 3: "Error getting local ip"

**Symptom:** Services fail with "Error getting local ip: no ip found"

**Solution:**
This should be fixed by the `--peer-ip` flags in the startup scripts. If it still occurs:

1. Verify the VM_IP is correctly detected:
   ```bash
   hostname -I | awk '{print $1}'
   ```

2. Manually set the IP in the startup script if needed.

### Issue 4: Port Conflicts

**Symptom:** "Address already in use" errors.

**Solution:**
```bash
# Find what's using the port
netstat -tuln | grep <port>
lsof -i :<port>

# Stop conflicting service or change port in param.sh files
```

## Advanced Configuration

### Persistent Storage

To persist data across container restarts:

```bash
# On VM1
mkdir -p /var/kraken/data/{testfs,cache,logs}

# Update vm1_herd_start.sh to add volume mounts:
# -v /var/kraken/data/testfs:/data \
# -v /var/kraken/data/cache:/var/cache/kraken \
# -v /var/kraken/data/logs:/var/log/kraken \
```

### Resource Limits

Add resource limits to prevent runaway containers:

```bash
# In startup scripts, add to docker run:
--memory="2g" \
--cpus="2.0" \
--memory-swap="2g" \
```

### TLS/Security

For production, enable TLS on all endpoints. Update configs with:
- Certificate paths
- TLS flags in command-line arguments
- Updated health check URLs (https://)

## Summary

You now have a **3-VM distributed Kraken cluster**:

✅ **VM1** - Central herd services (push endpoint)  
✅ **VM2** - Agent One (pull endpoint + P2P)  
✅ **VM3** - Agent Two (pull endpoint + P2P)  
✅ Full P2P distribution between agents  
✅ Health monitoring and management scripts  
✅ Automated startup/shutdown procedures  

### Quick Reference

**Start Cluster:**
```bash
# VM1
ssh root@stg-droveexeckraken001.phonepe.nb6 "/root/kraken-config/devcluster/vm1_herd_start.sh"

# VM2
ssh root@stg-droveexeckraken002.phonepe.nb6 "/root/kraken-config/devcluster/vm2_agent_one_start.sh"

# VM3
ssh root@stg-droveexeckraken003.phonepe.nb6 "/root/kraken-config/devcluster/vm3_agent_two_start.sh"
```

**Stop Cluster:**
```bash
# VM1
ssh root@stg-droveexeckraken001.phonepe.nb6 "/root/kraken-config/devcluster/vm1_stop.sh"

# VM2
ssh root@stg-droveexeckraken002.phonepe.nb6 "/root/kraken-config/devcluster/vm2_stop.sh"

# VM3
ssh root@stg-droveexeckraken003.phonepe.nb6 "/root/kraken-config/devcluster/vm3_stop.sh"
```

**Test:**
```bash
# Push to VM1
docker push 172.24.24.49:15000/test/myimage:latest

# Pull from VM2
docker pull 172.24.24.50:16000/test/myimage:latest

# Pull from VM3
docker pull 172.24.24.51:17000/test/myimage:latest
```

For production deployment, refer to [CONFIGURATION.md](docs/CONFIGURATION.md) for advanced options.
