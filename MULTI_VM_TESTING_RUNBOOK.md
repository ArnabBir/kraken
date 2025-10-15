# Kraken Multi-VM Testing Runbook

This runbook provides step-by-step instructions for testing the Kraken P2P Docker Registry deployed across 3 VMs.

## Quick Start

### Prerequisites Check

Before starting, ensure:
- [ ] All 3 VMs are accessible via SSH
- [ ] Docker is running on all VMs
- [ ] Network connectivity exists between all VMs
- [ ] You have the VM IPs or can resolve hostnames

### Environment Setup

```bash
# Set your environment variables
export VM1_HOST="stg-droveexeckraken001.phonepe.nb6"
export VM2_HOST="stg-droveexeckraken002.phonepe.nb6"
export VM3_HOST="stg-droveexeckraken003.phonepe.nb6"

export VM1_IP="172.24.24.49"
export VM2_IP="172.24.24.50"
export VM3_IP="172.24.24.51"

export VM_USER="root"
```

## Automated Deployment

### Option 1: Fully Automated (Recommended)

Run the automated deployment script from your local Mac:

```bash
cd /path/to/kraken

# Deploy everything
./scripts/deploy_multi_vm.sh
```

This script will:
1. Build images locally
2. Transfer to all VMs
3. Load images on each VM
4. Update configurations
5. Create startup scripts
6. Start all services
7. Run health checks

**Time estimate:** 10-15 minutes

### Option 2: Manual Step-by-Step

Follow the detailed steps in [MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md).

**Time estimate:** 30-45 minutes

## Testing Procedures

### Test 1: Basic Connectivity

**Objective:** Verify all services are reachable.

**Steps:**

1. **Test Herd Services (VM1):**
   ```bash
   curl http://${VM1_IP}:15000/v2/          # Proxy (push endpoint)
   curl http://${VM1_IP}:14000/health       # TestFS
   curl http://${VM1_IP}:15002/health       # Origin
   curl http://${VM1_IP}:15003/health       # Tracker
   curl http://${VM1_IP}:15004/health       # Build-Index
   ```

   **Expected:** All should return `200 OK` or `{}`.

2. **Test Agent One (VM2):**
   ```bash
   curl http://${VM2_IP}:16000/v2/          # Registry (pull endpoint)
   ```

   **Expected:** `200 OK` with `{}`.

3. **Test Agent Two (VM3):**
   ```bash
   curl http://${VM3_IP}:17000/v2/          # Registry (pull endpoint)
   ```

   **Expected:** `200 OK` with `{}`.

**Pass Criteria:** All endpoints return successful responses.

---

### Test 2: Push Image

**Objective:** Verify image can be pushed to the herd.

**Steps:**

1. **Pull a test image:**
   ```bash
   docker pull hello-world:latest
   ```

2. **Tag for Kraken:**
   ```bash
   docker tag hello-world:latest ${VM1_IP}:15000/test/hello-world:v1
   ```

3. **Push to Kraken:**
   ```bash
   docker push ${VM1_IP}:15000/test/hello-world:v1
   ```

   **Expected output:**
   ```
   The push refers to repository [172.24.24.49:15000/test/hello-world]
   ...
   v1: digest: sha256:... size: ...
   ```

4. **Verify in logs:**
   ```bash
   ssh ${VM_USER}@${VM1_HOST} "docker logs kraken-herd | grep -i 'hello-world' | tail -20"
   ```

**Pass Criteria:** 
- Push completes successfully
- Logs show image receipt on origin

---

### Test 3: Pull from Agent One

**Objective:** Verify image can be pulled from Agent One.

**Steps:**

1. **Remove local image:**
   ```bash
   docker rmi hello-world:latest ${VM1_IP}:15000/test/hello-world:v1 2>/dev/null || true
   ```

2. **Pull from Agent One:**
   ```bash
   docker pull ${VM2_IP}:16000/test/hello-world:v1
   ```

   **Expected output:**
   ```
   v1: Pulling from test/hello-world
   ...
   Status: Downloaded newer image for 172.24.24.50:16000/test/hello-world:v1
   ```

3. **Verify image exists:**
   ```bash
   docker images | grep hello-world
   ```

4. **Check agent logs:**
   ```bash
   ssh ${VM_USER}@${VM2_HOST} "docker logs kraken-agent-one | grep -i 'hello-world' | tail -20"
   ```

**Pass Criteria:**
- Image downloads successfully
- Image appears in `docker images`
- Agent logs show download activity

---

### Test 4: Pull from Agent Two

**Objective:** Verify image can be pulled from Agent Two.

**Steps:**

1. **Remove local image:**
   ```bash
   docker rmi ${VM2_IP}:16000/test/hello-world:v1 2>/dev/null || true
   ```

2. **Pull from Agent Two:**
   ```bash
   docker pull ${VM3_IP}:17000/test/hello-world:v1
   ```

3. **Verify:**
   ```bash
   docker images | grep hello-world
   ```

4. **Check agent logs:**
   ```bash
   ssh ${VM_USER}@${VM3_HOST} "docker logs kraken-agent-two | grep -i 'hello-world' | tail -20"
   ```

**Pass Criteria:**
- Image downloads successfully
- Agent Two logs show activity

---

### Test 5: P2P Distribution

**Objective:** Verify agents can share blobs via P2P protocol.

**Steps:**

1. **Push a larger image to see P2P activity:**
   ```bash
   docker pull nginx:latest
   docker tag nginx:latest ${VM1_IP}:15000/test/nginx:v1
   docker push ${VM1_IP}:15000/test/nginx:v1
   ```

2. **Clear local cache:**
   ```bash
   docker rmi nginx:latest ${VM1_IP}:15000/test/nginx:v1
   ```

3. **Pull from Agent One:**
   ```bash
   docker pull ${VM2_IP}:16000/test/nginx:v1
   ```

4. **Without removing, pull from Agent Two (this should trigger P2P):**
   ```bash
   # In a separate terminal/session
   docker pull ${VM3_IP}:17000/test/nginx:v1
   ```

5. **Check P2P logs on Agent One:**
   ```bash
   ssh ${VM_USER}@${VM2_HOST} "docker logs kraken-agent-one 2>&1 | grep -i 'peer\|seed\|upload' | tail -30"
   ```

6. **Check P2P logs on Agent Two:**
   ```bash
   ssh ${VM_USER}@${VM3_HOST} "docker logs kraken-agent-two 2>&1 | grep -i 'peer\|seed\|download' | tail -30"
   ```

**Pass Criteria:**
- Both agents successfully download the image
- Logs show peer-to-peer activity (seeding/leeching)
- Agent Two gets some pieces from Agent One (not just origin)

---

### Test 6: Concurrent Pulls (P2P Stress Test)

**Objective:** Verify P2P works under concurrent load.

**Steps:**

1. **Push a medium-sized image:**
   ```bash
   docker pull ubuntu:22.04
   docker tag ubuntu:22.04 ${VM1_IP}:15000/test/ubuntu:22.04
   docker push ${VM1_IP}:15000/test/ubuntu:22.04
   ```

2. **Clear local cache:**
   ```bash
   docker rmi ubuntu:22.04 ${VM1_IP}:15000/test/ubuntu:22.04
   ```

3. **Pull from both agents simultaneously:**
   ```bash
   # Terminal 1
   time docker pull ${VM2_IP}:16000/test/ubuntu:22.04 &
   
   # Terminal 2 (or background)
   time docker pull ${VM3_IP}:17000/test/ubuntu:22.04 &
   
   # Wait for both
   wait
   ```

4. **Compare times and check logs:**
   ```bash
   # Check if agents shared pieces
   ssh ${VM_USER}@${VM2_HOST} "docker logs kraken-agent-one 2>&1 | grep -E 'peer|piece|ubuntu' | tail -50"
   ssh ${VM_USER}@${VM3_HOST} "docker logs kraken-agent-two 2>&1 | grep -E 'peer|piece|ubuntu' | tail -50"
   ```

**Pass Criteria:**
- Both pulls complete successfully
- Logs show peer-to-peer piece sharing
- Download times are reasonable (P2P should help distribute load)

---

### Test 7: Multi-Layer Image

**Objective:** Verify Kraken handles multi-layer images correctly.

**Steps:**

1. **Push a multi-layer image:**
   ```bash
   docker pull alpine:3.18
   docker tag alpine:3.18 ${VM1_IP}:15000/test/alpine:3.18
   docker push ${VM1_IP}:15000/test/alpine:3.18
   ```

2. **Pull and verify layers:**
   ```bash
   docker rmi alpine:3.18 ${VM1_IP}:15000/test/alpine:3.18
   docker pull ${VM2_IP}:16000/test/alpine:3.18
   docker history ${VM2_IP}:16000/test/alpine:3.18
   ```

3. **Test the image works:**
   ```bash
   docker run --rm ${VM2_IP}:16000/test/alpine:3.18 echo "Kraken P2P works!"
   ```

   **Expected:** `Kraken P2P works!`

**Pass Criteria:**
- Image pulls correctly
- All layers present
- Image runs successfully

---

### Test 8: Tag Management

**Objective:** Verify tag updates and overwrites work.

**Steps:**

1. **Push initial version:**
   ```bash
   docker pull busybox:1.36
   docker tag busybox:1.36 ${VM1_IP}:15000/test/busybox:latest
   docker push ${VM1_IP}:15000/test/busybox:latest
   ```

2. **Pull from agent:**
   ```bash
   docker pull ${VM2_IP}:16000/test/busybox:latest
   DIGEST1=$(docker images --digests ${VM2_IP}:16000/test/busybox:latest | grep latest | awk '{print $3}')
   echo "Digest 1: $DIGEST1"
   ```

3. **Push a different image with same tag:**
   ```bash
   docker pull busybox:1.35
   docker tag busybox:1.35 ${VM1_IP}:15000/test/busybox:latest
   docker push ${VM1_IP}:15000/test/busybox:latest
   ```

4. **Pull updated version:**
   ```bash
   docker pull ${VM2_IP}:16000/test/busybox:latest
   DIGEST2=$(docker images --digests ${VM2_IP}:16000/test/busybox:latest | grep latest | awk '{print $3}')
   echo "Digest 2: $DIGEST2"
   ```

5. **Verify digests differ:**
   ```bash
   if [ "$DIGEST1" != "$DIGEST2" ]; then
     echo "✓ Tag update works correctly"
   else
     echo "✗ Tag update failed - digests are identical"
   fi
   ```

**Pass Criteria:**
- Second push succeeds
- Pull gets the new image
- Digests are different

---

### Test 9: Failure Recovery

**Objective:** Verify system recovers from agent failure.

**Steps:**

1. **Stop Agent Two:**
   ```bash
   ssh ${VM_USER}@${VM3_HOST} "docker stop kraken-agent-two"
   ```

2. **Push a new image:**
   ```bash
   docker pull redis:alpine
   docker tag redis:alpine ${VM1_IP}:15000/test/redis:alpine
   docker push ${VM1_IP}:15000/test/redis:alpine
   ```

3. **Pull from Agent One (should still work):**
   ```bash
   docker pull ${VM2_IP}:16000/test/redis:alpine
   ```

4. **Restart Agent Two:**
   ```bash
   ssh ${VM_USER}@${VM3_HOST} "docker start kraken-agent-two"
   sleep 5
   ```

5. **Pull from Agent Two:**
   ```bash
   docker pull ${VM3_IP}:17000/test/redis:alpine
   ```

**Pass Criteria:**
- Agent One continues working when Agent Two is down
- Agent Two recovers and can pull images after restart
- No data corruption

---

### Test 10: Performance Baseline

**Objective:** Establish performance metrics.

**Steps:**

1. **Direct pull (baseline):**
   ```bash
   docker pull ubuntu:22.04
   docker rmi ubuntu:22.04
   time docker pull ubuntu:22.04
   ```

2. **Push to Kraken:**
   ```bash
   docker tag ubuntu:22.04 ${VM1_IP}:15000/perf/ubuntu:22.04
   time docker push ${VM1_IP}:15000/perf/ubuntu:22.04
   ```

3. **Pull from Agent One:**
   ```bash
   docker rmi ubuntu:22.04 ${VM1_IP}:15000/perf/ubuntu:22.04
   time docker pull ${VM2_IP}:16000/perf/ubuntu:22.04
   ```

4. **Pull from Agent Two:**
   ```bash
   docker rmi ${VM2_IP}:16000/perf/ubuntu:22.04
   time docker pull ${VM3_IP}:17000/perf/ubuntu:22.04
   ```

5. **Record times:**
   ```bash
   echo "Direct pull:    X seconds"
   echo "Push to Kraken: Y seconds"
   echo "Pull from VM2:  Z seconds"
   echo "Pull from VM3:  W seconds"
   ```

**Pass Criteria:**
- Kraken pull times are reasonable (within 2-3x of direct pull)
- System is functional under load

---

## Health Monitoring

### Continuous Health Check

Run this script to continuously monitor cluster health:

```bash
cat > /tmp/kraken_health_monitor.sh << 'EOF'
#!/bin/bash

VM1_IP="${VM1_IP:-172.24.24.49}"
VM2_IP="${VM2_IP:-172.24.24.50}"
VM3_IP="${VM3_IP:-172.24.24.51}"

while true; do
  clear
  echo "========================================="
  echo "Kraken Cluster Health - $(date)"
  echo "========================================="
  
  echo ""
  echo "VM1 - Herd Services:"
  curl -s -o /dev/null -w "  Proxy:       %{http_code}\n" http://${VM1_IP}:15000/v2/
  curl -s -o /dev/null -w "  TestFS:      %{http_code}\n" http://${VM1_IP}:14000/health
  curl -s -o /dev/null -w "  Origin:      %{http_code}\n" http://${VM1_IP}:15002/health
  curl -s -o /dev/null -w "  Tracker:     %{http_code}\n" http://${VM1_IP}:15003/health
  curl -s -o /dev/null -w "  Build-Index: %{http_code}\n" http://${VM1_IP}:15004/health
  
  echo ""
  echo "VM2 - Agent One:"
  curl -s -o /dev/null -w "  Registry:    %{http_code}\n" http://${VM2_IP}:16000/v2/
  
  echo ""
  echo "VM3 - Agent Two:"
  curl -s -o /dev/null -w "  Registry:    %{http_code}\n" http://${VM3_IP}:17000/v2/
  
  echo ""
  echo "Refreshing in 10 seconds... (Ctrl+C to stop)"
  sleep 10
done
EOF

chmod +x /tmp/kraken_health_monitor.sh
/tmp/kraken_health_monitor.sh
```

### Log Aggregation

View logs from all services:

```bash
# Herd logs
ssh ${VM_USER}@${VM1_HOST} "docker logs -f kraken-herd"

# Agent One logs
ssh ${VM_USER}@${VM2_HOST} "docker logs -f kraken-agent-one"

# Agent Two logs
ssh ${VM_USER}@${VM3_HOST} "docker logs -f kraken-agent-two"
```

---

## Cleanup

### Stop All Services

```bash
# Stop in reverse order
ssh ${VM_USER}@${VM3_HOST} "/root/kraken-config/devcluster/vm3_stop.sh"
ssh ${VM_USER}@${VM2_HOST} "/root/kraken-config/devcluster/vm2_stop.sh"
ssh ${VM_USER}@${VM1_HOST} "/root/kraken-config/devcluster/vm1_stop.sh"
```

### Clean Up Images (Optional)

```bash
# On each VM, remove Kraken images
ssh ${VM_USER}@${VM1_HOST} "docker rmi kraken-herd:dev"
ssh ${VM_USER}@${VM2_HOST} "docker rmi kraken-agent:dev"
ssh ${VM_USER}@${VM3_HOST} "docker rmi kraken-agent:dev"

# Clean up test images
docker rmi $(docker images | grep '172.24.24' | awk '{print $1":"$2}')
```

---

## Test Results Template

Document your test results:

```markdown
# Kraken Multi-VM Test Results

**Date:** YYYY-MM-DD
**Tester:** Your Name
**Environment:** 3 VMs (stg-droveexeckraken001-003)

## Test Summary

| Test # | Test Name              | Status | Notes |
|--------|------------------------|--------|-------|
| 1      | Basic Connectivity     | ✓/✗    |       |
| 2      | Push Image             | ✓/✗    |       |
| 3      | Pull from Agent One    | ✓/✗    |       |
| 4      | Pull from Agent Two    | ✓/✗    |       |
| 5      | P2P Distribution       | ✓/✗    |       |
| 6      | Concurrent Pulls       | ✓/✗    |       |
| 7      | Multi-Layer Image      | ✓/✗    |       |
| 8      | Tag Management         | ✓/✗    |       |
| 9      | Failure Recovery       | ✓/✗    |       |
| 10     | Performance Baseline   | ✓/✗    |       |

## Performance Metrics

- Direct pull time: X seconds
- Kraken push time: Y seconds
- Agent pull time: Z seconds
- P2P efficiency: % of data from peers

## Issues Encountered

1. Issue description
2. Resolution
3. ...

## Recommendations

- List any improvements or observations
```

---

## Troubleshooting Quick Reference

| Issue | Quick Fix |
|-------|-----------|
| Can't connect to service | Check `docker ps` on that VM, verify firewall |
| "no ip found" error | Check VM_IP detection in startup scripts |
| Push fails | Verify herd is running, check proxy logs |
| Pull fails | Check agent logs, verify connection to tracker |
| P2P not working | Check peer ports (16001, 17001), verify tracker |
| Slow performance | Check network bandwidth, review resource limits |

---

## Next Steps

After successful testing:

1. **Document Results** - Fill out the test results template
2. **Performance Tuning** - Adjust cache sizes, connection limits
3. **Production Planning** - Consider TLS, authentication, monitoring
4. **Scale Testing** - Add more agents to test scalability
5. **Integration** - Integrate with CI/CD pipelines

For production deployment, refer to [CONFIGURATION.md](docs/CONFIGURATION.md).
