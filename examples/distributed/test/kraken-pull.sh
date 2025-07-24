#!/bin/bash

# kraken-pull.sh - Distributed cluster version with agent endpoint

CLUSTER_LB=${CLUSTER_LB:-localhost:5000}

kraken_pull() {
    local image_name=$1
    local agent_endpoint=$2
    
    # Validate required parameters
    if [ -z "$image_name" ]; then
        echo "Error: Image name is required"
        echo "Usage: kraken-pull.sh <image:tag> <agent_endpoint>"
        echo "Example: kraken-pull.sh company/app:v1.0 localhost:16000"
        return 1
    fi
    
    if [ -z "$agent_endpoint" ]; then
        echo "Error: Agent endpoint is required"
        echo "Usage: kraken-pull.sh <image:tag> <agent_endpoint>"
        echo "Example: kraken-pull.sh company/app:v1.0 localhost:16000"
        return 1
    fi
    
    echo "Pulling ${image_name} from agent: ${agent_endpoint}"
    
    # Try the local agent first (P2P enabled)
    if docker pull ${agent_endpoint}/${image_name}; then
        docker tag ${agent_endpoint}/${image_name} ${image_name}
        docker rmi ${agent_endpoint}/${image_name}
        echo "✓ Successfully pulled via P2P agent: ${image_name}"
        return 0
    fi
    
    # Fallback to cluster load balancer
    echo "Agent pull failed, falling back to cluster: $CLUSTER_LB"
    if docker pull ${CLUSTER_LB}/${image_name}; then
        docker tag ${CLUSTER_LB}/${image_name} ${image_name}
        docker rmi ${CLUSTER_LB}/${image_name}
        echo "✓ Successfully pulled via cluster: ${image_name}"
        return 0
    fi
    
    echo "✗ Failed to pull ${image_name} from both agent and cluster"
    return 1
}

# Validate arguments
if [ $# -lt 2 ]; then
    echo "Error: Missing required arguments"
    echo "Usage: kraken-pull.sh <image:tag> <agent_endpoint>"
    echo ""
    echo "Examples:"
    echo "  # Pull from local agent on VM"
    echo "  kraken-pull.sh company/app:v1.0 localhost:16000"
    echo ""
    echo "  # Pull from specific VM agent"
    echo "  kraken-pull.sh company/app:v1.0 10.0.2.50:16000"
    echo ""
    echo "Environment variables:"
    echo "  CLUSTER_LB - Fallback cluster endpoint (default: localhost:5000)"
    exit 1
fi

# Execute the pull
kraken_pull "$1" "$2"
