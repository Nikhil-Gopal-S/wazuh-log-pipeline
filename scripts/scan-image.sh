#!/bin/bash
# Container Image Vulnerability Scanner
# Uses Trivy to scan Docker images for security vulnerabilities
#
# Usage: ./scripts/scan-image.sh <image-name:tag>
# Example: ./scripts/scan-image.sh wazuh-api:latest

set -e

# Configuration
SEVERITY_THRESHOLD="CRITICAL,HIGH"
EXIT_ON_CRITICAL=true
REPORT_DIR="./reports/security"
TRIVY_VERSION="latest"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Parse arguments
IMAGE_NAME="${1:-wazuh-api:latest}"
REPORT_FORMAT="${2:-table}"  # table, json, sarif

# Create report directory
mkdir -p "$REPORT_DIR"

# Generate timestamp for report
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$REPORT_DIR/scan_${IMAGE_NAME//[:\/]/_}_${TIMESTAMP}"

echo "=========================================="
echo "Container Image Vulnerability Scanner"
echo "=========================================="
echo "Image: $IMAGE_NAME"
echo "Severity: $SEVERITY_THRESHOLD"
echo "Report: $REPORT_FILE"
echo ""

# Check if Trivy is installed locally
if command -v trivy &> /dev/null; then
    echo "Using local Trivy installation..."
    TRIVY_CMD="trivy"
    USE_DOCKER=false
else
    echo "Trivy not found locally, using Docker..."
    TRIVY_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $PWD/$REPORT_DIR:/reports aquasec/trivy:$TRIVY_VERSION"
    USE_DOCKER=true
fi

# Run Trivy scan
echo "Running Trivy vulnerability scan..."

if [ "$USE_DOCKER" = true ]; then
    # Run scan with Docker and save report
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$PWD/$REPORT_DIR:/reports" \
        aquasec/trivy:$TRIVY_VERSION image \
        --severity "$SEVERITY_THRESHOLD" \
        --format "$REPORT_FORMAT" \
        --output "/reports/scan_${IMAGE_NAME//[:\/]/_}_${TIMESTAMP}.${REPORT_FORMAT}" \
        "$IMAGE_NAME"
    
    SCAN_EXIT_CODE=$?
    
    # Also generate table output for console
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        aquasec/trivy:$TRIVY_VERSION image \
        --severity "$SEVERITY_THRESHOLD" \
        "$IMAGE_NAME"
else
    # Run scan with local Trivy
    trivy image \
        --severity "$SEVERITY_THRESHOLD" \
        --format "$REPORT_FORMAT" \
        --output "$REPORT_FILE.$REPORT_FORMAT" \
        "$IMAGE_NAME"
    
    SCAN_EXIT_CODE=$?
    
    # Also generate table output for console
    trivy image \
        --severity "$SEVERITY_THRESHOLD" \
        "$IMAGE_NAME"
fi

# Check results
echo ""
if [ $SCAN_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ No CRITICAL or HIGH vulnerabilities found${NC}"
else
    echo -e "${RED}✗ Vulnerabilities found!${NC}"
    if [ "$EXIT_ON_CRITICAL" = true ]; then
        echo -e "${YELLOW}Exiting with error due to EXIT_ON_CRITICAL=true${NC}"
        exit 1
    fi
fi

echo ""
echo "Report saved to: $REPORT_FILE.$REPORT_FORMAT"
echo ""
echo "=========================================="
echo "Scan Complete"
echo "=========================================="