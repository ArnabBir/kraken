# Kraken VM Deployment - Quick Start

This is a quick reference guide for deploying Kraken from your Mac (ARM64) to a Linux VM (x86_64).

## Prerequisites

- **Local Mac**: Docker Desktop, Go, Make
- **Remote VM**: Docker installed, SSH access
- **VM Details**: 
  - Hostname: `stg-droveexeckraken001`
  - Architecture: `x86_64`

## Option 1: Automated Deployment (Recommended)

### Step 1: Prepare Deployment Package

```bash
# On your local Mac
cd /path/to/kraken

# Set your VM details
export VM_HOST=stg-droveexeckraken001
export VM_USER=root

# Build and prepare everything
./scripts/prepare_vm_deployment.sh
```

This will:
- ✅ Clean old binaries
- ✅ Build x86_64 binaries using Docker
- ✅ Verify architecture is correct
- ✅ Build Docker images for linux/amd64
- ✅ Save and compress images
- ✅ Copy and update configuration files
- ✅ Create deployment scripts

Output location: `./vm-deployment/`

### Step 2: Transfer to VM

```bash
cd vm-deployment
./transfer_to_vm.sh

# Or manually:
scp -r ./* root@stg-droveexeckraken001:/root/kraken/
```

### Step 3: Deploy on VM

```bash
# SSH to VM
ssh root@stg-droveexeckraken001

# Navigate to deployment directory
cd /root/kraken

# Load Docker images
gunzip kraken-herd.tar.gz kraken-agent.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar

# Start the cluster
./start_kraken_cluster.sh
```

### Step 4: Test POC

```bash
# On the VM, test the deployment
docker pull hello-world
docker tag hello-world localhost:15000/test/hello-world:latest
docker push localhost:15000/test/hello-world:latest

# Pull from agents (P2P)
docker pull localhost:16000/test/hello-world:latest
docker pull localhost:17000/test/hello-world:latest
```

## Option 2: Manual Step-by-Step

### On Local Mac:

```bash
# 1. Build binaries
make clean
make bins

# 2. Build images
make images

# 3. Save images
docker save kraken-herd:dev -o kraken-herd.tar
docker save kraken-agent:dev -o kraken-agent.tar
gzip kraken-herd.tar kraken-agent.tar

# 4. Transfer to VM
scp kraken-herd.tar.gz root@stg-droveexeckraken001:/root/
scp kraken-agent.tar.gz root@stg-droveexeckraken001:/root/
scp -r examples/devcluster root@stg-droveexeckraken001:/root/kraken-config/
```

### On VM:

```bash
# 1. Update configurations
cd /root/kraken-config/devcluster/config
find . -type f -name "*.yaml" -exec sed -i 's/host.docker.internal/localhost/g' {} \;

# 2. Load images
cd /root
gunzip kraken-herd.tar.gz kraken-agent.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar

# 3. Follow the deployment scripts in KRAKEN_VM_DEPLOYMENT.md
```

## Quick Commands Reference

### On VM:

```bash
# Start cluster
./start_kraken_cluster.sh

# Stop cluster
./stop_kraken_cluster.sh

# Check status
docker ps --filter name=kraken

# View logs
docker logs kraken-herd | tail -50
docker logs kraken-agent-one
docker logs kraken-agent-two

# Test endpoints
curl http://localhost:15000/v2/  # Proxy (push)
curl http://localhost:16000/v2/  # Agent One (pull)
curl http://localhost:17000/v2/  # Agent Two (pull)
curl http://localhost:14000/health  # TestFS
```

### Test POC:

```bash
# Push test
docker pull nginx:latest
docker tag nginx:latest localhost:15000/test/nginx:latest
docker push localhost:15000/test/nginx:latest

# Pull test (P2P)
docker pull localhost:16000/test/nginx:latest &
docker pull localhost:17000/test/nginx:latest &
wait

# Monitor P2P activity
docker logs kraken-agent-one | grep -i peer
docker logs kraken-agent-two | grep -i peer
```

## Troubleshooting

### Issue: "Exec format error"

**Cause**: Architecture mismatch  
**Fix**: The Makefile now includes `--platform linux/amd64` in CROSS_COMPILER. Rebuild:

```bash
# On Mac
make clean
make bins
make images
```

### Issue: Services can't connect

**Cause**: Using `host.docker.internal` on Linux  
**Fix**: Already handled by preparation script. Or manually:

```bash
# On VM
find /root/kraken-config/devcluster/config -name "*.yaml" -exec sed -i 's/host.docker.internal/localhost/g' {} \;
```

### Issue: Container fails to start

**Check logs**:
```bash
docker logs kraken-herd
docker logs kraken-agent-one
docker logs kraken-agent-two
```

**Verify images loaded**:
```bash
docker images | grep kraken
```

## Port Mapping

| Component | Port | Access From |
|-----------|------|-------------|
| Proxy (Push) | 15000 | Any machine |
| Agent One (Pull) | 16000 | Any machine |
| Agent Two (Pull) | 17000 | Any machine |
| TestFS | 14000 | Internal |
| Origin | 15002 | Internal |
| Tracker | 15003 | Internal |
| Build-Index | 15004 | Internal |

## Documentation

- **Detailed VM Guide**: `KRAKEN_VM_DEPLOYMENT.md`
- **Mac Setup Codelab**: `KRAKEN_MAC_SETUP_CODELAB.md`
- **Configuration**: `docs/CONFIGURATION.md`

## What's Been Fixed

✅ **Makefile**: Added `--platform linux/amd64` to CROSS_COMPILER  
✅ **Architecture**: Binaries now build correctly for x86_64  
✅ **Configuration**: Automated replacement of `host.docker.internal` with `localhost`  
✅ **Scripts**: Complete deployment automation  
✅ **Documentation**: Step-by-step VM deployment guide  

## Success Criteria

After deployment, you should see:

```bash
$ docker ps --filter name=kraken
CONTAINER ID   IMAGE              STATUS       PORTS     NAMES
xxxxx          kraken-herd:dev    Up 2 min     ...       kraken-herd
xxxxx          kraken-agent:dev   Up 1 min     ...       kraken-agent-one
xxxxx          kraken-agent:dev   Up 1 min     ...       kraken-agent-two
```

All health checks should pass:
```bash
✓ Proxy OK
✓ Agent One OK
✓ Agent Two OK
✓ TestFS OK
```

## Next Steps

1. ✅ Deploy to VM
2. ✅ Complete POC testing
3. 📋 Document findings
4. 🚀 Plan production deployment

Happy P2P container distribution! 🐙
