#!/bin/bash

set -ex

# Validate environment variables
if [ -z "$VM_IP" ]; then
    VM_IP=$(hostname -I | awk '{print $1}')
fi

if [ -z "$VM_ID" ]; then
    VM_ID=$(hostname)
fi

source examples/distributed/agent_param.sh

echo "Starting Kraken Agent on VM ${VM_ID} (${VM_IP})..."

# Create cache directory
mkdir -p ${CACHE_DIR}

# Substitute environment variables in agent config
export CLUSTER_LB_TRACKER CLUSTER_NODE_1 CLUSTER_NODE_2 CLUSTER_NODE_3
export TRACKER_PORT BUILD_INDEX_PORT

envsubst < examples/distributed/config/agent/distributed.yaml > /tmp/agent_config.yaml

# Start Kraken agent
docker run -d \
    --name ${AGENT_CONTAINER_NAME} \
    -p ${AGENT_REGISTRY_PORT}:${AGENT_REGISTRY_PORT} \
    -p ${AGENT_PEER_PORT}:${AGENT_PEER_PORT} \
    -p ${AGENT_SERVER_PORT}:${AGENT_SERVER_PORT} \
    -v /tmp/agent_config.yaml:/etc/kraken/config/agent/distributed.yaml \
    -v ${CACHE_DIR}:/var/lib/kraken/cache \
    -e VM_ID=${VM_ID} \
    -e VM_IP=${VM_IP} \
    --restart unless-stopped \
    ${AGENT_IMAGE} \
    /usr/bin/kraken-agent \
    --config=/etc/kraken/config/agent/distributed.yaml \
    --peer-ip=${VM_IP} \
    --peer-port=${AGENT_PEER_PORT} \
    --agent-server-port=${AGENT_SERVER_PORT} \
    --agent-registry-port=${AGENT_REGISTRY_PORT}

echo "Kraken Agent started successfully!"
echo "Agent available at: ${VM_IP}:${AGENT_REGISTRY_PORT}"
echo "Cache directory: ${CACHE_DIR}"
