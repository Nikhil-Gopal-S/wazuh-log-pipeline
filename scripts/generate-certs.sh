#!/bin/bash
# =============================================================================
# Self-Signed Certificate Generation Script
# For development and testing purposes only
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    read -p "Do you want to regenerate them? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Keeping existing certificates.${NC}"
        exit 0
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
chmod 600 "$KEY_FILE"
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