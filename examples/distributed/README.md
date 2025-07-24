# Kraken Distributed High-Availability Cluster

This setup provides a production-ready, high-availability Kraken deployment with:
- **3-Node Cluster**: Distributed server-side components with Redis clustering
- **Load Balancing**: NGINX load balancer for proxy and tracker services
- **Standardized Agents**: Uniform agent deployment across VMs with reserved ports
- **Automatic Failover**: Built-in redundancy and health monitoring

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Load Balancer (NGINX)                    │
│  Push: :5000  │  Tracker: :5003  │  Health: /health        │
└─────────────────┬─────────────────┬─────────────────────────┘
                  │                 │
    ┌─────────────┼─────────────────┼─────────────────┐
    │             │                 │                 │
    v             v                 v                 v
┌─────────┐  ┌─────────┐  ┌─────────┐         ┌─────────────┐
│ Node 1  │  │ Node 2  │  │ Node 3  │         │ Redis       │
│ :15000  │  │ :15000  │  │ :15000  │ <-----> │ Cluster     │
│ :15002  │  │ :15002  │  │ :15002  │         │ :14001      │
│ :15003  │  │ :15003  │  │ :15003  │         └─────────────┘
│ :15004  │  │ :15004  │  │ :15004  │
└─────────┘  └─────────┘  └─────────┘
                  │
        ┌─────────┼─────────────────┐
        │         │                 │
        v         v                 v
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │ VM-1    │ │ VM-2    │ │ VM-N    │
    │ Agent   │ │ Agent   │ │ Agent   │
    │ :16000  │ │ :16000  │ │ :16000  │
    │ :16001  │ │ :16001  │ │ :16001  │
    │ :16002  │ │ :16002  │ │ :16002  │
    └─────────┘ └─────────┘ └─────────┘
```

## Components

### Server-Side Cluster (High Availability)
- **3 Cluster Nodes**: Each running Origin, Tracker, Build-Index, Proxy
- **Redis Cluster**: Distributed storage backend with automatic sharding
- **Load Balancer**: NGINX providing failover and load distribution
- **Reserved Ports**: Consistent port allocation across cluster

### Client-Side Agents (VM Deployment)
- **Standardized Ports**: All agents use ports 16000-16002
- **Automatic Discovery**: Connect to cluster via load balancer
- **P2P Distribution**: Efficient inter-VM image sharing
- **Simple Deployment**: Single script installation per VM

## Quick Start

### Prerequisites
- Docker installed on all nodes
- Network connectivity between cluster nodes
- Network connectivity from VMs to cluster

### 1. Deploy High-Availability Cluster

```bash
# Clone repository and navigate to distributed example
cd examples/distributed

# Build required images
make images

# Deploy 3-node cluster with load balancer
./scripts/deploy_cluster.sh 10.0.1.100 10.0.1.101 10.0.1.102
```

This creates:
- **Node 1**: 10.0.1.100 (Proxy, Origin, Tracker, Build-Index, Redis)
- **Node 2**: 10.0.1.101 (Proxy, Origin, Tracker, Build-Index, Redis)
- **Node 3**: 10.0.1.102 (Proxy, Origin, Tracker, Build-Index, Redis)
- **Load Balancer**: Running on Node 1 (ports 5000, 5003)

### 2. Deploy Agents on VMs

```bash
# On each VM, run the agent installation
./scripts/install_agent.sh kraken-cluster.local:5000

# Or with specific parameters
./scripts/install_agent.sh 10.0.1.100:5000 10.0.2.50 vm-worker-01
```

### 3. Test the Setup

```bash
# Test cluster and P2P distribution
./test/test_cluster.sh localhost:5000 localhost:16000
```

## Detailed Deployment Guide

### Step 1: Prepare Cluster Nodes

On each cluster node (10.0.1.100, 10.0.1.101, 10.0.1.102):

```bash
# Install Docker (if not already installed)
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Clone Kraken repository
git clone https://github.com/ArnabBir/kraken.git
cd kraken/examples/distributed

# Build images (only needed on one node, then distribute)
make images
```

### Step 2: Configure Cluster Parameters

Edit cluster configuration if needed:

```bash
# Edit examples/distributed/cluster_param.sh
CLUSTER_NODE_1="10.0.1.100"
CLUSTER_NODE_2="10.0.1.101" 
CLUSTER_NODE_3="10.0.1.102"
```

### Step 3: Deploy Cluster Sequentially

```bash
# Node 1 (Primary)
NODE_ID=1 NODE_IP=10.0.1.100 ./cluster/cluster_start_node.sh

# Wait 30 seconds, then Node 2
NODE_ID=2 NODE_IP=10.0.1.101 ./cluster/cluster_start_node.sh

# Wait 30 seconds, then Node 3  
NODE_ID=3 NODE_IP=10.0.1.102 ./cluster/cluster_start_node.sh

# Wait 60 seconds for cluster to stabilize

# Deploy load balancer (on Node 1 or dedicated LB node)
./cluster/load_balancer_start.sh
```

### Step 4: Verify Cluster Health

```bash
# Check load balancer
curl http://10.0.1.100:5000/health
curl http://10.0.1.100:5003/health

# Check individual nodes
curl http://10.0.1.100:15000/v2/
curl http://10.0.1.101:15000/v2/
curl http://10.0.1.102:15000/v2/

# Check Redis cluster
redis-cli -h 10.0.1.100 -p 14001 cluster nodes
```

### Step 5: Deploy Agents on VMs

Copy agent deployment script to each VM:

```bash
# Copy script to VM
scp -r examples/distributed/scripts/ user@vm-ip:~/kraken-scripts/

# On each VM
cd ~/kraken-scripts/
chmod +x *.sh

# Install agent (pointing to load balancer)
./install_agent.sh 10.0.1.100:5000
```

## Usage Examples

### Push Images (CI/CD)

```bash
# Push to load-balanced cluster
docker tag myapp:v1.0 10.0.1.100:5000/company/myapp:v1.0
docker push 10.0.1.100:5000/company/myapp:v1.0
```

### Pull Images (VM Deployment)

```bash
# Pull from local agent (with P2P distribution)
./test/kraken-pull.sh company/myapp:v1.0 localhost:16000

# Or directly with Docker
docker pull localhost:16000/company/myapp:v1.0
docker tag localhost:16000/company/myapp:v1.0 company/myapp:v1.0
docker rmi localhost:16000/company/myapp:v1.0
```

### Monitor Cluster

```bash
# Check cluster status
./test/cluster_status.sh

# Check agent status on VM
docker logs kraken-agent
docker stats kraken-agent
```

## Configuration Reference

### Reserved Ports

| Component | Port | Purpose |
|-----------|------|---------|
| **Load Balancer** | | |
| Proxy LB | 5000 | Load-balanced push endpoint |
| Tracker LB | 5003 | Load-balanced tracker endpoint |
| **Cluster Nodes** | | |
| Redis | 14001 | Cluster storage backend |
| TestFS | 14000 | File storage backend |
| Proxy | 15000 | Docker registry proxy |
| Origin | 15002 | Blob storage service |
| Tracker | 15003 | P2P coordination |
| Build Index | 15004 | Tag management |
| **VM Agents** | | |
| Registry | 16000 | Docker pull endpoint |
| Peer | 16001 | P2P communication |
| Server | 16002 | Agent management |

### Environment Variables

#### Cluster Configuration
```bash
CLUSTER_NODE_1=10.0.1.100    # Primary cluster node
CLUSTER_NODE_2=10.0.1.101    # Secondary cluster node  
CLUSTER_NODE_3=10.0.1.102    # Tertiary cluster node
NODE_ID=1                    # Current node ID (1-3)
NODE_IP=10.0.1.100          # Current node IP
```

#### Agent Configuration
```bash
CLUSTER_LB_PROXY=10.0.1.100:5000   # Load balanced proxy endpoint
CLUSTER_LB_TRACKER=10.0.1.100:5003 # Load balanced tracker endpoint
VM_IP=10.0.2.50                    # VM IP address
VM_ID=vm-worker-01                  # VM identifier
CACHE_SIZE=10GB                     # Agent cache size
```

## High Availability Features

### Automatic Failover
- **Load Balancer**: NGINX automatically routes around failed nodes
- **Redis Cluster**: Automatic failover with multiple master nodes
- **Service Recovery**: Containers restart automatically on failure

### Health Monitoring
```bash
# Load balancer health
curl http://cluster-ip:5000/health
curl http://cluster-ip:5003/health

# Individual node health
curl http://node-ip:15000/v2/
curl http://node-ip:15003/health

# Agent health
curl http://vm-ip:16000/v2/
```

### Scaling

#### Add Cluster Nodes
```bash
# Add 4th node
NODE_ID=4 NODE_IP=10.0.1.103 ./cluster/cluster_start_node.sh

# Update load balancer config and restart
```

#### Add VM Agents
```bash
# Install on new VM
./scripts/install_agent.sh 10.0.1.100:5000
```

## Troubleshooting

### Cluster Issues

#### Check Redis Cluster Status
```bash
redis-cli -h 10.0.1.100 -p 14001 cluster nodes
redis-cli -h 10.0.1.100 -p 14001 cluster info
```

#### Check Service Logs
```bash
# Cluster node logs
docker logs kraken-cluster-node-1
docker logs kraken-cluster-node-2
docker logs kraken-cluster-node-3

# Load balancer logs
docker logs kraken-load-balancer
```

#### Restart Failed Services
```bash
# Restart cluster node
docker restart kraken-cluster-node-1

# Restart load balancer
docker restart kraken-load-balancer
```

### Agent Issues

#### Check Agent Status
```bash
# Agent logs
docker logs kraken-agent

# Agent resource usage
docker stats kraken-agent

# Network connectivity
curl http://localhost:16000/v2/
```

#### Restart Agent
```bash
# Stop agent
docker stop kraken-agent
docker rm kraken-agent

# Restart agent
./scripts/deploy_agent.sh
```

### Network Issues

#### Test Connectivity
```bash
# From VM to cluster
curl http://cluster-ip:5000/health
curl http://cluster-ip:5003/health

# Between cluster nodes
redis-cli -h node-ip -p 14001 ping
```

#### Check Load Balancer
```bash
# Check upstream status
curl http://cluster-ip:5000/health
curl http://cluster-ip:5003/health

# Check individual nodes
curl http://node1-ip:15000/v2/
curl http://node2-ip:15000/v2/
curl http://node3-ip:15000/v2/
```

## File Structure

```
examples/distributed/
├── README.md                           # This documentation
├── cluster_param.sh                    # Cluster configuration
├── agent_param.sh                      # Agent configuration
├── config/
│   ├── agent/distributed.yaml          # Agent configuration
│   ├── origin/distributed.yaml         # Origin configuration
│   ├── tracker/distributed.yaml        # Tracker configuration
│   ├── build-index/distributed.yaml    # Build index configuration
│   ├── proxy/distributed.yaml          # Proxy configuration
│   └── nginx/load_balancer.conf        # Load balancer configuration
├── cluster/
│   ├── cluster_start_processes.sh      # Cluster node startup
│   ├── cluster_start_node.sh           # Individual node launcher
│   └── load_balancer_start.sh          # Load balancer launcher
├── scripts/
│   ├── deploy_cluster.sh               # Full cluster deployment
│   ├── deploy_agent.sh                 # Agent deployment
│   └── install_agent.sh                # VM agent installation
└── test/
    ├── test_cluster.sh                 # Cluster testing
    ├── kraken-pull.sh                  # Normalized image pull
    └── cluster_status.sh               # Cluster monitoring
```

## Production Considerations

### Security
- Configure TLS for cluster communication
- Set up authentication for Docker registry
- Use proper firewall rules
- Secure Redis cluster communication

### Monitoring
- Deploy Prometheus + Grafana for metrics
- Set up log aggregation (ELK stack)
- Configure alerting for cluster health
- Monitor agent performance across VMs

### Backup & Recovery
- Regular Redis cluster backups
- Configuration backup procedures
- Disaster recovery planning
- Agent image distribution strategy

### Performance Tuning
- Adjust Redis cluster configuration
- Tune NGINX load balancer settings
- Optimize agent cache sizes
- Network bandwidth considerations

This distributed setup provides enterprise-grade reliability and scalability for Docker image distribution across your VM infrastructure.
