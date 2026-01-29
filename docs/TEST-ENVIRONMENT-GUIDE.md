# Test Environment Deployment Guide

## Wazuh Log Ingestion Pipeline - Pre-Production Validation

**Version:** 1.0.0  
**Last Updated:** 2026-01-29  
**Purpose:** Step-by-step guide for deploying and testing the Wazuh log ingestion pipeline in a test VM environment

---

## Table of Contents

1. [Overview](#1-overview)
2. [Test Environment Configuration](#2-test-environment-configuration)
3. [Wazuh Agent Connection](#3-wazuh-agent-connection)
4. [Rate Limiting Implementation](#4-rate-limiting-implementation)
5. [IP Whitelisting Configuration](#5-ip-whitelisting-configuration)
6. [Sample Test Events](#6-sample-test-events)
7. [Custom Wazuh Rules and Decoders](#7-custom-wazuh-rules-and-decoders)
8. [Dashboard Verification](#8-dashboard-verification)
9. [Complete Test Workflow](#9-complete-test-workflow)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

This guide provides comprehensive instructions for deploying the Wazuh log ingestion pipeline in a test VM environment for pre-production validation. The test environment connects to an **existing Wazuh Manager** and allows you to validate:

- API functionality and authentication
- Rate limiting behavior
- IP whitelisting configuration
- Log ingestion and forwarding to Wazuh
- Custom decoders and rules
- Dashboard visualization

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         TEST ENVIRONMENT                                 │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    TEST VM (Docker Host)                           │ │
│  │                                                                     │ │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌────────────────┐ │ │
│  │  │     Nginx       │    │   API Service   │    │  Wazuh Agent   │ │ │
│  │  │  (Port 443/80)  │───▶│   (Port 9000)   │───▶│  (Container)   │ │ │
│  │  │                 │    │                 │    │                │ │ │
│  │  └─────────────────┘    └─────────────────┘    └───────┬────────┘ │ │
│  │                                                         │          │ │
│  │  ┌─────────────────┐                                   │          │ │
│  │  │    Fail2ban     │                                   │          │ │
│  │  │   (Optional)    │                                   │          │ │
│  │  └─────────────────┘                                   │          │ │
│  └────────────────────────────────────────────────────────┼──────────┘ │
│                                                            │            │
└────────────────────────────────────────────────────────────┼────────────┘
                                                             │
                                                             ▼
                                          ┌──────────────────────────────┐
                                          │   EXISTING WAZUH MANAGER     │
                                          │      (Port 1514/1515)        │
                                          │                              │
                                          │  • Receives agent data       │
                                          │  • Processes custom rules    │
                                          │  • Stores in Wazuh Indexer   │
                                          └──────────────────────────────┘
```

### Key Differences from Production

| Aspect | Test Environment | Production |
|--------|------------------|------------|
| TLS Certificates | Self-signed (OK) | CA-signed required |
| Cloudflare | Not used | Required for WAF |
| Rate Limits | Lower (for testing) | Higher (100 req/s) |
| IP Extraction | Direct client IP | CF-Connecting-IP |
| Fail2ban | Optional | Required |

---

## 2. Test Environment Configuration

### 2.1 Prerequisites

#### VM Specifications

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 2 cores | 4 cores |
| **RAM** | 4 GB | 8 GB |
| **Disk** | 20 GB | 50 GB |
| **OS** | Ubuntu 22.04 LTS / Debian 12 | Ubuntu 22.04 LTS |

#### Required Software

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Install Docker Compose (v2)
sudo apt install -y docker-compose-plugin

# Verify installations
docker --version
docker compose version

# Install additional utilities
sudo apt install -y curl jq openssl git
```

#### Network Requirements

| Port | Direction | Protocol | Purpose |
|------|-----------|----------|---------|
| **443** | Inbound | TCP | HTTPS API access |
| **80** | Inbound | TCP | HTTP → HTTPS redirect |
| **1514** | Outbound | TCP | Wazuh agent communication |
| **1515** | Outbound | TCP | Wazuh agent enrollment |

Ensure the test VM can reach the existing Wazuh Manager on ports 1514 and 1515.

### 2.2 Clone and Setup Repository

```bash
# Clone the repository
git clone <repository-url> wazuh-log-pipeline
cd wazuh-log-pipeline

# Create required directories
mkdir -p secrets backups deploy/nginx/certs

# Set directory permissions
chmod 700 secrets
chmod 755 backups
chmod 755 deploy/nginx/certs
```

### 2.3 Environment Variables for Test Mode

Create a `.env` file with test environment settings:

```bash
cat > .env << 'EOF'
# =============================================================================
# Test Environment Configuration
# =============================================================================

# Environment identifier
ENVIRONMENT=development

# Disable strict TLS checking for self-signed certificates
STRICT_TLS_CHECK=false

# Log level (use INFO or DEBUG for testing)
LOG_LEVEL=INFO

# =============================================================================
# Wazuh Manager Connection
# =============================================================================
# Replace with your existing Wazuh Manager's IP or hostname
MANAGER_URL=192.168.1.100
MANAGER_PORT=1515
SERVER_URL=192.168.1.100
SERVER_PORT=1514

# =============================================================================
# Agent Configuration
# =============================================================================
# Unique name for this test agent
NAME=test-api-ingest-vm

# Agent group (create this group in Wazuh Manager first)
GROUP=test-ingest

# Enrollment token (get from Wazuh Manager)
# Generate with: /var/ossec/bin/manage_agents -e
ENROL_TOKEN=your-enrollment-token-here

# =============================================================================
# API Configuration
# =============================================================================
# Request timeout (seconds)
REQUEST_TIMEOUT_SECONDS=30

# Slow request warning threshold (seconds)
SLOW_REQUEST_THRESHOLD=5

# Decoder header for log routing
WAZUH_DECODER_HEADER=1:custom-api:
EOF
```

### 2.4 Docker Compose Configuration for Test Environment

The default [`docker-compose.yml`](../docker-compose.yml) works for testing. Key services:

| Service | Container Name | Purpose |
|---------|----------------|---------|
| `nginx` | `wazuh-nginx` | Reverse proxy, TLS termination |
| `agent-ingest` | - | API + Wazuh agent |
| `fail2ban` | `wazuh-fail2ban` | IP banning (optional for testing) |

#### Disabling Cloudflare IP Extraction for Direct Testing

For direct testing without Cloudflare, modify the Nginx configuration to use the direct client IP instead of `CF-Connecting-IP`.

Create a test-specific Cloudflare configuration:

```bash
# Backup original configuration
cp deploy/nginx/conf.d/cloudflare_real_ip.conf deploy/nginx/conf.d/cloudflare_real_ip.conf.bak

# Create test configuration that uses direct client IP
cat > deploy/nginx/conf.d/cloudflare_real_ip.conf << 'EOF'
# =============================================================================
# Test Environment: Direct Client IP Configuration
# =============================================================================
# For testing WITHOUT Cloudflare, we use the direct client IP.
# In production, restore the original cloudflare_real_ip.conf file.
# =============================================================================

# Trust local/private networks for X-Forwarded-For header
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
set_real_ip_from 192.168.0.0/16;
set_real_ip_from 127.0.0.1;

# Use X-Forwarded-For header if present, otherwise use direct connection IP
real_ip_header X-Forwarded-For;
real_ip_recursive on;
EOF
```

### 2.5 Generate Test Certificates (Self-Signed)

For testing, self-signed certificates are acceptable:

```bash
# Run the certificate generation script
./scripts/generate-certs.sh
```

**Expected output:**
```
========================================
Self-Signed Certificate Generator
========================================

Generating self-signed certificate...

Certificate generated successfully!

Certificate details:
  Location: ./deploy/nginx/certs/server.crt
  Private Key: ./deploy/nginx/certs/server.key
  Valid for: 365 days
  Key Size: 2048 bits

Certificate Information:
subject=C = US, ST = California, L = San Francisco, O = Wazuh Development, OU = Security, CN = localhost
notBefore=Jan 29 00:00:00 2026 GMT
notAfter=Jan 29 00:00:00 2027 GMT

WARNING: This is a self-signed certificate for development only.
For production, use certificates from a trusted CA.
```

**Verify certificates exist:**
```bash
ls -la deploy/nginx/certs/
# Expected:
# -rw-r--r-- 1 user user 1234 Jan 29 00:00 server.crt
# -rw------- 1 user user 1704 Jan 29 00:00 server.key
```

### 2.6 Generate Test API Key

```bash
# Run the secrets initialization script
./scripts/init-secrets.sh
```

**Expected output:**
```
==========================================
  Wazuh Log Pipeline - Secrets Setup
==========================================

✓ Secrets directory exists
Generating new API key...
✓ API key generated and saved to ./secrets/api_key.txt
✓ API key validation passed (64 hex characters)

==========================================
  Setup Complete
==========================================

Secrets directory: ./secrets
API key file:      ./secrets/api_key.txt

File permissions:
-rw------- 1 user user 65 Jan 29 00:00 ./secrets/api_key.txt

Secrets initialized successfully!
```

**Store the API key for testing:**
```bash
# View and copy the API key
cat secrets/api_key.txt

# Store in environment variable for easy access during testing
export API_KEY=$(cat secrets/api_key.txt)
echo "API Key: $API_KEY"
```

### 2.7 Build and Start Services

```bash
# Build Docker images
docker compose build --no-cache

# Start services in detached mode
docker compose up -d

# Verify all containers are running
docker compose ps
```

**Expected output:**
```
NAME                IMAGE                              STATUS          PORTS
wazuh-nginx         wazuh-log-pipeline-nginx           Up (healthy)    0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
agent-ingest        sammascanner/wazuh-agent:ingets    Up (healthy)    
wazuh-fail2ban      wazuh-log-pipeline-fail2ban        Up              
```

**Check container logs for errors:**
```bash
# View all logs
docker compose logs -f --tail=50

# View specific service logs
docker compose logs -f agent-ingest
docker compose logs -f nginx
```

### 2.8 Verify Basic Connectivity

```bash
# Test liveness probe (no auth required)
curl -k https://localhost/health/live
# Expected: {"status":"alive"}

# Test readiness probe (no auth required)
curl -k https://localhost/health/ready
# Expected: {"status":"ready","wazuh_socket":"connected"}

# Test authentication enforcement (should fail without API key)
curl -k https://localhost/api/health
# Expected: 401 Unauthorized

# Test with API key (should succeed)
curl -k -H "X-API-Key: $API_KEY" https://localhost/api/health
# Expected: {"status":"healthy","service":"wazuh-api","version":"1.0.0",...}
```

---

## 3. Wazuh Agent Connection

The test VM runs a Wazuh agent inside the `agent-ingest` container that must connect to your **existing Wazuh Manager**.

### 3.1 Wazuh Manager Prerequisites

Before connecting the test agent, ensure your Wazuh Manager is configured to accept new agents:

**On the Wazuh Manager:**
```bash
# Check Wazuh Manager is running
sudo systemctl status wazuh-manager

# Verify authd is running (for agent enrollment)
sudo /var/ossec/bin/wazuh-control status
# Should show: wazuh-authd is running

# Check listening ports
sudo netstat -tlnp | grep -E '1514|1515'
# Expected:
# tcp 0 0 0.0.0.0:1514 0.0.0.0:* LISTEN <pid>/wazuh-remoted
# tcp 0 0 0.0.0.0:1515 0.0.0.0:* LISTEN <pid>/wazuh-authd
```

### 3.2 Agent Configuration (ossec.conf)

The agent configuration is generated from the template at [`config/ossec.tpl`](../config/ossec.tpl) using environment variables. The key settings are:

```xml
<ossec_config>
  <client>
    <server>
      <address>${SERVER_URL}</address>
      <port>${SERVER_PORT}</port>
      <protocol>tcp</protocol>
    </server>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>${MANAGER_URL}</manager_address>
      <port>${MANAGER_PORT}</port>
      <agent_name>${NAME}</agent_name>
      <groups>${GROUP}</groups>
    </enrollment>
  </client>
</ossec_config>
```

The environment variables in your `.env` file control these settings:

| Variable | Purpose | Example |
|----------|---------|---------|
| `SERVER_URL` | Wazuh Manager IP for communication | `192.168.1.100` |
| `SERVER_PORT` | Agent communication port | `1514` |
| `MANAGER_URL` | Wazuh Manager IP for enrollment | `192.168.1.100` |
| `MANAGER_PORT` | Agent enrollment port | `1515` |
| `NAME` | Unique agent name | `test-api-ingest-vm` |
| `GROUP` | Agent group | `test-ingest` |

### 3.3 Agent Registration

The agent automatically attempts to register on container startup. If automatic registration fails, you can manually register:

**Option A: Using Enrollment Token (Recommended)**

1. **On the Wazuh Manager**, generate an enrollment token:
   ```bash
   # Generate enrollment token
   sudo /var/ossec/bin/manage_agents -e
   ```

2. **Add the token to your `.env` file:**
   ```bash
   ENROL_TOKEN=your-generated-token
   ```

3. **Restart the container:**
   ```bash
   docker compose restart agent-ingest
   ```

**Option B: Manual Registration with agent-auth**

1. **Access the container:**
   ```bash
   docker compose exec agent-ingest bash
   ```

2. **Run agent-auth:**
   ```bash
   /var/ossec/bin/agent-auth -m <MANAGER_IP> -A <AGENT_NAME>
   ```
   
   Example:
   ```bash
   /var/ossec/bin/agent-auth -m 192.168.1.100 -A test-api-ingest-vm
   ```

3. **Expected output:**
   ```
   2026/01/29 10:00:00 agent-auth: INFO: Started (pid: 1234).
   2026/01/29 10:00:00 agent-auth: INFO: Requesting a key from server: 192.168.1.100
   2026/01/29 10:00:00 agent-auth: INFO: Using agent name as: test-api-ingest-vm
   2026/01/29 10:00:00 agent-auth: INFO: Waiting for server reply
   2026/01/29 10:00:01 agent-auth: INFO: Valid key received
   ```

4. **Restart the Wazuh agent:**
   ```bash
   /var/ossec/bin/wazuh-control restart
   ```

### 3.4 Verify Agent Connection

**On the Test VM (inside container):**
```bash
# Check agent status
docker compose exec agent-ingest /var/ossec/bin/wazuh-control status

# Expected output:
# wazuh-agentd is running...
# wazuh-execd is running...
# wazuh-modulesd is running...
# wazuh-syscheckd is running...
# wazuh-logcollector is running...

# Check agent logs for connection status
docker compose exec agent-ingest tail -20 /var/ossec/logs/ossec.log

# Look for:
# "Connected to the server"
# "Agent is now connected"
```

**On the Wazuh Manager:**
```bash
# List connected agents
sudo /var/ossec/bin/manage_agents -l

# Expected output:
# Available agents:
#    ID: 001, Name: test-api-ingest-vm, IP: any, Active

# Check agent status via API (if Wazuh API is enabled)
curl -k -u admin:admin https://localhost:55000/agents?pretty

# Check agent connection in real-time
sudo tail -f /var/ossec/logs/ossec.log | grep -i "test-api-ingest"
```

### 3.5 Troubleshooting Agent Connection

#### Issue: Agent not connecting

**Check network connectivity:**
```bash
# From test VM, verify connectivity to Wazuh Manager
nc -zv <MANAGER_IP> 1514
nc -zv <MANAGER_IP> 1515

# Expected:
# Connection to <MANAGER_IP> 1514 port [tcp/*] succeeded!
# Connection to <MANAGER_IP> 1515 port [tcp/*] succeeded!
```

**Check firewall rules on Wazuh Manager:**
```bash
# On Wazuh Manager
sudo ufw status
# or
sudo iptables -L -n | grep -E '1514|1515'
```

#### Issue: Authentication failed

**Check agent key:**
```bash
# Inside container
docker compose exec agent-ingest cat /var/ossec/etc/client.keys
# Should contain: <agent_id> <agent_name> <any> <key>
```

**Re-register the agent:**
```bash
# Remove existing key
docker compose exec agent-ingest rm -f /var/ossec/etc/client.keys

# Re-run registration
docker compose exec agent-ingest /var/ossec/bin/agent-auth -m <MANAGER_IP> -A <AGENT_NAME>
```

#### Issue: Agent shows as disconnected on Manager

**Check agent logs:**
```bash
docker compose exec agent-ingest tail -50 /var/ossec/logs/ossec.log
```

**Common causes:**
- Firewall blocking ports 1514/1515
- Wrong Manager IP in configuration
- Agent name conflict (another agent with same name)
- Time synchronization issues between agent and manager

---

## 4. Rate Limiting Implementation

### 4.1 Understanding Rate Limiting Configuration

Rate limiting is configured in [`deploy/nginx/conf.d/rate-limiting.conf`](../deploy/nginx/conf.d/rate-limiting.conf):

```nginx
# Global rate limit zone
# - $limit_key: Either $binary_remote_addr (for non-whitelisted IPs) or ""
#   (empty string for whitelisted IPs, which bypasses rate limiting)
# - zone=api_limit:10m: 10MB shared memory zone
# - rate=100r/s: Maximum 100 requests per second per IP address
limit_req_zone $limit_key zone=api_limit:10m rate=100r/s;

# Health endpoint rate limit zone (separate to prevent abuse)
limit_req_zone $limit_key zone=health_limit:1m rate=10r/s;

# Return 429 Too Many Requests when rate limit is exceeded
limit_req_status 429;

# Log rate-limited requests at warn level
limit_req_log_level warn;
```

Rate limits are applied in [`deploy/nginx/conf.d/default.conf`](../deploy/nginx/conf.d/default.conf):

```nginx
# Health endpoints: 10 req/s with burst of 5
location /health {
    limit_req zone=health_limit burst=5 nodelay;
    # ...
}

# API endpoints: 100 req/s with burst of 50
location /api/ {
    limit_req zone=api_limit burst=50 nodelay;
    # ...
}
```

### 4.2 Adjusting Rate Limits for Testing

For easier testing, create lower rate limits:

```bash
# Backup original configuration
cp deploy/nginx/conf.d/rate-limiting.conf deploy/nginx/conf.d/rate-limiting.conf.bak

# Create test configuration with lower limits
cat > deploy/nginx/conf.d/rate-limiting.conf << 'EOF'
# =============================================================================
# TEST ENVIRONMENT: Lower Rate Limits for Testing
# =============================================================================
# These limits are intentionally low to easily test rate limiting behavior.
# For production, restore the original rate-limiting.conf file.
# =============================================================================

# API rate limit: 5 requests per second (easy to test)
limit_req_zone $limit_key zone=api_limit:10m rate=5r/s;

# Health endpoint rate limit: 2 requests per second
limit_req_zone $limit_key zone=health_limit:1m rate=2r/s;

# Return 429 Too Many Requests when rate limit is exceeded
limit_req_status 429;

# Log rate-limited requests at warn level
limit_req_log_level warn;
EOF

# Reload Nginx to apply changes
docker compose exec nginx nginx -s reload
```

### 4.3 Test Commands to Verify Rate Limiting

#### Test Health Endpoint Rate Limiting

```bash
# Send 10 rapid requests to health endpoint (limit: 2r/s + burst 5)
echo "Testing health endpoint rate limiting..."
for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k https://localhost/health/live)
  echo "Request $i: HTTP $STATUS"
done
```

**Expected output:**
```
Testing health endpoint rate limiting...
Request 1: HTTP 200
Request 2: HTTP 200
Request 3: HTTP 200
Request 4: HTTP 200
Request 5: HTTP 200
Request 6: HTTP 200
Request 7: HTTP 200
Request 8: HTTP 429    # Rate limited
Request 9: HTTP 429    # Rate limited
Request 10: HTTP 429   # Rate limited
```

#### Test API Endpoint Rate Limiting

```bash
# Send 15 rapid requests to API endpoint (limit: 5r/s + burst 50)
echo "Testing API endpoint rate limiting..."
for i in {1..15}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k \
    -H "X-API-Key: $API_KEY" \
    https://localhost/api/health)
  echo "Request $i: HTTP $STATUS"
done
```

#### Burst Test Script

Create a comprehensive test script:

```bash
cat > test-rate-limiting.sh << 'EOF'
#!/bin/bash
# Rate Limiting Test Script

API_KEY="${API_KEY:-$(cat secrets/api_key.txt)}"
HOST="${HOST:-https://localhost}"

echo "============================================"
echo "Rate Limiting Test Suite"
echo "============================================"
echo ""

# Test 1: Health endpoint burst
echo "Test 1: Health Endpoint Burst (10 requests)"
echo "--------------------------------------------"
SUCCESS=0
RATE_LIMITED=0
for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k "$HOST/health/live")
  if [ "$STATUS" = "200" ]; then
    ((SUCCESS++))
  elif [ "$STATUS" = "429" ]; then
    ((RATE_LIMITED++))
  fi
done
echo "Success: $SUCCESS, Rate Limited: $RATE_LIMITED"
echo ""

# Wait for rate limit to reset
echo "Waiting 2 seconds for rate limit reset..."
sleep 2
echo ""

# Test 2: API endpoint burst
echo "Test 2: API Endpoint Burst (20 requests)"
echo "-----------------------------------------"
SUCCESS=0
RATE_LIMITED=0
AUTH_FAILED=0
for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k \
    -H "X-API-Key: $API_KEY" \
    "$HOST/api/health")
  if [ "$STATUS" = "200" ]; then
    ((SUCCESS++))
  elif [ "$STATUS" = "429" ]; then
    ((RATE_LIMITED++))
  elif [ "$STATUS" = "401" ]; then
    ((AUTH_FAILED++))
  fi
done
echo "Success: $SUCCESS, Rate Limited: $RATE_LIMITED, Auth Failed: $AUTH_FAILED"
echo ""

# Test 3: Sustained load
echo "Test 3: Sustained Load (1 request/second for 10 seconds)"
echo "---------------------------------------------------------"
SUCCESS=0
RATE_LIMITED=0
for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k \
    -H "X-API-Key: $API_KEY" \
    "$HOST/api/health")
  if [ "$STATUS" = "200" ]; then
    ((SUCCESS++))
  elif [ "$STATUS" = "429" ]; then
    ((RATE_LIMITED++))
  fi
  sleep 1
done
echo "Success: $SUCCESS, Rate Limited: $RATE_LIMITED"
echo ""

echo "============================================"
echo "Rate Limiting Tests Complete"
echo "============================================"
EOF

chmod +x test-rate-limiting.sh
./test-rate-limiting.sh
```

### 4.4 View Rate Limit Logs

```bash
# View Nginx access logs for rate-limited requests
docker compose exec nginx cat /var/log/nginx/access.log | \
  jq -r 'select(.status == 429) | "\(.timestamp) \(.remote_addr) \(.request_uri)"'

# Watch rate limiting in real-time
docker compose exec nginx tail -f /var/log/nginx/access.log | \
  jq -r 'select(.status == 429) | "RATE LIMITED: \(.remote_addr) -> \(.request_uri)"'

# Check Nginx error log for rate limit warnings
docker compose exec nginx grep "limiting requests" /var/log/nginx/error.log
```

### 4.5 Restore Production Rate Limits

After testing, restore the original configuration:

```bash
# Restore original rate limiting configuration
cp deploy/nginx/conf.d/rate-limiting.conf.bak deploy/nginx/conf.d/rate-limiting.conf

# Reload Nginx
docker compose exec nginx nginx -s reload
```

---

## 5. IP Whitelisting Configuration

### 5.1 Understanding IP Whitelisting

IP whitelisting is configured in [`deploy/nginx/conf.d/ip-whitelist.conf`](../deploy/nginx/conf.d/ip-whitelist.conf). Whitelisted IPs bypass rate limiting entirely.

**How it works:**

1. The `geo` block checks if the client IP is in the whitelist
2. The `map` block converts the whitelist status to a rate limit key
3. Whitelisted IPs get an empty key (bypasses rate limit)
4. Non-whitelisted IPs use their IP address as the key (subject to rate limit)

```nginx
# Geo block: Returns 1 for whitelisted IPs, 0 for others
geo $whitelist {
    default 0;
    
    # Localhost
    127.0.0.1 1;
    ::1 1;
    
    # Private networks
    10.0.0.0/8 1;
    172.16.0.0/12 1;
    192.168.0.0/16 1;
    
    # Docker networks
    172.17.0.0/16 1;
    172.18.0.0/16 1;
    172.19.0.0/16 1;
    172.20.0.0/16 1;
}

# Map block: Convert whitelist status to rate limit key
map $whitelist $limit_key {
    0 $binary_remote_addr;  # Non-whitelisted: use IP as key
    1 "";                    # Whitelisted: empty key bypasses rate limiting
}
```

### 5.2 Configure Test Machine IP for Whitelisting

To add your test machine's IP to the whitelist:

**Method 1: Using the update-whitelist.sh script**

```bash
# Add a single IP
./scripts/update-whitelist.sh add 10.0.0.100 "Test machine - Development"

# Add a CIDR range
./scripts/update-whitelist.sh add 10.0.0.0/24 "Test network"

# List current whitelist
./scripts/update-whitelist.sh list

# Validate configuration
./scripts/update-whitelist.sh validate
```

**Method 2: Manual configuration**

Edit [`deploy/nginx/conf.d/ip-whitelist.conf`](../deploy/nginx/conf.d/ip-whitelist.conf):

```bash
# Open the file for editing
nano deploy/nginx/conf.d/ip-whitelist.conf
```

Add your test machine IP in the "Trusted External IPs" section:

```nginx
    # === ADD TRUSTED EXTERNAL IPs BELOW THIS LINE ===
    
    # Test machine - exempt from rate limiting
    10.0.0.100 1;  # Test workstation - Added 2026-01-29 by admin
    
    # Test network range
    10.0.0.0/24 1;  # Test lab network - Added 2026-01-29 by admin
    
    # === END TRUSTED EXTERNAL IPs ===
```

**Apply the changes:**

```bash
# Reload Nginx to apply whitelist changes
docker compose exec nginx nginx -s reload

# Verify configuration is valid
docker compose exec nginx nginx -t
```

### 5.3 Verify Whitelist is Working

**Test from a whitelisted IP:**

```bash
# From your whitelisted test machine, send many rapid requests
# These should all succeed (no 429 responses)
for i in {1..50}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k https://<TEST_VM_IP>/health/live)
  echo "Request $i: HTTP $STATUS"
done

# All requests should return 200 (no rate limiting)
```

**Test from a non-whitelisted IP:**

```bash
# From a different machine (not whitelisted), send rapid requests
# These should hit rate limits
for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k https://<TEST_VM_IP>/health/live)
  echo "Request $i: HTTP $STATUS"
done

# Should see 429 responses after burst limit is exceeded
```

### 5.4 Remove IP from Whitelist

```bash
# Using the script
./scripts/update-whitelist.sh remove 10.0.0.100

# Reload Nginx
docker compose exec nginx nginx -s reload
```

---

## 6. Sample Test Events

### 6.1 Event Schema

The API accepts events with the following schema (defined in [`api/api.py`](../api/api.py:400)):

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `timestamp` | string | Yes | ISO 8601 format timestamp |
| `source` | string | Yes | Source identifier (1-256 chars) |
| `message` | string | Yes | Log message (1-65536 chars) |
| `level` | string | No | Log level: debug, info, warning, error, critical |
| `tags` | array | No | List of tags for categorization |
| `metadata` | object | No | Additional key-value pairs |
| `decoder` | string | No | Custom decoder name for Wazuh |

### 6.2 Sample Events

#### Example 1: Simple Security Event

```json
{
  "timestamp": "2026-01-29T10:00:00Z",
  "source": "test-application",
  "event_type": "authentication",
  "severity": "warning",
  "message": "Failed login attempt",
  "level": "warning",
  "tags": ["security", "authentication", "failed-login"],
  "metadata": {
    "user": "admin",
    "source_ip": "192.168.1.100",
    "attempts": 3,
    "method": "password"
  }
}
```

**Send this event:**
```bash
curl -k -X PUT https://localhost/api/ \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": "2026-01-29T10:00:00Z",
    "source": "test-application",
    "message": "Failed login attempt for user admin from 192.168.1.100",
    "level": "warning",
    "tags": ["security", "authentication", "failed-login"],
    "metadata": {
      "user": "admin",
      "source_ip": "192.168.1.100",
      "attempts": 3,
      "method": "password"
    }
  }'
```

**Expected response:**
```json
{
  "status": "success",
  "message": "Event sent to Wazuh",
  "request_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

#### Example 2: System Event

```json
{
  "timestamp": "2026-01-29T10:01:00Z",
  "source": "test-server",
  "message": "Service nginx started successfully",
  "level": "info",
  "tags": ["system", "service", "startup"],
  "metadata": {
    "service": "nginx",
    "pid": 1234,
    "action": "start",
    "status": "success"
  }
}
```

**Send this event:**
```bash
curl -k -X PUT https://localhost/api/ \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": "2026-01-29T10:01:00Z",
    "source": "test-server",
    "message": "Service nginx started successfully",
    "level": "info",
    "tags": ["system", "service", "startup"],
    "metadata": {
      "service": "nginx",
      "pid": 1234,
      "action": "start",
      "status": "success"
    }
  }'
```

#### Example 3: Network Security Event

```json
{
  "timestamp": "2026-01-29T10:02:00Z",
  "source": "firewall",
  "message": "Blocked connection attempt from 10.0.0.50 to 192.168.1.1:22",
  "level": "error",
  "tags": ["network", "firewall", "blocked", "ssh"],
  "metadata": {
    "source_ip": "10.0.0.50",
    "dest_ip": "192.168.1.1",
    "dest_port": 22,
    "protocol": "tcp",
    "action": "blocked",
    "rule_id": "1001"
  }
}
```

**Send this event:**
```bash
curl -k -X PUT https://localhost/api/ \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": "2026-01-29T10:02:00Z",
    "source": "firewall",
    "message": "Blocked connection attempt from 10.0.0.50 to 192.168.1.1:22",
    "level": "error",
    "tags": ["network", "firewall", "blocked", "ssh"],
    "metadata": {
      "source_ip": "10.0.0.50",
      "dest_ip": "192.168.1.1",
      "dest_port": 22,
      "protocol": "tcp",
      "action": "blocked",
      "rule_id": "1001"
    }
  }'
```

#### Example 4: Application Error Event

```json
{
  "timestamp": "2026-01-29T10:03:00Z",
  "source": "web-application",
  "message": "Database connection timeout after 30 seconds",
  "level": "critical",
  "tags": ["application", "database", "timeout", "critical"],
  "metadata": {
    "database": "production-db",
    "host": "db.internal.example.com",
    "port": 5432,
    "timeout_seconds": 30,
    "retry_count": 3
  }
}
```

**Send this event:**
```bash
curl -k -X PUT https://localhost/api/ \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": "2026-01-29T10:03:00Z",
    "source": "web-application",
    "message": "Database connection timeout after 30 seconds",
    "level": "critical",
    "tags": ["application", "database", "timeout", "critical"],
    "metadata": {
      "database": "production-db",
      "host": "db.internal.example.com",
      "port": 5432,
      "timeout_seconds": 30,
      "retry_count": 3
    }
  }'
```

### 6.3 Batch Event Submission

Send multiple events in a single request using the `/batch` endpoint:

```bash
curl -k -X PUT https://localhost/batch \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {
        "timestamp": "2026-01-29T10:00:00Z",
        "source": "batch-test",
        "message": "Batch event 1 - User login",
        "level": "info",
        "tags": ["batch", "test"],
        "metadata": {"event_number": 1}
      },
      {
        "timestamp": "2026-01-29T10:00:01Z",
        "source": "batch-test",
        "message": "Batch event 2 - File access",
        "level": "info",
        "tags": ["batch", "test"],
        "metadata": {"event_number": 2}
      },
      {
        "timestamp": "2026-01-29T10:00:02Z",
        "source": "batch-test",
        "message": "Batch event 3 - Configuration change",
        "level": "warning",
        "tags": ["batch", "test", "config"],
        "metadata": {"event_number": 3}
      }
    ]
  }'
```

**Expected response:**
```json
{
  "status": "batch_processed",
  "total": 3,
  "errors": 0,
  "details": [
    {"status": "success", "message": "Event sent to Wazuh"},
    {"status": "success", "message": "Event sent to Wazuh"},
    {"status": "success", "message": "Event sent to Wazuh"}
  ],
  "request_id": "b2c3d4e5-f6a7-8901-bcde-f23456789012"
}
```

### 6.4 Test Event Generation Script

Create a script to generate and send test events:

```bash
cat > generate-test-events.sh << 'EOF'
#!/bin/bash
# Test Event Generator Script

API_KEY="${API_KEY:-$(cat secrets/api_key.txt)}"
HOST="${HOST:-https://localhost}"

echo "============================================"
echo "Test Event Generator"
echo "============================================"
echo ""

# Function to send event
send_event() {
  local event="$1"
  local description="$2"
  
  echo "Sending: $description"
  RESPONSE=$(curl -s -k -X PUT "$HOST/api/" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$event")
  
  STATUS=$(echo "$RESPONSE" | jq -r '.status // "error"')
  if [ "$STATUS" = "success" ]; then
    echo "  ✓ Success"
  else
    echo "  ✗ Failed: $RESPONSE"
  fi
  echo ""
}

# Event 1: Authentication failure
send_event '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test-auth-service",
  "message": "Failed login attempt for user testuser",
  "level": "warning",
  "tags": ["security", "auth"],
  "metadata": {"user": "testuser", "source_ip": "10.0.0.50"}
}' "Authentication failure event"

# Event 2: Successful login
send_event '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test-auth-service",
  "message": "Successful login for user admin",
  "level": "info",
  "tags": ["security", "auth", "success"],
  "metadata": {"user": "admin", "source_ip": "10.0.0.1"}
}' "Successful login event"

# Event 3: Firewall block
send_event '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test-firewall",
  "message": "Blocked suspicious connection attempt",
  "level": "error",
  "tags": ["network", "firewall", "blocked"],
  "metadata": {"src_ip": "192.168.100.50", "dst_port": 22, "protocol": "tcp"}
}' "Firewall block event"

# Event 4: Application error
send_event '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test-application",
  "message": "Unhandled exception in payment processing module",
  "level": "critical",
  "tags": ["application", "error", "payment"],
  "metadata": {"module": "payment", "error_code": "PAY001"}
}' "Application error event"

# Event 5: System event
send_event '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "source": "test-system",
  "message": "Disk usage exceeded 80% threshold",
  "level": "warning",
  "tags": ["system", "disk", "threshold"],
  "metadata": {"disk": "/dev/sda1", "usage_percent": 85, "threshold": 80}
}' "System threshold event"

echo "============================================"
echo "Test events sent successfully!"
echo "============================================"
EOF

chmod +x generate-test-events.sh
./generate-test-events.sh
```

---

## 7. Custom Wazuh Rules and Decoders

To properly process events from the API, you need to create custom decoders and rules on the **Wazuh Manager**.

### 7.1 Custom Decoder

Create the decoder file on the Wazuh Manager:

**File: `/var/ossec/etc/decoders/custom_api_decoder.xml`**

```xml
<!--
  =============================================================================
  Custom Decoder for Wazuh Log Ingestion API
  =============================================================================
  This decoder processes JSON events received through the custom API.
  
  Expected log format:
  1:custom-api:{"timestamp":"...","source":"...","message":"...","level":"..."}
  
  The decoder extracts key fields for rule matching and alerting.
  =============================================================================
-->

<!-- Parent decoder: Identifies API-ingested logs -->
<decoder name="custom-api">
  <prematch>^{"timestamp":</prematch>
</decoder>

<!-- Child decoder: Extracts JSON fields -->
<decoder name="custom-api-json">
  <parent>custom-api</parent>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- Alternative decoder for specific field extraction -->
<decoder name="custom-api-fields">
  <parent>custom-api</parent>
  <regex>"source":"(\S+)".*"message":"([^"]+)".*"level":"(\S+)"</regex>
  <order>source,message,level</order>
</decoder>

<!-- Decoder for authentication events -->
<decoder name="custom-api-auth">
  <parent>custom-api</parent>
  <prematch>"tags":\[.*"authentication".*\]</prematch>
  <regex>"user":"(\S+)".*"source_ip":"(\S+)"</regex>
  <order>user,srcip</order>
</decoder>

<!-- Decoder for network events -->
<decoder name="custom-api-network">
  <parent>custom-api</parent>
  <prematch>"tags":\[.*"network".*\]</prematch>
  <regex>"source_ip":"(\S+)".*"dest_ip":"(\S+)".*"dest_port":(\d+)</regex>
  <order>srcip,dstip,dstport</order>
</decoder>

<!-- Decoder for firewall events -->
<decoder name="custom-api-firewall">
  <parent>custom-api</parent>
  <prematch>"source":"firewall"</prematch>
  <regex>"src_ip":"(\S+)".*"dst_port":(\d+).*"protocol":"(\S+)"</regex>
  <order>srcip,dstport,protocol</order>
</decoder>
```

**Deploy the decoder:**
```bash
# On the Wazuh Manager
sudo nano /var/ossec/etc/decoders/custom_api_decoder.xml
# Paste the content above

# Set correct permissions
sudo chown wazuh:wazuh /var/ossec/etc/decoders/custom_api_decoder.xml
sudo chmod 640 /var/ossec/etc/decoders/custom_api_decoder.xml
```

### 7.2 Custom Rules

Create the rules file on the Wazuh Manager:

**File: `/var/ossec/etc/rules/custom_api_rules.xml`**

```xml
<!--
  =============================================================================
  Custom Rules for Wazuh Log Ingestion API
  =============================================================================
  Rule ID Range: 100000-100999 (reserved for custom API rules)
  
  Severity Levels:
    0-3:   Low (informational)
    4-7:   Medium (warning)
    8-11:  High (error)
    12-15: Critical (immediate action required)
  =============================================================================
-->

<group name="custom-api,">

  <!-- Base rule for all API-ingested events -->
  <rule id="100000" level="3">
    <decoded_as>custom-api</decoded_as>
    <description>Event received via Custom API</description>
    <group>custom-api,</group>
  </rule>

  <!-- =========================================================================
       Authentication Events (100100-100199)
       ========================================================================= -->

  <!-- Failed authentication attempt -->
  <rule id="100100" level="5">
    <if_sid>100000</if_sid>
    <field name="level">warning</field>
    <match>Failed login|Authentication failed|Invalid credentials</match>
    <description>API: Failed authentication attempt</description>
    <group>authentication_failed,custom-api,</group>
  </rule>

  <!-- Multiple failed authentication attempts (brute force indicator) -->
  <rule id="100101" level="10" frequency="5" timeframe="120">
    <if_matched_sid>100100</if_matched_sid>
    <same_source_ip />
    <description>API: Multiple failed authentication attempts - possible brute force</description>
    <group>authentication_failures,attack,custom-api,</group>
  </rule>

  <!-- Successful authentication -->
  <rule id="100102" level="3">
    <if_sid>100000</if_sid>
    <field name="level">info</field>
    <match>Successful login|Authentication successful|User logged in</match>
    <description>API: Successful authentication</description>
    <group>authentication_success,custom-api,</group>
  </rule>

  <!-- =========================================================================
       Network Security Events (100200-100299)
       ========================================================================= -->

  <!-- Firewall block event -->
  <rule id="100200" level="6">
    <if_sid>100000</if_sid>
    <match>Blocked connection|Firewall block|Connection denied</match>
    <description>API: Firewall blocked connection</description>
    <group>firewall,custom-api,</group>
  </rule>

  <!-- SSH connection blocked -->
  <rule id="100201" level="8">
    <if_sid>100200</if_sid>
    <field name="dstport">22</field>
    <description>API: SSH connection attempt blocked by firewall</description>
    <group>firewall,ssh,custom-api,</group>
  </rule>

  <!-- Multiple blocked connections from same source -->
  <rule id="100202" level="10" frequency="10" timeframe="60">
    <if_matched_sid>100200</if_matched_sid>
    <same_source_ip />
    <description>API: Multiple blocked connections from same source - possible scan</description>
    <group>firewall,attack,recon,custom-api,</group>
  </rule>

  <!-- =========================================================================
       System Events (100300-100399)
       ========================================================================= -->

  <!-- Service started -->
  <rule id="100300" level="3">
    <if_sid>100000</if_sid>
    <match>Service started|started successfully</match>
    <description>API: Service started</description>
    <group>service,custom-api,</group>
  </rule>

  <!-- Service stopped -->
  <rule id="100301" level="5">
    <if_sid>100000</if_sid>
    <match>Service stopped|stopped successfully|shutdown</match>
    <description>API: Service stopped</description>
    <group>service,custom-api,</group>
  </rule>

  <!-- Disk threshold exceeded -->
  <rule id="100302" level="7">
    <if_sid>100000</if_sid>
    <match>Disk usage exceeded|disk threshold|storage warning</match>
    <description>API: Disk usage threshold exceeded</description>
    <group>system,disk,custom-api,</group>
  </rule>

  <!-- =========================================================================
       Application Events (100400-100499)
       ========================================================================= -->

  <!-- Application error -->
  <rule id="100400" level="7">
    <if_sid>100000</if_sid>
    <field name="level">error</field>
    <description>API: Application error reported</description>
    <group>application,error,custom-api,</group>
  </rule>

  <!-- Critical application error -->
  <rule id="100401" level="12">
    <if_sid>100000</if_sid>
    <field name="level">critical</field>
    <description>API: Critical application error - immediate attention required</description>
    <group>application,critical,custom-api,</group>
  </rule>

  <!-- Database connection error -->
  <rule id="100402" level="10">
    <if_sid>100400</if_sid>
    <match>Database connection|DB connection|database timeout</match>
    <description>API: Database connection error</description>
    <group>application,database,custom-api,</group>
  </rule>

  <!-- =========================================================================
       Security Events (100500-100599)
       ========================================================================= -->

  <!-- Suspicious activity detected -->
  <rule id="100500" level="8">
    <if_sid>100000</if_sid>
    <match>suspicious|malicious|threat detected|security alert</match>
    <description>API: Suspicious activity detected</description>
    <group>security,suspicious,custom-api,</group>
  </rule>

  <!-- Data exfiltration attempt -->
  <rule id="100501" level="12">
    <if_sid>100000</if_sid>
    <match>data exfiltration|unauthorized export|data leak</match>
    <description>API: Possible data exfiltration attempt</description>
    <group>security,data_exfiltration,custom-api,</group>
  </rule>

  <!-- Privilege escalation -->
  <rule id="100502" level="12">
    <if_sid>100000</if_sid>
    <match>privilege escalation|unauthorized access|permission violation</match>
    <description>API: Privilege escalation attempt detected</description>
    <group>security,privilege_escalation,custom-api,</group>
  </rule>

</group>
```

**Deploy the rules:**
```bash
# On the Wazuh Manager
sudo nano /var/ossec/etc/rules/custom_api_rules.xml
# Paste the content above

# Set correct permissions
sudo chown wazuh:wazuh /var/ossec/etc/rules/custom_api_rules.xml
sudo chmod 640 /var/ossec/etc/rules/custom_api_rules.xml
```

### 7.3 Test Decoder with ossec-logtest

Test the decoder on the Wazuh Manager:

```bash
# Run ossec-logtest
sudo /var/ossec/bin/wazuh-logtest
```

**Paste a sample log entry:**
```
{"timestamp":"2026-01-29T10:00:00Z","source":"test-application","message":"Failed login attempt for user admin","level":"warning","tags":["security","authentication"],"metadata":{"user":"admin","source_ip":"192.168.1.100"}}
```

**Expected output:**
```
**Phase 1: Completed pre-decoding.
       full event: '{"timestamp":"2026-01-29T10:00:00Z","source":"test-application","message":"Failed login attempt for user admin","level":"warning","tags":["security","authentication"],"metadata":{"user":"admin","source_ip":"192.168.1.100"}}'

**Phase 2: Completed decoding.
       name: 'custom-api'
       source: 'test-application'
       message: 'Failed login attempt for user admin'
       level: 'warning'

**Phase 3: Completed filtering (rules).
       id: '100100'
       level: '5'
       description: 'API: Failed authentication attempt'
       groups: '['authentication_failed', 'custom-api']'
       firedtimes: '1'
```

### 7.4 Restart Wazuh Manager

After adding decoders and rules, restart the Wazuh Manager:

```bash
# Restart Wazuh Manager
sudo systemctl restart wazuh-manager

# Verify it's running
sudo systemctl status wazuh-manager

# Check for configuration errors
sudo /var/ossec/bin/wazuh-control status
sudo tail -50 /var/ossec/logs/ossec.log
```

### 7.5 Rule ID Guidelines

| Range | Purpose |
|-------|---------|
| 100000-100099 | Base/generic API events |
| 100100-100199 | Authentication events |
| 100200-100299 | Network/firewall events |
| 100300-100399 | System events |
| 100400-100499 | Application events |
| 100500-100599 | Security events |
| 100600-100999 | Reserved for future use |

### 7.6 Severity Level Guidelines

| Level | Severity | Use Case |
|-------|----------|----------|
| 0-3 | Low | Informational, successful operations |
| 4-7 | Medium | Warnings, single failures, threshold alerts |
| 8-11 | High | Errors, multiple failures, attack indicators |
| 12-15 | Critical | Immediate action required, active attacks |

---

## 8. Dashboard Verification

### 8.1 Index Pattern Check

Verify the Wazuh index pattern exists in Kibana/OpenSearch Dashboards:

1. **Access Wazuh Dashboard:**
   - URL: `https://<WAZUH_MANAGER_IP>:443` (or your configured port)
   - Login with your credentials

2. **Check Index Patterns:**
   - Navigate to: **Stack Management** → **Index Patterns**
   - Verify `wazuh-alerts-*` pattern exists
   - If missing, create it with `@timestamp` as the time field

### 8.2 Discover View

Search for your test events in the Discover view:

1. **Navigate to Discover:**
   - Click **Discover** in the left menu

2. **Select Index Pattern:**
   - Choose `wazuh-alerts-*`

3. **Set Time Range:**
   - Set to "Last 15 minutes" or appropriate range

4. **Search for API Events:**
   ```
   rule.groups: "custom-api"
   ```
   
   Or search by specific rule:
   ```
   rule.id: 100100
   ```
   
   Or search by source:
   ```
   data.source: "test-application"
   ```

### 8.3 Expected Fields

When viewing an API-ingested event, you should see these fields:

| Field | Description | Example |
|-------|-------------|---------|
| `@timestamp` | Event timestamp | `2026-01-29T10:00:00.000Z` |
| `rule.id` | Matched rule ID | `100100` |
| `rule.description` | Rule description | `API: Failed authentication attempt` |
| `rule.level` | Severity level | `5` |
| `rule.groups` | Rule groups | `["authentication_failed", "custom-api"]` |
| `agent.name` | Agent name | `test-api-ingest-vm` |
| `data.source` | Event source | `test-application` |
| `data.message` | Event message | `Failed login attempt for user admin` |
| `data.level` | Log level | `warning` |

### 8.4 Create Test Dashboard

Create a simple dashboard to visualize API events:

1. **Navigate to Dashboards:**
   - Click **Dashboards** → **Create dashboard**

2. **Add Visualizations:**

   **Visualization 1: Event Count Over Time**
   - Type: Line chart
   - Index: `wazuh-alerts-*`
   - Y-axis: Count
   - X-axis: Date Histogram (@timestamp)
   - Filter: `rule.groups: "custom-api"`

   **Visualization 2: Events by Severity**
   - Type: Pie chart
   - Index: `wazuh-alerts-*`
   - Slice by: `rule.level`
   - Filter: `rule.groups: "custom-api"`

   **Visualization 3: Events by Source**
   - Type: Bar chart
   - Index: `wazuh-alerts-*`
   - Y-axis: Count
   - X-axis: Terms (`data.source`)
   - Filter: `rule.groups: "custom-api"`

   **Visualization 4: Recent Events Table**
   - Type: Data table
   - Index: `wazuh-alerts-*`
   - Columns: `@timestamp`, `rule.description`, `data.source`, `data.message`
   - Filter: `rule.groups: "custom-api"`
   - Sort: `@timestamp` descending

3. **Save Dashboard:**
   - Click **Save**
   - Name: "Custom API Events Dashboard"

### 8.5 Troubleshooting Dashboard Issues

#### Events not appearing in dashboard

1. **Check agent connection:**
   ```bash
   # On Wazuh Manager
   sudo /var/ossec/bin/manage_agents -l
   # Verify agent is listed and active
   ```

2. **Check if events are being received:**
   ```bash
   # On Wazuh Manager
   sudo tail -f /var/ossec/logs/alerts/alerts.json | jq 'select(.rule.groups[] == "custom-api")'
   ```

3. **Check decoder is working:**
   ```bash
   # Test with ossec-logtest
   sudo /var/ossec/bin/wazuh-logtest
   ```

4. **Check index exists:**
   ```bash
   # Query Elasticsearch/OpenSearch
   curl -k -u admin:admin https://localhost:9200/_cat/indices/wazuh-alerts-*
   ```

#### Events appear but fields are missing

1. **Verify decoder extracts fields correctly:**
   - Use `wazuh-logtest` to check field extraction
   - Update decoder regex if needed

2. **Check index mapping:**
   - Some fields may need explicit mapping
   - Check Wazuh documentation for custom field mapping

---

## 9. Complete Test Workflow

This section provides a complete end-to-end test workflow with all commands and expected outputs.

### 9.1 Pre-Test Checklist

```bash
# 1. Verify all containers are running
docker compose ps
# Expected: All services "Up (healthy)"

# 2. Verify API key is set
echo "API Key: $API_KEY"
# Expected: 64-character hex string

# 3. Verify agent connection
docker compose exec agent-ingest /var/ossec/bin/wazuh-control status
# Expected: All services running

# 4. Verify Wazuh Manager connectivity
docker compose exec agent-ingest nc -zv $MANAGER_URL 1514
# Expected: Connection succeeded
```

### 9.2 Test Execution Script

Create and run a comprehensive test script:

```bash
cat > run-full-test.sh << 'EOF'
#!/bin/bash
# =============================================================================
# Complete Test Workflow Script
# =============================================================================

set -e

# Configuration
API_KEY="${API_KEY:-$(cat secrets/api_key.txt)}"
HOST="${HOST:-https://localhost}"
MANAGER_IP="${MANAGER_URL:-192.168.1.100}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() {
    echo ""
    echo "============================================"
    echo "$1"
    echo "============================================"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# =============================================================================
# Test 1: Health Checks
# =============================================================================
print_header "Test 1: Health Checks"

echo "Testing liveness probe..."
RESPONSE=$(curl -s -k "$HOST/health/live")
if echo "$RESPONSE" | jq -e '.status == "alive"' > /dev/null 2>&1; then
    print_success "Liveness probe: OK"
else
    print_error "Liveness probe: FAILED - $RESPONSE"
fi

echo "Testing readiness probe..."
RESPONSE=$(curl -s -k "$HOST/health/ready")
if echo "$RESPONSE" | jq -e '.status == "ready"' > /dev/null 2>&1; then
    print_success "Readiness probe: OK"
else
    print_error "Readiness probe: FAILED - $RESPONSE"
fi

echo "Testing authenticated health check..."
RESPONSE=$(curl -s -k -H "X-API-Key: $API_KEY" "$HOST/api/health")
if echo "$RESPONSE" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
    print_success "Authenticated health: OK"
else
    print_error "Authenticated health: FAILED - $RESPONSE"
fi

# =============================================================================
# Test 2: Authentication
# =============================================================================
print_header "Test 2: Authentication"

echo "Testing without API key (should fail)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k "$HOST/api/health")
if [ "$STATUS" = "401" ]; then
    print_success "No API key: Correctly rejected (401)"
else
    print_error "No API key: Expected 401, got $STATUS"
fi

echo "Testing with invalid API key (should fail)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k -H "X-API-Key: invalid" "$HOST/api/health")
if [ "$STATUS" = "401" ]; then
    print_success "Invalid API key: Correctly rejected (401)"
else
    print_error "Invalid API key: Expected 401, got $STATUS"
fi

echo "Testing with valid API key (should succeed)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k -H "X-API-Key: $API_KEY" "$HOST/api/health")
if [ "$STATUS" = "200" ]; then
    print_success "Valid API key: Accepted (200)"
else
    print_error "Valid API key: Expected 200, got $STATUS"
fi

# =============================================================================
# Test 3: Single Event Ingestion
# =============================================================================
print_header "Test 3: Single Event Ingestion"

echo "Sending test event..."
RESPONSE=$(curl -s -k -X PUT "$HOST/api/" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "source": "test-workflow",
        "message": "Test event from complete workflow",
        "level": "info",
        "tags": ["test", "workflow"],
        "metadata": {"test_id": "workflow-001"}
    }')

if echo "$RESPONSE" | jq -e '.status == "success"' > /dev/null 2>&1; then
    REQUEST_ID=$(echo "$RESPONSE" | jq -r '.request_id')
    print_success "Event sent successfully (Request ID: $REQUEST_ID)"
else
    print_error "Event failed: $RESPONSE"
fi

# =============================================================================
# Test 4: Batch Event Ingestion
# =============================================================================
print_header "Test 4: Batch Event Ingestion"

echo "Sending batch of 5 events..."
RESPONSE=$(curl -s -k -X PUT "$HOST/batch" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "events": [
            {"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "source": "batch-test", "message": "Batch event 1", "level": "info"},
            {"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "source": "batch-test", "message": "Batch event 2", "level": "info"},
            {"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "source": "batch-test", "message": "Batch event 3", "level": "warning"},
            {"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "source": "batch-test", "message": "Batch event 4", "level": "error"},
            {"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "source": "batch-test", "message": "Batch event 5", "level": "info"}
        ]
    }')

TOTAL=$(echo "$RESPONSE" | jq -r '.total // 0')
ERRORS=$(echo "$RESPONSE" | jq -r '.errors // -1')
if [ "$TOTAL" = "5" ] && [ "$ERRORS" = "0" ]; then
    print_success "Batch sent successfully (5 events, 0 errors)"
else
    print_error "Batch failed: Total=$TOTAL, Errors=$ERRORS"
fi

# =============================================================================
# Test 5: Rate Limiting
# =============================================================================
print_header "Test 5: Rate Limiting"

echo "Sending rapid requests to test rate limiting..."
SUCCESS=0
RATE_LIMITED=0
for i in {1..15}; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k "$HOST/health/live")
    if [ "$STATUS" = "200" ]; then
        ((SUCCESS++))
    elif [ "$STATUS" = "429" ]; then
        ((RATE_LIMITED++))
    fi
done

if [ "$RATE_LIMITED" -gt 0 ]; then
    print_success "Rate limiting working: $SUCCESS succeeded, $RATE_LIMITED rate-limited"
else
    print_warning "Rate limiting may not be active: All $SUCCESS requests succeeded"
fi

# =============================================================================
# Test 6: Security Events
# =============================================================================
print_header "Test 6: Security Events"

echo "Sending authentication failure event..."
RESPONSE=$(curl -s -k -X PUT "$HOST/api/" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "source": "security-test",
        "message": "Failed login attempt for user testuser",
        "level": "warning",
        "tags": ["security", "authentication"],
        "metadata": {"user": "testuser", "source_ip": "10.0.0.50"}
    }')

if echo "$RESPONSE" | jq -e '.status == "success"' > /dev/null 2>&1; then
    print_success "Security event sent"
else
    print_error "Security event failed: $RESPONSE"
fi

echo "Sending firewall block event..."
RESPONSE=$(curl -s -k -X PUT "$HOST/api/" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "source": "firewall",
        "message": "Blocked connection attempt from 192.168.100.50 to port 22",
        "level": "error",
        "tags": ["network", "firewall", "blocked"],
        "metadata": {"src_ip": "192.168.100.50", "dst_port": 22, "protocol": "tcp"}
    }')

if echo "$RESPONSE" | jq -e '.status == "success"' > /dev/null 2>&1; then
    print_success "Firewall event sent"
else
    print_error "Firewall event failed: $RESPONSE"
fi

# =============================================================================
# Summary
# =============================================================================
print_header "Test Summary"

echo ""
echo "All tests completed. Please verify:"
echo "  1. Events appear in Wazuh Dashboard"
echo "  2. Custom rules are triggering (rule IDs 100000+)"
echo "  3. Agent is connected to Wazuh Manager"
echo ""
echo "Dashboard search query: rule.groups: \"custom-api\""
echo ""
EOF

chmod +x run-full-test.sh
./run-full-test.sh
```

### 9.3 Expected Test Results

After running the complete test workflow:

| Test | Expected Result |
|------|-----------------|
| Liveness probe | `{"status":"alive"}` |
| Readiness probe | `{"status":"ready","wazuh_socket":"connected"}` |
| No API key | HTTP 401 |
| Invalid API key | HTTP 401 |
| Valid API key | HTTP 200 |
| Single event | `{"status":"success",...}` |
| Batch events | `{"status":"batch_processed","total":5,"errors":0,...}` |
| Rate limiting | Some HTTP 429 responses |
| Security events | `{"status":"success",...}` |

### 9.4 Verify Events in Wazuh

After running tests, verify events on the Wazuh Manager:

```bash
# On Wazuh Manager - Check recent alerts
sudo tail -20 /var/ossec/logs/alerts/alerts.json | jq 'select(.rule.groups[] == "custom-api")'

# Check specific rule triggers
sudo grep "100100" /var/ossec/logs/alerts/alerts.json | tail -5 | jq .

# Count API events in last hour
sudo cat /var/ossec/logs/alerts/alerts.json | \
    jq -r 'select(.rule.groups[] == "custom-api") | .rule.id' | \
    sort | uniq -c | sort -rn
```

---

## 10. Troubleshooting

### 10.1 API Returns 401 Unauthorized

**Symptoms:**
- All API requests return 401
- Health endpoints work but authenticated endpoints fail

**Diagnosis:**
```bash
# Check if API key file exists and has content
cat secrets/api_key.txt
wc -c secrets/api_key.txt  # Should be 64 characters

# Check if container can read the secret
docker compose exec agent-ingest cat /run/secrets/api_key

# Check API logs
docker compose logs agent-ingest | grep -i "api key\|auth"
```

**Solutions:**

1. **Regenerate API key:**
   ```bash
   ./scripts/init-secrets.sh
   docker compose restart agent-ingest
   ```

2. **Verify API key in request:**
   ```bash
   # Ensure no extra whitespace or newlines
   API_KEY=$(cat secrets/api_key.txt | tr -d '\n')
   curl -k -H "X-API-Key: $API_KEY" https://localhost/api/health
   ```

3. **Check header name:**
   - Must be exactly `X-API-Key` (case-sensitive)

### 10.2 API Returns 429 Too Many Requests

**Symptoms:**
- Requests are being rate-limited
- 429 responses even with low request rate

**Diagnosis:**
```bash
# Check current rate limit configuration
docker compose exec nginx cat /etc/nginx/conf.d/rate-limiting.conf

# Check if your IP is whitelisted
docker compose exec nginx cat /etc/nginx/conf.d/ip-whitelist.conf
```

**Solutions:**

1. **Add your IP to whitelist:**
   ```bash
   ./scripts/update-whitelist.sh add <YOUR_IP> "Test machine"
   docker compose exec nginx nginx -s reload
   ```

2. **Increase rate limits for testing:**
   ```bash
   # Edit rate-limiting.conf to increase limits
   # Then reload Nginx
   docker compose exec nginx nginx -s reload
   ```

3. **Wait for rate limit to reset:**
   - Rate limits reset after the configured time window

### 10.3 Events Not Appearing in Wazuh

**Symptoms:**
- API returns success but events don't appear in Wazuh Dashboard
- No alerts generated for test events

**Diagnosis:**

1. **Check agent connection:**
   ```bash
   # Inside container
   docker compose exec agent-ingest /var/ossec/bin/wazuh-control status
   docker compose exec agent-ingest tail -20 /var/ossec/logs/ossec.log
   ```

2. **Check Wazuh socket:**
   ```bash
   # Verify socket exists
   docker compose exec agent-ingest ls -la /var/ossec/queue/sockets/queue
   ```

3. **Check decoder on Manager:**
   ```bash
   # On Wazuh Manager
   sudo /var/ossec/bin/wazuh-logtest
   # Paste a test event and check if decoder matches
   ```

**Solutions:**

1. **Restart agent:**
   ```bash
   docker compose exec agent-ingest /var/ossec/bin/wazuh-control restart
   ```

2. **Re-register agent:**
   ```bash
   docker compose exec agent-ingest /var/ossec/bin/agent-auth -m <MANAGER_IP> -A <AGENT_NAME>
   docker compose exec agent-ingest /var/ossec/bin/wazuh-control restart
   ```

3. **Check decoder configuration:**
   - Verify decoder file exists on Manager
   - Test with `wazuh-logtest`
   - Restart Wazuh Manager after changes

### 10.4 Rules Not Firing

**Symptoms:**
- Events appear in Wazuh but custom rules don't trigger
- Only base rule (100000) fires

**Diagnosis:**
```bash
# On Wazuh Manager - Test rules
sudo /var/ossec/bin/wazuh-logtest

# Check rule syntax
sudo /var/ossec/bin/wazuh-control info -t
```

**Solutions:**

1. **Check rule syntax:**
   ```bash
   # Validate rules
   sudo /var/ossec/bin/wazuh-control info -t
   ```

2. **Verify rule conditions:**
   - Check `<match>` patterns match your event messages
   - Check `<field>` names match decoded fields
   - Use `wazuh-logtest` to debug rule matching

3. **Restart Wazuh Manager:**
   ```bash
   sudo systemctl restart wazuh-manager
   ```

### 10.5 Dashboard Empty

**Symptoms:**
- Wazuh Dashboard shows no data
- Index pattern exists but no documents

**Diagnosis:**
```bash
# Check if alerts are being generated
sudo tail -f /var/ossec/logs/alerts/alerts.json

# Check Elasticsearch/OpenSearch
curl -k -u admin:admin https://localhost:9200/_cat/indices/wazuh-alerts-*

# Check index document count
curl -k -u admin:admin https://localhost:9200/wazuh-alerts-*/_count
```

**Solutions:**

1. **Check time range:**
   - Ensure dashboard time range includes your test events
   - Try "Last 24 hours" or "Last 7 days"

2. **Refresh index pattern:**
   - Go to Stack Management → Index Patterns
   - Refresh the `wazuh-alerts-*` pattern

3. **Check Filebeat/Logstash:**
   - Verify log shipping is working
   - Check Filebeat logs on Wazuh Manager

### 10.6 Container Startup Failures

**Symptoms:**
- Containers exit immediately
- Health checks fail

**Diagnosis:**
```bash
# Check container logs
docker compose logs agent-ingest
docker compose logs nginx

# Check container status
docker compose ps -a
```

**Solutions:**

1. **Missing secrets:**
   ```bash
   ls -la secrets/
   ./scripts/init-secrets.sh
   ```

2. **Missing certificates:**
   ```bash
   ls -la deploy/nginx/certs/
   ./scripts/generate-certs.sh
   ```

3. **Port conflicts:**
   ```bash
   sudo lsof -i :80
   sudo lsof -i :443
   # Stop conflicting services
   ```

4. **Permission issues:**
   ```bash
   chmod 700 secrets/
   chmod 600 secrets/api_key.txt
   chmod 644 deploy/nginx/certs/server.crt
   chmod 600 deploy/nginx/certs/server.key
   ```

### 10.7 Quick Diagnostic Commands

```bash
# Overall system status
docker compose ps
docker compose logs --tail=20

# API status
curl -k https://localhost/health/live
curl -k https://localhost/health/ready

# Agent status
docker compose exec agent-ingest /var/ossec/bin/wazuh-control status

# Nginx status
docker compose exec nginx nginx -t
docker compose exec nginx cat /var/log/nginx/error.log | tail -20

# Network connectivity
docker compose exec agent-ingest nc -zv $MANAGER_URL 1514
docker compose exec agent-ingest nc -zv $MANAGER_URL 1515
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2026-01-29 | Documentation Team | Initial test environment guide |

---

*This document is part of the Wazuh Log Ingestion Pipeline documentation. For production deployment, see:*
- [Production Deployment Guide](PRODUCTION-DEPLOYMENT-GUIDE.md)
- [Security Testing Checklist](SECURITY-TESTING-CHECKLIST.md)
- [Certificate Management](certificate-management.md)