# Kraken Multi-Host Deployment

This setup deploys Kraken's P2P Docker registry across multiple hosts using BitTorrent-like distribution for efficient image delivery.

## Architecture

**Components:**
- **Herd**: Centralized services cluster (proxy, origin, tracker, build-index, testfs)
- **Agents**: Distributed P2P nodes, one per host, all using port 16000

```
Host 1 (Herd): 10.0.1.100
├── Proxy: :15000 (Docker registry API, push endpoint)
├── Origin: :15002 (Blob storage backend) + :15001 (P2P seeding)
├── Tracker: :15003 (P2P peer discovery and coordination)
├── Build Index: :15004 (Tag-to-blob mapping service)
├── TestFS: :14000 (File storage backend)
└── Redis: :14001 (Metadata cache)

Host 2 (Agent): 10.0.1.101:16000 (Docker registry API + P2P client)
Host 3 (Agent): 10.0.1.102:16000 (Docker registry API + P2P client)
Host 4 (Agent): 10.0.1.103:16000 (Docker registry API + P2P client)
```

**P2P Flow:**
1. Images pushed to herd proxy (:15000) are stored in origin (:15002)
2. Origin creates torrents and announces to tracker (:15003)
3. Agents query tracker for peers when pulling images
4. Agents download directly from origin and other agents via BitTorrent protocol
5. Subsequent pulls leverage P2P distribution between agents

## Quick Start

### Prerequisites
- Docker and Docker Compose installed on all hosts
- Network connectivity between herd and agent hosts on required ports
- Git repository cloned on herd host for building images

## On-Premise VM Setup

### VM Environment Preparation
If you're deploying Kraken on on-premise VMs with limited internet access or package repository issues, follow these steps to prepare your environment:

#### 1. Manual Dependency Installation (REQUIRED)
Since all apt-get commands have been removed from Dockerfiles due to repository access issues, ALL dependencies must be pre-installed on the host VM:

```bash
# Update package list (if possible)
sudo apt-get update || echo "Package update failed - proceeding with manual installation"

# Install ALL required dependencies for Kraken services
sudo apt-get install -y \
    curl \
    nginx \
    sqlite3 \
    build-essential \
    sudo \
    procps \
    gettext-base \
    redis-server \
    make \
    gcc \
    libc6-dev || echo "Some packages may need manual installation"

# Alternative: Install packages individually if batch installation fails
sudo apt-get install -y curl
sudo apt-get install -y nginx  
sudo apt-get install -y sqlite3
sudo apt-get install -y build-essential
sudo apt-get install -y sudo
sudo apt-get install -y procps
sudo apt-get install -y gettext-base
sudo apt-get install -y redis-server
sudo apt-get install -y make gcc libc6-dev

# Verify all installations
which curl nginx sqlite3 redis-server envsubst make gcc
```

#### 2. Create Custom Ubuntu Base Image with Dependencies (Alternative Approach)
If installing packages on host VM is not suitable, create a custom base image:

```bash
# Create a Dockerfile for custom base image
cat > Dockerfile.base << 'EOF'
FROM docker.phonepe.com/ubuntu

ENV DEBIAN_FRONTEND=noninteractive

# Install all required dependencies in base image
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    nginx \
    sqlite3 \
    build-essential \
    sudo \
    procps \
    gettext-base \
    redis-server \
    make \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean
EOF

# Build custom base image
docker build -f Dockerfile.base -t phonepe-ubuntu-kraken:latest .

# Update all Kraken Dockerfiles to use this base image instead of docker.phonepe.com/ubuntu
find docker/ -name "Dockerfile" -exec sed -i 's|FROM docker.phonepe.com/ubuntu|FROM phonepe-ubuntu-kraken:latest|g' {} \;
```

#### 2. Docker Permission Setup
```bash
# Add current user to docker group
sudo usermod -aG docker $USER

# Apply group membership
newgrp docker

# Verify Docker access
docker ps
docker version
```

#### 3. PhonePe Docker Registry Configuration
```bash
# Configure Docker to use PhonePe internal registry
sudo mkdir -p /etc/docker
sudo cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["https://docker.phonepe.com"],
  "insecure-registries": ["docker.phonepe.com"]
}
EOF

# Restart Docker daemon
sudo systemctl restart docker
sudo systemctl status docker
```

#### 4. Directory and Permission Setup
```bash
# Create required directories with proper permissions
sudo mkdir -p /var/log/kraken
sudo mkdir -p /var/cache/kraken
sudo mkdir -p /var/run/kraken
sudo chmod -R 777 /var/log/kraken
sudo chmod -R 777 /var/cache/kraken
sudo chmod -R 777 /var/run/kraken

# Verify directories
ls -la /var/log/ | grep kraken
ls -la /var/cache/ | grep kraken
ls -la /var/run/ | grep kraken
```

#### 5. Network and Firewall Configuration
```bash
# Configure firewall for Kraken ports
sudo ufw allow 14000:15005/tcp  # Herd ports
sudo ufw allow 16000:16002/tcp  # Agent ports

# Verify port availability
sudo netstat -tlnp | grep -E "14000|15000|16000"

# Test network connectivity between VMs (replace with actual IPs)
# From agent VMs to herd VM:
telnet <HERD_VM_IP> 15000
telnet <HERD_VM_IP> 15003
```

#### 6. Verification Checklist
```bash
# ✓ Dependencies installed
which curl nginx sqlite3

# ✓ Docker working
docker ps
docker images

# ✓ PhonePe registry accessible
docker pull docker.phonepe.com/ubuntu || echo "Check registry access"

# ✓ Directories created
ls -la /var/log/kraken /var/cache/kraken /var/run/kraken

# ✓ Firewall configured
sudo ufw status | grep -E "14000|15000|16000"

# ✓ Network connectivity (from agent to herd)
ping <HERD_VM_IP>
telnet <HERD_VM_IP> 15000
```

### 1. Build Images (on herd host)
```bash
# Clone repository and build Kraken images
git clone <kraken-repo-url>
cd kraken
make images

# Verify images are built
docker images | grep kraken
```

### 2. Deploy Herd (Central Services Host)
```bash
# Navigate to multihost directory
cd examples/multihost

# Make scripts executable
chmod +x scripts/*.sh test/*.sh

# Deploy herd with proper hostname resolution
# CRITICAL: Use external IP/hostname that agents can reach
./scripts/deploy_herd.sh 10.0.1.100

# For local testing, use host.docker.internal for container networking
./scripts/deploy_herd.sh host.docker.internal
```

**Note:** The herd hostname must be reachable from agent containers. Using `localhost` will cause P2P connection failures.

### 3. Deploy Agents (Worker Hosts)
```bash
# Copy multihost directory to agent hosts or use shared filesystem
scp -r examples/multihost/ user@10.0.1.101:/path/to/kraken/

# On each agent host
cd examples/multihost
chmod +x scripts/*.sh test/*.sh

# Deploy agent with herd and agent IPs
./scripts/deploy_agent.sh <HERD_IP> <AGENT_IP>

# Examples:
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.101  # Agent host 1
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.102  # Agent host 2
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.103  # Agent host 3
```

### 4. Verify Deployment
```bash
# Check herd services are running
curl http://10.0.1.100:15000/v2/        # Proxy (should return {})
curl http://10.0.1.100:15003/health      # Tracker (should return OK)
curl http://10.0.1.100:14000/            # TestFS (404 is normal)

# Check agent services
curl http://10.0.1.101:16000/v2/         # Agent 1
curl http://10.0.1.102:16000/v2/         # Agent 2
curl http://10.0.1.103:16000/v2/         # Agent 3

# Verify container status
docker ps | grep kraken                  # Should show running containers
```

### 5. Test P2P Distribution
```bash
# Push test image to herd
docker pull hello-world
docker tag hello-world 10.0.1.100:15000/test/hello-world:latest
docker push 10.0.1.100:15000/test/hello-world:latest

# Pull from agents using P2P
./test/kraken-pull.sh test/hello-world:latest 10.0.1.101:16000
./test/kraken-pull.sh test/hello-world:latest 10.0.1.102:16000
./test/kraken-pull.sh test/hello-world:latest 10.0.1.103:16000

# Run comprehensive test
./test/test_multihost.sh 10.0.1.100 10.0.1.101
```

## Usage Examples

### Local Testing (Single Machine)
```bash
# Deploy herd with container networking hostname
./scripts/deploy_herd.sh host.docker.internal

# Deploy local agent (simulating remote host)
./scripts/deploy_agent.sh host.docker.internal localhost

# Verify services
curl http://localhost:15000/v2/     # Herd proxy
curl http://localhost:16000/v2/     # Agent

# Run automated test
./test/test_multihost.sh localhost localhost

# Expected output:
# ✓ Push to herd succeeds
# ✓ Agent pulls via P2P (no timeout)
# ✓ Image verification passes
```

### Production Multi-Host Deployment
```bash
# 1. Deploy herd on central server
./scripts/deploy_herd.sh 10.0.1.100

# 2. Deploy agents on worker hosts
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.101
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.102
./scripts/deploy_agent.sh 10.0.1.100 10.0.1.103

# 3. Push from CI/CD system
docker build -t myapp:v1.0 .
docker tag myapp:v1.0 10.0.1.100:15000/company/myapp:v1.0
docker push 10.0.1.100:15000/company/myapp:v1.0

# 4. Pull on worker hosts (leverages P2P)
# First pull: Downloads from origin, seeds to tracker
./test/kraken-pull.sh company/myapp:v1.0 10.0.1.101:16000

# Subsequent pulls: P2P distribution between agents
./test/kraken-pull.sh company/myapp:v1.0 10.0.1.102:16000
./test/kraken-pull.sh company/myapp:v1.0 10.0.1.103:16000

# 5. Verify P2P efficiency
docker logs kraken-agent-$(hostname) | grep -E "torrent|conn|complete"
```

### Container Runtime Integration
```bash
# Configure Docker daemon to use Kraken agents
# /etc/docker/daemon.json
{
  "registry-mirrors": [
    "http://10.0.1.101:16000",
    "http://10.0.1.102:16000",
    "http://10.0.1.103:16000"
  ]
}

# Restart Docker daemon
sudo systemctl restart docker

# Regular docker pull now uses Kraken P2P
docker pull company/myapp:v1.0
```

## Technical Details

### Port Configuration
```
Herd Ports:
- 14000: TestFS (file storage backend)
- 14001: Redis (metadata cache)
- 15000: Proxy (Docker registry API, push endpoint)
- 15001: Origin P2P (BitTorrent seeding)
- 15002: Origin Server (blob storage API)
- 15003: Tracker (P2P peer discovery)
- 15004: Build Index (tag-to-blob mapping)
- 15005: Proxy Server (internal)

Agent Ports:
- 16000: Registry API (Docker pull endpoint)
- 16001: P2P Client (BitTorrent protocol)
- 16002: Agent Server (internal management)
```

### Container Networking
- **Critical**: Herd must be deployed with externally reachable hostname
- Origin announces itself to tracker with `--peer-ip=${HERD_HOST_IP}`
- Agent containers resolve herd via `host.docker.internal` (local) or IP (remote)
- P2P connections fail if agents can't reach announced peer addresses

### Configuration Files
- `config/agent/multihost.yaml`: Agent runtime configuration
- `config/origin/multihost.yaml`: Origin storage and P2P settings
- `config/tracker/multihost.yaml`: Tracker coordination settings
- `config/proxy/multihost.yaml`: Registry API proxy configuration
- `config/build-index/multihost.yaml`: Tag indexing service

### Environment Variables
```bash
# Required for herd deployment
HERD_HOST_IP=<externally_reachable_hostname>  # Used for P2P announcements
HOSTNAME=<container_hostname>                 # Internal container name

# Required for agent deployment  
AGENT_HOST_IP=<agent_machine_ip>              # Agent's external IP
HERD_HOST_IP=<herd_machine_ip>                # Herd's external IP

# Optional
HERD_HOST=<fallback_endpoint>                 # Default: localhost:15000
```

## Key Features

1. **BitTorrent-Based Distribution**: Leverages peer-to-peer protocol for efficient image distribution
2. **Centralized Coordination**: Herd provides tracker for peer discovery and blob storage
3. **Automatic Fallback**: Falls back to herd if P2P fails or times out
4. **Docker Registry Compatibility**: Drop-in replacement for Docker registry
5. **Horizontal Scaling**: Add more agents to increase P2P efficiency
6. **Network Efficiency**: Reduces bandwidth usage by 50-90% after initial seeding
7. **Image Normalization**: Consistent image naming across agents

## Best Practices

### Deployment
- Use external IP addresses, not `localhost`, for multi-host deployments
- Deploy herd on high-bandwidth, central location
- Place agents close to container workloads
- Use persistent storage for herd, ephemeral for agents

### Configuration
- Set appropriate cache TTLs based on image update frequency
- Configure cleanup policies to manage disk usage
- Monitor agent cache hit ratios
- Use health checks in production deployments

### Monitoring
```bash
# Essential metrics to track
docker logs kraken-herd-multihost | grep -c "push"     # Push count
docker logs kraken-agent-* | grep -c "Torrent complete" # P2P success rate
docker stats kraken-* --no-stream                      # Resource usage
```

### Production Checklist
- [ ] Firewall rules configured for all Kraken ports
- [ ] Persistent volumes mounted for herd storage
- [ ] Health checks configured for all services
- [ ] Log aggregation setup for monitoring
- [ ] Backup strategy for herd configuration and data
- [ ] Network connectivity tested between all hosts
- [ ] Container restart policies configured
- [ ] Resource limits set appropriately

## File Structure

```
examples/multihost/
├── README.md
├── herd_param.sh                  # Herd configuration parameters
├── agent_param.sh                 # Agent configuration parameters
├── herd_start_processes.sh        # Herd startup script
├── herd_start_container.sh        # Herd container launcher
├── agent_start_container.sh       # Agent container launcher
├── config/
│   ├── agent/multihost.yaml       # Agent configuration
│   ├── origin/multihost.yaml      # Origin configuration
│   ├── tracker/multihost.yaml     # Tracker configuration
│   ├── build-index/multihost.yaml # Build index configuration
│   └── proxy/multihost.yaml       # Proxy configuration
├── scripts/
│   ├── deploy_herd.sh             # Deploy herd script
│   └── deploy_agent.sh            # Deploy agent script
└── test/
    ├── test_multihost.sh          # Multi-host test script
    └── kraken-pull.sh             # Image pull with normalization
```

## Environment Variables Reference

| Variable | Component | Purpose | Example |
|----------|-----------|---------|---------|
| `HERD_HOST_IP` | Herd | External IP for P2P announcements | `10.0.1.100` |
| `HOSTNAME` | Herd | Container internal hostname | `host.docker.internal` |
| `AGENT_HOST_IP` | Agent | Agent's external IP address | `10.0.1.101` |
| `HERD_HOST` | kraken-pull.sh | Fallback herd endpoint | `localhost:15000` |
| `BIND_ADDRESS` | Both | Network interface binding | `0.0.0.0` |

## Performance Considerations

### Scaling Guidelines
- **Herd**: Single instance per cluster (handles all pushes)
- **Agents**: One per worker host (handles pulls for that host)
- **Tracker**: Can handle 1000+ concurrent peer connections
- **P2P**: Efficiency increases with more agents (more peers)

### Network Requirements
- **Bandwidth**: P2P reduces herd egress by 50-90% after first pull
- **Latency**: Sub-100ms recommended between agents for optimal P2P
- **Firewall**: All Kraken ports must be accessible between herd and agents

### Storage Requirements
```bash
# Herd storage (persistent)
/var/cache/kraken/origin/     # Original images
/var/cache/kraken/proxy/      # Registry cache

# Agent storage (can be ephemeral)
/var/cache/kraken/agent/download/  # Active downloads
/var/cache/kraken/agent/cache/     # P2P cache
```

## Security Considerations

### Network Security
- Deploy in trusted network environment
- Use firewall rules to restrict access to Kraken ports
- Consider TLS termination at load balancer level

### Access Control
- Kraken operates in trusted mode (no authentication by default)
- Implement authentication at proxy layer if needed
- Use network segmentation for production deployments

### Container Security
```bash
# Run containers with minimal privileges
docker run --user 1000:1000 --read-only --tmpfs /tmp ...

# Use security profiles
docker run --security-opt seccomp=kraken-seccomp.json ...
```

## Clean Up Procedures

### Complete Cleanup
```bash
# Stop all Kraken containers
docker stop $(docker ps -q --filter "name=kraken")

# Remove containers
docker rm $(docker ps -aq --filter "name=kraken")

# Remove images (optional)
docker rmi $(docker images --filter "reference=kraken*" -q)

# Clean up volumes
docker volume prune -f
```

### Selective Cleanup
```bash
# Restart just the herd
docker stop kraken-herd-multihost && docker rm kraken-herd-multihost
./scripts/deploy_herd.sh <HERD_IP>

# Restart specific agent
docker stop kraken-agent-$(hostname) && docker rm kraken-agent-$(hostname)
./scripts/deploy_agent.sh <HERD_IP> <AGENT_IP>
```

## Troubleshooting

### Build Issues

#### On-Premise VM Dependency Issues
**Symptoms:**
```bash
make images
# Build hangs or fails with connection timeouts:
# "Could not connect to archive.ubuntu.com:80"
# "Unable to locate package redis-server"

# OR container runtime errors:
docker logs kraken-herd-multihost
./herd_start_processes.sh: line 5: redis-server: command not found
./herd_start_processes.sh: line 14: envsubst: command not found
```

**Root Cause:** 
- Ubuntu package repositories not accessible from VM environment
- Connection timeouts to archive.ubuntu.com and security.ubuntu.com
- Air-gapped or restricted network environment

**Solutions:**

**Option 1: Use the smart build script (Recommended)**
```bash
# Use the provided smart build script that auto-detects your environment
chmod +x build-kraken.sh
./build-kraken.sh

# This script will:
# - Test if external images are accessible
# - Use multi-stage build with Redis image if possible
# - Fall back to shell script replacements if needed
# - Provide manual setup instructions if build fails
```

**Option 2: Manual build with Redis from external image**
```bash
# If you can access docker hub but not Ubuntu repos:
docker pull redis:6-alpine  # Test if this works

# If successful, build with the updated Dockerfile:
make clean
make images

# The herd Dockerfile now uses Redis binary from official image
# and creates shell script replacements for envsubst
```

**Option 3: Complete fallback approach**
```bash
# If no external images are accessible:
docker build -f docker/herd/Dockerfile.fallback -t kraken-herd:dev ./

# This creates shell script replacements for all missing tools
# Test the container:
docker run --rm kraken-herd:dev which redis-server envsubst
```

**Option 4: Host tool mounting (if tools available on host)**
```bash
# Install tools on host if possible:
sudo apt-get install -y redis-server gettext-base curl

# Verify they exist:
which redis-server envsubst curl

# Run container with mounted tools:
docker run -d --name kraken-herd-multihost \
    -v /usr/bin/redis-server:/usr/bin/redis-server:ro \
    -v /usr/bin/envsubst:/usr/bin/envsubst:ro \
    -v /usr/bin/curl:/usr/bin/curl:ro \
    -p 14000-15005:14000-15005 \
    -e HERD_HOST_IP=host.docker.internal \
    -e HOSTNAME=host.docker.internal \
    kraken-herd:dev
```

**Current Solution Strategy:**
- **Herd container**: Uses Redis binary from official image + shell script replacements
- **Other containers**: Minimal dependencies, expect tools in base image
- **No apt-get**: All package installations removed to avoid network issues

**Verification:**
```bash
# Test if build succeeds without network calls:
time ./build-kraken.sh  # Should complete quickly

# Test essential tools in container:
docker run --rm kraken-herd:dev sh -c "redis-server --version; envsubst --help"

# Test container startup:
docker logs kraken-herd-multihost  # Should not show missing command errors
```

#### Docker Permission Denied Error
**Symptoms:**
```bash
make images
permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
make: *** [Makefile:81: images] Error 1
```

**Root Cause:** Current user doesn't have permission to access Docker daemon socket.

**Solutions:**

**Option 1: Add user to docker group (Recommended)**
```bash
# Add current user to docker group
sudo usermod -aG docker $USER

# Apply group membership (requires logout/login or new shell)
newgrp docker

# Verify docker access
docker ps
docker info

# Now build Kraken images
make images
```

**Option 2: Use sudo for Docker commands**
```bash
# Build with sudo
sudo make images

# Alternative: Run docker commands with sudo
sudo docker build -t kraken-agent:dev -f docker/agent/Dockerfile ./
```

**Option 3: Fix Docker socket permissions (Temporary)**
```bash
# Make docker socket accessible (temporary fix)
sudo chmod 666 /var/run/docker.sock

# Build images
make images

# Note: This permission change is lost on Docker daemon restart
```

**Option 4: Configure Docker daemon for current user**
```bash
# Start Docker daemon in user mode (if using Docker Desktop)
# Or ensure Docker service is running with proper permissions
sudo systemctl restart docker

# Verify Docker is running
sudo systemctl status docker
```

**Verification:**
```bash
# Test Docker access without sudo
docker version
docker ps
docker info

# Should work without permission errors
```

#### Docker Registry Access Error (Production Environment)
**Symptoms:**
```bash
Sending build context to Docker daemon 143.8MB
Step 1/18 : FROM debian:12
Get "https://registry-1.docker.io/v2/": Service Unavailable
make: *** [Makefile:81: images] Error 1
```

**Root Cause:** Production VM cannot access Docker Hub registry due to:
- Corporate firewall blocking external registries
- No internet access in production environment
- Proxy configuration issues

**Solutions:**

**Option 1: Configure Docker proxy (if corporate proxy available)**
```bash
# Create Docker systemd override directory
sudo mkdir -p /etc/systemd/system/docker.service.d

# Configure proxy for Docker daemon
sudo cat > /etc/systemd/system/docker.service.d/http-proxy.conf << 'EOF'
[Service]
Environment="HTTP_PROXY=http://proxy.company.com:8080"
Environment="HTTPS_PROXY=http://proxy.company.com:8080"
Environment="NO_PROXY=localhost,127.0.0.1,.company.com"
EOF

# Reload systemd and restart Docker
sudo systemctl daemon-reload
sudo systemctl restart docker

# Verify proxy configuration
docker info | grep -i proxy
```

**Option 2: Use corporate/internal registry**
```bash
# Configure Docker to use internal registry
sudo mkdir -p /etc/docker
sudo cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["https://docker.phonepe.com"],
  "insecure-registries": ["docker.phonepe.com"]
}
EOF

# Restart Docker
sudo systemctl restart docker

# Update Dockerfiles to use PhonePe registry for all base images
find docker/ -name "Dockerfile" -exec sed -i 's|FROM golang:1.14.15|FROM docker.phonepe.com/golang:1.14.15|g' {} \;
find docker/ -name "Dockerfile" -exec sed -i 's|FROM nginx:1.13|FROM docker.phonepe.com/nginx:1.13|g' {} \;
find docker/ -name "Dockerfile" -exec sed -i 's|FROM redis:5.0|FROM docker.phonepe.com/redis:5.0|g' {} \;

# Ubuntu base image is already updated to use docker.phonepe.com/ubuntu
```

**Option 3: Pre-pull and transfer base images (Air-gapped environment)**
```bash
# IMPORTANT: Ensure dependencies are pre-installed on target VMs
# Run this on target VMs first:
# sudo apt-get install -y curl nginx sqlite3 build-essential redis-server

# On a machine with internet access:
# 1. Pull all required base images
docker pull docker.phonepe.com/ubuntu
docker pull docker.phonepe.com/golang:1.14.15
docker pull docker.phonepe.com/nginx:1.13
docker pull docker.phonepe.com/redis:5.0

# 2. Save images to tar files
mkdir -p kraken-base-images
docker save docker.phonepe.com/ubuntu | gzip > kraken-base-images/ubuntu.tar.gz
docker save docker.phonepe.com/golang:1.14.15 | gzip > kraken-base-images/golang-1.14.15.tar.gz
docker save docker.phonepe.com/nginx:1.13 | gzip > kraken-base-images/nginx-1.13.tar.gz
docker save docker.phonepe.com/redis:5.0 | gzip > kraken-base-images/redis-5.0.tar.gz

# 3. Transfer to production VM (via USB, SCP, etc.)
scp -r kraken-base-images/ user@prod-vm:/tmp/

# On production VM:
# 4. Load the images
cd /tmp/kraken-base-images
docker load < ubuntu.tar.gz
docker load < golang-1.14.15.tar.gz
docker load < nginx-1.13.tar.gz
docker load < redis-5.0.tar.gz

# 5. Verify images are available
docker images

# 6. Now build Kraken images
cd /path/to/kraken
make images
```

**Option 4: Build images externally and transfer**
```bash
# On a machine with internet access:
# 1. Build all Kraken images
make images

# 2. Save Kraken images
docker save kraken-agent:dev | gzip > kraken-agent.tar.gz
docker save kraken-herd:dev | gzip > kraken-herd.tar.gz
docker save kraken-origin:dev | gzip > kraken-origin.tar.gz
docker save kraken-proxy:dev | gzip > kraken-proxy.tar.gz
docker save kraken-tracker:dev | gzip > kraken-tracker.tar.gz
docker save kraken-build-index:dev | gzip > kraken-build-index.tar.gz
docker save kraken-testfs:dev | gzip > kraken-testfs.tar.gz

# 3. Transfer to production VM
scp *.tar.gz user@prod-vm:/tmp/

# On production VM:
# 4. Load images
cd /tmp
docker load < kraken-agent.tar.gz
docker load < kraken-herd.tar.gz
docker load < kraken-origin.tar.gz
docker load < kraken-proxy.tar.gz
docker load < kraken-tracker.tar.gz
docker load < kraken-build-index.tar.gz
docker load < kraken-testfs.tar.gz

# 5. Verify images
docker images | grep kraken
```

**Verification:**
```bash
# Test Docker registry connectivity
docker pull hello-world  # Should work if properly configured

# Verify base images are available
docker images | grep -E "docker.phonepe.com"

# IMPORTANT: Verify dependencies are installed on host
which curl nginx sqlite3 || echo "Install missing dependencies"

# Test Kraken image builds
make images
```

### Common Issues

#### 1. P2P Connection Timeouts (504 Gateway Time-out)
**Symptoms:**
```
Error response from daemon: received unexpected HTTP status: 504 Gateway Time-out
Agent pull failed, falling back to herd
```

**Root Cause:** Agent cannot connect to origin's P2P port (15001)

**Diagnosis:**
```bash
# Check agent logs for connection errors
docker logs kraken-agent-$(hostname) | grep "connection refused\|localhost:15001"

# Expected error pattern:
# "dial tcp [::1]:15001: connect: connection refused"
# "addr": "localhost:15001"
```

**Solution:**
```bash
# 1. Verify herd environment variables
docker exec kraken-herd-multihost env | grep -E "HOST|HOSTNAME"
# Should show: HERD_HOST_IP=<external_ip>, not localhost

# 2. Restart herd with correct hostname
docker stop kraken-herd-multihost && docker rm kraken-herd-multihost
./scripts/deploy_herd.sh <EXTERNAL_IP>  # NOT localhost

# 3. Restart agents to pick up new tracker info
docker stop kraken-agent-$(hostname) && docker rm kraken-agent-$(hostname)
./scripts/deploy_agent.sh <HERD_IP> <AGENT_IP>
```

#### 2. Container Network Connectivity Issues
**Symptoms:**
```bash
curl: (7) Failed to connect to <herd_ip>:15003: Connection refused
```

**Diagnosis:**
```bash
# Check if containers are running
docker ps | grep kraken

# Check port bindings
docker port kraken-herd-multihost

# Test network connectivity
telnet <herd_ip> 15003
```

**Solution:**
```bash
# Verify firewall allows required ports
sudo ufw allow 14000:15005/tcp  # Herd ports
sudo ufw allow 16000:16002/tcp  # Agent ports

# Check Docker daemon is binding to correct interface
netstat -tlnp | grep -E "15000|15003|16000"
```

#### 3. Image Push/Pull Failures
**Symptoms:**
```
denied: requested access to the resource is denied
no basic auth credentials
```

**Solution:**
```bash
# Kraken doesn't require authentication by default
# Ensure using correct registry endpoint
docker push <herd_ip>:15000/namespace/image:tag    # Push to herd
docker pull <agent_ip>:16000/namespace/image:tag   # Pull from agent

# Check if registry is responding
curl http://<herd_ip>:15000/v2/
curl http://<agent_ip>:16000/v2/
```

#### 4. Container Startup Failures
**Symptoms:**
```bash
docker logs kraken-herd-multihost
# Shows missing dependencies or configuration errors
```

**Diagnosis:**
```bash
# Check container logs
docker logs kraken-herd-multihost
docker logs kraken-agent-$(hostname)

# Verify image build
docker images | grep kraken

# Check mounted configurations
docker exec kraken-herd-multihost ls -la /etc/kraken/config/
```

**Solution:**
```bash
# Rebuild images if corrupted
make clean && make images

# Verify configuration files exist
ls -la config/*/multihost.yaml

# Check script permissions
chmod +x scripts/*.sh test/*.sh
```

### Advanced Debugging

#### Monitor P2P Activity
```bash
# Watch agent P2P connections in real-time
docker logs -f kraken-agent-$(hostname) | grep -E "torrent|conn|peer"

# Expected successful flow:
# "Added new torrent"
# "Added pending conn"
# "Moved conn from pending to active"  
# "Torrent complete"
```

#### Check Tracker Status
```bash
# Query tracker for registered peers
curl http://<herd_ip>:15003/health

# Check tracker logs
docker logs kraken-herd-multihost | grep -i tracker

# Monitor peer announcements
docker exec kraken-herd-multihost ps aux | grep tracker
```

#### Performance Monitoring
```bash
# Monitor download speeds
docker logs kraken-agent-$(hostname) | grep -E "downloaded|speed|rate"

# Check disk usage
docker exec kraken-agent-$(hostname) df -h /var/cache/kraken/

# Monitor network connections
docker exec kraken-agent-$(hostname) netstat -an | grep -E "15001|16001"
```

### Service Status Verification
```bash
# Health check all services
curl http://<herd_ip>:15000/v2/     # Proxy (should return {})
curl http://<herd_ip>:15003/health  # Tracker (should return OK)
curl http://<herd_ip>:14000/        # TestFS (404 is normal)
curl http://<agent_ip>:16000/v2/    # Agent (should return {})

# Container status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep kraken

# Resource usage
docker stats $(docker ps --format "{{.Names}}" | grep kraken)
```
