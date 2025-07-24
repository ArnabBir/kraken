#!/bin/bash

# Cluster Status Monitoring Script

source examples/distributed/cluster_param.sh

echo "=== Kraken Distributed Cluster Status ==="
echo "Timestamp: $(date)"
echo ""

# Check Load Balancer
echo "Load Balancer Status:"
echo "  Proxy LB (5000): $(curl -s http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/health 2>/dev/null || echo 'DOWN')"
echo "  Tracker LB (5003): $(curl -s http://${CLUSTER_NODE_1}:${LB_TRACKER_PORT}/health 2>/dev/null || echo 'DOWN')"
echo ""

# Check Cluster Nodes
echo "Cluster Nodes:"
for i in 1 2 3; do
    eval node_ip=\$CLUSTER_NODE_$i
    echo "  Node $i ($node_ip):"
    echo "    Proxy: $(curl -s http://${node_ip}:${PROXY_PORT}/v2/ 2>/dev/null && echo 'UP' || echo 'DOWN')"
    echo "    Origin: $(curl -s http://${node_ip}:${ORIGIN_PORT}/health 2>/dev/null && echo 'UP' || echo 'DOWN')"
    echo "    Tracker: $(curl -s http://${node_ip}:${TRACKER_PORT}/health 2>/dev/null && echo 'UP' || echo 'DOWN')"
    echo "    Build Index: $(curl -s http://${node_ip}:${BUILD_INDEX_PORT}/health 2>/dev/null && echo 'UP' || echo 'DOWN')"
    echo "    Redis: $(redis-cli -h ${node_ip} -p ${REDIS_PORT} ping 2>/dev/null || echo 'DOWN')"
done
echo ""

# Check Redis Cluster
echo "Redis Cluster Status:"
redis_status=$(redis-cli -h ${CLUSTER_NODE_1} -p ${REDIS_PORT} cluster info 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "  State: $(echo "$redis_status" | grep cluster_state | cut -d: -f2)"
    echo "  Nodes: $(echo "$redis_status" | grep cluster_known_nodes | cut -d: -f2)"
    echo "  Slots: $(echo "$redis_status" | grep cluster_slots_assigned | cut -d: -f2)/16384"
else
    echo "  Status: DOWN or not clustered"
fi
echo ""

# Check Docker Containers
echo "Container Status:"
for i in 1 2 3; do
    eval node_ip=\$CLUSTER_NODE_$i
    container_status=$(docker ps --filter name=kraken-cluster-node-$i --format "{{.Status}}" 2>/dev/null)
    if [ -n "$container_status" ]; then
        echo "  Node $i Container: $container_status"
    else
        echo "  Node $i Container: NOT RUNNING"
    fi
done

lb_status=$(docker ps --filter name=kraken-load-balancer --format "{{.Status}}" 2>/dev/null)
if [ -n "$lb_status" ]; then
    echo "  Load Balancer: $lb_status"
else
    echo "  Load Balancer: NOT RUNNING"
fi
echo ""

# Performance Metrics
echo "Performance Metrics:"
echo "  Load Balancer Connections:"
docker exec kraken-load-balancer nginx -T 2>/dev/null | grep -c "upstream\|server" || echo "  Unable to get metrics"

echo ""
echo "=== Status Check Complete ==="
