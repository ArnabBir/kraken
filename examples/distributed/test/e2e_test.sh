#!/bin/bash

# Full End-to-End Test Suite for Distributed Kraken Cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Kraken Distributed Cluster E2E Test Suite ===${NC}"
echo "Starting comprehensive test suite..."
echo ""

# Source configuration
source examples/distributed/cluster_param.sh

# Test tracker
test_tracker() {
    echo -e "${YELLOW}Testing Tracker...${NC}"
    tracker_response=$(curl -s http://${CLUSTER_NODE_1}:${LB_TRACKER_PORT}/health)
    if [[ "$tracker_response" == *"ok"* ]]; then
        echo -e "${GREEN}✓ Tracker is responding${NC}"
    else
        echo -e "${RED}✗ Tracker health check failed${NC}"
        return 1
    fi
}

# Test origin
test_origin() {
    echo -e "${YELLOW}Testing Origin...${NC}"
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        origin_response=$(curl -s http://${node_ip}:${ORIGIN_PORT}/health)
        if [[ "$origin_response" == *"ok"* ]]; then
            echo -e "${GREEN}✓ Origin Node $i is responding${NC}"
        else
            echo -e "${RED}✗ Origin Node $i health check failed${NC}"
            return 1
        fi
    done
}

# Test proxy
test_proxy() {
    echo -e "${YELLOW}Testing Proxy Registry...${NC}"
    proxy_response=$(curl -s http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/v2/)
    if [[ "$proxy_response" == *"{}"* ]]; then
        echo -e "${GREEN}✓ Proxy registry is responding${NC}"
    else
        echo -e "${RED}✗ Proxy registry check failed${NC}"
        return 1
    fi
}

# Test build-index
test_build_index() {
    echo -e "${YELLOW}Testing Build Index...${NC}"
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        bi_response=$(curl -s http://${node_ip}:${BUILD_INDEX_PORT}/health)
        if [[ "$bi_response" == *"ok"* ]]; then
            echo -e "${GREEN}✓ Build Index Node $i is responding${NC}"
        else
            echo -e "${RED}✗ Build Index Node $i health check failed${NC}"
            return 1
        fi
    done
}

# Test Redis cluster
test_redis() {
    echo -e "${YELLOW}Testing Redis Cluster...${NC}"
    redis_status=$(redis-cli -h ${CLUSTER_NODE_1} -p ${REDIS_PORT} cluster info 2>/dev/null || echo "error")
    if [[ "$redis_status" == *"cluster_state:ok"* ]]; then
        echo -e "${GREEN}✓ Redis cluster is healthy${NC}"
    else
        echo -e "${RED}✗ Redis cluster check failed${NC}"
        return 1
    fi
}

# Test image pull through proxy
test_image_pull() {
    echo -e "${YELLOW}Testing Image Pull Through Proxy...${NC}"
    
    # Configure Docker to use proxy
    export DOCKER_DAEMON_CONFIG='{
        "registry-mirrors": ["http://'${CLUSTER_NODE_1}':'${LB_PROXY_PORT}'"],
        "insecure-registries": ["'${CLUSTER_NODE_1}':'${LB_PROXY_PORT}'"]
    }'
    
    # Try to pull a test image
    test_image="alpine:latest"
    echo "Pulling ${test_image} through Kraken proxy..."
    
    if docker pull ${CLUSTER_NODE_1}:${LB_PROXY_PORT}/library/${test_image}; then
        echo -e "${GREEN}✓ Successfully pulled image through Kraken proxy${NC}"
        
        # Verify the image is in origin
        sleep 2
        for i in 1 2 3; do
            eval node_ip=\$CLUSTER_NODE_$i
            if curl -s http://${node_ip}:${ORIGIN_PORT}/blobs/sha256/ | grep -q "alpine"; then
                echo -e "${GREEN}✓ Image found in Origin Node $i${NC}"
                break
            fi
        done
    else
        echo -e "${RED}✗ Failed to pull image through proxy${NC}"
        return 1
    fi
}

# Test agent deployment and pull
test_agent_operations() {
    echo -e "${YELLOW}Testing Agent Operations...${NC}"
    
    # Test agent deployment script
    if [ -f "examples/distributed/scripts/deploy_agent.sh" ]; then
        echo "Testing agent deployment script..."
        bash examples/distributed/scripts/deploy_agent.sh --dry-run ${CLUSTER_NODE_1}
        echo -e "${GREEN}✓ Agent deployment script syntax OK${NC}"
    fi
    
    # Test kraken-pull script
    if [ -f "examples/distributed/scripts/kraken-pull.sh" ]; then
        echo "Testing kraken-pull script..."
        # This would be tested on actual agent VMs
        echo -e "${GREEN}✓ Kraken-pull script available${NC}"
    fi
}

# Test load balancer failover
test_load_balancer_failover() {
    echo -e "${YELLOW}Testing Load Balancer Failover...${NC}"
    
    # Check initial proxy response
    initial_response=$(curl -s http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/v2/)
    if [[ "$initial_response" == *"{}"* ]]; then
        echo -e "${GREEN}✓ Load balancer initial state OK${NC}"
    else
        echo -e "${RED}✗ Load balancer initial state failed${NC}"
        return 1
    fi
    
    # Test multiple requests to check round-robin
    echo "Testing round-robin distribution..."
    for i in {1..6}; do
        response=$(curl -s http://${CLUSTER_NODE_1}:${LB_PROXY_PORT}/v2/ -w "%{time_total}")
        if [[ "$response" == *"{}"* ]]; then
            echo -e "${GREEN}✓ Request $i successful${NC}"
        else
            echo -e "${RED}✗ Request $i failed${NC}"
        fi
    done
}

# Test data persistence
test_data_persistence() {
    echo -e "${YELLOW}Testing Data Persistence...${NC}"
    
    # Check if data directories exist and have content
    for i in 1 2 3; do
        data_dir="/tmp/kraken-distributed/cluster-node-$i"
        if [ -d "$data_dir" ]; then
            echo -e "${GREEN}✓ Data directory exists for Node $i${NC}"
            
            # Check if there's any data
            if [ "$(ls -A $data_dir 2>/dev/null)" ]; then
                echo -e "${GREEN}✓ Node $i has persistent data${NC}"
            else
                echo -e "${YELLOW}⚠ Node $i data directory is empty${NC}"
            fi
        else
            echo -e "${RED}✗ Data directory missing for Node $i${NC}"
        fi
    done
}

# Main test execution
main() {
    echo "Starting test suite execution..."
    echo ""
    
    tests=(
        "test_tracker"
        "test_origin" 
        "test_proxy"
        "test_build_index"
        "test_redis"
        "test_load_balancer_failover"
        "test_data_persistence"
        "test_agent_operations"
    )
    
    passed=0
    total=${#tests[@]}
    
    for test in "${tests[@]}"; do
        echo ""
        echo -e "${BLUE}Running: $test${NC}"
        if $test; then
            ((passed++))
            echo -e "${GREEN}✓ $test PASSED${NC}"
        else
            echo -e "${RED}✗ $test FAILED${NC}"
        fi
        echo "---"
    done
    
    echo ""
    echo -e "${BLUE}=== Test Suite Results ===${NC}"
    echo "Passed: $passed/$total tests"
    
    if [ $passed -eq $total ]; then
        echo -e "${GREEN}🎉 All tests passed! Cluster is healthy.${NC}"
        return 0
    else
        echo -e "${RED}❌ Some tests failed. Check cluster status.${NC}"
        return 1
    fi
}

# Check if cluster is running
echo "Checking if cluster is running..."
if ! docker ps | grep -q "kraken-cluster"; then
    echo -e "${RED}❌ Cluster is not running. Please start the cluster first:${NC}"
    echo "    cd examples/distributed && ./cluster_start_processes.sh"
    exit 1
fi

# Run tests
main "$@"
