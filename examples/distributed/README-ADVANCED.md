# Kraken Distributed Cluster - Advanced Production Setup

## Overview

This is an enterprise-grade, highly available Kraken P2P image distribution cluster designed for production BMS environments. The setup includes auto-recovery, performance monitoring, backup/disaster recovery, and standardized VM agent deployment.

## 🚀 Quick Start

### 1. Production Deployment
```bash
# Copy and customize environment configuration
cp .env.template .env
vim .env  # Customize for your environment

# Run production deployment
./scripts/production_deploy.sh

# Or perform a dry run first
./scripts/production_deploy.sh --dry-run
```

### 2. Deploy Agents to VMs
```bash
# Deploy standardized agent to a VM
./scripts/deploy_agent.sh <VM_IP>

# Or use the install script directly on the VM
curl -fsSL http://your-cluster:5000/install | bash
```

### 3. Monitor and Maintain
```bash
# Check cluster status
./test/cluster_status.sh

# Run comprehensive tests
./test/e2e_test.sh

# Monitor performance
./scripts/performance_monitor.sh watch

# Create backup
./scripts/backup_recovery.sh backup
```

## 📋 Production Features

### ✅ High Availability
- **3-Node Cluster**: Distributed across multiple hosts with automatic failover
- **Redis Clustering**: Distributed storage with automatic sharding and replication
- **Load Balancer**: NGINX with health checks and round-robin distribution
- **Auto-Recovery**: Automatic detection and recovery of failed services

### ✅ Enterprise Operations
- **Backup & Recovery**: Automated backup scheduling with disaster recovery
- **Performance Monitoring**: Real-time metrics and optimization recommendations
- **Health Monitoring**: Continuous service health checks with alerting
- **Configuration Management**: Environment-based configuration with templates

### ✅ Production Deployment
- **Automated Deployment**: One-command production deployment with validation
- **Standardized Agents**: Consistent agent deployment across all VMs
- **Security Hardened**: TLS support, authentication, and secure defaults
- **Scalable Architecture**: Designed to handle enterprise-scale image distribution

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Load Balancer (NGINX)                   │
│              Proxy :5000  │  Tracker :5003                 │
└─────────────────┬───────────────┬───────────────────────────┘
                  │               │
    ┌─────────────┴─────────────┬─┴─────────────┬─────────────┐
    │                           │               │             │
┌───▼────┐                 ┌───▼────┐      ┌───▼────┐        │
│ Node 1 │                 │ Node 2 │      │ Node 3 │        │
│────────│                 │────────│      │────────│        │
│Proxy   │                 │Proxy   │      │Proxy   │        │
│Origin  │◄────────────────┤Origin  │◄─────┤Origin  │        │
│Tracker │                 │Tracker │      │Tracker │        │
│Build-Idx│                │Build-Idx│     │Build-Idx│       │
│Redis   │◄────Cluster─────┤Redis   │◄─────┤Redis   │        │
└────────┘                 └────────┘      └────────┘        │
     ▲                          ▲               ▲            │
     │                          │               │            │
┌────┴──────────────────────────┴───────────────┴────────────┘
│                    P2P Network                             │
│                                                            │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│  │Agent VM1│  │Agent VM2│  │Agent VM3│  │Agent VMn│       │
│  │:8080    │  │:8080    │  │:8080    │  │:8080    │       │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## 🔧 Configuration

### Environment Configuration (`.env`)

Key configuration sections:

**Cluster Nodes:**
```bash
CLUSTER_NODE_1=10.0.1.10
CLUSTER_NODE_2=10.0.1.11
CLUSTER_NODE_3=10.0.1.12
```

**Service Ports:**
```bash
ORIGIN_PORT=8080
TRACKER_PORT=8081
BUILD_INDEX_PORT=8082
PROXY_PORT=8083
LB_PROXY_PORT=5000
LB_TRACKER_PORT=5003
```

**Production Settings:**
```bash
ENABLE_TLS=true
RECOVERY_ENABLED=true
AUTO_BACKUP=true
BACKUP_SCHEDULE="0 2 * * *"
```

## 🛠️ Management Scripts

### Core Operations
- **`production_deploy.sh`** - Complete production deployment automation
- **`cluster_recovery.sh`** - Auto-healing and recovery monitoring
- **`backup_recovery.sh`** - Backup creation and disaster recovery
- **`performance_monitor.sh`** - Performance monitoring and optimization

### Testing & Validation
- **`cluster_status.sh`** - Real-time cluster health monitoring
- **`e2e_test.sh`** - Comprehensive end-to-end testing
- **`test_cluster.sh`** - Basic cluster functionality tests

### Agent Management
- **`deploy_agent.sh`** - Deploy standardized agent to VMs
- **`install_agent.sh`** - Agent installation script for VMs
- **`kraken-pull.sh`** - Normalized image pulling for agents

## 📊 Monitoring & Alerting

### Performance Monitoring
```bash
# Real-time monitoring
./scripts/performance_monitor.sh watch

# One-time metrics
./scripts/performance_monitor.sh monitor

# Apply optimizations
./scripts/performance_monitor.sh optimize
```

### Health Monitoring
```bash
# Continuous health monitoring with auto-recovery
./scripts/cluster_recovery.sh monitor

# One-time health check
./scripts/cluster_recovery.sh check

# Force recovery
./scripts/cluster_recovery.sh recover
```

### Status Dashboard
```bash
# Comprehensive status
./test/cluster_status.sh

# Service-specific checks
curl http://cluster-node:5000/health
curl http://cluster-node:5003/health
```

## 💾 Backup & Recovery

### Automated Backups
```bash
# Create full backup
./scripts/backup_recovery.sh backup

# List available backups
./scripts/backup_recovery.sh list

# Cleanup old backups
./scripts/backup_recovery.sh cleanup 7
```

### Disaster Recovery
```bash
# Full disaster recovery from latest backup
./scripts/backup_recovery.sh disaster-recovery

# Restore specific component
./scripts/backup_recovery.sh restore /path/to/backup
```

## 🚀 Agent Deployment

### Standardized VM Deployment
```bash
# Deploy to single VM
./scripts/deploy_agent.sh 10.0.2.10

# Deploy to multiple VMs
for vm in 10.0.2.{10..20}; do
    ./scripts/deploy_agent.sh $vm
done
```

### Agent Configuration
Agents are automatically configured with:
- Standardized port allocation (8080)
- Cluster discovery via load balancer
- Optimized P2P settings
- Health monitoring integration

## 🔐 Security Features

### TLS/SSL Support
```bash
# Enable TLS in .env
ENABLE_TLS=true
CERT_PATH=/etc/ssl/certs/kraken.crt
KEY_PATH=/etc/ssl/private/kraken.key
```

### Authentication
```bash
# Enable authentication
ENABLE_AUTH=true
AUTH_SECRET=your-secret-key
```

### Network Security
- Configurable firewall rules
- Secure inter-node communication
- Agent authentication via shared secrets

## 📈 Performance Optimization

### Resource Tuning
- **Memory**: Configurable limits per service
- **CPU**: Multi-core optimization
- **Network**: TCP keepalive and connection pooling
- **Storage**: Optimized caching strategies

### Redis Optimization
- Cluster mode with automatic sharding
- Memory optimization
- Connection pooling
- Performance monitoring

### Load Balancer Tuning
- Health check optimization
- Connection limits
- Timeout configuration
- Round-robin with failover

## 🔍 Troubleshooting

### Common Issues

**Cluster not starting:**
```bash
# Check Docker status
docker ps --filter name=kraken-

# Check logs
docker logs kraken-cluster-node-1

# Force restart
./scripts/cluster_recovery.sh recover
```

**Agent connection issues:**
```bash
# Test connectivity
curl http://cluster-lb:5000/health

# Check agent logs
tail -f /var/log/kraken/agent.log

# Restart agent
systemctl restart kraken-agent
```

**Performance issues:**
```bash
# Check system resources
./scripts/performance_monitor.sh monitor

# Optimize cluster
./scripts/performance_monitor.sh optimize

# Check Redis cluster
redis-cli -h cluster-node -p 6379 cluster info
```

### Log Locations
- **Cluster logs**: `/tmp/kraken-logs/`
- **Container logs**: `docker logs <container>`
- **Agent logs**: `/var/log/kraken/agent.log`
- **Performance logs**: `/tmp/kraken-metrics/`

## 🚀 Production Checklist

Before deploying to production:

- [ ] Customize `.env` configuration
- [ ] Configure TLS certificates
- [ ] Set up monitoring alerts
- [ ] Configure backup schedule
- [ ] Test disaster recovery
- [ ] Validate network connectivity
- [ ] Configure firewall rules
- [ ] Test agent deployment
- [ ] Run comprehensive tests
- [ ] Document environment specifics

## 📞 Support

For issues and questions:
1. Check logs in `/tmp/kraken-logs/`
2. Run diagnostic tests: `./test/e2e_test.sh`
3. Check cluster status: `./test/cluster_status.sh`
4. Review performance metrics: `./scripts/performance_monitor.sh monitor`

## 🔄 Updates & Maintenance

### Regular Maintenance
```bash
# Weekly health check
./test/e2e_test.sh

# Monthly optimization
./scripts/performance_monitor.sh optimize

# Backup verification
./scripts/backup_recovery.sh list
```

### Updating Kraken
```bash
# Update configuration
vim .env  # Update KRAKEN_VERSION

# Redeploy with new version
./scripts/production_deploy.sh
```

This distributed setup provides enterprise-grade reliability, monitoring, and management capabilities for production BMS environments.
