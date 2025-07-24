#!/bin/bash

set -ex

# Validate required environment variables
if [ -z "$NODE_ID" ] || [ -z "$NODE_IP" ]; then
    echo "Error: NODE_ID and NODE_IP environment variables are required"
    echo "Usage: NODE_ID=1 NODE_IP=10.0.1.100 ./cluster_start_node.sh"
    exit 1
fi

source examples/distributed/cluster_param.sh

echo "Starting Kraken Cluster Node ${NODE_ID} on ${NODE_IP}..."

# Create network if it doesn't exist
docker network create ${CLUSTER_NETWORK} 2>/dev/null || true

# Start cluster node
docker run -d \
    --name kraken-cluster-node-${NODE_ID} \
    --network ${CLUSTER_NETWORK} \
    -p ${REDIS_PORT}:${REDIS_PORT} \
    -p ${ORIGIN_PORT}:${ORIGIN_PORT} \
    -p ${TRACKER_PORT}:${TRACKER_PORT} \
    -p ${BUILD_INDEX_PORT}:${BUILD_INDEX_PORT} \
    -p ${PROXY_PORT}:${PROXY_PORT} \
    -p ${TESTFS_PORT}:${TESTFS_PORT} \
    -e NODE_ID=${NODE_ID} \
    -e NODE_IP=${NODE_IP} \
    -e CLUSTER_NODE_1=${CLUSTER_NODE_1} \
    -e CLUSTER_NODE_2=${CLUSTER_NODE_2} \
    -e CLUSTER_NODE_3=${CLUSTER_NODE_3} \
    -e REDIS_PORT=${REDIS_PORT} \
    -e ORIGIN_PORT=${ORIGIN_PORT} \
    -e TRACKER_PORT=${TRACKER_PORT} \
    -e BUILD_INDEX_PORT=${BUILD_INDEX_PORT} \
    -e PROXY_PORT=${PROXY_PORT} \
    -v $(pwd)/examples/distributed/config:/etc/kraken/config \
    -v $(pwd)/examples/distributed/cluster_param.sh:/etc/kraken/cluster_param.sh \
    -v $(pwd)/examples/distributed/cluster/cluster_start_processes.sh:/etc/kraken/cluster_start_processes.sh \
    --restart unless-stopped \
    kraken-cluster:dev ./cluster_start_processes.sh

echo "Cluster Node ${NODE_ID} started successfully!"
echo "Services available at:"
echo "  - Redis: ${NODE_IP}:${REDIS_PORT}"
echo "  - Origin: ${NODE_IP}:${ORIGIN_PORT}"
echo "  - Tracker: ${NODE_IP}:${TRACKER_PORT}"
echo "  - Build Index: ${NODE_IP}:${BUILD_INDEX_PORT}"
echo "  - Proxy: ${NODE_IP}:${PROXY_PORT}"
