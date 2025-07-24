#!/bin/bash

# VM Agent Installation Script
# Run this script on each VM to install the Kraken agent

CLUSTER_LB_ENDPOINT=${1:-"kraken-cluster.local:5000"}
VM_IP=${2:-$(hostname -I | awk '{print $1}')}
VM_ID=${3:-$(hostname)}

if [ -z "$CLUSTER_LB_ENDPOINT" ]; then
    echo "Usage: ./install_agent.sh <cluster_lb_endpoint> [vm_ip] [vm_id]"
    echo "Example: ./install_agent.sh kraken-cluster.local:5000"
    echo "         ./install_agent.sh 10.0.1.100:5000 10.0.2.50 vm-worker-01"
    exit 1
fi

export CLUSTER_LB_PROXY=${CLUSTER_LB_ENDPOINT}
export CLUSTER_LB_TRACKER=${CLUSTER_LB_ENDPOINT/5000/5003}
export VM_IP VM_ID

echo "=== Installing Kraken Agent on VM ==="
echo "VM ID: ${VM_ID}"
echo "VM IP: ${VM_IP}"
echo "Cluster LB Proxy: ${CLUSTER_LB_PROXY}"
echo "Cluster LB Tracker: ${CLUSTER_LB_TRACKER}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

# Create cache directory
sudo mkdir -p /var/lib/kraken/cache
sudo chown $USER:$USER /var/lib/kraken/cache

# Download or copy agent image (if not already available)
if ! docker image inspect kraken-agent:distributed >/dev/null 2>&1; then
    echo "Pulling agent image..."
    # In production, you would pull from your registry
    # docker pull your-registry.com/kraken-agent:distributed
    echo "Note: Agent image should be built/pulled manually"
fi

# Deploy the agent
./examples/distributed/scripts/deploy_agent.sh

echo ""
echo "=== Agent Installation Complete! ==="
echo ""
echo "Agent Services:"
echo "  - Registry: ${VM_IP}:16000"
echo "  - Peer: ${VM_IP}:16001" 
echo "  - Server: ${VM_IP}:16002"
echo ""
echo "Test agent:"
echo "  docker pull ${VM_IP}:16000/<image>:<tag>"
echo ""
echo "Agent logs:"
echo "  docker logs kraken-agent"
