#!/bin/bash

# Deploy High-Availability Kraken Cluster

CLUSTER_NODES=(
    "${1:-10.0.1.100}"
    "${2:-10.0.1.101}" 
    "${3:-10.0.1.102}"
)

if [ ${#CLUSTER_NODES[@]} -ne 3 ]; then
    echo "Usage: ./deploy_cluster.sh <node1_ip> <node2_ip> <node3_ip>"
    echo "Example: ./deploy_cluster.sh 10.0.1.100 10.0.1.101 10.0.1.102"
    exit 1
fi

export CLUSTER_NODE_1=${CLUSTER_NODES[0]}
export CLUSTER_NODE_2=${CLUSTER_NODES[1]}
export CLUSTER_NODE_3=${CLUSTER_NODES[2]}

echo "=== Deploying Kraken High-Availability Cluster ==="
echo "Cluster Nodes:"
echo "  - Node 1: ${CLUSTER_NODE_1}"
echo "  - Node 2: ${CLUSTER_NODE_2}"
echo "  - Node 3: ${CLUSTER_NODE_3}"

# Build cluster images
echo "Building cluster images..."
make images

# Deploy cluster nodes
for i in {1..3}; do
    node_ip=${CLUSTER_NODES[$((i-1))]}
    echo "Deploying Node ${i} on ${node_ip}..."
    
    NODE_ID=${i} NODE_IP=${node_ip} ./examples/distributed/cluster/cluster_start_node.sh
    
    # Wait between nodes
    sleep 30
done

# Wait for cluster to stabilize
echo "Waiting for cluster to stabilize..."
sleep 60

# Deploy load balancer
echo "Deploying load balancer..."
./examples/distributed/cluster/load_balancer_start.sh

echo ""
echo "=== Cluster Deployment Complete! ==="
echo ""
echo "Load Balanced Endpoints:"
echo "  - Push Images: docker push localhost:5000/<image>:<tag>"
echo "  - Tracker: localhost:5003"
echo ""
echo "Direct Node Access:"
for i in {1..3}; do
    node_ip=${CLUSTER_NODES[$((i-1))]}
    echo "  - Node ${i}: ${node_ip}:15000 (proxy), ${node_ip}:15003 (tracker)"
done
echo ""
echo "Next: Deploy agents on VMs using:"
echo "  ./scripts/deploy_agent.sh"
