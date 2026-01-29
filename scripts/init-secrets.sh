#!/bin/bash
#
# Initialize secrets for the Wazuh Log Pipeline
# This script generates secure API keys and sets proper file permissions
#
set -e

# Configuration
SECRETS_DIR="./secrets"
API_KEY_FILE="${SECRETS_DIR}/api_key.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Wazuh Log Pipeline - Secrets Setup"
echo "=========================================="
echo ""

# Create secrets directory if it doesn't exist
if [ ! -d "$SECRETS_DIR" ]; then
    echo -e "${YELLOW}Creating secrets directory...${NC}"
    mkdir -p "$SECRETS_DIR"
    echo -e "${GREEN}✓ Created $SECRETS_DIR${NC}"
else
    echo -e "${GREEN}✓ Secrets directory exists${NC}"
fi

# Generate API key if it doesn't exist
if [ ! -f "$API_KEY_FILE" ]; then
    echo -e "${YELLOW}Generating new API key...${NC}"
    
    # Check if openssl is available
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}Error: openssl is required but not installed.${NC}"
        echo "Please install openssl and try again."
        exit 1
    fi
    
    # Generate a 32-byte (64 hex character) random key
    openssl rand -hex 32 > "$API_KEY_FILE"
    
    # Set restrictive permissions (owner read/write only)
    chmod 600 "$API_KEY_FILE"
    
    echo -e "${GREEN}✓ API key generated and saved to $API_KEY_FILE${NC}"
else
    echo -e "${GREEN}✓ API key already exists at $API_KEY_FILE${NC}"
    
    # Ensure permissions are correct even for existing files
    chmod 600 "$API_KEY_FILE"
    echo -e "${GREEN}✓ Verified permissions on $API_KEY_FILE${NC}"
fi

# Validate the generated key
if [ -f "$API_KEY_FILE" ]; then
    KEY_LENGTH=$(cat "$API_KEY_FILE" | tr -d '\n' | wc -c)
    if [ "$KEY_LENGTH" -eq 64 ]; then
        echo -e "${GREEN}✓ API key validation passed (64 hex characters)${NC}"
    else
        echo -e "${YELLOW}⚠ Warning: API key length is $KEY_LENGTH characters (expected 64)${NC}"
    fi
fi

# Display summary
echo ""
echo "=========================================="
echo "  Setup Complete"
echo "=========================================="
echo ""
echo "Secrets directory: $SECRETS_DIR"
echo "API key file:      $API_KEY_FILE"
echo ""
echo "File permissions:"
ls -la "$API_KEY_FILE"
echo ""
echo -e "${GREEN}Secrets initialized successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Start the application with: docker-compose up -d"
echo "  2. The API will read the key from $API_KEY_FILE"
echo ""