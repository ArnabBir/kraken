#!/bin/bash

# Distributed Kraken Cluster Configuration

# Common ports for all components (reserved across cluster)
PROXY_PORT=15000
ORIGIN_PORT=15002
TRACKER_PORT=15003
BUILD_INDEX_PORT=15004
TESTFS_PORT=14000
REDIS_PORT=14001

# Load balancer ports
LB_PROXY_PORT=5000
LB_TRACKER_PORT=5003

# Agent standardized ports (same on all VMs)
AGENT_REGISTRY_PORT=16000
AGENT_PEER_PORT=16001
AGENT_SERVER_PORT=16002

# High Availability Configuration
CLUSTER_NODES=${CLUSTER_NODES:-3}
REDIS_CLUSTER_ENABLED=${REDIS_CLUSTER_ENABLED:-true}

# Network configuration
CLUSTER_NETWORK="kraken-cluster"
BIND_ADDRESS="0.0.0.0"

# Cluster node discovery
CLUSTER_NODE_1=${CLUSTER_NODE_1:-"10.0.1.100"}
CLUSTER_NODE_2=${CLUSTER_NODE_2:-"10.0.1.101"}
CLUSTER_NODE_3=${CLUSTER_NODE_3:-"10.0.1.102"}

# Current node configuration
NODE_ID=${NODE_ID:-1}
NODE_IP=${NODE_IP:-"localhost"}

# Storage backend (shared across cluster)
STORAGE_TYPE=${STORAGE_TYPE:-"redis"}  # redis, s3, or shared-fs
REDIS_CLUSTER_HOSTS="${CLUSTER_NODE_1}:${REDIS_PORT},${CLUSTER_NODE_2}:${REDIS_PORT},${CLUSTER_NODE_3}:${REDIS_PORT}"

# Load balancer configuration
LB_ALGORITHM=${LB_ALGORITHM:-"round_robin"}  # round_robin, least_conn, ip_hash
