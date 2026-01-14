# Kraken Multi-VM Deployment - Complete Package

This package provides everything you need to deploy and test Kraken P2P Docker Registry across 3 separate VMs.

## 📁 Package Contents

### Core Documentation

1. **[MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md)** (21 KB)
   - Complete step-by-step deployment guide
   - Architecture overview and port allocation
   - Phase-by-phase instructions
   - Troubleshooting and advanced configuration

2. **[MULTI_VM_TESTING_RUNBOOK.md](MULTI_VM_TESTING_RUNBOOK.md)** (15 KB)
   - 10 comprehensive test scenarios
   - Health monitoring procedures
   - Performance benchmarking
   - Test results template

3. **[MULTI_VM_QUICK_REFERENCE.md](MULTI_VM_QUICK_REFERENCE.md)** (3.8 KB)
   - Quick command cheat sheet
   - Port reference table
   - Common issues and solutions
   - One-page reference card

4. **[MULTI_VM_IMPLEMENTATION_SUMMARY.md](MULTI_VM_IMPLEMENTATION_SUMMARY.md)** (16 KB)
   - Technical implementation details
   - Architecture diagrams
   - File structure on VMs
   - Troubleshooting guide

5. **[MULTI_VM_DEPLOYMENT_CHECKLIST.md](MULTI_VM_DEPLOYMENT_CHECKLIST.md)** (7.8 KB)
   - Interactive checklist
   - Pre-deployment verification
   - Post-deployment checks
   - Issue tracking template

### Automation Scripts

6. **[scripts/deploy_multi_vm.sh](scripts/deploy_multi_vm.sh)** (9.9 KB, executable)
   - Automated deployment script
   - Builds, transfers, and deploys to all VMs
   - Runs health checks
   - Provides usage instructions

---

## 🚀 Quick Start

### Prerequisites

- **3 VMs** with Docker installed
- **SSH access** to all VMs
- **Network connectivity** between VMs
- **Mac/Linux** build machine with Docker

### 1-Command Deployment

```bash
# Set your VMs
export VM1_HOST="stg-droveexeckraken001.phonepe.nb6"
export VM2_HOST="stg-droveexeckraken002.phonepe.nb6"
export VM3_HOST="stg-droveexeckraken003.phonepe.nb6"
export VM1_IP="172.24.24.49"
export VM2_IP="172.24.24.50"
export VM3_IP="172.24.24.51"
export VM_USER="root"

# Deploy!
./scripts/deploy_multi_vm.sh
```

**That's it!** The script will:
1. Build images for x86_64
2. Transfer to all VMs
3. Configure everything
4. Start all services
5. Run health checks

---

## 🏗️ Architecture

```
                    Push Images Here ↓
┌───────────────────────────────────────────────┐
│  VM1: stg-droveexeckraken001 (172.24.24.49)  │
│  ┌─────────────────────────────────────────┐ │
│  │  Kraken Herd (All Control Services)    │ │
│  │  - Origin, Tracker, Build-Index         │ │
│  │  - Proxy (Push: :15000)                 │ │
│  │  - TestFS (Storage)                     │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
                         ↓
          Peer-to-Peer Distribution
                    ↙        ↘
┌──────────────────────┐  ┌──────────────────────┐
│  VM2 (172.24.24.50)  │  │  VM3 (172.24.24.51)  │
│  ┌────────────────┐  │  │  ┌────────────────┐  │
│  │ Agent One      │←─┼──┼→ │ Agent Two      │  │
│  │ Pull: :16000   │  │  │  │ Pull: :17000   │  │
│  │ P2P:  :16001   │  │  │  │ P2P:  :17001   │  │
│  └────────────────┘  │  │  └────────────────┘  │
└──────────────────────┘  └──────────────────────┘
         ↑                         ↑
    Pull from here            Pull from here
```

---

## 📋 Documentation Guide

### For First-Time Deployment
Start here → **[MULTI_VM_DEPLOYMENT_CHECKLIST.md](MULTI_VM_DEPLOYMENT_CHECKLIST.md)**

### For Detailed Instructions
Read → **[MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md)**

### For Testing
Follow → **[MULTI_VM_TESTING_RUNBOOK.md](MULTI_VM_TESTING_RUNBOOK.md)**

### For Quick Commands
Reference → **[MULTI_VM_QUICK_REFERENCE.md](MULTI_VM_QUICK_REFERENCE.md)**

### For Technical Details
Review → **[MULTI_VM_IMPLEMENTATION_SUMMARY.md](MULTI_VM_IMPLEMENTATION_SUMMARY.md)**

---

## 🎯 Common Use Cases

### Use Case 1: Quick Demo
```bash
# Deploy
./scripts/deploy_multi_vm.sh

# Push image
docker tag nginx:latest ${VM1_IP}:15000/demo/nginx:v1
docker push ${VM1_IP}:15000/demo/nginx:v1

# Pull from agents
docker pull ${VM2_IP}:16000/demo/nginx:v1
docker pull ${VM3_IP}:17000/demo/nginx:v1
```

### Use Case 2: Performance Testing
```bash
# Follow Test 10 in MULTI_VM_TESTING_RUNBOOK.md
# Measure push/pull times
# Compare with direct Docker Hub pulls
```

### Use Case 3: P2P Verification
```bash
# Push large image
docker push ${VM1_IP}:15000/test/large-image:v1

# Pull from both agents simultaneously
docker pull ${VM2_IP}:16000/test/large-image:v1 &
docker pull ${VM3_IP}:17000/test/large-image:v1 &

# Check P2P activity in logs
ssh root@${VM2_HOST} "docker logs kraken-agent-one | grep -i peer"
```

---

## 🔧 Management Commands

### Start Cluster
```bash
ssh root@${VM1_HOST} /root/kraken-config/devcluster/vm1_herd_start.sh
ssh root@${VM2_HOST} /root/kraken-config/devcluster/vm2_agent_one_start.sh
ssh root@${VM3_HOST} /root/kraken-config/devcluster/vm3_agent_two_start.sh
```

### Stop Cluster
```bash
ssh root@${VM1_HOST} /root/kraken-config/devcluster/vm1_stop.sh
ssh root@${VM2_HOST} /root/kraken-config/devcluster/vm2_stop.sh
ssh root@${VM3_HOST} /root/kraken-config/devcluster/vm3_stop.sh
```

### Check Health
```bash
curl http://${VM1_IP}:15000/v2/  # Proxy
curl http://${VM2_IP}:16000/v2/  # Agent 1
curl http://${VM3_IP}:17000/v2/  # Agent 2
```

### View Logs
```bash
ssh root@${VM1_HOST} "docker logs -f kraken-herd"
ssh root@${VM2_HOST} "docker logs -f kraken-agent-one"
ssh root@${VM3_HOST} "docker logs -f kraken-agent-two"
```

---

## 📊 Test Scenarios Included

1. ✅ **Basic Connectivity** - Verify all endpoints
2. ✅ **Push Image** - Test image upload
3. ✅ **Pull from Agent One** - Test VM2 download
4. ✅ **Pull from Agent Two** - Test VM3 download
5. ✅ **P2P Distribution** - Verify peer sharing
6. ✅ **Concurrent Pulls** - Stress test P2P
7. ✅ **Multi-Layer Images** - Complex image handling
8. ✅ **Tag Management** - Tag updates/overwrites
9. ✅ **Failure Recovery** - Resilience testing
10. ✅ **Performance Baseline** - Benchmark metrics

Each test includes:
- Objective
- Step-by-step commands
- Expected output
- Pass/fail criteria

---

## 🐛 Troubleshooting

### Quick Fixes

| Problem | Quick Fix |
|---------|-----------|
| Can't connect | `docker ps` on VM, check firewall |
| "no ip found" | Check `hostname -I` output |
| Push fails | Check herd logs on VM1 |
| Pull fails | Check agent logs, verify tracker |
| P2P not working | Verify peer ports accessible |

See **[MULTI_VM_DEPLOYMENT.md](MULTI_VM_DEPLOYMENT.md)** for detailed troubleshooting.

---

## 🎓 Learning Path

1. **Understand the Architecture**
   - Read Implementation Summary
   - Review port allocation
   - Understand VM roles

2. **Deploy the Cluster**
   - Use the checklist
   - Run automated script
   - Verify all services

3. **Test Functionality**
   - Follow testing runbook
   - Run all 10 tests
   - Document results

4. **Optimize Performance**
   - Benchmark metrics
   - Tune configurations
   - Monitor P2P efficiency

---

## 📈 Expected Performance

Based on Uber's production metrics:
- **20K blobs (100MB-1G)** distributed in **< 30 seconds**
- **Download speed:** > 50% of max bandwidth
- **Cluster capacity:** 15K+ hosts

For your 3-VM setup:
- First pull: Baseline speed from origin
- P2P pulls: Improved speed via peer sharing
- Concurrent pulls: Load distribution across agents

---

## 🔐 Security Notes

Current setup is for **testing only**. For production:

1. **Enable TLS** on all endpoints
2. **Add authentication** (registry auth, mTLS)
3. **Secure storage** backend
4. **Network policies** between VMs
5. **Regular updates** and patches

See production docs: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

---

## 🚧 Known Limitations

- **Development configuration** - not production-hardened
- **No TLS** - plain HTTP only
- **No authentication** - open access
- **TestFS backend** - not suitable for production
- **No monitoring** - manual log inspection only

These are intentional for easy testing. Production setup requires additional configuration.

---

## 💡 Tips & Best Practices

### Deployment Tips
- Always verify network connectivity first
- Check firewall rules before deployment
- Use actual IPs instead of hostnames if DNS is unreliable
- Keep environment variables in a script for easy reuse

### Testing Tips
- Start with basic connectivity tests
- Progress to functionality tests
- End with performance benchmarks
- Document all test results

### Monitoring Tips
- Keep logs open during testing
- Monitor all 3 VMs simultaneously
- Look for peer-to-peer activity in agent logs
- Check tracker for peer registration

---

## 📞 Support & Resources

### Documentation
- Main Kraken Docs: [docs/](docs/)
- Configuration Guide: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

### Community
- GitHub Issues: https://github.com/uber/kraken/issues
- Original Uber Blog: https://eng.uber.com/introducing-kraken/

---

## ✅ Success Criteria

Your deployment is successful when:

- [ ] All containers running on all VMs
- [ ] All health checks pass (HTTP 200)
- [ ] Can push images to VM1:15000
- [ ] Can pull from VM2:16000 and VM3:17000
- [ ] Logs show no fatal errors
- [ ] P2P transfers visible in agent logs
- [ ] Images work correctly after pull

---

## 🎉 What's Next?

After successful deployment:

1. **Complete all tests** in the testing runbook
2. **Document your results** using the checklist
3. **Experiment** with different image sizes
4. **Monitor** P2P efficiency
5. **Plan production** deployment if satisfied

---

## 📝 Files Created on VMs

After deployment, each VM will have:

### VM1
- Startup script: `/root/kraken-config/devcluster/vm1_herd_start.sh`
- Stop script: `/root/kraken-config/devcluster/vm1_stop.sh`
- Configs: `/root/kraken-config/devcluster/config/`

### VM2
- Startup script: `/root/kraken-config/devcluster/vm2_agent_one_start.sh`
- Stop script: `/root/kraken-config/devcluster/vm2_stop.sh`
- Configs: `/root/kraken-config/devcluster/config/agent/`

### VM3
- Startup script: `/root/kraken-config/devcluster/vm3_agent_two_start.sh`
- Stop script: `/root/kraken-config/devcluster/vm3_stop.sh`
- Configs: `/root/kraken-config/devcluster/config/agent/`

---

## 🏁 Summary

This package provides a **complete, tested solution** for deploying Kraken across multiple VMs:

- ✅ **Automated deployment** - One script does everything
- ✅ **Comprehensive docs** - 5 detailed guides
- ✅ **Testing procedures** - 10 test scenarios
- ✅ **Quick reference** - Command cheat sheet
- ✅ **Production-ready architecture** - True distributed setup

**Total package size:** ~74 KB of documentation + automation

Ready to deploy your distributed P2P Docker registry! 🚀

---

**Questions?** Review the documentation or check the troubleshooting sections.

**Issues?** Document them in the checklist and refer to troubleshooting guides.

**Success?** Congratulations! You have a working P2P Docker registry cluster! 🎊
