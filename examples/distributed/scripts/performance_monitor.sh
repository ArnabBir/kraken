#!/bin/bash

# Performance Tuning and Monitoring Script for Kraken Distributed Cluster

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

source "$(dirname "$0")/../cluster_param.sh"

METRICS_DIR="/tmp/kraken-metrics"
mkdir -p "$METRICS_DIR"

# System resource monitoring
monitor_resources() {
    echo -e "${BLUE}=== System Resource Monitoring ===${NC}"
    
    # CPU and Memory usage
    echo "System Resources:"
    echo "  CPU Usage: $(top -l 1 | grep "CPU usage" | awk '{print $3}' | sed 's/%//')"
    echo "  Memory Usage: $(memory_pressure | grep "System-wide memory free" | awk '{print $5}')"
    echo "  Load Average: $(uptime | awk -F'load averages:' '{print $2}')"
    echo ""
    
    # Docker container resources
    echo "Container Resources:"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep kraken
    echo ""
}

# Network performance monitoring
monitor_network() {
    echo -e "${BLUE}=== Network Performance ===${NC}"
    
    # Test latency between nodes
    echo "Node Connectivity:"
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        latency=$(ping -c 1 "$node_ip" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' || echo "N/A")
        echo "  Node $i ($node_ip): ${latency}ms"
    done
    echo ""
    
    # Load balancer response times
    echo "Load Balancer Performance:"
    proxy_time=$(curl -o /dev/null -s -w "%{time_total}" "http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/health")
    tracker_time=$(curl -o /dev/null -s -w "%{time_total}" "http://${CLUSTER_NODE_1}:${LB_TRACKER_PORT}/health")
    echo "  Proxy LB Response: ${proxy_time}s"
    echo "  Tracker LB Response: ${tracker_time}s"
    echo ""
}

# Redis cluster performance
monitor_redis() {
    echo -e "${BLUE}=== Redis Cluster Performance ===${NC}"
    
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        echo "Node $i Redis Stats:"
        redis_info=$(redis-cli -h "$node_ip" -p "$REDIS_PORT" info stats 2>/dev/null || echo "unavailable")
        
        if [[ "$redis_info" != "unavailable" ]]; then
            ops_per_sec=$(echo "$redis_info" | grep "instantaneous_ops_per_sec" | cut -d: -f2 | tr -d '\r')
            used_memory=$(redis-cli -h "$node_ip" -p "$REDIS_PORT" info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
            connected_clients=$(echo "$redis_info" | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
            
            echo "  Operations/sec: $ops_per_sec"
            echo "  Memory Used: $used_memory"
            echo "  Connected Clients: $connected_clients"
        else
            echo "  Status: Unavailable"
        fi
        echo ""
    done
}

# Kraken service performance
monitor_kraken_services() {
    echo -e "${BLUE}=== Kraken Services Performance ===${NC}"
    
    # Origin service metrics
    echo "Origin Service Metrics:"
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        # Check blob count and size
        blob_info=$(curl -s "http://${node_ip}:${ORIGIN_PORT}/blobs" 2>/dev/null || echo "unavailable")
        if [[ "$blob_info" != "unavailable" ]]; then
            echo "  Node $i: Origin service responding"
        else
            echo "  Node $i: Origin service unavailable"
        fi
    done
    echo ""
    
    # Tracker service metrics
    echo "Tracker Service Metrics:"
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        tracker_info=$(curl -s "http://${node_ip}:${TRACKER_PORT}/health" 2>/dev/null || echo "unavailable")
        if [[ "$tracker_info" == *"ok"* ]]; then
            echo "  Node $i: Tracker service healthy"
        else
            echo "  Node $i: Tracker service unhealthy"
        fi
    done
    echo ""
}

# Generate performance recommendations
generate_recommendations() {
    echo -e "${BLUE}=== Performance Recommendations ===${NC}"
    
    # Check CPU usage
    cpu_usage=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | sed 's/%//')
    if (( $(echo "$cpu_usage > 80" | bc -l) )); then
        echo -e "${YELLOW}⚠ High CPU usage detected ($cpu_usage%). Consider:${NC}"
        echo "  - Adding more cluster nodes"
        echo "  - Optimizing container resource limits"
        echo "  - Load balancing configuration tuning"
    fi
    
    # Check memory usage
    available_memory=$(vm_stat | grep "Pages free:" | awk '{print $3}' | sed 's/\.//')
    if [[ "$available_memory" -lt 100000 ]]; then
        echo -e "${YELLOW}⚠ Low memory detected. Consider:${NC}"
        echo "  - Increasing system memory"
        echo "  - Tuning Redis memory settings"
        echo "  - Optimizing container memory limits"
    fi
    
    # Check network latency
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        latency=$(ping -c 1 "$node_ip" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | sed 's/ms//' || echo "999")
        if (( $(echo "$latency > 10" | bc -l) )); then
            echo -e "${YELLOW}⚠ High latency to Node $i (${latency}ms). Consider:${NC}"
            echo "  - Network optimization"
            echo "  - Closer geographic placement"
            echo "  - Network hardware upgrades"
        fi
    done
    
    # Redis performance check
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        ops_per_sec=$(redis-cli -h "$node_ip" -p "$REDIS_PORT" info stats 2>/dev/null | grep "instantaneous_ops_per_sec" | cut -d: -f2 | tr -d '\r' || echo "0")
        if [[ "$ops_per_sec" -gt 1000 ]]; then
            echo -e "${GREEN}✓ Redis Node $i performing well (${ops_per_sec} ops/sec)${NC}"
        elif [[ "$ops_per_sec" -gt 0 ]]; then
            echo -e "${YELLOW}⚠ Redis Node $i low activity (${ops_per_sec} ops/sec)${NC}"
        fi
    done
    
    echo ""
}

# Log metrics to file
log_metrics() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local metrics_file="$METRICS_DIR/performance-$(date '+%Y%m%d').log"
    
    {
        echo "[$timestamp] Performance Metrics"
        echo "CPU: $(top -l 1 | grep "CPU usage" | awk '{print $3}')"
        echo "Memory: $(memory_pressure | grep "System-wide memory free" | awk '{print $5}')"
        echo "Load: $(uptime | awk -F'load averages:' '{print $2}')"
        
        for i in 1 2 3; do
            eval node_ip=\$CLUSTER_NODE_$i
            proxy_time=$(curl -o /dev/null -s -w "%{time_total}" "http://${node_ip}:${PROXY_PORT}/v2/" 2>/dev/null || echo "timeout")
            echo "Node $i Proxy Response: ${proxy_time}s"
        done
        echo "---"
    } >> "$metrics_file"
}

# Optimize cluster configuration
optimize_cluster() {
    echo -e "${BLUE}=== Cluster Optimization ===${NC}"
    
    # Optimize Docker containers
    echo "Optimizing Docker containers..."
    docker system prune -f >/dev/null 2>&1 || true
    
    # Optimize Redis
    echo "Optimizing Redis configuration..."
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        # Set Redis optimizations
        redis-cli -h "$node_ip" -p "$REDIS_PORT" config set save "" 2>/dev/null || true
        redis-cli -h "$node_ip" -p "$REDIS_PORT" config set tcp-keepalive 60 2>/dev/null || true
        redis-cli -h "$node_ip" -p "$REDIS_PORT" config set timeout 300 2>/dev/null || true
    done
    
    echo -e "${GREEN}✓ Optimization complete${NC}"
    echo ""
}

# Main execution
case "${1:-monitor}" in
    "monitor")
        echo -e "${BLUE}=== Kraken Cluster Performance Monitor ===${NC}"
        echo "Timestamp: $(date)"
        echo ""
        monitor_resources
        monitor_network
        monitor_redis
        monitor_kraken_services
        generate_recommendations
        log_metrics
        ;;
    "optimize")
        optimize_cluster
        ;;
    "log")
        log_metrics
        echo "Metrics logged to: $METRICS_DIR/"
        ;;
    "watch")
        echo "Starting continuous monitoring (Ctrl+C to stop)..."
        while true; do
            clear
            $0 monitor
            sleep 30
        done
        ;;
    *)
        echo "Usage: $0 [monitor|optimize|log|watch]"
        echo "  monitor:  Show current performance metrics"
        echo "  optimize: Apply performance optimizations"
        echo "  log:      Log metrics to file"
        echo "  watch:    Continuous monitoring"
        exit 1
        ;;
esac
