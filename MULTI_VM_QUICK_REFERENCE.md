# Kraken Multi-VM Quick Reference

## VM Assignment

| VM | Role | IP | Ports |
|----|------|-----|-------|
| stg-droveexeckraken001 | Herd | 172.24.24.49 | 14000-15005 |
| stg-droveexeckraken002 | Agent-1 | 172.24.24.50 | 16000-16002 |
| stg-droveexeckraken003 | Agent-2 | 172.24.24.51 | 17000-17002 |

## Quick Deploy

```bash
export VM1_HOST="stg-droveexeckraken001.phonepe.nb6"
export VM2_HOST="stg-droveexeckraken002.phonepe.nb6"
export VM3_HOST="stg-droveexeckraken003.phonepe.nb6"
export VM1_IP="172.24.24.49"
export VM2_IP="172.24.24.50"
export VM3_IP="172.24.24.51"
export VM_USER="root"

./scripts/deploy_multi_vm.sh
```

## Start/Stop

### Start
```bash
# VM1
ssh root@stg-droveexeckraken001.phonepe.nb6 /root/kraken-config/devcluster/vm1_herd_start.sh

# VM2
ssh root@stg-droveexeckraken002.phonepe.nb6 /root/kraken-config/devcluster/vm2_agent_one_start.sh

# VM3
ssh root@stg-droveexeckraken003.phonepe.nb6 /root/kraken-config/devcluster/vm3_agent_two_start.sh
```

### Stop
```bash
ssh root@stg-droveexeckraken001.phonepe.nb6 /root/kraken-config/devcluster/vm1_stop.sh
ssh root@stg-droveexeckraken002.phonepe.nb6 /root/kraken-config/devcluster/vm2_stop.sh
ssh root@stg-droveexeckraken003.phonepe.nb6 /root/kraken-config/devcluster/vm3_stop.sh
```

## Health Check

```bash
# All services
curl http://172.24.24.49:15000/v2/  # Proxy (push)
curl http://172.24.24.50:16000/v2/  # Agent 1 (pull)
curl http://172.24.24.51:17000/v2/  # Agent 2 (pull)
curl http://172.24.24.49:14000/health  # TestFS
```

## Usage

### Push
```bash
docker tag myimage:tag 172.24.24.49:15000/namespace/myimage:tag
docker push 172.24.24.49:15000/namespace/myimage:tag
```

### Pull
```bash
# From Agent 1
docker pull 172.24.24.50:16000/namespace/myimage:tag

# From Agent 2
docker pull 172.24.24.51:17000/namespace/myimage:tag
```

## Logs

```bash
# Herd
ssh root@stg-droveexeckraken001.phonepe.nb6 "docker logs kraken-herd | tail -50"

# Agent 1
ssh root@stg-droveexeckraken002.phonepe.nb6 "docker logs kraken-agent-one | tail -50"

# Agent 2
ssh root@stg-droveexeckraken003.phonepe.nb6 "docker logs kraken-agent-two | tail -50"
```

## Container Status

```bash
# VM1
ssh root@stg-droveexeckraken001.phonepe.nb6 "docker ps --filter name=kraken"

# VM2
ssh root@stg-droveexeckraken002.phonepe.nb6 "docker ps --filter name=kraken"

# VM3
ssh root@stg-droveexeckraken003.phonepe.nb6 "docker ps --filter name=kraken"
```

## Common Issues

| Problem | Solution |
|---------|----------|
| "Service Unavailable" or tries HTTPS | Configure insecure registries (see below) |
| Connection refused | Check `docker ps`, verify service is running |
| "no ip found" | Check `hostname -I` output, verify network |
| Push fails | Check herd logs, verify proxy is up |
| Pull fails | Check agent logs, verify tracker connection |
| P2P not working | Check firewall allows peer ports (16001, 17001) |

### Fix: Docker Trying HTTPS Instead of HTTP

**Problem:** `Get "https://172.24.24.49:15000/v2/": Service Unavailable`

**Solution:** Configure Docker to allow insecure (HTTP) registries:

```bash
# On each VM, add to /etc/docker/daemon.json:
{
  "insecure-registries": [
    "172.24.24.49:15000",
    "172.24.24.50:16000", 
    "172.24.24.51:17000"
  ]
}

# Restart Docker
systemctl restart docker

# Verify
docker info | grep -A 5 "Insecure Registries"
```

**On Mac (Docker Desktop):**
1. Open Docker Desktop settings
2. Go to "Docker Engine"
3. Add the insecure-registries config
4. Click "Apply & Restart"

## Port Reference

### VM1 - Herd (172.24.24.49)
- **15000** - Proxy (PUSH here)
- **14000** - TestFS
- **15001** - Origin P2P
- **15002** - Origin Server
- **15003** - Tracker
- **15004** - Build-Index
- **15005** - Proxy Server

### VM2 - Agent 1 (172.24.24.50)
- **16000** - Registry (PULL here)
- **16001** - Peer P2P
- **16002** - Agent Server

### VM3 - Agent 2 (172.24.24.51)
- **17000** - Registry (PULL here)
- **17001** - Peer P2P
- **17002** - Agent Server

## File Locations

- **Configs:** `/root/kraken-config/devcluster/config/`
- **Scripts:** `/root/kraken-config/devcluster/vm*_*.sh`
- **Logs:** `docker logs <container>`

## Testing Cheat Sheet

```bash
# Quick test flow
docker pull hello-world
docker tag hello-world 172.24.24.49:15000/test/hello:v1
docker push 172.24.24.49:15000/test/hello:v1
docker pull 172.24.24.50:16000/test/hello:v1
docker pull 172.24.24.51:17000/test/hello:v1
```

## Documentation

- **Full Deployment:** [MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md)
- **Testing Runbook:** [MULTI_VM_TESTING_RUNBOOK.md](MULTI_VM_TESTING_RUNBOOK.md)
- **Single VM:** [KRAKEN_VM_DEPLOYMENT.md](KRAKEN_VM_DEPLOYMENT.md)
