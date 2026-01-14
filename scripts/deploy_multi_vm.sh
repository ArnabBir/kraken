#!/bin/bash

# Kraken Multi-VM Deployment Script
# This script automates the deployment of Kraken across 3 VMs

set -e

# Configuration
VM1_HOST="${VM1_HOST:-stg-droveexeckraken001.phonepe.nb6}"
VM2_HOST="${VM2_HOST:-stg-droveexeckraken002.phonepe.nb6}"
VM3_HOST="${VM3_HOST:-stg-droveexeckraken003.phonepe.nb6}"

VM1_IP="${VM1_IP:-172.24.24.49}"
VM2_IP="${VM2_IP:-172.24.24.50}"
VM3_IP="${VM3_IP:-172.24.24.51}"

VM_USER="${VM_USER:-root}"

echo "========================================="
echo "Kraken Multi-VM Deployment"
echo "========================================="
echo "VM1 (Herd):      $VM1_HOST ($VM1_IP)"
echo "VM2 (Agent One): $VM2_HOST ($VM2_IP)"
echo "VM3 (Agent Two): $VM3_HOST ($VM3_IP)"
echo "========================================="
echo ""

# Step 1: Build images locally
echo "Step 1: Building Kraken images..."
make clean
make bins
make images

if [ $? -ne 0 ]; then
    echo "Error: Failed to build images"
    exit 1
fi

# Step 2: Save images
echo ""
echo "Step 2: Saving images..."
docker save kraken-herd:dev -o kraken-herd.tar
docker save kraken-agent:dev -o kraken-agent.tar
gzip -f kraken-herd.tar kraken-agent.tar

# Step 3: Transfer to VMs
echo ""
echo "Step 3: Transferring images and configs to VMs..."

echo "  → Transferring to VM1 (Herd)..."
scp kraken-herd.tar.gz ${VM_USER}@${VM1_HOST}:/root/
scp -r examples/devcluster ${VM_USER}@${VM1_HOST}:/root/kraken-config/

echo "  → Transferring to VM2 (Agent One)..."
scp kraken-agent.tar.gz ${VM_USER}@${VM2_HOST}:/root/
scp -r examples/devcluster ${VM_USER}@${VM2_HOST}:/root/kraken-config/

echo "  → Transferring to VM3 (Agent Two)..."
scp kraken-agent.tar.gz ${VM_USER}@${VM3_HOST}:/root/
scp -r examples/devcluster ${VM_USER}@${VM3_HOST}:/root/kraken-config/

# Step 4: Load images on each VM
echo ""
echo "Step 4: Loading images on VMs..."

echo "  → Loading on VM1..."
ssh ${VM_USER}@${VM1_HOST} "cd /root && gunzip -f kraken-herd.tar.gz && docker load -i kraken-herd.tar"

echo "  → Loading on VM2..."
ssh ${VM_USER}@${VM2_HOST} "cd /root && gunzip -f kraken-agent.tar.gz && docker load -i kraken-agent.tar"

echo "  → Loading on VM3..."
ssh ${VM_USER}@${VM3_HOST} "cd /root && gunzip -f kraken-agent.tar.gz && docker load -i kraken-agent.tar"

# Step 4.5: Configure Docker for insecure registries
echo ""
echo "Step 4.5: Configuring Docker for insecure registries..."

echo "  → Configuring VM1..."
ssh ${VM_USER}@${VM1_HOST} "cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  \"insecure-registries\": [\"${VM1_IP}:15000\", \"localhost:15000\"]
}
DOCKEREOF
systemctl restart docker"

echo "  → Configuring VM2..."
ssh ${VM_USER}@${VM2_HOST} "cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  \"insecure-registries\": [\"${VM1_IP}:15000\", \"${VM2_IP}:16000\", \"localhost:16000\"]
}
DOCKEREOF
systemctl restart docker"

echo "  → Configuring VM3..."
ssh ${VM_USER}@${VM3_HOST} "cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  \"insecure-registries\": [\"${VM1_IP}:15000\", \"${VM3_IP}:17000\", \"localhost:17000\"]
}
DOCKEREOF
systemctl restart docker"

echo "  → Waiting for Docker to restart..."
sleep 5

# Step 5: Update configs
echo ""
echo "Step 5: Updating configuration files..."

echo "  → Updating configs on VM1..."
ssh ${VM_USER}@${VM1_HOST} "cd /root/kraken-config/devcluster/config && find . -type f -name '*.yaml' -exec sed -i 's/host\.docker\.internal/${VM1_IP}/g' {} \;"

echo "  → Updating configs on VM2..."
ssh ${VM_USER}@${VM2_HOST} "cd /root/kraken-config/devcluster/config && sed -i 's/host\.docker\.internal/${VM1_IP}/g' agent/development.yaml"

echo "  → Updating configs on VM3..."
ssh ${VM_USER}@${VM3_HOST} "cd /root/kraken-config/devcluster/config && sed -i 's/host\.docker\.internal/${VM1_IP}/g' agent/development.yaml"

# Step 6: Create startup scripts
echo ""
echo "Step 6: Creating startup scripts on each VM..."

echo "  → Creating VM1 herd startup script..."
ssh ${VM_USER}@${VM1_HOST} 'bash -s' << 'ENDSSH'
cat > /root/kraken-config/devcluster/vm1_herd_start.sh << 'EOF'
#!/bin/bash
docker rm -f kraken-herd 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./herd_param.sh
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Herd on VM1"
echo "VM IP: $VM_IP"
echo "========================================="

docker run -d \
    --name kraken-herd \
    --network host \
    --restart unless-stopped \
    -e VM_IP="$VM_IP" \
    -v "$(pwd)/config/origin/development.yaml":/etc/kraken/config/origin/development.yaml \
    -v "$(pwd)/config/tracker/development.yaml":/etc/kraken/config/tracker/development.yaml \
    -v "$(pwd)/config/build-index/development.yaml":/etc/kraken/config/build-index/development.yaml \
    -v "$(pwd)/config/proxy/development.yaml":/etc/kraken/config/proxy/development.yaml \
    -v "$(pwd)/herd_param.sh":/etc/kraken/herd_param.sh \
    -v "$(pwd)/herd_start_processes.sh":/etc/kraken/herd_start_processes.sh:ro \
    kraken-herd:dev bash -c 'cp /etc/kraken/herd_start_processes.sh /tmp/herd_start.sh && sed -i "s/--peer-ip=\${HOSTNAME}/--peer-ip=$VM_IP/g" /tmp/herd_start.sh && sed -i "s/--blobserver-hostname=\${HOSTNAME}/--blobserver-hostname=$VM_IP/g" /tmp/herd_start.sh && chmod +x /tmp/herd_start.sh && /tmp/herd_start.sh'

sleep 8
echo "Herd started. Checking status..."
docker ps --filter name=kraken-herd
docker logs kraken-herd | tail -20
EOF
chmod +x /root/kraken-config/devcluster/vm1_herd_start.sh
ENDSSH

echo "  → Creating VM2 agent one startup script..."
ssh ${VM_USER}@${VM2_HOST} 'bash -s' << 'ENDSSH'
cat > /root/kraken-config/devcluster/vm2_agent_one_start.sh << 'EOF'
#!/bin/bash
docker rm -f kraken-agent-one 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./agent_one_param.sh
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Agent One on VM2"
echo "VM IP: $VM_IP"
echo "========================================="

docker run -d \
    --name kraken-agent-one \
    --network host \
    --restart unless-stopped \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_one_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

sleep 5
echo "Agent One started. Checking status..."
docker ps --filter name=kraken-agent-one
docker logs kraken-agent-one | tail -20
EOF
chmod +x /root/kraken-config/devcluster/vm2_agent_one_start.sh
ENDSSH

echo "  → Creating VM3 agent two startup script..."
ssh ${VM_USER}@${VM3_HOST} 'bash -s' << 'ENDSSH'
cat > /root/kraken-config/devcluster/vm3_agent_two_start.sh << 'EOF'
#!/bin/bash
docker rm -f kraken-agent-two 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./agent_two_param.sh
VM_IP=$(hostname -I | awk '{print $1}')

echo "========================================="
echo "Starting Kraken Agent Two on VM3"
echo "VM IP: $VM_IP"
echo "========================================="

docker run -d \
    --name kraken-agent-two \
    --network host \
    --restart unless-stopped \
    -v "$(pwd)/config/agent/development.yaml":/etc/kraken/config/agent/development.yaml \
    -v "$(pwd)/agent_two_param.sh":/etc/kraken/agent_param.sh \
    kraken-agent:dev bash -c "source /etc/kraken/agent_param.sh && /usr/bin/kraken-agent --config=/etc/kraken/config/agent/development.yaml --peer-ip=$VM_IP --peer-port=\$AGENT_PEER_PORT --agent-server-port=\$AGENT_SERVER_PORT --agent-registry-port=\$AGENT_REGISTRY_PORT"

sleep 5
echo "Agent Two started. Checking status..."
docker ps --filter name=kraken-agent-two
docker logs kraken-agent-two | tail -20
EOF
chmod +x /root/kraken-config/devcluster/vm3_agent_two_start.sh
ENDSSH

# Step 7: Create stop scripts
echo ""
echo "Step 7: Creating stop scripts..."

ssh ${VM_USER}@${VM1_HOST} 'cat > /root/kraken-config/devcluster/vm1_stop.sh << "EOF"
#!/bin/bash
echo "Stopping Kraken Herd on VM1..."
docker rm -f kraken-herd 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm1_stop.sh'

ssh ${VM_USER}@${VM2_HOST} 'cat > /root/kraken-config/devcluster/vm2_stop.sh << "EOF"
#!/bin/bash
echo "Stopping Kraken Agent One on VM2..."
docker rm -f kraken-agent-one 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm2_stop.sh'

ssh ${VM_USER}@${VM3_HOST} 'cat > /root/kraken-config/devcluster/vm3_stop.sh << "EOF"
#!/bin/bash
echo "Stopping Kraken Agent Two on VM3..."
docker rm -f kraken-agent-two 2>/dev/null || true
echo "Done."
EOF
chmod +x /root/kraken-config/devcluster/vm3_stop.sh'

# Step 8: Deploy
echo ""
echo "Step 8: Starting Kraken services..."
echo ""

echo "  → Starting Herd on VM1..."
ssh ${VM_USER}@${VM1_HOST} "/root/kraken-config/devcluster/vm1_herd_start.sh"

echo ""
echo "  → Waiting for Herd to stabilize..."
sleep 15

echo ""
echo "  → Starting Agent One on VM2..."
ssh ${VM_USER}@${VM2_HOST} "/root/kraken-config/devcluster/vm2_agent_one_start.sh"

echo ""
echo "  → Starting Agent Two on VM3..."
ssh ${VM_USER}@${VM3_HOST} "/root/kraken-config/devcluster/vm3_agent_two_start.sh"

# Step 9: Health check
echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Running health checks..."
echo ""

echo "VM1 - Herd:"
ssh ${VM_USER}@${VM1_HOST} "curl -s http://localhost:15000/v2/ > /dev/null && echo '  ✓ Proxy OK' || echo '  ✗ Proxy FAIL'"
ssh ${VM_USER}@${VM1_HOST} "curl -s http://localhost:14000/health > /dev/null && echo '  ✓ TestFS OK' || echo '  ✗ TestFS FAIL'"

echo ""
echo "VM2 - Agent One:"
ssh ${VM_USER}@${VM2_HOST} "curl -s http://localhost:16000/v2/ > /dev/null && echo '  ✓ Registry OK' || echo '  ✗ Registry FAIL'"

echo ""
echo "VM3 - Agent Two:"
ssh ${VM_USER}@${VM3_HOST} "curl -s http://localhost:17000/v2/ > /dev/null && echo '  ✓ Registry OK' || echo '  ✗ Registry FAIL'"

echo ""
echo "========================================="
echo "Usage:"
echo "========================================="
echo "Push images to:   ${VM1_IP}:15000"
echo "Pull from VM2:    ${VM2_IP}:16000"
echo "Pull from VM3:    ${VM3_IP}:17000"
echo ""
echo "Example:"
echo "  docker tag myimage:latest ${VM1_IP}:15000/test/myimage:latest"
echo "  docker push ${VM1_IP}:15000/test/myimage:latest"
echo "  docker pull ${VM2_IP}:16000/test/myimage:latest"
echo ""
echo "To stop the cluster, run:"
echo "  ssh ${VM_USER}@${VM1_HOST} /root/kraken-config/devcluster/vm1_stop.sh"
echo "  ssh ${VM_USER}@${VM2_HOST} /root/kraken-config/devcluster/vm2_stop.sh"
echo "  ssh ${VM_USER}@${VM3_HOST} /root/kraken-config/devcluster/vm3_stop.sh"
echo "========================================="
