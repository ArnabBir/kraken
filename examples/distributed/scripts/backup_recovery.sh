#!/bin/bash

# Backup and Disaster Recovery Script for Kraken Distributed Cluster

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

source "$(dirname "$0")/../cluster_param.sh"

BACKUP_DIR="${BACKUP_DIR:-/tmp/kraken-backups}"
RESTORE_DIR="${RESTORE_DIR:-/tmp/kraken-restore}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

mkdir -p "$BACKUP_DIR" "$RESTORE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Backup Redis cluster data
backup_redis() {
    log "${BLUE}Backing up Redis cluster data...${NC}"
    
    local backup_path="$BACKUP_DIR/redis_$TIMESTAMP"
    mkdir -p "$backup_path"
    
    for i in 1 2 3; do
        eval node_ip=\$CLUSTER_NODE_$i
        local node_backup="$backup_path/node_$i"
        
        log "Creating Redis backup for Node $i..."
        
        # Create Redis backup
        redis-cli -h "$node_ip" -p "$REDIS_PORT" --rdb "$node_backup.rdb" 2>/dev/null || {
            log "${RED}Failed to backup Redis Node $i${NC}"
            continue
        }
        
        # Save cluster configuration
        redis-cli -h "$node_ip" -p "$REDIS_PORT" cluster nodes > "$node_backup.nodes" 2>/dev/null || true
        redis-cli -h "$node_ip" -p "$REDIS_PORT" info > "$node_backup.info" 2>/dev/null || true
        
        log "${GREEN}✓ Redis Node $i backed up${NC}"
    done
    
    echo "$backup_path" > "$BACKUP_DIR/latest_redis_backup.txt"
    log "${GREEN}Redis backup completed: $backup_path${NC}"
}

# Backup configuration files
backup_configs() {
    log "${BLUE}Backing up configuration files...${NC}"
    
    local config_backup="$BACKUP_DIR/configs_$TIMESTAMP"
    mkdir -p "$config_backup"
    
    # Copy all configuration files
    cp -r "$(dirname "$0")/../config" "$config_backup/" 2>/dev/null || true
    cp "$(dirname "$0")/../cluster_param.sh" "$config_backup/" 2>/dev/null || true
    cp "$(dirname "$0")/../agent_param.sh" "$config_backup/" 2>/dev/null || true
    cp "$(dirname "$0")/../load_balancer.conf" "$config_backup/" 2>/dev/null || true
    
    # Save current environment
    env | grep KRAKEN > "$config_backup/environment.env" 2>/dev/null || true
    
    echo "$config_backup" > "$BACKUP_DIR/latest_config_backup.txt"
    log "${GREEN}Configuration backup completed: $config_backup${NC}"
}

# Backup persistent data
backup_data() {
    log "${BLUE}Backing up persistent data...${NC}"
    
    local data_backup="$BACKUP_DIR/data_$TIMESTAMP"
    mkdir -p "$data_backup"
    
    # Backup origin data from each node
    for i in 1 2 3; do
        local node_data_dir="/tmp/kraken-distributed/cluster-node-$i"
        if [ -d "$node_data_dir" ]; then
            log "Backing up data for Node $i..."
            cp -r "$node_data_dir" "$data_backup/node_$i" 2>/dev/null || {
                log "${YELLOW}Warning: Could not backup data for Node $i${NC}"
            }
        fi
    done
    
    # Backup load balancer logs
    docker logs kraken-load-balancer > "$data_backup/load_balancer.log" 2>/dev/null || true
    
    # Backup container logs
    for i in 1 2 3; do
        docker logs "kraken-cluster-node-$i" > "$data_backup/node_$i.log" 2>/dev/null || true
    done
    
    echo "$data_backup" > "$BACKUP_DIR/latest_data_backup.txt"
    log "${GREEN}Data backup completed: $data_backup${NC}"
}

# Create full backup
create_full_backup() {
    log "${BLUE}=== Creating Full Cluster Backup ===${NC}"
    
    local full_backup="$BACKUP_DIR/full_backup_$TIMESTAMP"
    mkdir -p "$full_backup"
    
    # Check cluster status first
    if ! docker ps | grep -q "kraken-cluster"; then
        log "${YELLOW}Warning: Cluster is not running. Backup may be incomplete.${NC}"
    fi
    
    # Backup all components
    backup_redis
    backup_configs
    backup_data
    
    # Create manifest
    cat > "$full_backup/backup_manifest.txt" << EOF
Kraken Distributed Cluster Backup
Created: $(date)
Timestamp: $TIMESTAMP
Cluster Status: $(docker ps | grep -c "kraken-" || echo "0") containers running

Components Backed Up:
- Redis cluster data
- Configuration files
- Persistent data
- Container logs

Backup Paths:
- Redis: $(cat "$BACKUP_DIR/latest_redis_backup.txt" 2>/dev/null || echo "Failed")
- Configs: $(cat "$BACKUP_DIR/latest_config_backup.txt" 2>/dev/null || echo "Failed")
- Data: $(cat "$BACKUP_DIR/latest_data_backup.txt" 2>/dev/null || echo "Failed")
EOF
    
    # Create compressed archive
    tar -czf "$full_backup.tar.gz" -C "$BACKUP_DIR" \
        "$(basename "$(cat "$BACKUP_DIR/latest_redis_backup.txt")")" \
        "$(basename "$(cat "$BACKUP_DIR/latest_config_backup.txt")")" \
        "$(basename "$(cat "$BACKUP_DIR/latest_data_backup.txt")")" \
        2>/dev/null || {
        log "${YELLOW}Warning: Could not create compressed archive${NC}"
    }
    
    echo "$full_backup.tar.gz" > "$BACKUP_DIR/latest_full_backup.txt"
    log "${GREEN}=== Full backup completed: $full_backup.tar.gz ===${NC}"
}

# Restore Redis cluster
restore_redis() {
    local backup_path=$1
    
    if [ ! -d "$backup_path" ]; then
        log "${RED}Redis backup path not found: $backup_path${NC}"
        return 1
    fi
    
    log "${BLUE}Restoring Redis cluster from: $backup_path${NC}"
    
    # Stop current cluster
    log "Stopping current Redis instances..."
    for i in 1 2 3; do
        docker exec "kraken-cluster-node-$i" pkill redis-server 2>/dev/null || true
    done
    
    sleep 5
    
    # Restore each node
    for i in 1 2 3; do
        local node_backup="$backup_path/node_$i"
        if [ -f "$node_backup.rdb" ]; then
            log "Restoring Redis Node $i..."
            
            eval node_ip=\$CLUSTER_NODE_$i
            
            # Copy backup file to node
            docker cp "$node_backup.rdb" "kraken-cluster-node-$i:/tmp/dump.rdb"
            
            # Start Redis with restored data
            docker exec "kraken-cluster-node-$i" sh -c "
                cp /tmp/dump.rdb /data/dump.rdb
                redis-server --port $REDIS_PORT --cluster-enabled yes --cluster-config-file nodes.conf --daemonize yes
            " 2>/dev/null || {
                log "${RED}Failed to restore Redis Node $i${NC}"
                continue
            }
            
            log "${GREEN}✓ Redis Node $i restored${NC}"
        else
            log "${YELLOW}Warning: No backup found for Redis Node $i${NC}"
        fi
    done
    
    # Wait for cluster to form
    sleep 10
    
    # Verify cluster
    if redis-cli -h "$CLUSTER_NODE_1" -p "$REDIS_PORT" cluster info | grep -q "cluster_state:ok"; then
        log "${GREEN}Redis cluster restoration successful${NC}"
    else
        log "${YELLOW}Redis cluster may need manual intervention${NC}"
    fi
}

# Restore configuration
restore_configs() {
    local backup_path=$1
    
    if [ ! -d "$backup_path" ]; then
        log "${RED}Config backup path not found: $backup_path${NC}"
        return 1
    fi
    
    log "${BLUE}Restoring configurations from: $backup_path${NC}"
    
    # Backup current configs
    local current_backup="/tmp/kraken-config-backup-$(date +%s)"
    mkdir -p "$current_backup"
    cp -r "$(dirname "$0")/../config" "$current_backup/" 2>/dev/null || true
    
    # Restore configs
    cp -r "$backup_path/config"/* "$(dirname "$0")/../config/" 2>/dev/null || true
    cp "$backup_path/cluster_param.sh" "$(dirname "$0")/../" 2>/dev/null || true
    cp "$backup_path/agent_param.sh" "$(dirname "$0")/../" 2>/dev/null || true
    cp "$backup_path/load_balancer.conf" "$(dirname "$0")/../" 2>/dev/null || true
    
    log "${GREEN}Configuration restoration completed${NC}"
    log "${BLUE}Previous configs backed up to: $current_backup${NC}"
}

# Disaster recovery
disaster_recovery() {
    log "${BLUE}=== Starting Disaster Recovery ===${NC}"
    
    # Find latest backup
    local latest_backup
    if [ -f "$BACKUP_DIR/latest_full_backup.txt" ]; then
        latest_backup=$(cat "$BACKUP_DIR/latest_full_backup.txt")
    else
        log "${RED}No backup found. Cannot proceed with disaster recovery.${NC}"
        return 1
    fi
    
    if [ ! -f "$latest_backup" ]; then
        log "${RED}Backup file not found: $latest_backup${NC}"
        return 1
    fi
    
    log "Using backup: $latest_backup"
    
    # Extract backup
    local extract_dir="$RESTORE_DIR/disaster_recovery_$TIMESTAMP"
    mkdir -p "$extract_dir"
    tar -xzf "$latest_backup" -C "$extract_dir" 2>/dev/null || {
        log "${RED}Failed to extract backup${NC}"
        return 1
    }
    
    # Stop current cluster
    log "Stopping current cluster..."
    cd "$(dirname "$0")/.."
    docker stop $(docker ps -q --filter name=kraken-) 2>/dev/null || true
    docker rm $(docker ps -aq --filter name=kraken-) 2>/dev/null || true
    
    # Restore components
    restore_configs "$extract_dir/configs_"*
    
    # Restart cluster
    log "Starting cluster with restored configuration..."
    ./cluster/cluster_start_processes.sh
    
    # Wait for startup
    sleep 30
    
    # Restore Redis data
    restore_redis "$extract_dir/redis_"*
    
    log "${GREEN}=== Disaster recovery completed ===${NC}"
    log "${BLUE}Please verify cluster status with: ./test/cluster_status.sh${NC}"
}

# List available backups
list_backups() {
    echo -e "${BLUE}=== Available Backups ===${NC}"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "No backups found in $BACKUP_DIR"
        return
    fi
    
    echo "Backup Directory: $BACKUP_DIR"
    echo ""
    
    # Full backups
    echo "Full Backups:"
    find "$BACKUP_DIR" -name "full_backup_*.tar.gz" -exec ls -lh {} \; 2>/dev/null | while read line; do
        echo "  $line"
    done
    
    # Component backups
    echo ""
    echo "Component Backups:"
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "*_2*" | sort | while read dir; do
        echo "  $(basename "$dir"): $(du -sh "$dir" 2>/dev/null | cut -f1)"
    done
    
    # Latest backups
    echo ""
    echo "Latest Backups:"
    [ -f "$BACKUP_DIR/latest_full_backup.txt" ] && echo "  Full: $(cat "$BACKUP_DIR/latest_full_backup.txt")"
    [ -f "$BACKUP_DIR/latest_redis_backup.txt" ] && echo "  Redis: $(cat "$BACKUP_DIR/latest_redis_backup.txt")"
    [ -f "$BACKUP_DIR/latest_config_backup.txt" ] && echo "  Config: $(cat "$BACKUP_DIR/latest_config_backup.txt")"
    [ -f "$BACKUP_DIR/latest_data_backup.txt" ] && echo "  Data: $(cat "$BACKUP_DIR/latest_data_backup.txt")"
}

# Cleanup old backups
cleanup_backups() {
    local days=${1:-7}
    
    log "${BLUE}Cleaning up backups older than $days days...${NC}"
    
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime "+$days" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -type d -name "*_2*" -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
    
    log "${GREEN}Cleanup completed${NC}"
}

# Main execution
case "${1:-help}" in
    "backup")
        create_full_backup
        ;;
    "restore")
        if [ -z "$2" ]; then
            echo "Usage: $0 restore <backup_path>"
            exit 1
        fi
        restore_configs "$2"
        ;;
    "disaster-recovery"|"dr")
        disaster_recovery
        ;;
    "list")
        list_backups
        ;;
    "cleanup")
        cleanup_backups "${2:-7}"
        ;;
    "redis-backup")
        backup_redis
        ;;
    "config-backup")
        backup_configs
        ;;
    "data-backup")
        backup_data
        ;;
    *)
        echo "Kraken Distributed Cluster Backup & Recovery"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  backup              Create full cluster backup"
        echo "  restore <path>      Restore from backup"
        echo "  disaster-recovery   Full disaster recovery from latest backup"
        echo "  list                List available backups"
        echo "  cleanup [days]      Clean up old backups (default: 7 days)"
        echo "  redis-backup        Backup only Redis data"
        echo "  config-backup       Backup only configurations"
        echo "  data-backup         Backup only persistent data"
        echo ""
        echo "Environment Variables:"
        echo "  BACKUP_DIR          Backup directory (default: /tmp/kraken-backups)"
        echo "  RESTORE_DIR         Restore directory (default: /tmp/kraken-restore)"
        exit 1
        ;;
esac
