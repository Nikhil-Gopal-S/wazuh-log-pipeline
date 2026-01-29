#!/bin/bash
# =============================================================================
# Self-Signed Certificate Generation Script
# For development and testing purposes only
# =============================================================================
#
# Usage: ./generate-certs.sh [OPTIONS]
#
# Options:
#   -f, --force     Force regeneration even if certificates exist
#   -y, --yes       Non-interactive mode (auto-confirm prompts)
#   -h, --help      Show this help message
#
# Examples:
#   ./generate-certs.sh              # Interactive mode
#   ./generate-certs.sh -y           # Non-interactive, skip if exists
#   ./generate-certs.sh -f -y        # Non-interactive, force regenerate
# =============================================================================

set -e

# Configuration
CERT_DIR="./deploy/nginx/certs"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
DAYS_VALID=365
KEY_SIZE=2048
COUNTRY="US"
STATE="California"
CITY="San Francisco"
ORG="Wazuh Development"
OU="Security"
CN="localhost"

# Options
FORCE_REGEN=false
NON_INTERACTIVE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE_REGEN=true
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Self-Signed Certificate Generation Script"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --force     Force regeneration even if certificates exist"
            echo "  -y, --yes       Non-interactive mode (auto-confirm prompts)"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Self-Signed Certificate Generator${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Create certificates directory
mkdir -p "$CERT_DIR"

# Check if certificates already exist
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo -e "${YELLOW}Certificates already exist at:${NC}"
    echo "  Certificate: $CERT_FILE"
    echo "  Private Key: $KEY_FILE"
    echo ""
    
    if [ "$FORCE_REGEN" = true ]; then
        echo -e "${YELLOW}Force regeneration requested (-f flag)${NC}"
    elif [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${GREEN}Keeping existing certificates (non-interactive mode).${NC}"
        exit 0
    else
        read -p "Do you want to regenerate them? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Keeping existing certificates.${NC}"
            exit 0
        fi
    fi
fi

echo -e "${GREEN}Generating self-signed certificate...${NC}"
echo ""

# Generate private key and certificate
openssl req -x509 -nodes \
    -days $DAYS_VALID \
    -newkey rsa:$KEY_SIZE \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=$CN" \
    -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1"

# Set secure permissions
chmod 644 "$KEY_FILE"
chmod 644 "$CERT_FILE"

echo ""
echo -e "${GREEN}Certificate generated successfully!${NC}"
echo ""
echo "Certificate details:"
echo "  Location: $CERT_FILE"
echo "  Private Key: $KEY_FILE"
echo "  Valid for: $DAYS_VALID days"
echo "  Key Size: $KEY_SIZE bits"
echo ""

# Display certificate info
echo -e "${GREEN}Certificate Information:${NC}"
openssl x509 -in "$CERT_FILE" -noout -subject -dates

echo ""
echo -e "${YELLOW}WARNING: This is a self-signed certificate for development only.${NC}"
echo -e "${YELLOW}For production, use certificates from a trusted CA.${NC}"