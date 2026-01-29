# Production Deployment Guide

## Wazuh Log Ingestion Pipeline - Internet-Facing Deployment

**Version:** 1.0.0  
**Last Updated:** 2026-01-29  
**Status:** ✅ PRODUCTION READY (Post Security Audit)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Pre-Deployment Checklist](#2-pre-deployment-checklist)
3. [Deployment Steps](#3-deployment-steps)
4. [Security Architecture](#4-security-architecture)
5. [Environment Variables Reference](#5-environment-variables-reference)
6. [Cloudflare WAF Configuration](#6-cloudflare-waf-configuration)
7. [Monitoring and Alerting](#7-monitoring-and-alerting)
8. [Maintenance Procedures](#8-maintenance-procedures)
9. [Incident Response](#9-incident-response)
10. [Verification Commands](#10-verification-commands)
11. [Troubleshooting](#11-troubleshooting)
12. [Security Contacts](#12-security-contacts)

---

## 1. Executive Summary

### System Overview

The Wazuh Log Ingestion Pipeline is a production-ready, security-hardened API gateway for ingesting security logs into a Wazuh SIEM. It provides:

- **RESTful API** for single and batch log ingestion
- **TLS 1.2/1.3 encryption** for all communications
- **API key authentication** with constant-time comparison
- **Multi-layer rate limiting** (Nginx + API level)
- **Automated threat response** via Fail2ban integration
- **Cloudflare-ready** real IP extraction for accurate blocking

### Production Readiness Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Security Audit** | ✅ Complete | All 23 vulnerabilities remediated |
| **TLS Configuration** | ✅ Hardened | TLS 1.2/1.3 only, strong ciphers |
| **Authentication** | ✅ Mandatory | API key required for all endpoints |
| **Rate Limiting** | ✅ Active | 100 req/s API, 10 req/s health |
| **Fail2ban** | ✅ Operational | JSON log format filters fixed |
| **Logging** | ✅ Structured | JSON format with sanitization |
| **Container Security** | ✅ Hardened | Non-root, capabilities dropped |

### Key Security Controls

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DEFENSE IN DEPTH LAYERS                          │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 1: Cloudflare WAF (External)                                 │
│    • DDoS protection                                                │
│    • OWASP managed rulesets                                         │
│    • Bot management                                                 │
│    • Geographic restrictions                                        │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 2: Nginx Reverse Proxy                                       │
│    • TLS termination (1.2/1.3 only)                                │
│    • Rate limiting (100 req/s API, 10 req/s health)                │
│    • Security headers (HSTS, CSP, X-Frame-Options)                 │
│    • Payload size limits (1MB ingest, 10MB batch)                  │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 3: Fail2ban                                                  │
│    • Auth failure banning (5 failures → 1 hour ban)                │
│    • Rate limit violation banning (20 hits → 30 min ban)           │
│    • Scanner detection (10 probes → 2 hour ban)                    │
│    • Bad request banning (10 errors → 30 min ban)                  │
├─────────────────────────────────────────────────────────────────────┤
│  Layer 4: API Application                                           │
│    • API key authentication (constant-time comparison)             │
│    • Input validation (Pydantic schemas)                           │
│    • Request timeout protection (30s max)                          │
│    • Structured logging with sensitive data redaction              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Pre-Deployment Checklist

**⚠️ CRITICAL: Complete ALL items before exposing the system to the internet.**

### Infrastructure Prerequisites

- [ ] **Update Cloudflare IP ranges**
  ```bash
  ./scripts/update-cloudflare-ips.sh
  ```
  This ensures Nginx extracts the real client IP from Cloudflare headers.

- [ ] **Generate/deploy CA-signed TLS certificates**
  ```bash
  # For Let's Encrypt:
  ./scripts/rotate-certs.sh --type letsencrypt --domain api.example.com --email admin@example.com
  
  # Or copy existing CA-signed certificates:
  cp /path/to/certificate.crt deploy/nginx/certs/server.crt
  cp /path/to/private.key deploy/nginx/certs/server.key
  chmod 644 deploy/nginx/certs/server.crt
  chmod 600 deploy/nginx/certs/server.key
  ```
  **⚠️ Self-signed certificates are NOT acceptable for production.**

- [ ] **Generate strong API key (minimum 32 characters)**
  ```bash
  # Generate a cryptographically secure API key
  openssl rand -hex 32 > secrets/api_key.txt
  chmod 600 secrets/api_key.txt
  
  # Verify key length (should be 64 hex characters = 32 bytes)
  wc -c secrets/api_key.txt
  ```

### Cloudflare Configuration

- [ ] **Configure Cloudflare WAF rules** (see [Section 6](#6-cloudflare-waf-configuration))
- [ ] **Enable Cloudflare SSL/TLS mode: Full (Strict)**
- [ ] **Configure Cloudflare rate limiting rules**
- [ ] **Enable Bot Fight Mode or Super Bot Fight Mode**

### Environment Configuration

- [ ] **Set environment variables for production**
  ```bash
  # Create production .env file
  cat > .env << 'EOF'
  ENVIRONMENT=production
  STRICT_TLS_CHECK=true
  LOG_LEVEL=INFO
  MANAGER_URL=your-wazuh-manager.example.com
  MANAGER_PORT=1515
  SERVER_URL=your-wazuh-manager.example.com
  SERVER_PORT=1514
  NAME=agent-ingest-prod
  GROUP=production
  ENROL_TOKEN=your-secure-enrollment-token
  EOF
  ```

### Security Verification

- [ ] **Review and test fail2ban filters**
  ```bash
  # Test each filter against sample logs
  fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-auth.conf
  fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-ratelimit.conf
  fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-scanner.conf
  fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-badrequest.conf
  ```

- [ ] **Verify rate limiting is working**
  ```bash
  # Test rate limiting (should see 429 responses)
  for i in {1..15}; do 
    curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/health/live
  done
  ```

- [ ] **Run security test suite**
  ```bash
  ./scripts/security-test.sh
  ```

### Final Verification

- [ ] **All containers start without errors**
- [ ] **Health endpoints respond correctly**
- [ ] **API authentication is enforced**
- [ ] **TLS certificate is valid and trusted**
- [ ] **Fail2ban jails are active**

---

## 3. Deployment Steps

### Step 1: Initial Setup and Configuration

```bash
# 1. Clone repository (if not already done)
git clone <repository-url>
cd wazuh-log-pipeline

# 2. Create required directories
mkdir -p secrets backups deploy/nginx/certs

# 3. Set directory permissions
chmod 700 secrets
chmod 755 backups
chmod 755 deploy/nginx/certs
```

### Step 2: Secrets Management

```bash
# Generate API key
./scripts/init-secrets.sh

# Or manually create with strong key
openssl rand -hex 32 > secrets/api_key.txt
chmod 600 secrets/api_key.txt

# Verify the secret file
cat secrets/api_key.txt
```

**Important:** Store the API key securely in your secrets management system (e.g., HashiCorp Vault, AWS Secrets Manager).

### Step 3: TLS Certificate Deployment

**Option A: Let's Encrypt (Recommended for public domains)**
```bash
./scripts/rotate-certs.sh --type letsencrypt \
  --domain api.example.com \
  --email admin@example.com
```

**Option B: Existing CA-signed certificates**
```bash
# Copy certificates
cp /path/to/fullchain.pem deploy/nginx/certs/server.crt
cp /path/to/privkey.pem deploy/nginx/certs/server.key

# Set permissions
chmod 644 deploy/nginx/certs/server.crt
chmod 600 deploy/nginx/certs/server.key
```

**Option C: Internal CA (for private networks)**
```bash
# Generate with your internal CA
# Ensure the certificate includes:
# - Subject Alternative Name (SAN) for your domain
# - Extended Key Usage: Server Authentication
```

### Step 4: Update Cloudflare IP Ranges

```bash
# Run the update script
./scripts/update-cloudflare-ips.sh

# Verify the generated configuration
cat deploy/nginx/conf.d/cloudflare_real_ip.conf
```

This step is **critical** for:
- Accurate rate limiting per real client IP
- Fail2ban blocking actual attackers (not Cloudflare servers)
- Forensic logging with real client IPs

### Step 5: Build and Deploy Containers

```bash
# Build images
docker compose build --no-cache

# Start services in detached mode
docker compose up -d

# Verify all containers are running
docker compose ps

# Check logs for any errors
docker compose logs -f --tail=100
```

### Step 6: Cloudflare WAF Configuration

See [Section 6](#6-cloudflare-waf-configuration) for detailed WAF rules.

### Step 7: DNS and Network Configuration

```bash
# Configure DNS to point to Cloudflare
# Your domain → Cloudflare → Your origin server

# Verify DNS propagation
dig api.example.com

# Test connectivity through Cloudflare
curl -I https://api.example.com/health/live
```

### Step 8: Verification and Testing

```bash
# 1. Test liveness probe
curl -k https://localhost/health/live
# Expected: {"status":"alive"}

# 2. Test readiness probe
curl -k https://localhost/health/ready
# Expected: {"status":"ready","wazuh_socket":"connected"}

# 3. Test authentication enforcement
curl -k https://localhost/api/health
# Expected: 401 Unauthorized

# 4. Test with valid API key
API_KEY=$(cat secrets/api_key.txt)
curl -k -H "X-API-Key: $API_KEY" https://localhost/api/health
# Expected: {"status":"healthy",...}

# 5. Test log ingestion
curl -k -X PUT https://localhost/ingest \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"timestamp":"2026-01-29T00:00:00Z","source":"test","message":"Production test"}'
# Expected: {"status":"success",...}
```

---

## 4. Security Architecture

### Traffic Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                         │
│                                  │                                            │
│                                  ▼                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                         CLOUDFLARE EDGE                                 │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │  │
│  │  │   DDoS       │  │     WAF      │  │     Bot      │                  │  │
│  │  │  Protection  │  │   Rules      │  │  Management  │                  │  │
│  │  └──────────────┘  └──────────────┘  └──────────────┘                  │  │
│  │                           │                                             │  │
│  │              CF-Connecting-IP header added                              │  │
│  └───────────────────────────┼────────────────────────────────────────────┘  │
│                              │                                                │
│                              ▼                                                │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                    YOUR ORIGIN SERVER                                   │  │
│  │                                                                         │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │                    NGINX REVERSE PROXY                           │   │  │
│  │  │  • Extract real IP from CF-Connecting-IP                        │   │  │
│  │  │  • TLS termination (TLS 1.2/1.3)                                │   │  │
│  │  │  • Rate limiting (100 req/s API, 10 req/s health)               │   │  │
│  │  │  • Security headers                                              │   │  │
│  │  │  • Payload size limits                                           │   │  │
│  │  │  • JSON access logging → /var/log/nginx/access.log              │   │  │
│  │  └──────────────────────────┬──────────────────────────────────────┘   │  │
│  │                             │                                           │  │
│  │  ┌──────────────────────────┼──────────────────────────────────────┐   │  │
│  │  │                          │         FAIL2BAN                      │   │  │
│  │  │                          │  • Monitors Nginx JSON logs           │   │  │
│  │  │                          │  • Bans IPs via iptables              │   │  │
│  │  │                          │  • 4 active jails                     │   │  │
│  │  └──────────────────────────┼──────────────────────────────────────┘   │  │
│  │                             │                                           │  │
│  │                             ▼                                           │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │                    FASTAPI APPLICATION                           │   │  │
│  │  │  • API key validation (constant-time comparison)                │   │  │
│  │  │  • Request validation (Pydantic schemas)                        │   │  │
│  │  │  • Timeout protection (30s max)                                 │   │  │
│  │  │  • Structured JSON logging                                       │   │  │
│  │  └──────────────────────────┬──────────────────────────────────────┘   │  │
│  │                             │                                           │  │
│  │                             ▼                                           │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │  │
│  │  │                    WAZUH AGENT                                   │   │  │
│  │  │  • Forwards logs to Wazuh Manager                               │   │  │
│  │  │  • Unix socket communication                                     │   │  │
│  │  └─────────────────────────────────────────────────────────────────┘   │  │
│  │                                                                         │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Rate Limiting Zones

| Zone | Rate | Burst | Purpose |
|------|------|-------|---------|
| `api_limit` | 100 req/s | 50 | API endpoints (`/api/*`, `/ingest`, `/batch`) |
| `health_limit` | 10 req/s | 5 | Health endpoints (`/health/*`) |

**Why separate zones?**
- Prevents attackers from exhausting API rate limits via unauthenticated health endpoints
- Health checks have lower limits since they're typically automated
- API endpoints allow higher throughput for legitimate log ingestion

### Fail2ban Jails

| Jail | Trigger | Find Time | Ban Time | Purpose |
|------|---------|-----------|----------|---------|
| `wazuh-api-auth` | 5 failures | 5 min | 1 hour | Authentication failures (401/403) |
| `wazuh-api-ratelimit` | 20 hits | 1 min | 30 min | Rate limit violations (429) |
| `wazuh-api-badrequest` | 10 errors | 5 min | 30 min | Malformed requests (400) |
| `wazuh-api-scanner` | 10 probes | 1 min | 2 hours | Vulnerability scanning (404 on sensitive paths) |

---

## 5. Environment Variables Reference

### Core Configuration

| Variable | Description | Default | Production Value |
|----------|-------------|---------|------------------|
| `ENVIRONMENT` | Deployment environment | `development` | `production` |
| `STRICT_TLS_CHECK` | Fail on self-signed certs | `false` | `true` |
| `LOG_LEVEL` | Application log level | `INFO` | `INFO` |
| `SSL_CERT_PATH` | Path to TLS certificate | `/etc/nginx/certs/server.crt` | - |
| `SKIP_READINESS_CHECKS` | Skip startup checks | `false` | `false` |

### Wazuh Manager Connection

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `MANAGER_URL` | Wazuh manager hostname | `localhost` | Yes |
| `MANAGER_PORT` | Enrollment port | `1515` | No |
| `SERVER_URL` | Wazuh server hostname | `localhost` | Yes |
| `SERVER_PORT` | Agent communication port | `1514` | No |
| `ENROL_TOKEN` | Agent enrollment token | - | Yes |

### Agent Configuration

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `NAME` | Agent name | `agent-ingest` | Must be unique |
| `GROUP` | Agent group | `default` | For Wazuh grouping |
| `WAZUH_DECODER_HEADER` | Default decoder header | `1:Wazuh-AWS:` | For log routing |

### API Configuration

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `API_KEY` | API authentication key | - | Via Docker secret preferred |
| `REQUEST_TIMEOUT_SECONDS` | Max request time | `30` | Slow client protection |
| `SLOW_REQUEST_THRESHOLD` | Slow request warning | `5` | Seconds |

### Example Production `.env`

```bash
# Environment
ENVIRONMENT=production
STRICT_TLS_CHECK=true
LOG_LEVEL=INFO

# Wazuh Manager
MANAGER_URL=wazuh-manager.internal.example.com
MANAGER_PORT=1515
SERVER_URL=wazuh-manager.internal.example.com
SERVER_PORT=1514
ENROL_TOKEN=your-secure-enrollment-token

# Agent
NAME=api-ingest-prod-01
GROUP=production-ingest

# API (key should be in secrets/api_key.txt, not here)
REQUEST_TIMEOUT_SECONDS=30
SLOW_REQUEST_THRESHOLD=5
```

---

## 6. Cloudflare WAF Configuration

### SSL/TLS Settings

1. **SSL/TLS Encryption Mode**: Set to **Full (Strict)**
   - Requires valid CA-signed certificate on origin
   - Prevents man-in-the-middle attacks

2. **Minimum TLS Version**: Set to **TLS 1.2**

3. **TLS 1.3**: **Enable**

### WAF Managed Rulesets

Enable the following managed rulesets:

| Ruleset | Action | Notes |
|---------|--------|-------|
| **Cloudflare Managed Ruleset** | Block | Core protection |
| **Cloudflare OWASP Core Ruleset** | Block | OWASP Top 10 |
| **Cloudflare Exposed Credentials Check** | Block | Credential stuffing |

### Custom WAF Rules

#### Rule 1: Block Non-API Paths
```
Expression: not (http.request.uri.path starts with "/api/" or 
                http.request.uri.path starts with "/ingest" or 
                http.request.uri.path starts with "/batch" or 
                http.request.uri.path starts with "/health")
Action: Block
```

#### Rule 2: Require Content-Type for POST/PUT
```
Expression: (http.request.method in {"POST" "PUT"}) and 
            not (http.request.headers["content-type"][0] contains "application/json")
Action: Block
```

#### Rule 3: Block Suspicious User Agents
```
Expression: (http.user_agent contains "sqlmap") or 
            (http.user_agent contains "nikto") or 
            (http.user_agent contains "nmap") or
            (http.user_agent contains "masscan") or
            (http.user_agent contains "zgrab")
Action: Block
```

#### Rule 4: Block Empty User Agents
```
Expression: http.user_agent eq ""
Action: Challenge
```

### Rate Limiting Rules

#### Rule 1: API Endpoint Rate Limit
```
Expression: http.request.uri.path starts with "/api/" or 
            http.request.uri.path starts with "/ingest" or 
            http.request.uri.path starts with "/batch"
Characteristics: IP
Period: 10 seconds
Requests: 100
Action: Block for 60 seconds
```

#### Rule 2: Health Endpoint Rate Limit
```
Expression: http.request.uri.path starts with "/health"
Characteristics: IP
Period: 10 seconds
Requests: 20
Action: Block for 60 seconds
```

### Bot Management

1. **Bot Fight Mode**: Enable
2. **Super Bot Fight Mode** (if available): Enable with:
   - Definitely automated: Block
   - Likely automated: Challenge
   - Verified bots: Allow

### Geographic Restrictions (Optional)

If your API is region-specific:
```
Expression: not (ip.geoip.country in {"US" "CA" "GB" "DE" "FR"})
Action: Block
```

---

## 7. Monitoring and Alerting

### Health Endpoints

| Endpoint | Auth | Purpose | Expected Response |
|----------|------|---------|-------------------|
| `/health/live` | No | Kubernetes liveness | `{"status":"alive"}` |
| `/health/ready` | No | Kubernetes readiness | `{"status":"ready","wazuh_socket":"connected"}` |
| `/api/health` | Yes | Detailed health | Full status with uptime |

### Key Metrics to Monitor

#### API Metrics
- Request rate (requests/second)
- Error rate (4xx, 5xx responses)
- Response latency (p50, p95, p99)
- Authentication failures

#### Infrastructure Metrics
- Container CPU/memory usage
- Nginx connection count
- Fail2ban ban count
- Disk usage (logs)

#### Security Metrics
- Rate limit hits (429 responses)
- Authentication failures (401/403)
- Scanner detections (404 on sensitive paths)
- Banned IP count

### Alerting Thresholds

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| Error rate (5xx) | > 1% | > 5% | Investigate immediately |
| Response latency (p95) | > 1s | > 5s | Scale or investigate |
| Auth failures | > 10/min | > 50/min | Check for brute force |
| Rate limit hits | > 100/min | > 500/min | Check for DDoS |
| Banned IPs | > 10/hour | > 50/hour | Review attack patterns |
| Certificate expiry | < 30 days | < 7 days | Rotate certificates |

### Log Locations

| Log | Location | Format | Purpose |
|-----|----------|--------|---------|
| Nginx access | `/var/log/nginx/access.log` | JSON | Request logging |
| Nginx error | `/var/log/nginx/error.log` | Standard | Error logging |
| API logs | Container stdout | JSON | Application logs |
| Fail2ban | `/var/log/fail2ban/fail2ban.log` | Standard | Ban activity |

### Example Monitoring Commands

```bash
# Watch real-time access logs
docker exec wazuh-nginx tail -f /var/log/nginx/access.log | jq .

# Check error rates
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r '.status' | sort | uniq -c | sort -rn

# Monitor fail2ban activity
docker exec wazuh-fail2ban tail -f /var/log/fail2ban/fail2ban.log

# Check banned IPs
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth
```

---

## 8. Maintenance Procedures

### Weekly Tasks

#### Update Cloudflare IP Ranges
```bash
# Run weekly (recommended: Sunday night)
./scripts/update-cloudflare-ips.sh

# Reload Nginx to apply changes
docker compose exec nginx nginx -s reload
```

**Why weekly?** Cloudflare occasionally adds new edge server IP ranges. Outdated lists may cause:
- Real client IPs not being extracted correctly
- Rate limiting applied to Cloudflare IPs instead of clients
- Fail2ban potentially blocking Cloudflare servers

### Monthly Tasks

#### Review Fail2ban Logs and Bans
```bash
# Check ban statistics
docker exec wazuh-fail2ban fail2ban-client status

# Review recent bans
docker exec wazuh-fail2ban cat /var/log/fail2ban/fail2ban.log | \
  grep "Ban" | tail -50

# Export banned IPs for analysis
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth | \
  grep "Banned IP"
```

#### Review Access Patterns
```bash
# Top requesting IPs
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r '.remote_addr' | sort | uniq -c | sort -rn | head -20

# Top user agents
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r '.http_user_agent' | sort | uniq -c | sort -rn | head -20

# Error distribution
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r 'select(.status >= 400) | "\(.status) \(.request_uri)"' | \
  sort | uniq -c | sort -rn | head -20
```

### Quarterly Tasks

#### Rotate API Keys
```bash
# 1. Generate new API key
NEW_KEY=$(openssl rand -hex 32)

# 2. Update secrets file
echo "$NEW_KEY" > secrets/api_key.txt
chmod 600 secrets/api_key.txt

# 3. Restart API container to load new key
docker compose restart agent-ingest

# 4. Update all API clients with new key

# 5. Verify new key works
curl -k -H "X-API-Key: $NEW_KEY" https://localhost/api/health
```

#### Security Audit
```bash
# Run security test suite
./scripts/security-test.sh

# Scan container images for vulnerabilities
./scripts/scan-image.sh

# Review and update dependencies
docker compose build --no-cache
```

### Certificate Rotation

#### Check Certificate Expiry
```bash
./scripts/rotate-certs.sh --check

# Or manually:
openssl x509 -in deploy/nginx/certs/server.crt -noout -dates
```

#### Rotate Certificates
```bash
# Let's Encrypt (automatic renewal)
./scripts/rotate-certs.sh --type letsencrypt \
  --domain api.example.com \
  --email admin@example.com

# Manual rotation
cp /path/to/new/certificate.crt deploy/nginx/certs/server.crt
cp /path/to/new/private.key deploy/nginx/certs/server.key
chmod 644 deploy/nginx/certs/server.crt
chmod 600 deploy/nginx/certs/server.key

# Reload Nginx
docker compose exec nginx nginx -s reload
```

---

## 9. Incident Response

### Suspected Breach

**Immediate Actions (0-15 minutes):**

1. **Isolate the system**
   ```bash
   # Block all incoming traffic except your IP
   iptables -I INPUT -p tcp --dport 443 -j DROP
   iptables -I INPUT -p tcp --dport 443 -s YOUR_IP -j ACCEPT
   ```

2. **Preserve evidence**
   ```bash
   # Create forensic backup
   TIMESTAMP=$(date +%Y%m%d_%H%M%S)
   mkdir -p /forensics/$TIMESTAMP
   
   # Copy logs
   docker cp wazuh-nginx:/var/log/nginx /forensics/$TIMESTAMP/nginx-logs
   docker logs agent-ingest > /forensics/$TIMESTAMP/api-logs.txt 2>&1
   docker exec wazuh-fail2ban cat /var/log/fail2ban/fail2ban.log > /forensics/$TIMESTAMP/fail2ban.log
   
   # Snapshot container state
   docker commit wazuh-nginx forensics-nginx-$TIMESTAMP
   docker commit agent-ingest forensics-api-$TIMESTAMP
   ```

3. **Rotate credentials immediately**
   ```bash
   # Generate new API key
   openssl rand -hex 32 > secrets/api_key.txt
   docker compose restart agent-ingest
   ```

4. **Notify security team** (see [Section 12](#12-security-contacts))

**Investigation (15-60 minutes):**

1. Analyze access logs for suspicious patterns
2. Check fail2ban logs for blocked IPs
3. Review API logs for unauthorized access
4. Check Cloudflare analytics for attack patterns

### DDoS Attack

**Immediate Actions:**

1. **Enable Cloudflare "Under Attack" mode**
   - Cloudflare Dashboard → Security → Under Attack Mode → ON

2. **Increase rate limiting**
   ```bash
   # Temporarily reduce rate limits
   # Edit deploy/nginx/conf.d/rate-limiting.conf
   # Change rate=100r/s to rate=10r/s
   docker compose exec nginx nginx -s reload
   ```

3. **Block attacking IPs at Cloudflare**
   - Use Cloudflare Firewall Rules to block specific IPs/ranges

4. **Monitor and adjust**
   ```bash
   # Watch request rates
   docker exec wazuh-nginx tail -f /var/log/nginx/access.log | \
     jq -r '.remote_addr' | pv -l -i 1 > /dev/null
   ```

### Certificate Compromise

**Immediate Actions:**

1. **Revoke the compromised certificate**
   - Contact your CA to revoke the certificate
   - If using Let's Encrypt: `certbot revoke --cert-path /path/to/cert.pem`

2. **Generate new certificate**
   ```bash
   ./scripts/rotate-certs.sh --type letsencrypt \
     --domain api.example.com \
     --email admin@example.com \
     --force
   ```

3. **Reload Nginx**
   ```bash
   docker compose exec nginx nginx -s reload
   ```

4. **Update Cloudflare origin certificate** (if using Cloudflare Origin CA)

### API Key Leak

**Immediate Actions:**

1. **Rotate API key immediately**
   ```bash
   openssl rand -hex 32 > secrets/api_key.txt
   chmod 600 secrets/api_key.txt
   docker compose restart agent-ingest
   ```

2. **Review access logs for unauthorized use**
   ```bash
   # Check for requests with the leaked key
   docker exec wazuh-nginx cat /var/log/nginx/access.log | \
     jq -r 'select(.status == 200) | "\(.timestamp) \(.remote_addr) \(.request_uri)"'
   ```

3. **Update all legitimate API clients** with the new key

4. **Consider blocking IPs** that used the leaked key

---

## 10. Verification Commands

### Test Fail2ban Filter Parsing

```bash
# Test authentication failure filter
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-auth.conf

# Test rate limit filter
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-ratelimit.conf

# Test bad request filter
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-badrequest.conf

# Test scanner detection filter
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/wazuh-api-scanner.conf
```

### Test Rate Limiting

```bash
# Test health endpoint rate limiting (should see 429 after ~10 requests)
for i in {1..15}; do 
  curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/health/live
done

# Test API rate limiting (should see 429 after ~100 requests)
API_KEY=$(cat secrets/api_key.txt)
for i in {1..150}; do 
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "X-API-Key: $API_KEY" \
    https://api.example.com/api/health
done
```

### Test Authentication

```bash
# Test without API key (should return 401)
curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/api/health

# Test with wrong API key (should return 401)
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-API-Key: wrong_key" \
  https://api.example.com/api/health

# Test with correct API key (should return 200)
API_KEY=$(cat secrets/api_key.txt)
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-API-Key: $API_KEY" \
  https://api.example.com/api/health
```

### Check Fail2ban Status

```bash
# Overall status
docker exec wazuh-fail2ban fail2ban-client status

# Specific jail status
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-ratelimit
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-scanner
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-badrequest

# List banned IPs
docker exec wazuh-fail2ban fail2ban-client banned
```

### Verify Cloudflare IP Extraction

```bash
# Check Nginx logs for CF-Connecting-IP extraction
docker compose logs nginx | grep "CF-Connecting-IP"

# Verify real_ip_header is working
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r '.remote_addr' | head -10
```

### Test TLS Configuration

```bash
# Test TLS 1.2
openssl s_client -connect api.example.com:443 -tls1_2 </dev/null 2>/dev/null | \
  grep "Protocol"

# Test TLS 1.3
openssl s_client -connect api.example.com:443 -tls1_3 </dev/null 2>/dev/null | \
  grep "Protocol"

# Test TLS 1.0 (should fail)
openssl s_client -connect api.example.com:443 -tls1 </dev/null 2>&1 | \
  grep -E "handshake failure|no protocols"

# Check certificate details
openssl s_client -connect api.example.com:443 </dev/null 2>/dev/null | \
  openssl x509 -noout -subject -issuer -dates
```

### Test Security Headers

```bash
curl -s -I https://api.example.com/health/live | \
  grep -iE "strict-transport|x-content-type|x-frame|x-xss|content-security|referrer-policy"
```

---

## 11. Troubleshooting

### Fail2ban Not Banning IPs

**Symptoms:**
- Repeated authentication failures not resulting in bans
- `fail2ban-client status` shows 0 banned IPs despite attacks

**Diagnosis:**
```bash
# Check if fail2ban is running
docker exec wazuh-fail2ban fail2ban-client ping

# Check jail status
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth

# Test filter against logs
docker exec wazuh-fail2ban fail2ban-regex \
  /var/log/nginx/access.log \
  /etc/fail2ban/filter.d/wazuh-api-auth.conf
```

**Solutions:**

1. **Log format mismatch**: Ensure Nginx is using JSON log format
   ```bash
   # Check log format
   docker exec wazuh-nginx head -1 /var/log/nginx/access.log
   # Should be JSON: {"timestamp":"...","remote_addr":"...",...}
   ```

2. **Filter regex issue**: The filters expect JSON format
   ```bash
   # Verify filter matches
   docker exec wazuh-fail2ban fail2ban-regex \
     /var/log/nginx/access.log \
     /etc/fail2ban/filter.d/wazuh-api-auth.conf --print-all-matched
   ```

3. **Log path issue**: Verify log volume is mounted
   ```bash
   docker exec wazuh-fail2ban ls -la /var/log/nginx/
   ```

### Rate Limiting Not Working

**Symptoms:**
- No 429 responses even with high request rates
- Rate limit headers not present

**Diagnosis:**
```bash
# Check rate limit zone configuration
docker exec wazuh-nginx nginx -T | grep limit_req

# Check if rate limiting is applied to location
docker exec wazuh-nginx nginx -T | grep -A5 "location /health"
```

**Solutions:**

1. **Zone not defined**: Ensure [`rate-limiting.conf`](../deploy/nginx/conf.d/rate-limiting.conf) is loaded
   ```bash
   docker exec wazuh-nginx ls -la /etc/nginx/conf.d/
   ```

2. **Whitelist bypass**: Check if your IP is whitelisted
   ```bash
   docker exec wazuh-nginx cat /etc/nginx/conf.d/ip-whitelist.conf
   ```

3. **Zone name mismatch**: Verify zone names match between definition and usage

### Certificate Warnings

**Symptoms:**
- Browser shows certificate warning
- `curl` fails without `-k` flag
- API clients reject connection

**Diagnosis:**
```bash
# Check certificate details
openssl x509 -in deploy/nginx/certs/server.crt -noout -text | \
  grep -E "Subject:|Issuer:|Not Before:|Not After:"

# Check if self-signed
openssl x509 -in deploy/nginx/certs/server.crt -noout -issuer -subject
# If Issuer == Subject, it's self-signed
```

**Solutions:**

1. **Self-signed certificate**: Replace with CA-signed certificate
   ```bash
   ./scripts/rotate-certs.sh --type letsencrypt \
     --domain api.example.com \
     --email admin@example.com
   ```

2. **Expired certificate**: Renew the certificate
   ```bash
   ./scripts/rotate-certs.sh --check
   ./scripts/rotate-certs.sh --force
   ```

3. **Wrong domain**: Ensure certificate matches your domain
   ```bash
   openssl x509 -in deploy/nginx/certs/server.crt -noout -text | \
     grep -A1 "Subject Alternative Name"
   ```

### Cloudflare IP Extraction Issues

**Symptoms:**
- All requests show Cloudflare IP instead of real client IP
- Rate limiting affects all users equally
- Fail2ban bans Cloudflare IPs

**Diagnosis:**
```bash
# Check if CF-Connecting-IP is being used
docker exec wazuh-nginx cat /etc/nginx/conf.d/cloudflare_real_ip.conf | head -20

# Check logged IPs
docker exec wazuh-nginx cat /var/log/nginx/access.log | \
  jq -r '.remote_addr' | sort | uniq -c | sort -rn | head -10
```

**Solutions:**

1. **Outdated Cloudflare IPs**: Update the IP list
   ```bash
   ./scripts/update-cloudflare-ips.sh
   docker compose exec nginx nginx -s reload
   ```

2. **Configuration not loaded**: Verify include order in [`nginx.conf`](../deploy/nginx/nginx.conf:239)
   ```bash
   docker exec wazuh-nginx nginx -T | grep cloudflare_real_ip
   ```

3. **Not behind Cloudflare**: If accessing directly, real IP extraction won't work
   - Ensure all traffic goes through Cloudflare
   - Block direct access to origin server

### Container Startup Failures

**Symptoms:**
- Containers exit immediately after starting
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

1. **Missing secrets**: Ensure API key file exists
   ```bash
   ls -la secrets/api_key.txt
   cat secrets/api_key.txt | wc -c  # Should be > 0
   ```

2. **Permission issues**: Fix file permissions
   ```bash
   chmod 700 secrets/
   chmod 600 secrets/api_key.txt
   chmod 644 deploy/nginx/certs/server.crt
   chmod 600 deploy/nginx/certs/server.key
   ```

3. **Port conflicts**: Check if ports are in use
   ```bash
   sudo lsof -i :80
   sudo lsof -i :443
   ```

---

## 12. Security Contacts

### Internal Contacts

| Role | Contact | Responsibility |
|------|---------|----------------|
| Security Team Lead | security-lead@example.com | Security incidents, policy |
| Operations Lead | ops-lead@example.com | Infrastructure, deployments |
| On-Call Engineer | oncall@example.com | 24/7 emergency response |
| CISO | ciso@example.com | Executive escalation |

### External Contacts

| Service | Contact | Purpose |
|---------|---------|---------|
| Cloudflare Support | support.cloudflare.com | WAF, DDoS issues |
| Certificate Authority | (your CA contact) | Certificate issues |
| Wazuh Support | support@wazuh.com | Wazuh-specific issues |

### Escalation Matrix

| Severity | Response Time | Escalation Path |
|----------|---------------|-----------------|
| **Critical** (breach, data loss) | 15 minutes | On-Call → Security Lead → CISO |
| **High** (service down, active attack) | 1 hour | On-Call → Ops Lead → Security Lead |
| **Medium** (degraded service) | 4 hours | On-Call → Ops Lead |
| **Low** (minor issues) | 24 hours | Ticket system |

### Incident Communication Template

```
SECURITY INCIDENT REPORT

Date/Time: [YYYY-MM-DD HH:MM UTC]
Severity: [Critical/High/Medium/Low]
Reporter: [Name]

SUMMARY:
[Brief description of the incident]

IMPACT:
- Systems affected: [list]
- Data affected: [description]
- Users affected: [number/description]

CURRENT STATUS:
[Contained/Investigating/Mitigated/Resolved]

ACTIONS TAKEN:
1. [Action 1]
2. [Action 2]

NEXT STEPS:
1. [Next step 1]
2. [Next step 2]

CONTACT:
[Primary contact for this incident]
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2026-01-29 | Security Team | Initial production deployment guide |

---

*This document is part of the Wazuh Log Ingestion Pipeline security documentation. For additional information, see:*
- [Deployment Guide](DEPLOYMENT.md)
- [Security Testing Checklist](SECURITY-TESTING-CHECKLIST.md)
- [Security Verification Report](SECURITY-VERIFICATION-REPORT.md)
- [Certificate Management](certificate-management.md)