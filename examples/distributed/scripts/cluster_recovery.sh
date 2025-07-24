#!/bin/bash

# Cluster Recovery and Auto-healing Script
# This script monitors the cluster and automatically recovers failed components

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source configuration
source "$(dirname "$0")/../cluster_param.sh"

LOG_FILE="/tmp/kraken-cluster-recovery.log"
RECOVERY_ENABLED=${RECOVERY_ENABLED:-true}
CHECK_INTERVAL=${CHECK_INTERVAL:-30}
MAX_RECOVERY_ATTEMPTS=${MAX_RECOVERY_ATTEMPTS:-3}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if a service is healthy
check_service_health() {
    local service_name=$1
    local endpoint=$2
    local expected_response=$3
    
    response=$(curl -s --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || echo "ERROR")
    
    if [[ "$response" == *"$expected_response"* ]]; then
        return 0
    else
        return 1
    fi
}

# Check Redis cluster health
check_redis_health() {
    local node_ip=$1
    redis-cli -h "$node_ip" -p "$REDIS_PORT" --connect-timeout 5000 ping >/dev/null 2>&1
}

# Restart a failed container
restart_container() {
    local container_name=$1
    local node_id=$2
    
    log "${YELLOW}Attempting to restart container: $container_name${NC}"
    
    # Stop the container if it's running
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Restart based on container type
    case $container_name in
        "kraken-cluster-node-"*)
            cd "$(dirname "$0")/.."
            ./cluster/cluster_start_node.sh "$node_id"
            ;;
        "kraken-load-balancer")
            cd "$(dirname "$0")/.."
            ./cluster/load_balancer_start.sh
            ;;
        *)
            log "${RED}Unknown container type: $container_name${NC}"
            return 1
            ;;
    esac
    
    # Wait for container to start
    sleep 10
    
    if docker ps | grep -q "$container_name"; then
        log "${GREEN}Successfully restarted: $container_name${NC}"
        return 0
    else
        log "${RED}Failed to restart: $container_name${NC}"
        return 1
    fi
}

# Recover Redis cluster
recover_redis_cluster() {
    log "${YELLOW}Attempting Redis cluster recovery${NC}"
    
    # Try to fix the cluster
    redis-cli -h "$CLUSTER_NODE_1" -p "$REDIS_PORT" cluster fix 2>/dev/null || true
    
    # Reset cluster if necessary
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        if ! check_redis_health "$node_ip"; then
            log "${YELLOW}Resetting Redis node: $node_ip${NC}"
            redis-cli -h "$node_ip" -p "$REDIS_PORT" cluster reset hard 2>/dev/null || true
        fi
    done
    
    # Recreate cluster
    echo "yes" | redis-cli --cluster create \
        "${CLUSTER_NODE_1}:${REDIS_PORT}" \
        "${CLUSTER_NODE_2}:${REDIS_PORT}" \
        "${CLUSTER_NODE_3}:${REDIS_PORT}" \
        --cluster-replicas 0 2>/dev/null || true
        
    sleep 5
}

# Main monitoring loop
monitor_cluster() {
    local recovery_attempts=0
    
    log "${BLUE}Starting cluster monitoring (interval: ${CHECK_INTERVAL}s)${NC}"
    
    while true; do
        failed_services=()
        
        # Check Load Balancer
        if ! check_service_health "Load Balancer Proxy" "http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/health" "healthy"; then
            failed_services+=("load_balancer_proxy")
        fi
        
        if ! check_service_health "Load Balancer Tracker" "http://${CLUSTER_NODE_1}:${LB_TRACKER_PORT}/health" "healthy"; then
            failed_services+=("load_balancer_tracker")
        fi
        
        # Check Cluster Nodes
        for i in 1 2 3; do
            eval node_ip=\$CLUSTER_NODE_$i
            
            # Check services on each node
            if ! check_service_health "Proxy Node $i" "http://${node_ip}:${PROXY_PORT}/v2/" "{}"; then
                failed_services+=("node_${i}_proxy")
            fi
            
            if ! check_service_health "Origin Node $i" "http://${node_ip}:${ORIGIN_PORT}/health" "ok"; then
                failed_services+=("node_${i}_origin")
            fi
            
            if ! check_service_health "Tracker Node $i" "http://${node_ip}:${TRACKER_PORT}/health" "ok"; then
                failed_services+=("node_${i}_tracker")
            fi
            
            if ! check_service_health "Build Index Node $i" "http://${node_ip}:${BUILD_INDEX_PORT}/health" "ok"; then
                failed_services+=("node_${i}_build_index")
            fi
            
            if ! check_redis_health "$node_ip"; then
                failed_services+=("node_${i}_redis")
            fi
        done
        
        # Check Redis cluster state
        redis_status=$(redis-cli -h "${CLUSTER_NODE_1}" -p "${REDIS_PORT}" cluster info 2>/dev/null || echo "cluster_state:fail")
        if [[ "$redis_status" != *"cluster_state:ok"* ]]; then
            failed_services+=("redis_cluster")
        fi
        
        # Recovery actions
        if [ ${#failed_services[@]} -gt 0 ]; then
            log "${RED}Failed services detected: ${failed_services[*]}${NC}"
            
            if [ "$RECOVERY_ENABLED" = "true" ] && [ $recovery_attempts -lt $MAX_RECOVERY_ATTEMPTS ]; then
                ((recovery_attempts++))
                log "${YELLOW}Starting recovery attempt $recovery_attempts/$MAX_RECOVERY_ATTEMPTS${NC}"
                
                # Restart failed containers
                for service in "${failed_services[@]}"; do
                    case $service in
                        "load_balancer_"*)
                            restart_container "kraken-load-balancer" ""
                            ;;
                        "node_"*"_"*)
                            node_id=$(echo "$service" | cut -d'_' -f2)
                            restart_container "kraken-cluster-node-$node_id" "$node_id"
                            ;;
                        "redis_cluster")
                            recover_redis_cluster
                            ;;
                    esac
                done
                
                log "${BLUE}Recovery attempt completed. Waiting for services to stabilize...${NC}"
                sleep 30
            else
                if [ $recovery_attempts -ge $MAX_RECOVERY_ATTEMPTS ]; then
                    log "${RED}Maximum recovery attempts reached. Manual intervention required.${NC}"
                    # Send alert (could integrate with monitoring systems)
                    echo "CRITICAL: Kraken cluster requires manual intervention" | wall 2>/dev/null || true
                fi
            fi
        else
            recovery_attempts=0
            log "${GREEN}All services healthy${NC}"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Signal handlers
cleanup() {
    log "${BLUE}Stopping cluster monitoring${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main execution
case "${1:-monitor}" in
    "monitor")
        monitor_cluster
        ;;
    "check")
        log "${BLUE}Performing one-time health check${NC}"
        # Run monitoring loop once
        CHECK_INTERVAL=0
        monitor_cluster
        exit 0
        ;;
    "recover")
        log "${BLUE}Forcing recovery of all services${NC}"
        RECOVERY_ENABLED=true
        MAX_RECOVERY_ATTEMPTS=1
        monitor_cluster
        ;;
    *)
        echo "Usage: $0 [monitor|check|recover]"
        echo "  monitor: Continuous monitoring (default)"
        echo "  check:   One-time health check"
        echo "  recover: Force recovery attempt"
        exit 1
        ;;
esac
