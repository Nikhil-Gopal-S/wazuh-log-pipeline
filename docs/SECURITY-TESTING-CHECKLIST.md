# Security Testing Checklist

This comprehensive checklist verifies all security controls are working correctly for the Wazuh Log Pipeline deployment.

## Overview

Use this checklist to validate security controls before and after deployment. Each test should be performed and documented with results.

**Testing Date:** _______________  
**Tester:** _______________  
**Environment:** _______________  
**Version:** _______________

---

## 1. Authentication Tests

Verify API key authentication is enforced correctly.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| AUTH-01 | Request without API key | 401 or 403 response | | ☐ Pass ☐ Fail |
| AUTH-02 | Request with invalid API key | 401 or 403 response | | ☐ Pass ☐ Fail |
| AUTH-03 | Request with valid API key | 200 response (or appropriate success) | | ☐ Pass ☐ Fail |
| AUTH-04 | Request with expired API key (if applicable) | 401 or 403 response | | ☐ Pass ☐ Fail |
| AUTH-05 | API key in header (X-API-Key) | Accepted | | ☐ Pass ☐ Fail |
| AUTH-06 | API key case sensitivity | Exact match required | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# AUTH-01: Missing API key
curl -k -s -o /dev/null -w "%{http_code}" https://localhost/api/

# AUTH-02: Invalid API key
curl -k -s -o /dev/null -w "%{http_code}" -H "X-API-Key: invalid-key" https://localhost/api/

# AUTH-03: Valid API key
curl -k -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $API_KEY" https://localhost/api/
```

---

## 2. TLS/SSL Tests

Verify TLS configuration meets security requirements.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| TLS-01 | TLS 1.2 supported | Connection successful | | ☐ Pass ☐ Fail |
| TLS-02 | TLS 1.3 supported | Connection successful | | ☐ Pass ☐ Fail |
| TLS-03 | TLS 1.0 rejected | Connection refused/failed | | ☐ Pass ☐ Fail |
| TLS-04 | TLS 1.1 rejected | Connection refused/failed | | ☐ Pass ☐ Fail |
| TLS-05 | SSL 3.0 rejected | Connection refused/failed | | ☐ Pass ☐ Fail |
| TLS-06 | Strong cipher suites only | Weak ciphers rejected | | ☐ Pass ☐ Fail |
| TLS-07 | Certificate validity | Valid, not expired | | ☐ Pass ☐ Fail |
| TLS-08 | Certificate chain complete | Full chain present | | ☐ Pass ☐ Fail |
| TLS-09 | HTTP to HTTPS redirect | 301/302 redirect | | ☐ Pass ☐ Fail |
| TLS-10 | HSTS header present | Strict-Transport-Security set | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# TLS-01: Test TLS 1.2
openssl s_client -connect localhost:443 -tls1_2 </dev/null 2>/dev/null | grep "Protocol"

# TLS-02: Test TLS 1.3
openssl s_client -connect localhost:443 -tls1_3 </dev/null 2>/dev/null | grep "Protocol"

# TLS-03: Test TLS 1.0 (should fail)
openssl s_client -connect localhost:443 -tls1 </dev/null 2>&1 | grep -E "handshake failure|no protocols"

# TLS-04: Test TLS 1.1 (should fail)
openssl s_client -connect localhost:443 -tls1_1 </dev/null 2>&1 | grep -E "handshake failure|no protocols"

# TLS-06: Check cipher suites
nmap --script ssl-enum-ciphers -p 443 localhost

# TLS-07: Check certificate validity
openssl s_client -connect localhost:443 </dev/null 2>/dev/null | openssl x509 -noout -dates

# TLS-09: Test HTTP redirect
curl -s -o /dev/null -w "%{http_code}" http://localhost/

# TLS-10: Check HSTS header
curl -k -s -I https://localhost/ | grep -i "strict-transport-security"
```

---

## 3. Rate Limiting Tests

Verify rate limiting protects against abuse.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| RATE-01 | Normal traffic passes | 200 responses | | ☐ Pass ☐ Fail |
| RATE-02 | Burst traffic triggers limit | 429 responses after threshold | | ☐ Pass ☐ Fail |
| RATE-03 | Rate limit resets after window | Requests allowed after cooldown | | ☐ Pass ☐ Fail |
| RATE-04 | Whitelisted IPs bypass limits | No 429 for whitelisted IPs | | ☐ Pass ☐ Fail |
| RATE-05 | Rate limit headers present | X-RateLimit-* headers | | ☐ Pass ☐ Fail |
| RATE-06 | Different endpoints have appropriate limits | Limits match configuration | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# RATE-01: Normal traffic
for i in {1..10}; do curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost/health/live; done

# RATE-02: Burst traffic (adjust count based on your limits)
for i in {1..150}; do curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost/health/live; done | grep 429 | wc -l

# RATE-05: Check rate limit headers
curl -k -s -I https://localhost/api/ -H "X-API-Key: $API_KEY" | grep -i "x-ratelimit"
```

---

## 4. Input Validation Tests

Verify input validation protects against malformed requests.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| INPUT-01 | Valid JSON accepted | 200 response | | ☐ Pass ☐ Fail |
| INPUT-02 | Invalid JSON rejected | 400 Bad Request | | ☐ Pass ☐ Fail |
| INPUT-03 | Oversized payload rejected | 413 Payload Too Large | | ☐ Pass ☐ Fail |
| INPUT-04 | Missing required fields rejected | 400 Bad Request | | ☐ Pass ☐ Fail |
| INPUT-05 | SQL injection attempts blocked | Request rejected/sanitized | | ☐ Pass ☐ Fail |
| INPUT-06 | XSS attempts blocked | Request rejected/sanitized | | ☐ Pass ☐ Fail |
| INPUT-07 | Path traversal attempts blocked | 400/403 response | | ☐ Pass ☐ Fail |
| INPUT-08 | Null bytes rejected | 400 response | | ☐ Pass ☐ Fail |
| INPUT-09 | Content-Type validation | Only application/json accepted | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# INPUT-01: Valid JSON
curl -k -s -o /dev/null -w "%{http_code}" -X POST https://localhost/api/logs \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"message": "test log"}'

# INPUT-02: Invalid JSON
curl -k -s -o /dev/null -w "%{http_code}" -X POST https://localhost/api/logs \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{invalid json}'

# INPUT-03: Oversized payload (adjust size based on your limit)
curl -k -s -o /dev/null -w "%{http_code}" -X POST https://localhost/api/logs \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'print("{\"data\": \"" + "x"*2000000 + "\"}")')"

# INPUT-07: Path traversal
curl -k -s -o /dev/null -w "%{http_code}" "https://localhost/api/../../../etc/passwd"
```

---

## 5. Container Security Tests

Verify container hardening measures are in place.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| CONT-01 | Nginx running as non-root | UID != 0 | | ☐ Pass ☐ Fail |
| CONT-02 | API running as non-root | UID != 0 | | ☐ Pass ☐ Fail |
| CONT-03 | Capabilities dropped | Minimal capabilities | | ☐ Pass ☐ Fail |
| CONT-04 | Read-only filesystem (where applicable) | Write attempts fail | | ☐ Pass ☐ Fail |
| CONT-05 | No privileged containers | privileged: false | | ☐ Pass ☐ Fail |
| CONT-06 | Security options set | no-new-privileges, seccomp | | ☐ Pass ☐ Fail |
| CONT-07 | Resource limits defined | CPU/memory limits set | | ☐ Pass ☐ Fail |
| CONT-08 | Health checks configured | Health checks running | | ☐ Pass ☐ Fail |
| CONT-09 | No sensitive env vars exposed | Secrets via files/mounts | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# CONT-01: Check nginx user
docker exec wazuh-nginx id

# CONT-02: Check API user
docker exec wazuh-api id

# CONT-03: Check capabilities
docker inspect wazuh-nginx --format='{{.HostConfig.CapDrop}}'
docker inspect wazuh-nginx --format='{{.HostConfig.CapAdd}}'

# CONT-05: Check privileged mode
docker inspect wazuh-nginx --format='{{.HostConfig.Privileged}}'

# CONT-06: Check security options
docker inspect wazuh-nginx --format='{{.HostConfig.SecurityOpt}}'

# CONT-07: Check resource limits
docker inspect wazuh-nginx --format='{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'

# CONT-08: Check health status
docker inspect wazuh-nginx --format='{{.State.Health.Status}}'
```

---

## 6. Network Isolation Tests

Verify network segmentation is properly configured.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| NET-01 | Only nginx exposed externally | Ports 80, 443 only | | ☐ Pass ☐ Fail |
| NET-02 | API not directly accessible | Connection refused on API port | | ☐ Pass ☐ Fail |
| NET-03 | Internal services isolated | Cannot reach from outside | | ☐ Pass ☐ Fail |
| NET-04 | Inter-container communication works | Internal network functional | | ☐ Pass ☐ Fail |
| NET-05 | External network restricted | Only nginx on external | | ☐ Pass ☐ Fail |
| NET-06 | DNS resolution controlled | Internal DNS only | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# NET-01: Check exposed ports
docker ps --format "{{.Names}}: {{.Ports}}" | grep -E "0.0.0.0|:::"

# NET-02: Try direct API access (should fail)
curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/

# NET-03: Check network configuration
docker network inspect wazuh-external
docker network inspect wazuh-internal

# NET-04: Test internal communication
docker exec wazuh-nginx curl -s http://wazuh-api:5000/health
```

---

## 7. Logging Tests

Verify logging captures security-relevant events.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| LOG-01 | Requests logged | Access logs populated | | ☐ Pass ☐ Fail |
| LOG-02 | Request IDs present | X-Request-ID in logs | | ☐ Pass ☐ Fail |
| LOG-03 | Client IPs logged | Real IP captured | | ☐ Pass ☐ Fail |
| LOG-04 | Auth failures logged | 401/403 events recorded | | ☐ Pass ☐ Fail |
| LOG-05 | Rate limit events logged | 429 events recorded | | ☐ Pass ☐ Fail |
| LOG-06 | Sensitive data NOT in logs | No API keys, passwords | | ☐ Pass ☐ Fail |
| LOG-07 | Log rotation configured | Logs rotated properly | | ☐ Pass ☐ Fail |
| LOG-08 | Error logs captured | Errors logged separately | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# LOG-01: Check access logs
docker logs wazuh-nginx 2>&1 | tail -20

# LOG-02: Check for request IDs
docker logs wazuh-nginx 2>&1 | grep -o 'request_id=[^ ]*' | head -5

# LOG-04: Generate and check auth failure
curl -k -s https://localhost/api/ -H "X-API-Key: invalid"
docker logs wazuh-nginx 2>&1 | grep -E "401|403" | tail -5

# LOG-06: Verify no sensitive data (should return nothing)
docker logs wazuh-nginx 2>&1 | grep -iE "api.?key|password|secret|token" | grep -v "X-API-Key"
```

---

## 8. Fail2ban Tests

Verify fail2ban protects against brute force attacks.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| F2B-01 | Fail2ban service running | Active and monitoring | | ☐ Pass ☐ Fail |
| F2B-02 | Auth failures trigger ban | IP banned after threshold | | ☐ Pass ☐ Fail |
| F2B-03 | Rate limit violations trigger ban | IP banned after threshold | | ☐ Pass ☐ Fail |
| F2B-04 | Scanner detection works | Suspicious patterns banned | | ☐ Pass ☐ Fail |
| F2B-05 | Ban duration correct | Matches configuration | | ☐ Pass ☐ Fail |
| F2B-06 | Whitelisted IPs not banned | Whitelist respected | | ☐ Pass ☐ Fail |
| F2B-07 | Ban notifications sent | Alerts generated | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# F2B-01: Check fail2ban status
docker exec wazuh-fail2ban fail2ban-client status

# F2B-02: Check specific jail status
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth

# F2B-03: List banned IPs
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-ratelimit

# F2B-05: Check ban time configuration
docker exec wazuh-fail2ban fail2ban-client get wazuh-api-auth bantime

# F2B-06: Check whitelist
docker exec wazuh-fail2ban fail2ban-client get wazuh-api-auth ignoreip
```

---

## 9. Security Headers Tests

Verify security headers are properly configured.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| HDR-01 | X-Content-Type-Options | nosniff | | ☐ Pass ☐ Fail |
| HDR-02 | X-Frame-Options | DENY or SAMEORIGIN | | ☐ Pass ☐ Fail |
| HDR-03 | X-XSS-Protection | 1; mode=block | | ☐ Pass ☐ Fail |
| HDR-04 | Content-Security-Policy | Appropriate policy | | ☐ Pass ☐ Fail |
| HDR-05 | Referrer-Policy | strict-origin-when-cross-origin | | ☐ Pass ☐ Fail |
| HDR-06 | Server header hidden/modified | No version info | | ☐ Pass ☐ Fail |
| HDR-07 | X-Request-ID present | Unique ID returned | | ☐ Pass ☐ Fail |

### Test Commands

```bash
# Check all security headers
curl -k -s -I https://localhost/health/live | grep -iE "x-content-type|x-frame|x-xss|content-security|referrer-policy|server|x-request-id"
```

---

## 10. Backup and Recovery Tests

Verify backup and recovery procedures work correctly.

| Test ID | Test Description | Expected Result | Actual Result | Status |
|---------|-----------------|-----------------|---------------|--------|
| BAK-01 | Backup script executes | Backup created successfully | | ☐ Pass ☐ Fail |
| BAK-02 | Backup includes all data | All components backed up | | ☐ Pass ☐ Fail |
| BAK-03 | Backup encryption works | Encrypted backup file | | ☐ Pass ☐ Fail |
| BAK-04 | Restore script executes | Restore completes | | ☐ Pass ☐ Fail |
| BAK-05 | Restored data valid | Services functional after restore | | ☐ Pass ☐ Fail |

---

## Summary

| Category | Total Tests | Passed | Failed | Skipped |
|----------|-------------|--------|--------|---------|
| Authentication | 6 | | | |
| TLS/SSL | 10 | | | |
| Rate Limiting | 6 | | | |
| Input Validation | 9 | | | |
| Container Security | 9 | | | |
| Network Isolation | 6 | | | |
| Logging | 8 | | | |
| Fail2ban | 7 | | | |
| Security Headers | 7 | | | |
| Backup/Recovery | 5 | | | |
| **TOTAL** | **73** | | | |

---

## Sign-off

**Security Testing Completed By:** _______________  
**Date:** _______________  
**Overall Status:** ☐ PASS ☐ FAIL  

**Notes:**
_____________________________________________________________________________
_____________________________________________________________________________
_____________________________________________________________________________

---

## Automated Testing

For automated security testing, use the provided script:

```bash
./scripts/security-test.sh
```

See [scripts/security-test.sh](../scripts/security-test.sh) for the automated test implementation.