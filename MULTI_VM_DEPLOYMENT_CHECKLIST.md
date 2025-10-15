# Multi-VM Deployment Checklist

Use this checklist to track your deployment progress.

## Pre-Deployment

### Environment Setup
- [ ] Confirmed access to all 3 VMs via SSH
- [ ] Verified Docker is installed on all VMs
- [ ] Verified network connectivity between VMs
- [ ] Noted VM hostnames:
  - VM1: `_______________________________`
  - VM2: `_______________________________`
  - VM3: `_______________________________`
- [ ] Noted VM IP addresses:
  - VM1: `_______________________________`
  - VM2: `_______________________________`
  - VM3: `_______________________________`
- [ ] Set environment variables in terminal:
  ```bash
  export VM1_HOST="your-vm1-hostname"
  export VM2_HOST="your-vm2-hostname"
  export VM3_HOST="your-vm3-hostname"
  export VM1_IP="your-vm1-ip"
  export VM2_IP="your-vm2-ip"
  export VM3_IP="your-vm3-ip"
  export VM_USER="root"
  ```

### Firewall/Network
- [ ] Verified ports are open on VM1: 14000-15005
- [ ] Verified ports are open on VM2: 16000-16002
- [ ] Verified ports are open on VM3: 17000-17002
- [ ] Tested connectivity:
  ```bash
  ping -c 3 $VM1_IP
  ping -c 3 $VM2_IP
  ping -c 3 $VM3_IP
  ```

### Local Machine
- [ ] Cloned Kraken repository
- [ ] Docker Desktop running
- [ ] Make installed
- [ ] Go installed (if building manually)

---

## Deployment

### Option A: Automated (Recommended)
- [ ] Reviewed environment variables are set correctly
- [ ] Ran deployment script:
  ```bash
  cd /path/to/kraken
  ./scripts/deploy_multi_vm.sh
  ```
- [ ] Script completed without errors
- [ ] All health checks passed

### Option B: Manual
- [ ] Built images locally: `make clean && make bins && make images`
- [ ] Transferred images to VMs
- [ ] Loaded images on each VM
- [ ] Updated configuration files with correct IPs
- [ ] Created startup scripts on each VM
- [ ] Started herd on VM1
- [ ] Started agent one on VM2
- [ ] Started agent two on VM3

---

## Post-Deployment Verification

### Container Status
- [ ] VM1 - Herd container running:
  ```bash
  ssh $VM_USER@$VM1_HOST "docker ps --filter name=kraken-herd"
  ```
- [ ] VM2 - Agent One running:
  ```bash
  ssh $VM_USER@$VM2_HOST "docker ps --filter name=kraken-agent-one"
  ```
- [ ] VM3 - Agent Two running:
  ```bash
  ssh $VM_USER@$VM3_HOST "docker ps --filter name=kraken-agent-two"
  ```

### Service Endpoints
- [ ] Proxy accessible: `curl http://$VM1_IP:15000/v2/`
- [ ] TestFS accessible: `curl http://$VM1_IP:14000/health`
- [ ] Origin accessible: `curl http://$VM1_IP:15002/health`
- [ ] Tracker accessible: `curl http://$VM1_IP:15003/health`
- [ ] Build-Index accessible: `curl http://$VM1_IP:15004/health`
- [ ] Agent One accessible: `curl http://$VM2_IP:16000/v2/`
- [ ] Agent Two accessible: `curl http://$VM3_IP:17000/v2/`

### Log Check
- [ ] Herd logs show no errors:
  ```bash
  ssh $VM_USER@$VM1_HOST "docker logs kraken-herd | tail -50"
  ```
- [ ] Agent One logs show no errors:
  ```bash
  ssh $VM_USER@$VM2_HOST "docker logs kraken-agent-one | tail -30"
  ```
- [ ] Agent Two logs show no errors:
  ```bash
  ssh $VM_USER@$VM3_HOST "docker logs kraken-agent-two | tail -30"
  ```

---

## Basic Functionality Tests

### Test 1: Push Image
- [ ] Pulled test image: `docker pull hello-world`
- [ ] Tagged for Kraken: `docker tag hello-world $VM1_IP:15000/test/hello:v1`
- [ ] Pushed successfully: `docker push $VM1_IP:15000/test/hello:v1`
- [ ] Verified in herd logs

### Test 2: Pull from Agent One
- [ ] Removed local image: `docker rmi hello-world $VM1_IP:15000/test/hello:v1`
- [ ] Pulled from VM2: `docker pull $VM2_IP:16000/test/hello:v1`
- [ ] Image downloaded successfully
- [ ] Image appears in `docker images`

### Test 3: Pull from Agent Two
- [ ] Removed local image: `docker rmi $VM2_IP:16000/test/hello:v1`
- [ ] Pulled from VM3: `docker pull $VM3_IP:17000/test/hello:v1`
- [ ] Image downloaded successfully
- [ ] Image appears in `docker images`

### Test 4: P2P Verification
- [ ] Pushed larger image (nginx): `docker tag nginx:latest $VM1_IP:15000/test/nginx:latest && docker push $VM1_IP:15000/test/nginx:latest`
- [ ] Pulled from both agents concurrently:
  ```bash
  docker pull $VM2_IP:16000/test/nginx:latest &
  docker pull $VM3_IP:17000/test/nginx:latest &
  wait
  ```
- [ ] Both downloads completed
- [ ] Checked P2P activity in logs:
  ```bash
  ssh $VM_USER@$VM2_HOST "docker logs kraken-agent-one | grep -i 'peer\|piece' | tail -20"
  ssh $VM_USER@$VM3_HOST "docker logs kraken-agent-two | grep -i 'peer\|piece' | tail -20"
  ```

---

## Advanced Testing (Optional)

Refer to [MULTI_VM_TESTING_RUNBOOK.md](MULTI_VM_TESTING_RUNBOOK.md) for:

- [ ] Test 5: P2P Distribution
- [ ] Test 6: Concurrent Pulls
- [ ] Test 7: Multi-Layer Images
- [ ] Test 8: Tag Management
- [ ] Test 9: Failure Recovery
- [ ] Test 10: Performance Baseline

---

## Documentation Review

- [ ] Read [MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md)
- [ ] Reviewed [MULTI_VM_TESTING_RUNBOOK.md](MULTI_VM_TESTING_RUNBOOK.md)
- [ ] Bookmarked [MULTI_VM_QUICK_REFERENCE.md](MULTI_VM_QUICK_REFERENCE.md)
- [ ] Read [MULTI_VM_IMPLEMENTATION_SUMMARY.md](MULTI_VM_IMPLEMENTATION_SUMMARY.md)

---

## Common Issues Encountered

Document any issues you encountered:

### Issue 1
- **Problem:** _________________________________
- **Error Message:** _________________________________
- **Solution:** _________________________________

### Issue 2
- **Problem:** _________________________________
- **Error Message:** _________________________________
- **Solution:** _________________________________

### Issue 3
- **Problem:** _________________________________
- **Error Message:** _________________________________
- **Solution:** _________________________________

---

## Performance Notes

### Push Performance
- Image: _________________________________
- Size: _________________________________
- Time: _________________________________

### Pull Performance (First Pull - from Origin)
- Image: _________________________________
- Agent: VM2/VM3
- Time: _________________________________

### Pull Performance (P2P)
- Image: _________________________________
- Agent: VM2/VM3
- Time: _________________________________
- P2P Pieces: Yes/No

---

## Next Steps

After successful deployment and testing:

- [ ] Document test results
- [ ] Share findings with team
- [ ] Plan production deployment
- [ ] Consider scaling (add more agents)
- [ ] Set up monitoring
- [ ] Configure TLS/authentication
- [ ] Integrate with CI/CD

---

## Cleanup (When Done)

- [ ] Stopped all services:
  ```bash
  ssh $VM_USER@$VM1_HOST /root/kraken-config/devcluster/vm1_stop.sh
  ssh $VM_USER@$VM2_HOST /root/kraken-config/devcluster/vm2_stop.sh
  ssh $VM_USER@$VM3_HOST /root/kraken-config/devcluster/vm3_stop.sh
  ```
- [ ] Removed test images (if needed)
- [ ] Documented results
- [ ] Archived logs (if needed)

---

## Sign-Off

**Deployment Date:** _______________  
**Deployed By:** _______________  
**Status:** Success / Partial / Failed  
**Notes:** _______________________________________________

---

## Quick Commands Reference

### Start Cluster
```bash
ssh $VM_USER@$VM1_HOST /root/kraken-config/devcluster/vm1_herd_start.sh
ssh $VM_USER@$VM2_HOST /root/kraken-config/devcluster/vm2_agent_one_start.sh
ssh $VM_USER@$VM3_HOST /root/kraken-config/devcluster/vm3_agent_two_start.sh
```

### Stop Cluster
```bash
ssh $VM_USER@$VM1_HOST /root/kraken-config/devcluster/vm1_stop.sh
ssh $VM_USER@$VM2_HOST /root/kraken-config/devcluster/vm2_stop.sh
ssh $VM_USER@$VM3_HOST /root/kraken-config/devcluster/vm3_stop.sh
```

### Check Status
```bash
# All at once
ssh $VM_USER@$VM1_HOST "docker ps --filter name=kraken"
ssh $VM_USER@$VM2_HOST "docker ps --filter name=kraken"
ssh $VM_USER@$VM3_HOST "docker ps --filter name=kraken"
```

### View Logs
```bash
ssh $VM_USER@$VM1_HOST "docker logs -f kraken-herd"
ssh $VM_USER@$VM2_HOST "docker logs -f kraken-agent-one"
ssh $VM_USER@$VM3_HOST "docker logs -f kraken-agent-two"
```
