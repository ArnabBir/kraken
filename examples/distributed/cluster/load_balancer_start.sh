#!/bin/bash

set -ex

source examples/distributed/cluster_param.sh

echo "Starting Kraken Load Balancer..."

# Create network if it doesn't exist
docker network create ${CLUSTER_NETWORK} 2>/dev/null || true

# Substitute environment variables in nginx config
export CLUSTER_NODE_1 CLUSTER_NODE_2 CLUSTER_NODE_3
export PROXY_PORT TRACKER_PORT LB_PROXY_PORT LB_TRACKER_PORT

envsubst < examples/distributed/config/nginx/load_balancer.conf > /tmp/load_balancer.conf

# Start NGINX load balancer
docker run -d \
    --name kraken-load-balancer \
    --network ${CLUSTER_NETWORK} \
    -p ${LB_PROXY_PORT}:${LB_PROXY_PORT} \
    -p ${LB_TRACKER_PORT}:${LB_TRACKER_PORT} \
    -v /tmp/load_balancer.conf:/etc/nginx/nginx.conf \
    --restart unless-stopped \
    nginx:alpine

echo "Load Balancer started successfully!"
echo "Load balanced endpoints:"
echo "  - Proxy (Push): localhost:${LB_PROXY_PORT}"
echo "  - Tracker (P2P): localhost:${LB_TRACKER_PORT}"
