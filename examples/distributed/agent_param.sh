#!/bin/bash

# Agent deployment configuration for VMs

# Standard agent ports (same across all VMs)
AGENT_REGISTRY_PORT=16000
AGENT_PEER_PORT=16001
AGENT_SERVER_PORT=16002

# Cluster discovery endpoints (load balanced)
CLUSTER_LB_PROXY=${CLUSTER_LB_PROXY:-"kraken-cluster.local:5000"}
CLUSTER_LB_TRACKER=${CLUSTER_LB_TRACKER:-"kraken-cluster.local:5003"}

# Direct cluster nodes (fallback)
CLUSTER_NODES=(
    "${CLUSTER_NODE_1:-10.0.1.100}"
    "${CLUSTER_NODE_2:-10.0.1.101}"
    "${CLUSTER_NODE_3:-10.0.1.102}"
)

# Agent VM configuration
VM_ID=${VM_ID:-$(hostname)}
VM_IP=${VM_IP:-$(hostname -I | awk '{print $1}')}

# Container configuration
AGENT_CONTAINER_NAME="kraken-agent"
AGENT_IMAGE="kraken-agent:distributed"

# Network configuration
BIND_ADDRESS="0.0.0.0"

# Cache configuration
CACHE_SIZE=${CACHE_SIZE:-"10GB"}
CACHE_DIR="/var/lib/kraken/cache"
