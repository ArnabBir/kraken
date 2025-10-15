# Kraken VM Deployment - Summary of Changes

## Problem Solved

You were getting `Exec format error` when running Kraken on your x86_64 VM because:
- Your local Mac is ARM64 (M-series chip)
- Your VM is x86_64 (Intel/AMD architecture)
- The binaries were being built for ARM64 instead of x86_64

## Changes Made

### 1. Fixed Makefile ✅

**File**: `Makefile`

**Change**: Added `--platform linux/amd64` to `CROSS_COMPILER`:

```makefile
CROSS_COMPILER = \
  docker run --rm \
    --platform linux/amd64 \    # ← Added this line
    -v $(REPO_ROOT):/app \
    -w /app \
    ...
```

This ensures that:
- Go binaries are built inside a `linux/amd64` Docker container
- All binaries are x86_64 compatible
- Docker images are built for the correct architecture

**Also Fixed**: Typo in line 87 - `$(call tag_imagitge,kraken-agent)` → `$(call tag_image,kraken-agent)`

### 2. Created Comprehensive Documentation 📚

Created **3 new documentation files**:

#### A. `KRAKEN_VM_DEPLOYMENT.md` (Detailed Guide)
- Step-by-step VM deployment instructions
- Manual configuration steps
- Troubleshooting section
- Port reference
- Advanced configuration options

#### B. `QUICKSTART_VM.md` (Quick Reference)
- Quick start commands
- Both automated and manual deployment options
- Common troubleshooting solutions
- Success criteria checklist

#### C. `VM_DEPLOYMENT_SUMMARY.md` (This file)
- Summary of all changes
- Quick usage guide

### 3. Created Automation Script 🚀

**File**: `scripts/prepare_vm_deployment.sh`

This script automates the entire deployment preparation:
- ✅ Cleans old binaries
- ✅ Builds x86_64 binaries
- ✅ Verifies architecture is correct
- ✅ Builds Docker images
- ✅ Saves and compresses images
- ✅ Updates configuration files (replaces `host.docker.internal` with `localhost`)
- ✅ Creates VM deployment scripts
- ✅ Creates transfer script

## How to Use

### Option 1: Automated (Recommended)

On your **local Mac**:

```bash
# Set environment variables
export VM_HOST=stg-droveexeckraken001
export VM_USER=root

# Run the preparation script
./scripts/prepare_vm_deployment.sh

# Transfer to VM
cd vm-deployment
./transfer_to_vm.sh
```

On your **VM**:

```bash
# Load images
cd /root/kraken
gunzip *.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar

# Start cluster
./start_kraken_cluster.sh
```

### Option 2: Manual

On your **local Mac**:

```bash
# Build binaries and images
make clean
make bins
make images

# Save images
docker save kraken-herd:dev -o kraken-herd.tar
docker save kraken-agent:dev -o kraken-agent.tar
gzip kraken-herd.tar kraken-agent.tar

# Transfer to VM
scp kraken-herd.tar.gz root@stg-droveexeckraken001:/root/
scp kraken-agent.tar.gz root@stg-droveexeckraken001:/root/
scp -r examples/devcluster root@stg-droveexeckraken001:/root/kraken-config/
```

On your **VM**:

```bash
# Update configs
cd /root/kraken-config/devcluster/config
find . -type f -name "*.yaml" -exec sed -i 's/host.docker.internal/localhost/g' {} \;

# Load images
cd /root
gunzip *.tar.gz
docker load -i kraken-herd.tar
docker load -i kraken-agent.tar

# Follow manual deployment steps in KRAKEN_VM_DEPLOYMENT.md
```

## Testing the POC

Once deployed, test with:

```bash
# Push an image
docker pull hello-world
docker tag hello-world localhost:15000/test/hello-world:latest
docker push localhost:15000/test/hello-world:latest

# Pull from agents (P2P distribution)
docker pull localhost:16000/test/hello-world:latest
docker pull localhost:17000/test/hello-world:latest

# Test with larger image
docker pull nginx:latest
docker tag nginx:latest localhost:15000/test/nginx:latest
docker push localhost:15000/test/nginx:latest

# Pull from both agents simultaneously (see P2P in action)
docker pull localhost:16000/test/nginx:latest &
docker pull localhost:17000/test/nginx:latest &
wait
```

## Port Mapping

| Component | Port | Purpose |
|-----------|------|---------|
| **Proxy** | 15000 | Push images (entry point) |
| **Agent One** | 16000 | Pull images (P2P enabled) |
| **Agent Two** | 17000 | Pull images (P2P enabled) |
| TestFS | 14000 | Storage backend |
| Origin | 15002 | Blob server |
| Tracker | 15003 | Peer coordination |
| Build-Index | 15004 | Tag mapping |

## Files Created

```
kraken/
├── Makefile                           # Fixed: Added --platform linux/amd64
├── KRAKEN_VM_DEPLOYMENT.md           # New: Detailed deployment guide
├── QUICKSTART_VM.md                  # New: Quick reference
├── VM_DEPLOYMENT_SUMMARY.md          # New: This summary
└── scripts/
    └── prepare_vm_deployment.sh      # New: Automation script
```

## What Gets Generated

When you run `./scripts/prepare_vm_deployment.sh`, it creates:

```
vm-deployment/
├── kraken-herd.tar.gz               # Herd Docker image
├── kraken-agent.tar.gz              # Agent Docker image
├── start_kraken_cluster.sh          # Main startup script
├── stop_kraken_cluster.sh           # Shutdown script
├── vm_herd_start.sh                 # Herd startup
├── vm_agents_start.sh               # Agents startup
├── transfer_to_vm.sh                # Transfer script
├── DEPLOY_README.md                 # Deployment instructions
└── devcluster/                      # Config files (updated for Linux)
    ├── config/
    │   ├── agent/development.yaml
    │   ├── build-index/development.yaml
    │   ├── origin/development.yaml
    │   ├── proxy/development.yaml
    │   └── tracker/development.yaml
    ├── herd_param.sh
    ├── herd_start_processes.sh
    ├── agent_one_param.sh
    └── agent_two_param.sh
```

## Key Fixes Summary

1. ✅ **Architecture Fix**: Binaries now build correctly for x86_64
2. ✅ **Configuration Fix**: Replaced `host.docker.internal` with `localhost` for Linux
3. ✅ **Automation**: Created script to handle entire deployment preparation
4. ✅ **Documentation**: Comprehensive guides for both automated and manual deployment
5. ✅ **Testing**: Complete POC test scenarios included

## Next Steps

1. ✅ **Build locally**: `VM_HOST=stg-droveexeckraken001 ./scripts/prepare_vm_deployment.sh`
2. ✅ **Transfer to VM**: `cd vm-deployment && ./transfer_to_vm.sh`
3. ✅ **Deploy on VM**: `ssh root@stg-droveexeckraken001 "cd /root/kraken && ./start_kraken_cluster.sh"`
4. ✅ **Complete POC**: Test push/pull with `hello-world` and `nginx` images
5. 📋 **Document results**: Record performance metrics and P2P behavior

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| "Exec format error" | Rebuild with `make clean && make bins && make images` |
| Services can't connect | Check configs have `localhost` not `host.docker.internal` |
| Container won't start | Check logs: `docker logs kraken-herd` |
| Port conflicts | Change ports in `*_param.sh` files or stop conflicting services |

## Documentation References

- **Detailed Guide**: [KRAKEN_VM_DEPLOYMENT.md](KRAKEN_VM_DEPLOYMENT.md)
- **Quick Start**: [QUICKSTART_VM.md](QUICKSTART_VM.md)
- **Mac Codelab**: [KRAKEN_MAC_SETUP_CODELAB.md](KRAKEN_MAC_SETUP_CODELAB.md)
- **Configuration**: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

---

**Status**: ✅ Ready for VM Deployment

Your Kraken setup is now fully configured to:
- Build cross-platform (ARM64 Mac → x86_64 VM)
- Deploy automatically or manually
- Test P2P distribution
- Complete your POC successfully

Happy P2P container distribution! 🐙
