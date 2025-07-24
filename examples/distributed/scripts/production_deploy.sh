#!/bin/bash

# Production Deployment Script for Kraken Distributed Cluster
# This script automates the deployment of Kraken cluster in production environments

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-production}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
DRY_RUN="${DRY_RUN:-false}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites..."
    
    local missing_tools=()
    
    # Check required tools
    for tool in docker docker-compose redis-cli curl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        return 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running"
        return 1
    fi
    
    # Check available disk space
    local available_space=$(df . | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 5000000 ]; then  # 5GB in KB
        warning "Low disk space detected. Recommended: at least 5GB free"
    fi
    
    # Check memory
    local available_memory=$(free -m | awk 'NR==2{printf "%.0f", $7}')
    if [ "$available_memory" -lt 2048 ]; then  # 2GB
        warning "Low memory detected. Recommended: at least 2GB available"
    fi
    
    success "Prerequisites validation passed"
}

# Load and validate configuration
load_configuration() {
    log "Loading configuration..."
    
    # Load environment configuration
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
        info "Loaded configuration from .env file"
    elif [ -f "$PROJECT_ROOT/.env.template" ]; then
        warning "No .env file found. Using template defaults."
        source "$PROJECT_ROOT/.env.template"
    else
        error "No configuration file found"
        return 1
    fi
    
    # Load cluster parameters
    if [ -f "$PROJECT_ROOT/cluster_param.sh" ]; then
        source "$PROJECT_ROOT/cluster_param.sh"
    else
        error "cluster_param.sh not found"
        return 1
    fi
    
    # Validate required variables
    local required_vars=(
        "CLUSTER_NODE_1" "CLUSTER_NODE_2" "CLUSTER_NODE_3"
        "ORIGIN_PORT" "TRACKER_PORT" "BUILD_INDEX_PORT" "PROXY_PORT"
        "LB_PROXY_PORT" "LB_TRACKER_PORT"
    )
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            error "Required variable $var is not set"
            return 1
        fi
    done
    
    success "Configuration loaded and validated"
}

# Setup directories and permissions
setup_directories() {
    log "Setting up directories..."
    
    local directories=(
        "${DATA_ROOT:-/tmp/kraken-distributed}"
        "${BACKUP_DIR:-/tmp/kraken-backups}"
        "${LOG_DIR:-/tmp/kraken-logs}"
    )
    
    for dir in "${directories[@]}"; do
        if [ "$DRY_RUN" = "false" ]; then
            mkdir -p "$dir"
            chmod 755 "$dir"
        fi
        info "Directory: $dir"
    done
    
    success "Directories setup completed"
}

# Prepare Docker environment
prepare_docker() {
    log "Preparing Docker environment..."
    
    # Create Docker network
    local network_name="${NETWORK_NAME:-kraken-distributed}"
    
    if [ "$DRY_RUN" = "false" ]; then
        if ! docker network ls | grep -q "$network_name"; then
            docker network create "$network_name" || true
        fi
    fi
    
    info "Docker network: $network_name"
    
    # Pull required images
    local images=(
        "${DOCKER_REGISTRY:-gcr.io/uber-container-tools}/kraken-agent:${KRAKEN_VERSION:-latest}"
        "${DOCKER_REGISTRY:-gcr.io/uber-container-tools}/kraken-origin:${KRAKEN_VERSION:-latest}"
        "${DOCKER_REGISTRY:-gcr.io/uber-container-tools}/kraken-tracker:${KRAKEN_VERSION:-latest}"
        "${DOCKER_REGISTRY:-gcr.io/uber-container-tools}/kraken-build-index:${KRAKEN_VERSION:-latest}"
        "${DOCKER_REGISTRY:-gcr.io/uber-container-tools}/kraken-proxy:${KRAKEN_VERSION:-latest}"
        "nginx:alpine"
        "redis:alpine"
    )
    
    for image in "${images[@]}"; do
        if [ "$DRY_RUN" = "false" ]; then
            log "Pulling image: $image"
            docker pull "$image" || warning "Failed to pull $image"
        else
            info "Would pull: $image"
        fi
    done
    
    success "Docker environment prepared"
}

# Deploy cluster nodes
deploy_cluster_nodes() {
    log "Deploying cluster nodes..."
    
    if [ "$DRY_RUN" = "false" ]; then
        cd "$PROJECT_ROOT"
        
        # Start cluster processes
        if [ -f "cluster/cluster_start_processes.sh" ]; then
            ./cluster/cluster_start_processes.sh
        else
            error "Cluster startup script not found"
            return 1
        fi
        
        # Wait for services to start
        sleep 30
        
        # Verify cluster health
        local healthy_nodes=0
        for i in 1 2 3; do
            eval node_ip=\$CLUSTER_NODE_$i
            if curl -s --connect-timeout 5 "http://${node_ip}:${ORIGIN_PORT}/health" | grep -q "ok"; then
                ((healthy_nodes++))
            fi
        done
        
        if [ $healthy_nodes -eq 3 ]; then
            success "All cluster nodes are healthy"
        else
            warning "Only $healthy_nodes/3 nodes are healthy"
        fi
    else
        info "Would deploy cluster nodes"
    fi
}

# Setup monitoring
setup_monitoring() {
    log "Setting up monitoring..."
    
    if [ "$ENABLE_PERFORMANCE_MONITORING" = "true" ]; then
        if [ "$DRY_RUN" = "false" ]; then
            # Start performance monitoring
            if [ -f "$PROJECT_ROOT/scripts/performance_monitor.sh" ]; then
                nohup "$PROJECT_ROOT/scripts/performance_monitor.sh" watch > "${LOG_DIR:-/tmp/kraken-logs}/performance.log" 2>&1 &
                echo $! > /tmp/kraken-performance-monitor.pid
                info "Performance monitoring started (PID: $(cat /tmp/kraken-performance-monitor.pid))"
            fi
        else
            info "Would start performance monitoring"
        fi
    fi
    
    if [ "$RECOVERY_ENABLED" = "true" ]; then
        if [ "$DRY_RUN" = "false" ]; then
            # Start cluster recovery monitoring
            if [ -f "$PROJECT_ROOT/scripts/cluster_recovery.sh" ]; then
                nohup "$PROJECT_ROOT/scripts/cluster_recovery.sh" monitor > "${LOG_DIR:-/tmp/kraken-logs}/recovery.log" 2>&1 &
                echo $! > /tmp/kraken-recovery-monitor.pid
                info "Recovery monitoring started (PID: $(cat /tmp/kraken-recovery-monitor.pid))"
            fi
        else
            info "Would start recovery monitoring"
        fi
    fi
    
    success "Monitoring setup completed"
}

# Setup backup schedule
setup_backup() {
    log "Setting up backup schedule..."
    
    if [ "$AUTO_BACKUP" = "true" ]; then
        local backup_script="$PROJECT_ROOT/scripts/backup_recovery.sh"
        local backup_schedule="${BACKUP_SCHEDULE:-0 2 * * *}"
        
        if [ "$DRY_RUN" = "false" ]; then
            # Add cron job for automatic backups
            (crontab -l 2>/dev/null || true; echo "$backup_schedule $backup_script backup") | crontab -
            info "Backup scheduled: $backup_schedule"
        else
            info "Would schedule backup: $backup_schedule"
        fi
    fi
    
    success "Backup setup completed"
}

# Validate deployment
validate_deployment() {
    log "Validating deployment..."
    
    if [ "$DRY_RUN" = "false" ]; then
        # Run health checks
        if [ -f "$PROJECT_ROOT/test/cluster_status.sh" ]; then
            "$PROJECT_ROOT/test/cluster_status.sh"
        fi
        
        # Run basic tests
        if [ "$RUN_TESTS" = "true" ] && [ -f "$PROJECT_ROOT/test/e2e_test.sh" ]; then
            "$PROJECT_ROOT/test/e2e_test.sh"
        fi
    else
        info "Would run validation tests"
    fi
    
    success "Deployment validation completed"
}

# Generate deployment report
generate_report() {
    log "Generating deployment report..."
    
    local report_file="${LOG_DIR:-/tmp/kraken-logs}/deployment-report-$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" << EOF
Kraken Distributed Cluster Deployment Report
============================================

Deployment Date: $(date)
Environment: $ENVIRONMENT
Deployment Type: $DEPLOYMENT_TYPE
Dry Run: $DRY_RUN

Cluster Configuration:
- Node 1: $CLUSTER_NODE_1
- Node 2: $CLUSTER_NODE_2
- Node 3: $CLUSTER_NODE_3

Service Ports:
- Origin: $ORIGIN_PORT
- Tracker: $TRACKER_PORT
- Build Index: $BUILD_INDEX_PORT
- Proxy: $PROXY_PORT
- Redis: $REDIS_PORT

Load Balancer:
- Proxy LB: $LB_PROXY_PORT
- Tracker LB: $LB_TRACKER_PORT

Data Directories:
- Data Root: ${DATA_ROOT:-/tmp/kraken-distributed}
- Backup Dir: ${BACKUP_DIR:-/tmp/kraken-backups}
- Log Dir: ${LOG_DIR:-/tmp/kraken-logs}

Monitoring:
- Performance Monitoring: ${ENABLE_PERFORMANCE_MONITORING:-false}
- Auto Recovery: ${RECOVERY_ENABLED:-false}
- Auto Backup: ${AUTO_BACKUP:-false}

Container Status:
$(docker ps --filter name=kraken- --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers found")

Network Status:
$(docker network ls --filter name=kraken 2>/dev/null || echo "No networks found")

Deployment Status: $([ "$DRY_RUN" = "false" ] && echo "COMPLETED" || echo "DRY RUN")
EOF
    
    info "Deployment report saved to: $report_file"
    
    # Display summary
    echo ""
    echo -e "${BLUE}=== Deployment Summary ===${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Status: $([ "$DRY_RUN" = "false" ] && echo "DEPLOYED" || echo "DRY RUN")"
    echo "Report: $report_file"
    echo ""
    
    if [ "$DRY_RUN" = "false" ]; then
        echo -e "${GREEN}Kraken Distributed Cluster is ready!${NC}"
        echo ""
        echo "Access points:"
        echo "  Proxy Registry: http://$CLUSTER_NODE_1:$LB_PROXY_PORT"
        echo "  Tracker: http://$CLUSTER_NODE_1:$LB_TRACKER_PORT"
        echo ""
        echo "Management commands:"
        echo "  Status: $PROJECT_ROOT/test/cluster_status.sh"
        echo "  Tests: $PROJECT_ROOT/test/e2e_test.sh"
        echo "  Backup: $PROJECT_ROOT/scripts/backup_recovery.sh backup"
    else
        echo -e "${YELLOW}This was a dry run. Use DRY_RUN=false to actually deploy.${NC}"
    fi
}

# Cleanup function
cleanup() {
    if [ "$1" = "error" ]; then
        error "Deployment failed. Cleaning up..."
        
        if [ "$DRY_RUN" = "false" ]; then
            # Stop any started containers
            docker stop $(docker ps -q --filter name=kraken-) 2>/dev/null || true
            docker rm $(docker ps -aq --filter name=kraken-) 2>/dev/null || true
        fi
    fi
}

# Signal handler
trap 'cleanup error' ERR

# Main deployment flow
main() {
    echo -e "${BLUE}=== Kraken Distributed Cluster Production Deployment ===${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Deployment Type: $DEPLOYMENT_TYPE"
    echo "Dry Run: $DRY_RUN"
    echo ""
    
    validate_prerequisites
    load_configuration
    setup_directories
    prepare_docker
    deploy_cluster_nodes
    setup_monitoring
    setup_backup
    validate_deployment
    generate_report
    
    success "Deployment completed successfully!"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --deployment-type)
            DEPLOYMENT_TYPE="$2"
            shift 2
            ;;
        --help)
            echo "Kraken Distributed Cluster Production Deployment"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --dry-run                 Perform a dry run without making changes"
            echo "  --environment ENV         Set deployment environment (default: prod)"
            echo "  --deployment-type TYPE    Set deployment type (default: production)"
            echo "  --help                    Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  DRY_RUN                   Set to true for dry run"
            echo "  ENVIRONMENT               Deployment environment"
            echo "  DEPLOYMENT_TYPE           Deployment type"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main deployment
main "$@"
