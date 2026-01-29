# Wazuh Log Ingestion Pipeline - Troubleshooting Guide

This guide provides solutions for common deployment issues encountered when running the Wazuh log ingestion pipeline using `scripts/migrate-deployment.sh`.

## Table of Contents

- [Overview](#overview)
- [API Endpoint Issues](#api-endpoint-issues)
- [Wazuh Agent Connectivity Issues](#wazuh-agent-connectivity-issues)
- [Agent Registration Issues](#agent-registration-issues)
- [Docker Network Troubleshooting](#docker-network-troubleshooting)
- [Verification Commands](#verification-commands)
- [Configuration Reference](#configuration-reference)

---

## Overview

The Wazuh log ingestion pipeline consists of several interconnected components:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        External Network                              │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Nginx Reverse Proxy                       │   │
│  │                    (wazuh-nginx:443/80)                      │   │
│  │  - TLS termination                                           │   │
│  │  - Rate limiting                                             │   │
│  │  - Request routing                                           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Internal Network                          │   │
│  │  ┌─────────────────┐    ┌─────────────────┐                 │   │
│  │  │  agent-ingest   │    │  agent-regular  │                 │   │
│  │  │  (FastAPI:9000) │    │  (Wazuh Agent)  │                 │   │
│  │  └────────┬────────┘    └────────┬────────┘                 │   │
│  │           │                      │                           │   │
│  │           └──────────┬───────────┘                           │   │
│  │                      ▼                                       │   │
│  │           ┌─────────────────────┐                            │   │
│  │           │   Wazuh Manager     │                            │   │
│  │           │   (10.47.5.216)     │                            │   │
│  │           │   :1514 (events)    │                            │   │
│  │           │   :1515 (enrollment)│                            │   │
│  └───────────┴─────────────────────┴────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

Common issues fall into three categories:
1. **API Endpoint Issues** - HTTP routing and endpoint availability
2. **Agent Connectivity Issues** - Network connectivity to Wazuh Manager
3. **Agent Registration Issues** - Authentication and enrollment problems

---

## API Endpoint Issues

### Symptom: `/api/ingest` Returns 404 or Errors

**Error Message:**
```json
{
  "error": "Not Found",
  "message": "The requested URL was not found on the server"
}
```

**Root Cause:**

The FastAPI backend defines endpoints at `/ingest` (not `/api/ingest`). If the Nginx configuration doesn't include a specific location block for `/api/ingest`, requests to this path will fail.

**Diagnosis Steps:**

1. Check if the endpoint exists in Nginx configuration:
   ```bash
   docker exec wazuh-nginx cat /etc/nginx/conf.d/default.conf | grep -A5 "location.*ingest"
   ```

2. Test the direct backend endpoint:
   ```bash
   docker exec wazuh-nginx curl -s http://wazuh-api/ingest
   ```

3. Test through Nginx:
   ```bash
   curl -k https://localhost/api/ingest -X POST \
     -H "Content-Type: application/json" \
     -H "X-API-Key: YOUR_API_KEY" \
     -d '{"timestamp":"2024-01-01T00:00:00Z","source":"test","message":"test"}'
   ```

**Resolution:**

Ensure [`deploy/nginx/conf.d/default.conf`](../deploy/nginx/conf.d/default.conf:94-123) contains the `/api/ingest` location block:

```nginx
# API Ingest Endpoint (Specific route for /api/ingest)
# Must be defined BEFORE the general /api/ location block
location = /api/ingest {
    limit_req zone=api_limit burst=50 nodelay;
    proxy_pass http://wazuh-api/ingest;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-API-Key $http_x_api_key;
    proxy_connect_timeout 30s;
    proxy_read_timeout 120s;
    proxy_send_timeout 60s;
    client_max_body_size 1m;
}
```

After modifying the configuration, reload Nginx:
```bash
docker exec wazuh-nginx nginx -s reload
```

### Available Endpoints Reference

| Endpoint | Method | Description | Auth Required | Max Payload |
|----------|--------|-------------|---------------|-------------|
| `/health/live` | GET | Liveness probe | No | N/A |
| `/health/ready` | GET | Readiness probe | No | N/A |
| `/health` | GET | Detailed health check | Yes | N/A |
| `/ingest` | POST | Single log ingestion | Yes | 1MB |
| `/api/ingest` | POST | Single log ingestion (alias) | Yes | 1MB |
| `/batch` | POST | Batch log ingestion | Yes | 10MB |
| `/api/health` | GET | Health check via /api prefix | Yes | N/A |

---

## Wazuh Agent Connectivity Issues

### Symptom: Agent Cannot Connect to Manager

**Error Messages:**
```
ERROR: Unable to connect to 10.47.5.216:1515
Connection refused
Connection timed out
```

**Root Cause:**

The Wazuh Manager (10.47.5.216) is typically only accessible from the target deployment network, not from local development machines. This is expected behavior when testing locally.

**Diagnosis Steps:**

1. **Check environment configuration:**
   ```bash
   cat .env | grep -E "(MANAGER|SERVER)_(URL|PORT)"
   ```
   
   Expected output:
   ```
   MANAGER_URL=10.47.5.216
   MANAGER_PORT=1515
   SERVER_URL=10.47.5.216
   SERVER_PORT=1514
   ```

2. **Test connectivity from inside the container:**
   ```bash
   # Test enrollment port (1515)
   docker exec agent-ingest nc -zv 10.47.5.216 1515 -w 5
   
   # Test event port (1514)
   docker exec agent-ingest nc -zv 10.47.5.216 1514 -w 5
   ```

3. **Check network configuration:**
   ```bash
   docker network inspect wazuh-internal
   ```

4. **Verify the agent's ossec.conf:**
   ```bash
   docker exec agent-ingest cat /var/ossec/etc/ossec.conf | grep -A10 "<server>"
   ```

**Common Causes:**

| Cause | Symptoms | Solution |
|-------|----------|----------|
| Network isolation | Connection timeout | Deploy on network with Manager access |
| Firewall blocking | Connection refused | Open ports 1514/1515 on firewall |
| Wrong IP address | Connection refused | Verify `MANAGER_URL` in [`.env`](../.env:2) |
| Manager not running | Connection refused | Check Manager status on target host |
| DNS resolution failure | Name resolution failed | Use IP address instead of hostname |

**Resolution Steps:**

1. **For local development (Manager not accessible):**
   
   The agent will fail to connect but the API will still function. Log ingestion will queue locally until the agent connects.

2. **For production deployment:**
   
   Ensure the deployment VM has network access to the Wazuh Manager:
   ```bash
   # On the deployment VM
   nc -zv 10.47.5.216 1515
   nc -zv 10.47.5.216 1514
   ```

3. **Verify Docker network allows outbound connections:**
   
   Check that [`docker-compose.yml`](../docker-compose.yml:361-366) has `internal: true` commented out:
   ```yaml
   wazuh-internal:
     driver: bridge
     # internal: true  # Must be commented out for Manager connectivity
     name: wazuh-internal
   ```

---

## Agent Registration Issues

### Symptom: Registration Fails

**Error Messages:**
```
ERROR: Unable to register agent
Authentication failed
Invalid password
```

### Scenario 1: Registration Without Authentication Token

**Root Cause:**

If the Wazuh Manager's `authd` service is configured to accept registrations without a password, the agent can register using only the Manager IP and port.

**Configuration:**

In [`.env`](../.env), the `ENROL_TOKEN` variable is optional:
```bash
# Optional - only required if Manager requires authentication
ENROL_TOKEN=
```

The agent configuration template [`config/ossec.tpl`](../config/ossec.tpl:19-25) uses these environment variables:
```xml
<enrollment>
    <agent_name>$NAME</agent_name>
    <groups>$GROUP</groups>
    <port>$MANAGER_PORT</port>
    <manager_address>$MANAGER_URL</manager_address>
</enrollment>
```

**Verification:**

Check if the Manager requires authentication:
```bash
# On the Wazuh Manager
cat /var/ossec/etc/ossec.conf | grep -A5 "<auth>"
```

If `<use_password>` is set to `no`, registration without token is allowed.

### Scenario 2: Registration With Authentication Token

**Configuration:**

1. Set the enrollment token in [`.env`](../.env):
   ```bash
   ENROL_TOKEN=your-secure-enrollment-token
   ```

2. The token must match the one configured on the Wazuh Manager:
   ```bash
   # On the Wazuh Manager
   cat /var/ossec/etc/authd.pass
   ```

**Troubleshooting Token Issues:**

| Issue | Diagnosis | Solution |
|-------|-----------|----------|
| Token mismatch | Check Manager's authd.pass | Update `ENROL_TOKEN` in `.env` |
| Token not set | `echo $ENROL_TOKEN` is empty | Set token in `.env` file |
| Token has whitespace | Token contains spaces/newlines | Remove whitespace from token |

---

## Docker Network Troubleshooting

### Testing Connectivity from Inside Containers

**Test outbound connectivity:**
```bash
# From agent-ingest container
docker exec agent-ingest ping -c 3 10.47.5.216

# Test specific ports
docker exec agent-ingest nc -zv 10.47.5.216 1514 -w 5
docker exec agent-ingest nc -zv 10.47.5.216 1515 -w 5
```

**Test inter-container connectivity:**
```bash
# From nginx to agent-ingest
docker exec wazuh-nginx curl -s http://agent-ingest:9000/health/live
```

### Network Configuration Verification

**List all networks:**
```bash
docker network ls | grep wazuh
```

**Inspect network details:**
```bash
docker network inspect wazuh-internal
docker network inspect wazuh-external
```

**Check container network attachments:**
```bash
docker inspect agent-ingest --format='{{json .NetworkSettings.Networks}}' | jq
```

### Common Docker Networking Issues

| Issue | Symptoms | Diagnosis | Solution |
|-------|----------|-----------|----------|
| Internal network blocking outbound | Cannot reach Manager | `internal: true` is set | Comment out `internal: true` in docker-compose.yml |
| DNS resolution failure | Cannot resolve hostnames | DNS not configured | Use IP addresses or configure DNS |
| Network not created | Container fails to start | Network doesn't exist | Run `docker-compose up` to create networks |
| Port conflicts | Container fails to bind | Port already in use | Change port mapping or stop conflicting service |

### Network Troubleshooting Flowchart

```
┌─────────────────────────────────────┐
│ Agent cannot connect to Manager     │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│ Can you ping Manager from host?     │
└─────────────────┬───────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
       Yes                  No
        │                   │
        ▼                   ▼
┌───────────────┐   ┌───────────────────────┐
│ Test from     │   │ Network issue outside │
│ container     │   │ Docker - check        │
│               │   │ firewall/routing      │
└───────┬───────┘   └───────────────────────┘
        │
        ▼
┌─────────────────────────────────────┐
│ Can container reach Manager?        │
└─────────────────┬───────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
       Yes                  No
        │                   │
        ▼                   ▼
┌───────────────┐   ┌───────────────────────┐
│ Check agent   │   │ Check docker-compose  │
│ configuration │   │ network settings      │
│ (ossec.conf)  │   │ (internal: true?)     │
└───────────────┘   └───────────────────────┘
```

---

## Verification Commands

### Complete Diagnostic Command Set

**1. Service Status:**
```bash
# Check all containers are running
docker-compose ps

# Check container health
docker inspect --format='{{.Name}}: {{.State.Health.Status}}' $(docker ps -q)
```

**2. API Health Checks:**
```bash
# Liveness probe (no auth)
curl -k https://localhost/health/live

# Readiness probe (no auth)
curl -k https://localhost/health/ready

# Full health check (requires auth)
curl -k https://localhost/health \
  -H "X-API-Key: $(cat secrets/api_key.txt)"
```

**Expected Outputs:**

| Endpoint | Healthy Response | Unhealthy Response |
|----------|------------------|-------------------|
| `/health/live` | `{"status": "alive"}` | Connection refused |
| `/health/ready` | `{"status": "ready", "wazuh_socket": "connected"}` | `{"status": "not_ready", "wazuh_socket": "disconnected"}` |
| `/health` | `{"status": "healthy", ...}` | `{"status": "unhealthy", ...}` |

**3. Log Ingestion Test:**
```bash
# Test single event ingestion
curl -k -X POST https://localhost/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $(cat secrets/api_key.txt)" \
  -d '{
    "timestamp": "2024-01-15T10:30:00Z",
    "source": "test-source",
    "message": "Test log message",
    "level": "info"
  }'
```

**Expected Output:**
```json
{
  "status": "success",
  "message": "Event sent to Wazuh",
  "request_id": "uuid-here"
}
```

**4. Container Logs:**
```bash
# View API logs
docker logs agent-ingest --tail 100

# View Nginx logs
docker logs wazuh-nginx --tail 100

# Follow logs in real-time
docker logs -f agent-ingest
```

**5. Wazuh Agent Status:**
```bash
# Check agent status
docker exec agent-ingest /var/ossec/bin/wazuh-control status

# Check agent connection
docker exec agent-ingest /var/ossec/bin/agent-auth -h
```

**6. Network Diagnostics:**
```bash
# List networks
docker network ls | grep wazuh

# Inspect internal network
docker network inspect wazuh-internal

# Test Manager connectivity
docker exec agent-ingest nc -zv 10.47.5.216 1515 -w 5
```

**7. Configuration Verification:**
```bash
# Check environment variables
docker exec agent-ingest env | grep -E "(MANAGER|SERVER|API)"

# Check ossec.conf
docker exec agent-ingest cat /var/ossec/etc/ossec.conf | head -50

# Check Nginx config
docker exec wazuh-nginx nginx -t
```

---

## Configuration Reference

### Key Configuration Files

| File | Purpose | Key Settings |
|------|---------|--------------|
| [`.env`](../.env) | Environment variables | Manager URL/ports, API port, agent version |
| [`docker-compose.yml`](../docker-compose.yml) | Service definitions | Networks, volumes, secrets, health checks |
| [`deploy/nginx/conf.d/default.conf`](../deploy/nginx/conf.d/default.conf) | Nginx routing | Endpoint proxying, rate limits, timeouts |
| [`config/ossec.tpl`](../config/ossec.tpl) | Agent config template | Server connection, enrollment settings |
| [`api/api.py`](../api/api.py) | FastAPI application | Endpoints, authentication, logging |

### Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `MANAGER_URL` | `localhost` | Wazuh Manager IP/hostname for enrollment |
| `MANAGER_PORT` | `1515` | Wazuh Manager enrollment port |
| `SERVER_URL` | `localhost` | Wazuh Manager IP/hostname for events |
| `SERVER_PORT` | `1514` | Wazuh Manager event port |
| `API_PORT` | `9000` | FastAPI internal port |
| `ENROL_TOKEN` | (empty) | Optional enrollment authentication token |
| `API_KEY` | (required) | API authentication key |
| `ENVIRONMENT` | `test` | Environment name (test/production) |
| `WAZUH_AGENT_VERSION` | `4.7.2` | Wazuh agent version to install |
| `WAZUH_DECODER_HEADER` | `1:Wazuh-AWS:` | Default decoder header for events |

### Secrets Management

Secrets are stored in the `secrets/` directory and mounted into containers:

| Secret | Path in Container | Purpose |
|--------|-------------------|---------|
| `api_key` | `/run/secrets/api_key` | API authentication |

**Initialize secrets:**
```bash
./scripts/init-secrets.sh
```

**Manual secret creation:**
```bash
# Generate a secure API key
openssl rand -hex 32 > secrets/api_key.txt
```

### Port Reference

| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 443 | Nginx | HTTPS | External API access |
| 80 | Nginx | HTTP | Redirect to HTTPS |
| 9000 | agent-ingest | HTTP | Internal API (not exposed) |
| 1514 | Wazuh Manager | TCP | Agent event communication |
| 1515 | Wazuh Manager | TCP | Agent enrollment |

---

## Quick Reference: Common Commands

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# Restart a specific service
docker-compose restart agent-ingest

# View logs
docker-compose logs -f

# Rebuild and restart
docker-compose up -d --build

# Check service health
curl -k https://localhost/health/live

# Test API endpoint
curl -k -X POST https://localhost/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $(cat secrets/api_key.txt)" \
  -d '{"timestamp":"2024-01-01T00:00:00Z","source":"test","message":"test"}'

# Check container connectivity to Manager
docker exec agent-ingest nc -zv 10.47.5.216 1515 -w 5