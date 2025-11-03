#!/usr/bin/env bash

################################################################################
# PaddleOCR-VL Service - EC2 Instance Configuration Script
################################################################################
#
# This script runs on the EC2 instance to configure it for the service.
# It performs:
#   1. System updates
#   2. Docker/NVIDIA verification
#   3. Instance store mount and Docker reconfiguration (CRITICAL)
#   4. Repository cloning
#   5. PaddlePaddle wheel download from S3
#   6. Service deployment
#
# This script is executed remotely by deploy-to-ec2.sh
#
# Usage:
#   ./configure-instance.sh [S3_WHEEL_PATH]
#
################################################################################

set -euo pipefail

# Get S3 wheel path from argument
WHEEL_S3_PATH="${1:-s3://deploy-assets/paddleocr-vl/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

# System updates
update_system() {
    log "Running system updates..."
    sudo apt-get update -qq
    sudo apt-get upgrade -y -qq
    log "System updated ✓"
}

# Verify Docker installation
verify_docker() {
    log "Verifying Docker installation..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker not found!"
        exit 1
    fi

    DOCKER_VERSION=$(docker --version)
    log "Docker version: $DOCKER_VERSION"

    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose not found!"
        exit 1
    fi

    COMPOSE_VERSION=$(docker compose version)
    log "Docker Compose version: $COMPOSE_VERSION"
    log "Docker verified ✓"
}

# Verify NVIDIA driver and GPU
verify_gpu() {
    log "Verifying NVIDIA GPU and drivers..."

    if ! command -v nvidia-smi &> /dev/null; then
        log_error "nvidia-smi not found!"
        exit 1
    fi

    # Run nvidia-smi
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)
    log "GPU detected: $GPU_INFO"

    # Verify NVIDIA Container Toolkit
    if ! docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
        log_error "Docker GPU access not working!"
        exit 1
    fi

    log "GPU access verified ✓"
}

# Configure instance store and Docker (CRITICAL)
configure_storage() {
    log "Configuring storage..."

    # Find instance store device
    INSTANCE_STORE_DEVICE=""
    for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdb; do
        if [[ -b "$dev" ]]; then
            INSTANCE_STORE_DEVICE="$dev"
            break
        fi
    done

    if [[ -z "$INSTANCE_STORE_DEVICE" ]]; then
        log_warning "Instance store device not found!"
        log_warning "Will use EBS root for Docker (may run out of space)"
        return
    fi

    log "Instance store device found: $INSTANCE_STORE_DEVICE"

    # Check if already mounted
    if mount | grep -q "/opt/dlami/nvme"; then
        log "Instance store already mounted at /opt/dlami/nvme"
    else
        log "Mounting instance store..."
        # Check if filesystem exists
        if ! sudo file -s "$INSTANCE_STORE_DEVICE" | grep -q "filesystem"; then
            log "Creating ext4 filesystem on $INSTANCE_STORE_DEVICE..."
            sudo mkfs.ext4 -F "$INSTANCE_STORE_DEVICE"
        fi

        sudo mkdir -p /opt/dlami/nvme
        sudo mount "$INSTANCE_STORE_DEVICE" /opt/dlami/nvme
        log "Instance store mounted ✓"
    fi

    # Show disk space
    df -h / /opt/dlami/nvme

    # Configure Docker to use instance store
    log "Configuring Docker to use instance store..."

    # Stop Docker
    sudo systemctl stop docker

    # Create Docker directory on instance store
    sudo mkdir -p /opt/dlami/nvme/docker

    # Configure Docker daemon
    sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "data-root": "/opt/dlami/nvme/docker"
}
EOF

    # Remove old Docker data from root EBS (if exists)
    if [[ -d /var/lib/docker ]]; then
        log "Removing old Docker data from /var/lib/docker..."
        sudo rm -rf /var/lib/docker
        log "Freed up root partition space"
    fi

    # Restart Docker
    sudo systemctl start docker

    # Verify Docker root dir
    DOCKER_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $4}')
    log "Docker Root Dir: $DOCKER_ROOT"

    if [[ "$DOCKER_ROOT" != "/opt/dlami/nvme/docker" ]]; then
        log_warning "Docker root dir not set correctly!"
    else
        log "Docker configured to use instance store ✓"
    fi

    # Show final disk space
    log "Final disk space:"
    df -h / /opt/dlami/nvme
}

# Clone repository
clone_repository() {
    log "Cloning repository..."

    if [[ -d ~/paddleocr-vl-service ]]; then
        log "Repository directory already exists, pulling latest..."
        cd ~/paddleocr-vl-service
        git pull
    else
        git clone https://github.com/Mark-Engineering-Inc/paddleocr-vl-service.git ~/paddleocr-vl-service
        cd ~/paddleocr-vl-service
    fi

    log "Repository ready ✓"
    log "Current commit: $(git log -1 --oneline)"
}

# Download PaddlePaddle wheel from S3
download_wheel() {
    log "Downloading PaddlePaddle wheel from S3..."
    log "  Source: $WHEEL_S3_PATH"
    log "  Destination: ~/paddleocr-vl-service/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl"

    # Download from S3 (uses AWS internal network - very fast!)
    if aws s3 cp "$WHEEL_S3_PATH" ~/paddleocr-vl-service/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl; then
        log "Wheel download complete ✓"

        # Verify file size
        WHEEL_SIZE=$(du -m ~/paddleocr-vl-service/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl | cut -f1)
        log "Downloaded file size: ${WHEEL_SIZE} MB"

        if [[ $WHEEL_SIZE -lt 1700 ]]; then
            log_warning "Downloaded file seems too small ($WHEEL_SIZE MB). Expected ~1800 MB"
        fi
    else
        log_error "Failed to download wheel from S3"
        log_error "Make sure the EC2 instance has S3 access (via IAM role or credentials)"
        exit 1
    fi
}

# Display final status
display_status() {
    log ""
    log "========================================="
    log "Instance Configuration Complete!"
    log "========================================="
    log ""
    log "System Information:"
    log "  OS: $(lsb_release -d | cut -f2)"
    log "  Kernel: $(uname -r)"
    log ""
    log "Software Versions:"
    log "  Docker: $(docker --version | awk '{print $3}')"
    log "  Docker Compose: $(docker compose version | awk '{print $4}')"
    log "  NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
    log "  CUDA: $(nvidia-smi | grep "CUDA Version" | awk '{print $9}')"
    log ""
    log "Storage:"
    df -h / /opt/dlami/nvme 2>/dev/null | grep -E "Filesystem|/$|/opt/dlami/nvme"
    log ""
    log "GPU:"
    nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader
    log ""
    log "Next Steps:"
    log "  1. Wheel file downloaded from S3 ✓"
    log "  2. Build Docker image"
    log "  3. Start service"
    log ""
    log "========================================="
}

# Main execution
main() {
    log "Starting EC2 instance configuration..."
    log "======================================="
    log "Wheel S3 path: $WHEEL_S3_PATH"

    update_system
    verify_docker
    verify_gpu
    configure_storage
    clone_repository
    download_wheel
    display_status

    log "Configuration complete ✓"
}

# Run main
main
