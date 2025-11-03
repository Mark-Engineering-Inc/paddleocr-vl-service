#!/usr/bin/env bash

################################################################################
# PaddleOCR-VL Service - Deployment Verification Script
################################################################################
#
# This script verifies that the PaddleOCR-VL service is deployed correctly
# and functioning as expected. It performs comprehensive health checks,
# API tests, and performance validation.
#
# Usage:
#   ./scripts/verify-deployment.sh [OPTIONS]
#
# Options:
#   --host HOST               Service host (default: localhost)
#   --port PORT               Service port (default: 8000)
#   --instance-id ID          EC2 instance ID (for SSH checks)
#   --region REGION           AWS region (default: us-west-2)
#   --key-name NAME           EC2 key pair name (default: paddleocr-vl-key)
#   --test-image PATH         Path to test image (default: use sample)
#   --skip-api-test           Skip actual OCR API test
#   --timeout SECONDS         Request timeout in seconds (default: 60)
#   --help                    Show this help message
#
# Examples:
#   # Verify local deployment
#   ./scripts/verify-deployment.sh --host localhost
#
#   # Verify remote EC2 deployment
#   ./scripts/verify-deployment.sh --host 18.237.13.84 --instance-id i-xxx
#
#   # Quick health check only
#   ./scripts/verify-deployment.sh --host 18.237.13.84 --skip-api-test
#
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
HOST="localhost"
PORT=8000
INSTANCE_ID=""
AWS_REGION="us-west-2"
KEY_NAME="paddleocr-vl-key"
TEST_IMAGE=""
SKIP_API_TEST=false
TIMEOUT=60
DEBUG=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Test result tracking
TEST_CONNECTIVITY="pending"
TEST_HEALTH="pending"
TEST_DOCKER="pending"
TEST_GPU="pending"
TEST_API="pending"
TEST_LOGS="pending"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        --test-image)
            TEST_IMAGE="$2"
            shift 2
            ;;
        --skip-api-test)
            SKIP_API_TEST=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
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

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check curl
    if ! command -v curl &> /dev/null; then
        log_error "curl not found. Please install it first."
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq not found. JSON parsing will be limited."
    fi

    # Check test image if provided
    if [[ -n "$TEST_IMAGE" && ! -f "$TEST_IMAGE" ]]; then
        log_error "Test image not found: $TEST_IMAGE"
        exit 1
    fi

    # Check SSH key if instance ID provided
    if [[ -n "$INSTANCE_ID" ]]; then
        KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"
        if [[ ! -f "$KEY_PATH" ]]; then
            log_error "SSH key not found: $KEY_PATH"
            exit 1
        fi
    fi

    log "Prerequisites met ✓"
}

# Test connectivity
test_connectivity() {
    log "Testing connectivity to ${HOST}:${PORT}..."

    if curl -s --connect-timeout 5 "http://${HOST}:${PORT}/health" > /dev/null 2>&1; then
        log "Connectivity OK ✓"
        TEST_CONNECTIVITY="pass"
        return 0
    else
        log_error "Cannot connect to ${HOST}:${PORT}"
        log_error "Please check:"
        log_error "  1. Service is running"
        log_error "  2. Port ${PORT} is accessible"
        log_error "  3. Firewall/security group allows connections"
        TEST_CONNECTIVITY="fail"
        exit 1
    fi
}

# Health check
check_health() {
    log "Checking service health..."

    HEALTH_RESPONSE=$(curl -s --max-time 10 "http://${HOST}:${PORT}/health" || echo "{}")

    if command -v jq &> /dev/null; then
        STATUS=$(echo "$HEALTH_RESPONSE" | jq -r '.status // "unknown"')
        SERVICE=$(echo "$HEALTH_RESPONSE" | jq -r '.service // "unknown"')
        VERSION=$(echo "$HEALTH_RESPONSE" | jq -r '.version // "unknown"')
        PIPELINE_READY=$(echo "$HEALTH_RESPONSE" | jq -r '.pipeline_ready // false')

        log "  Status: $STATUS"
        log "  Service: $SERVICE"
        log "  Version: $VERSION"
        log "  Pipeline Ready: $PIPELINE_READY"

        if [[ "$STATUS" == "healthy" ]]; then
            log "Health check passed ✓"
            TEST_HEALTH="pass"
            return 0
        else
            log_error "Service is not healthy"
            TEST_HEALTH="fail"
            return 1
        fi
    else
        # Fallback without jq
        if echo "$HEALTH_RESPONSE" | grep -q '"status".*"healthy"'; then
            log "Health check passed ✓"
            TEST_HEALTH="pass"
            return 0
        else
            log_error "Service is not healthy"
            echo "$HEALTH_RESPONSE"
            TEST_HEALTH="fail"
            return 1
        fi
    fi
}

# Check Docker container status (if EC2 instance provided)
check_docker_status() {
    if [[ -z "$INSTANCE_ID" ]]; then
        log_info "Skipping Docker check (no instance ID provided)"
        TEST_DOCKER="skip"
        return 0
    fi

    log "Checking Docker container status..."

    KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"

    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
        log_error "Could not get public IP for instance $INSTANCE_ID"
        TEST_DOCKER="fail"
        return 1
    fi

    # Check Docker containers using simpler command
    CONTAINER_CHECK=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$PUBLIC_IP" \
        "docker ps --filter name=paddleocr-vl-service --format '{{.Names}}\t{{.Status}}'" 2>&1)
    SSH_EXIT_CODE=$?

    if [[ $DEBUG == "true" ]]; then
        log_info "Docker check SSH exit code: $SSH_EXIT_CODE"
        log_info "Docker check output: $CONTAINER_CHECK"
    fi

    if [[ $SSH_EXIT_CODE -eq 0 && -n "$CONTAINER_CHECK" ]]; then
        CONTAINER_NAME=$(echo "$CONTAINER_CHECK" | awk '{print $1}')
        CONTAINER_STATUS=$(echo "$CONTAINER_CHECK" | cut -f2-)

        log "  Container: $CONTAINER_NAME"
        log "  Status: $CONTAINER_STATUS"

        if echo "$CONTAINER_STATUS" | grep -q "Up"; then
            log "Docker container running ✓"
            TEST_DOCKER="pass"
            return 0
        else
            log_error "Docker container not running properly"
            TEST_DOCKER="fail"
            return 1
        fi
    else
        log_warning "Could not retrieve Docker status"
        if [[ $DEBUG == "true" ]]; then
            log_info "SSH command failed or returned empty result"
            log_info "Error: $CONTAINER_CHECK"
        fi
        TEST_DOCKER="warn"
        return 0
    fi
}

# Check GPU status (if EC2 instance provided)
check_gpu_status() {
    if [[ -z "$INSTANCE_ID" ]]; then
        log_info "Skipping GPU check (no instance ID provided)"
        TEST_GPU="skip"
        return 0
    fi

    log "Checking GPU status..."

    KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"

    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    # Check GPU inside container
    GPU_INFO=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$PUBLIC_IP" \
        "docker exec paddleocr-vl-service nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader" 2>&1)
    SSH_EXIT_CODE=$?

    if [[ $DEBUG == "true" ]]; then
        log_info "GPU check SSH exit code: $SSH_EXIT_CODE"
        log_info "GPU check output: $GPU_INFO"
    fi

    if [[ $SSH_EXIT_CODE -eq 0 && -n "$GPU_INFO" && ! "$GPU_INFO" =~ "Error" ]]; then
        log "  GPU: $GPU_INFO"
        log "GPU detected ✓"
        TEST_GPU="pass"
        return 0
    else
        log_warning "Could not retrieve GPU information"
        if [[ $DEBUG == "true" ]]; then
            log_info "SSH command failed or returned error"
            log_info "Output: $GPU_INFO"
        fi
        TEST_GPU="warn"
        return 0
    fi
}

# Test OCR API
test_ocr_api() {
    if [[ "$SKIP_API_TEST" == "true" ]]; then
        log_info "Skipping API test (--skip-api-test flag set)"
        TEST_API="skip"
        return 0
    fi

    log "Testing OCR API..."

    # Create temporary test image if none provided
    if [[ -z "$TEST_IMAGE" ]]; then
        log "Creating temporary test image..."
        TEST_IMAGE="/tmp/test-ocr-$$.png"

        # Create a simple test image with text using ImageMagick (if available)
        if command -v convert &> /dev/null; then
            convert -size 400x100 xc:white \
                -pointsize 24 -fill black \
                -annotate +10+40 "PaddleOCR-VL Test" \
                -annotate +10+70 "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$TEST_IMAGE"
            log "Test image created: $TEST_IMAGE"
        else
            log_warning "ImageMagick not found, skipping API test"
            log_warning "Install ImageMagick or provide --test-image to test OCR"
            TEST_API="skip"
            return 0
        fi
    fi

    # Send OCR request
    log "Sending OCR request (timeout: ${TIMEOUT}s)..."
    START_TIME=$(date +%s)

    RESPONSE=$(curl -s --max-time "$TIMEOUT" \
        -X POST "http://${HOST}:${PORT}/api/v1/ocr/extract-document" \
        -F "file=@${TEST_IMAGE}" \
        -w "\n%{http_code}" || echo -e "\n000")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    log "  HTTP Status: $HTTP_CODE"
    log "  Request Time: ${ELAPSED}s"

    if [[ "$HTTP_CODE" == "200" ]]; then
        if command -v jq &> /dev/null; then
            SUCCESS=$(echo "$RESPONSE_BODY" | jq -r '.success // false')
            PROCESSING_TIME=$(echo "$RESPONSE_BODY" | jq -r '.processing_time // 0')
            RESULT_COUNT=$(echo "$RESPONSE_BODY" | jq -r '.results | length // 0')

            log "  Success: $SUCCESS"
            log "  Processing Time: ${PROCESSING_TIME}s"
            log "  Results: $RESULT_COUNT"

            if [[ "$SUCCESS" == "true" ]]; then
                log "OCR API test passed ✓"
                TEST_API="pass"

                # Extract text content
                TEXT_CONTENT=$(echo "$RESPONSE_BODY" | jq -r '.results[].parsing_res_list[].block_content // empty' | head -n 3)
                if [[ -n "$TEXT_CONTENT" ]]; then
                    log "  Sample extracted text:"
                    echo "$TEXT_CONTENT" | while read -r line; do
                        log "    $line"
                    done
                fi

                return 0
            else
                log_error "OCR processing failed"
                echo "$RESPONSE_BODY" | jq '.' || echo "$RESPONSE_BODY"
                TEST_API="fail"
                return 1
            fi
        else
            # Fallback without jq
            if echo "$RESPONSE_BODY" | grep -q '"success".*true'; then
                log "OCR API test passed ✓"
                TEST_API="pass"
                return 0
            else
                log_error "OCR processing failed"
                echo "$RESPONSE_BODY"
                TEST_API="fail"
                return 1
            fi
        fi
    else
        log_error "API request failed with status $HTTP_CODE"
        echo "$RESPONSE_BODY"
        TEST_API="fail"
        return 1
    fi
}

# Check logs (if EC2 instance provided)
check_logs() {
    if [[ -z "$INSTANCE_ID" ]]; then
        log_info "Skipping log check (no instance ID provided)"
        TEST_LOGS="skip"
        return 0
    fi

    log "Checking recent logs..."

    KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"

    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    # Get last 20 lines of logs using docker logs
    LOGS=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$PUBLIC_IP" \
        "docker logs paddleocr-vl-service --tail=20 2>&1")
    SSH_EXIT_CODE=$?

    if [[ $DEBUG == "true" ]]; then
        log_info "Logs check SSH exit code: $SSH_EXIT_CODE"
        log_info "First 100 chars of logs: ${LOGS:0:100}"
    fi

    if [[ $SSH_EXIT_CODE -eq 0 && -n "$LOGS" ]]; then
        # Check for errors
        ERROR_COUNT=$(echo "$LOGS" | grep -ci "error" || true)
        WARNING_COUNT=$(echo "$LOGS" | grep -ci "warning" || true)

        log "  Errors: $ERROR_COUNT"
        log "  Warnings: $WARNING_COUNT"

        if [[ $ERROR_COUNT -gt 0 ]]; then
            log_warning "Errors found in logs"
            echo "$LOGS" | grep -i "error" | tail -n 5
            TEST_LOGS="warn"
        else
            log "No errors in recent logs ✓"
            TEST_LOGS="pass"
        fi
    else
        log_warning "Could not retrieve logs"
        if [[ $DEBUG == "true" ]]; then
            log_info "SSH command failed or returned empty"
        fi
        TEST_LOGS="warn"
    fi
}

# Helper function to display test result
display_test_result() {
    local test_name="$1"
    local test_status="$2"

    case "$test_status" in
        pass)
            echo -e "  ${GREEN}✓${NC} $test_name"
            ;;
        fail)
            echo -e "  ${RED}✗${NC} $test_name"
            ;;
        warn)
            echo -e "  ${YELLOW}⚠${NC} $test_name"
            ;;
        skip)
            echo -e "  ${BLUE}⊘${NC} $test_name (skipped)"
            ;;
        *)
            echo -e "  ${YELLOW}?${NC} $test_name (not run)"
            ;;
    esac
}

# Display summary
display_summary() {
    log ""
    log "========================================="
    log "Verification Summary"
    log "========================================="
    log ""
    log "Service: http://${HOST}:${PORT}"

    if [[ -n "$INSTANCE_ID" ]]; then
        log "Instance: $INSTANCE_ID"
    fi

    log ""
    log "Test Results:"
    display_test_result "Connectivity" "$TEST_CONNECTIVITY"
    display_test_result "Health Check" "$TEST_HEALTH"

    if [[ -n "$INSTANCE_ID" ]]; then
        display_test_result "Docker Status" "$TEST_DOCKER"
        display_test_result "GPU Status" "$TEST_GPU"
        display_test_result "Recent Logs" "$TEST_LOGS"
    fi

    display_test_result "OCR API Test" "$TEST_API"

    log ""
    log "========================================="
    log ""
    log "Service Endpoints:"
    log "  Health: http://${HOST}:${PORT}/health"
    log "  API Docs: http://${HOST}:${PORT}/api/v1/docs"
    log "  OCR: http://${HOST}:${PORT}/api/v1/ocr/extract-document"
    log ""
    log "========================================="
}

# Main execution
main() {
    log "Starting PaddleOCR-VL Deployment Verification"
    log "=============================================="

    check_prerequisites

    # Run verification checks
    test_connectivity
    check_health
    check_docker_status
    check_gpu_status
    test_ocr_api
    check_logs

    display_summary

    log "Verification complete ✓"
}

# Run main function
main
