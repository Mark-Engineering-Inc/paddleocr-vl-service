#!/usr/bin/env bash

################################################################################
# PaddleOCR-VL Service - AWS EC2 Teardown Script
################################################################################
#
# This script safely terminates EC2 instances and cleans up related resources.
# It provides options to terminate by instance ID or tag, and optionally
# remove security group rules.
#
# Usage:
#   ./scripts/teardown-ec2.sh [OPTIONS]
#
# Options:
#   --instance-id ID          Instance ID to terminate (required unless --tag)
#   --tag KEY=VALUE           Find and terminate instances by tag
#   --region REGION           AWS region (default: us-west-2)
#   --remove-sg-rules         Remove SSH rules for current IP from security group
#   --security-group NAME     Security group name (default: paddleocr-vl-sg)
#   --force                   Skip confirmation prompt
#   --help                    Show this help message
#
# Examples:
#   # Terminate by instance ID
#   ./scripts/teardown-ec2.sh --instance-id i-1234567890abcdef0
#
#   # Find and terminate by tag
#   ./scripts/teardown-ec2.sh --tag Name=paddleocr-vl-service
#
#   # Terminate and remove security group rules
#   ./scripts/teardown-ec2.sh --instance-id i-xxx --remove-sg-rules --force
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
INSTANCE_ID=""
TAG_FILTER=""
SECURITY_GROUP_NAME="paddleocr-vl-sg"
REMOVE_SG_RULES=false
FORCE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/deployment-operation.log"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --tag)
            TAG_FILTER="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --security-group)
            SECURITY_GROUP_NAME="$2"
            shift 2
            ;;
        --remove-sg-rules)
            REMOVE_SG_RULES=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help)
            head -n 40 "$0" | tail -n +3
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

# Validate prerequisites
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

    # Check instance ID or tag provided
    if [[ -z "$INSTANCE_ID" && -z "$TAG_FILTER" ]]; then
        log_error "Either --instance-id or --tag must be specified"
        exit 1
    fi

    log "Prerequisites met ✓"
}

# Find instance by tag
find_instance_by_tag() {
    log "Finding instances with tag: $TAG_FILTER..."

    # Parse tag filter (format: Key=Value)
    TAG_KEY=$(echo "$TAG_FILTER" | cut -d'=' -f1)
    TAG_VALUE=$(echo "$TAG_FILTER" | cut -d'=' -f2)

    INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running,stopped,stopping" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

    if [[ -z "$INSTANCE_IDS" ]]; then
        log_error "No instances found with tag ${TAG_KEY}=${TAG_VALUE}"
        exit 1
    fi

    # Convert to array
    IFS=' ' read -ra INSTANCE_ID_ARRAY <<< "$INSTANCE_IDS"

    if [[ ${#INSTANCE_ID_ARRAY[@]} -gt 1 ]]; then
        log_warning "Found ${#INSTANCE_ID_ARRAY[@]} instances:"
        for id in "${INSTANCE_ID_ARRAY[@]}"; do
            echo "  - $id"
        done

        if [[ "$FORCE" == "false" ]]; then
            read -p "Terminate all? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log "Cancelled by user"
                exit 0
            fi
        fi
    else
        INSTANCE_ID="${INSTANCE_ID_ARRAY[0]}"
        log "Found instance: $INSTANCE_ID"
    fi
}

# Get instance details
get_instance_details() {
    local instance_id=$1

    log "Retrieving instance details: $instance_id..."

    INSTANCE_DATA=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0]' \
        --output json 2>/dev/null || echo "{}")

    if [[ "$INSTANCE_DATA" == "{}" ]]; then
        log_warning "Instance not found or already terminated: $instance_id"
        return 1
    fi

    INSTANCE_STATE=$(echo "$INSTANCE_DATA" | jq -r '.State.Name')
    INSTANCE_TYPE=$(echo "$INSTANCE_DATA" | jq -r '.InstanceType')
    PUBLIC_IP=$(echo "$INSTANCE_DATA" | jq -r '.PublicIpAddress // "N/A"')
    INSTANCE_NAME=$(echo "$INSTANCE_DATA" | jq -r '.Tags[]? | select(.Key=="Name") | .Value // "N/A"')

    log "Instance: $instance_id"
    log "  Name: $INSTANCE_NAME"
    log "  Type: $INSTANCE_TYPE"
    log "  State: $INSTANCE_STATE"
    log "  Public IP: $PUBLIC_IP"

    return 0
}

# Confirm termination
confirm_termination() {
    if [[ "$FORCE" == "true" ]]; then
        log "Force mode enabled, skipping confirmation"
        return 0
    fi

    echo ""
    log_warning "This will PERMANENTLY TERMINATE the following instance(s):"
    echo ""

    if [[ -n "$INSTANCE_ID" ]]; then
        get_instance_details "$INSTANCE_ID"
    else
        for id in "${INSTANCE_ID_ARRAY[@]}"; do
            get_instance_details "$id"
            echo ""
        done
    fi

    echo ""
    log_warning "All data will be lost (instance store is ephemeral)"
    read -p "Are you sure? Type 'yes' to confirm: " -r
    echo ""

    if [[ ! $REPLY == "yes" ]]; then
        log "Cancelled by user"
        exit 0
    fi
}

# Terminate instance
terminate_instance() {
    local instance_id=$1

    log "Terminating instance: $instance_id..."

    aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --output json > /dev/null

    log "Termination initiated ✓"
    log_to_file "Terminated instance: $instance_id"

    # Wait for termination
    log "Waiting for instance to terminate (this may take 1-2 minutes)..."
    aws ec2 wait instance-terminated \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id"

    log "Instance terminated ✓"
}

# Remove security group rules
remove_security_group_rules() {
    log "Removing security group rules..."

    # Get security group ID
    SG_ID=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "None")

    if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
        log_warning "Security group not found: $SECURITY_GROUP_NAME"
        return 0
    fi

    # Get current IP
    CURRENT_IP=$(curl -s https://checkip.amazonaws.com)
    log "Current IP: $CURRENT_IP"

    # Check if rule exists
    RULE_EXISTS=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[?CidrIp==\`${CURRENT_IP}/32\`]" \
        --output text)

    if [[ -z "$RULE_EXISTS" ]]; then
        log "No SSH rule for current IP found"
        return 0
    fi

    # Remove rule
    aws ec2 revoke-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "${CURRENT_IP}/32" \
        --output json > /dev/null

    log "Removed SSH rule for ${CURRENT_IP}/32 ✓"
    log_to_file "Removed security group rule: ${CURRENT_IP}/32"
}

# Display summary
display_summary() {
    log ""
    log "========================================="
    log "Teardown Complete!"
    log "========================================="
    log ""
    log "Terminated Instances:"

    if [[ -n "$INSTANCE_ID" ]]; then
        log "  - $INSTANCE_ID"
    else
        for id in "${INSTANCE_ID_ARRAY[@]}"; do
            log "  - $id"
        done
    fi

    log ""
    log "Region: $AWS_REGION"
    log ""

    if [[ "$REMOVE_SG_RULES" == "true" ]]; then
        log "Security group rules removed ✓"
    else
        log "Security group rules preserved"
        log "  (use --remove-sg-rules to remove)"
    fi

    log ""
    log "========================================="
}

# Main execution
main() {
    log "Starting PaddleOCR-VL EC2 Teardown"
    log "====================================="

    check_prerequisites

    # Find instances if using tag filter
    if [[ -n "$TAG_FILTER" ]]; then
        find_instance_by_tag
    fi

    # Confirm termination
    confirm_termination

    # Terminate instance(s)
    if [[ -n "$INSTANCE_ID" ]]; then
        terminate_instance "$INSTANCE_ID"
    else
        for id in "${INSTANCE_ID_ARRAY[@]}"; do
            terminate_instance "$id"
        done
    fi

    # Remove security group rules if requested
    if [[ "$REMOVE_SG_RULES" == "true" ]]; then
        remove_security_group_rules
    fi

    display_summary

    log "Done!"
}

# Run main function
main
