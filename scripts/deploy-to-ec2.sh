#!/usr/bin/env bash

################################################################################
# PaddleOCR-VL Service - AWS EC2 Deployment Script
################################################################################
#
# This script automates the complete deployment of PaddleOCR-VL service on
# AWS EC2 g6.xlarge instances with optimized storage configuration:
#   - 45GB EBS root (OS, drivers, configs) - $3.60/month
#   - 250GB Instance Store (Docker, models) - FREE
#
# Usage:
#   ./scripts/deploy-to-ec2.sh [OPTIONS]
#
# Options:
#   --region REGION           AWS region (default: us-west-2)
#   --instance-type TYPE      Instance type (default: g6.xlarge)
#   --root-volume-size SIZE   EBS root volume size in GB (default: 45, min: 45)
#   --key-name NAME           EC2 key pair name (default: paddleocr-vl-key)
#   --security-group NAME     Security group name (default: paddleocr-vl-sg)
#   --wheel-s3-path S3_PATH   S3 path to PaddlePaddle wheel file (default: s3://deploy-assets/paddleocr-vl/...)
#   --skip-build              Skip Docker build (for testing)
#   --help                    Show this help message
#
# Example:
#   ./scripts/deploy-to-ec2.sh --region us-west-2 --instance-type g6.xlarge
#
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
AWS_REGION="us-west-2"
INSTANCE_TYPE="g6.xlarge"
ROOT_VOLUME_SIZE=45  # Deep Learning AMI requires min 45GB
KEY_NAME="paddleocr-vl-key"
SECURITY_GROUP_NAME="paddleocr-vl-sg"
WHEEL_S3_PATH="s3://deploy-assets/paddleocr-vl/paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl"
SKIP_BUILD=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/deployment-operation.log"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --root-volume-size)
            ROOT_VOLUME_SIZE="$2"
            shift 2
            ;;
        --key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        --security-group)
            SECURITY_GROUP_NAME="$2"
            shift 2
            ;;
        --wheel-s3-path)
            WHEEL_S3_PATH="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help)
            head -n 35 "$0" | tail -n +3
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Helper functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Prerequisite checks
check_prerequisites() {
    log "Checking prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install it first."
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        exit 1
    fi

    # Check SSH key
    KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"
    if [[ ! -f "$KEY_PATH" ]]; then
        log_error "SSH key not found: $KEY_PATH"
        log_error "Please create the key pair first or specify a different key with --key-name"
        exit 1
    fi

    # Check key permissions
    KEY_PERMS=$(stat -f "%A" "$KEY_PATH" 2>/dev/null || stat -c "%a" "$KEY_PATH" 2>/dev/null)
    if [[ "$KEY_PERMS" != "400" ]]; then
        log_warning "Fixing key permissions: chmod 400 $KEY_PATH"
        chmod 400 "$KEY_PATH"
    fi

    # Check PaddlePaddle wheel file in S3
    log "Verifying wheel file in S3..."
    if ! aws s3 ls "$WHEEL_S3_PATH" &> /dev/null; then
        log_error "PaddlePaddle wheel file not found in S3: $WHEEL_S3_PATH"
        log_error "Please upload it first with:"
        log_error "  aws s3 cp paddlepaddle_gpu-3.2.0-cp310-cp310-linux_x86_64.whl $WHEEL_S3_PATH"
        exit 1
    fi

    # Check wheel file size (should be ~1.8GB)
    WHEEL_SIZE=$(aws s3 ls "$WHEEL_S3_PATH" | awk '{print $3}')
    WHEEL_SIZE_MB=$((WHEEL_SIZE / 1024 / 1024))
    log "Wheel file size: ${WHEEL_SIZE_MB} MB"
    if [[ $WHEEL_SIZE_MB -lt 1700 ]]; then
        log_warning "Wheel file seems too small ($WHEEL_SIZE_MB MB). Expected ~1800 MB"
    fi

    # Check root volume size
    if [[ $ROOT_VOLUME_SIZE -lt 45 ]]; then
        log_error "Root volume size must be at least 45GB (Deep Learning AMI requirement, specified: ${ROOT_VOLUME_SIZE}GB)"
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq not found. Installing via brew (if available)..."
        if command -v brew &> /dev/null; then
            brew install jq
        else
            log_error "Please install jq manually"
            exit 1
        fi
    fi

    log "All prerequisites met ✓"
}

# Find latest Deep Learning AMI
find_ami() {
    log "Finding latest Deep Learning AMI for Ubuntu 22.04..."

    AMI_ID=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners amazon \
        --filters "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch*Ubuntu 22.04*" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)

    if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
        log_error "Could not find suitable Deep Learning AMI"
        exit 1
    fi

    AMI_NAME=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$AMI_ID" \
        --query 'Images[0].Name' \
        --output text)

    log "Found AMI: $AMI_ID ($AMI_NAME)"
    log_to_file "AMI Selected: $AMI_ID - $AMI_NAME"
}

# Get or create security group
setup_security_group() {
    log "Setting up security group: $SECURITY_GROUP_NAME..."

    # Check if security group exists
    SG_ID=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "None")

    if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
        log_error "Security group not found: $SECURITY_GROUP_NAME"
        log_error "Please create it first or it will be created automatically"
        exit 1
    fi

    # Get current IP
    CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
    log "Current IP: $CURRENT_IP"

    # Add current IP to security group if not already there
    EXISTING_IPS=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[*].CidrIp' \
        --output text)

    if ! echo "$EXISTING_IPS" | grep -q "${CURRENT_IP}/32"; then
        log "Adding current IP to security group..."
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr "${CURRENT_IP}/32" > /dev/null
        log "Added ${CURRENT_IP}/32 to SSH access"
    else
        log "Current IP already authorized for SSH"
    fi

    log_to_file "Security Group: $SG_ID (SSH: $CURRENT_IP/32)"
}

# Launch EC2 instance
launch_instance() {
    log "Launching EC2 instance..."
    log "  Instance Type: $INSTANCE_TYPE"
    log "  Root Volume: ${ROOT_VOLUME_SIZE}GB EBS (gp3)"
    log "  Instance Store: 250GB NVMe SSD (auto-attached)"

    # Create block device mapping for minimal root EBS
    BLOCK_DEVICE_MAPPING="[{
        \"DeviceName\": \"/dev/sda1\",
        \"Ebs\": {
            \"VolumeSize\": $ROOT_VOLUME_SIZE,
            \"VolumeType\": \"gp3\",
            \"DeleteOnTermination\": true
        }
    }]"

    # Launch instance
    INSTANCE_DATA=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile Name=paddleocr-vl-instance-profile \
        --block-device-mappings "$BLOCK_DEVICE_MAPPING" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=paddleocr-vl-service}]" \
        --output json)

    INSTANCE_ID=$(echo "$INSTANCE_DATA" | jq -r '.Instances[0].InstanceId')
    log "Instance launched: $INSTANCE_ID"
    log_to_file "Instance ID: $INSTANCE_ID"

    # Wait for instance to be running
    log "Waiting for instance to reach 'running' state..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
    log "Instance is running ✓"

    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    PUBLIC_DNS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text)

    log "Public IP: $PUBLIC_IP"
    log "Public DNS: $PUBLIC_DNS"
    log_to_file "Public IP: $PUBLIC_IP"
    log_to_file "Public DNS: $PUBLIC_DNS"

    # Wait for SSH to be ready
    log "Waiting for SSH to be ready (60 seconds)..."
    sleep 60

    # Test SSH connection
    log "Testing SSH connection..."
    MAX_RETRIES=10
    RETRY_COUNT=0
    while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$PUBLIC_IP" "echo 'SSH ready'" &> /dev/null; then
            log "SSH connection successful ✓"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "SSH not ready yet, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep 10
    done

    if [[ $RETRY_COUNT -eq $MAX_RETRIES ]]; then
        log_error "SSH connection failed after $MAX_RETRIES attempts"
        log_error "Instance ID: $INSTANCE_ID"
        log_error "You can manually terminate it with: aws ec2 terminate-instances --region $AWS_REGION --instance-ids $INSTANCE_ID"
        exit 1
    fi
}

# Configure instance
configure_instance() {
    log "Configuring instance..."

    # Copy configuration script to instance
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/configure-instance.sh" \
        ubuntu@"$PUBLIC_IP":~/configure-instance.sh

    # Make it executable and run it with S3 path
    ssh -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "chmod +x ~/configure-instance.sh && ~/configure-instance.sh '$WHEEL_S3_PATH'"

    log "Instance configuration complete ✓"
}

# Build and start service
deploy_service() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_warning "Skipping Docker build (--skip-build flag set)"
        return
    fi

    log "Building Docker image (this will take 10-15 minutes)..."

    ssh -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "cd ~/paddleocr-vl-service && docker compose build"

    log "Docker image built ✓"
    log "Starting service..."

    ssh -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "cd ~/paddleocr-vl-service && docker compose up -d"

    log "Service started ✓"
    log "Waiting 10 seconds for service to initialize..."
    sleep 10
}

# Verify deployment
verify_deployment() {
    log "Verifying deployment..."

    # Check health endpoint
    HEALTH_RESPONSE=$(ssh -i "$KEY_PATH" ubuntu@"$PUBLIC_IP" "curl -s http://localhost:8000/health")

    if echo "$HEALTH_RESPONSE" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
        log "Health check passed ✓"
        log "Service is healthy!"
    else
        log_warning "Health check returned unexpected response:"
        echo "$HEALTH_RESPONSE"
    fi

    # Check from local machine
    log "Testing external access..."
    if curl -s "http://$PUBLIC_IP:8000/health" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
        log "External access working ✓"
    else
        log_warning "External access check failed"
    fi
}

# Display summary
display_summary() {
    log ""
    log "========================================="
    log "Deployment Complete!"
    log "========================================="
    log ""
    log "Instance Information:"
    log "  Instance ID: $INSTANCE_ID"
    log "  Public IP: $PUBLIC_IP"
    log "  Public DNS: $PUBLIC_DNS"
    log "  Region: $AWS_REGION"
    log "  Instance Type: $INSTANCE_TYPE"
    log ""
    log "Service Endpoints:"
    log "  Health Check: http://$PUBLIC_IP:8000/health"
    log "  API Docs: http://$PUBLIC_IP:8000/api/v1/docs"
    log "  OCR Endpoint: http://$PUBLIC_IP:8000/api/v1/ocr/extract-document"
    log ""
    log "Storage Configuration:"
    log "  EBS Root: ${ROOT_VOLUME_SIZE}GB (OS, drivers, configs)"
    log "  Instance Store: 250GB NVMe SSD (Docker, models)"
    log ""
    log "SSH Access:"
    log "  ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
    log ""
    log "Docker Commands:"
    log "  View logs: ssh ubuntu@${PUBLIC_IP} 'cd paddleocr-vl-service && docker compose logs -f'"
    log "  Restart: ssh ubuntu@${PUBLIC_IP} 'cd paddleocr-vl-service && docker compose restart'"
    log "  Stop: ssh ubuntu@${PUBLIC_IP} 'cd paddleocr-vl-service && docker compose down'"
    log ""
    log "Cleanup:"
    log "  ./scripts/teardown-ec2.sh --instance-id $INSTANCE_ID --region $AWS_REGION"
    log ""
    log "========================================="

    # Save to file
    {
        echo ""
        echo "Deployment Summary - $(date)"
        echo "Instance ID: $INSTANCE_ID"
        echo "Public IP: $PUBLIC_IP"
        echo "Public DNS: $PUBLIC_DNS"
        echo "Service URL: http://$PUBLIC_IP:8000"
    } >> "$LOG_FILE"
}

# Main execution
main() {
    log "Starting PaddleOCR-VL EC2 Deployment"
    log "===================================="

    check_prerequisites
    find_ami
    setup_security_group
    launch_instance
    configure_instance
    deploy_service
    verify_deployment
    display_summary

    log "Done!"
}

# Run main function
main
