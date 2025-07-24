#!/bin/bash

source /etc/kraken/cluster_param.sh

# Start Redis Cluster Node
start_redis_cluster() {
    local node_id=$1
    local bind_ip=$2
    
    echo "Starting Redis cluster node ${node_id} on ${bind_ip}:${REDIS_PORT}"
    
    # Create Redis configuration for clustering
    cat > /tmp/redis-${node_id}.conf <<EOF
port ${REDIS_PORT}
bind ${bind_ip}
cluster-enabled yes
cluster-config-file nodes-${node_id}.conf
cluster-node-timeout 5000
appendonly yes
EOF

    redis-server /tmp/redis-${node_id}.conf &
}

# Start Kraken services with clustering
start_kraken_services() {
    local node_id=$1
    local node_ip=$2
    
    # Wait for Redis to start
    sleep 5
    
    # Substitute environment variables in config files
    export CLUSTER_NODE_1 CLUSTER_NODE_2 CLUSTER_NODE_3
    export REDIS_PORT ORIGIN_PORT TRACKER_PORT BUILD_INDEX_PORT PROXY_PORT
    
    envsubst < /etc/kraken/config/origin/distributed.yaml > /tmp/origin.yaml
    envsubst < /etc/kraken/config/tracker/distributed.yaml > /tmp/tracker.yaml
    envsubst < /etc/kraken/config/build-index/distributed.yaml > /tmp/build-index.yaml
    envsubst < /etc/kraken/config/proxy/distributed.yaml > /tmp/proxy.yaml

    # Start Origin
    /usr/bin/kraken-origin \
        --config=/tmp/origin.yaml \
        --blobserver-hostname=${node_ip} \
        --blobserver-port=${ORIGIN_PORT} \
        --peer-ip=${node_ip} \
        --peer-port=$((ORIGIN_PORT + 1000)) \
        &>/var/log/kraken/kraken-origin/stdout.log &

    # Start Tracker
    /usr/bin/kraken-tracker \
        --config=/tmp/tracker.yaml \
        --port=${TRACKER_PORT} \
        --addr=${BIND_ADDRESS}:${TRACKER_PORT} \
        &>/var/log/kraken/kraken-tracker/stdout.log &

    # Start Build Index
    /usr/bin/kraken-build-index \
        --config=/tmp/build-index.yaml \
        --port=${BUILD_INDEX_PORT} \
        --addr=${BIND_ADDRESS}:${BUILD_INDEX_PORT} \
        &>/var/log/kraken/kraken-build-index/stdout.log &

    # Start Proxy
    /usr/bin/kraken-proxy \
        --config=/tmp/proxy.yaml \
        --port=${PROXY_PORT} \
        --server-port=$((PROXY_PORT + 1000)) \
        --addr=${BIND_ADDRESS}:${PROXY_PORT} \
        &>/var/log/kraken/kraken-proxy/stdout.log &
}

# Main startup
echo "Starting Kraken Cluster Node ${NODE_ID} on ${NODE_IP}"

# Start Redis cluster node
start_redis_cluster ${NODE_ID} ${NODE_IP}

# Start Kraken services
start_kraken_services ${NODE_ID} ${NODE_IP}

echo "Kraken Cluster Node ${NODE_ID} started"
echo "Services:"
echo "  - Redis: ${NODE_IP}:${REDIS_PORT}"
echo "  - Origin: ${NODE_IP}:${ORIGIN_PORT}"
echo "  - Tracker: ${NODE_IP}:${TRACKER_PORT}"
echo "  - Build Index: ${NODE_IP}:${BUILD_INDEX_PORT}"
echo "  - Proxy: ${NODE_IP}:${PROXY_PORT}"

# Wait for services to be ready
sleep 10

# Initialize Redis cluster (only on node 1)
if [ "${NODE_ID}" = "1" ]; then
    echo "Initializing Redis cluster..."
    redis-cli --cluster create \
        ${CLUSTER_NODE_1}:${REDIS_PORT} \
        ${CLUSTER_NODE_2}:${REDIS_PORT} \
        ${CLUSTER_NODE_3}:${REDIS_PORT} \
        --cluster-replicas 0 --cluster-yes 2>/dev/null || echo "Cluster already exists"
fi

# Health check and supervisor
while : ; do
    for service in redis-server kraken-origin kraken-tracker kraken-build-index kraken-proxy; do
        if ! pgrep -f $service > /dev/null; then
            echo "Service $service failed. Restarting..."
            # Add restart logic here
        fi
    done
    sleep 30
done
