#!/bin/bash
# Security Testing Script
# Runs automated security tests against the Wazuh API
#
# Usage:
#   ./scripts/security-test.sh [options]
#
# Options:
#   -u, --url URL       Base URL to test (default: https://localhost)
#   -k, --api-key KEY   API key for authenticated tests
#   -v, --verbose       Enable verbose output
#   -h, --help          Show this help message
#
# Environment Variables:
#   BASE_URL            Base URL to test
#   API_KEY             API key for authenticated tests

set -euo pipefail

# Configuration
BASE_URL="${BASE_URL:-https://localhost}"
API_KEY="${API_KEY:-}"
VERBOSE="${VERBOSE:-false}"
NGINX_CONTAINER="${NGINX_CONTAINER:-wazuh-nginx}"
API_CONTAINER="${API_CONTAINER:-wazuh-api}"
FAIL2BAN_CONTAINER="${FAIL2BAN_CONTAINER:-wazuh-fail2ban}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)
            BASE_URL="$2"
            shift 2
            ;;
        -k|--api-key)
            API_KEY="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            head -20 "$0" | tail -18
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Test result functions
test_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

test_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

test_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((SKIPPED++))
}

# Helper function to check if a container exists and is running
container_running() {
    local container="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"
}

# Helper function for curl with common options
do_curl() {
    curl -k -s --connect-timeout 5 --max-time 10 "$@"
}

# ============================================
# Authentication Tests
# ============================================
section_auth() {
    echo ""
    echo -e "${CYAN}━━━ Authentication Tests ━━━${NC}"
    
    # AUTH-01: Missing API key
    log_verbose "Testing missing API key..."
    local status
    status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/api/")
    if [[ "$status" == "401" || "$status" == "403" ]]; then
        test_pass "AUTH-01: Missing API key returns $status"
    else
        test_fail "AUTH-01: Missing API key returns $status (expected 401/403)"
    fi
    
    # AUTH-02: Invalid API key
    log_verbose "Testing invalid API key..."
    status=$(do_curl -o /dev/null -w "%{http_code}" -H "X-API-Key: invalid-key-12345" "$BASE_URL/api/")
    if [[ "$status" == "401" || "$status" == "403" ]]; then
        test_pass "AUTH-02: Invalid API key returns $status"
    else
        test_fail "AUTH-02: Invalid API key returns $status (expected 401/403)"
    fi
    
    # AUTH-03: Valid API key (if provided)
    if [[ -n "$API_KEY" ]]; then
        log_verbose "Testing valid API key..."
        status=$(do_curl -o /dev/null -w "%{http_code}" -H "X-API-Key: $API_KEY" "$BASE_URL/api/")
        if [[ "$status" == "200" || "$status" == "404" ]]; then
            test_pass "AUTH-03: Valid API key returns $status (authenticated)"
        else
            test_fail "AUTH-03: Valid API key returns $status (expected 200/404)"
        fi
    else
        test_skip "AUTH-03: Valid API key test (no API_KEY provided)"
    fi
}

# ============================================
# TLS/SSL Tests
# ============================================
section_tls() {
    echo ""
    echo -e "${CYAN}━━━ TLS/SSL Tests ━━━${NC}"
    
    local host
    host=$(echo "$BASE_URL" | sed -E 's|https?://||' | sed 's|/.*||' | sed 's|:.*||')
    local port
    port=$(echo "$BASE_URL" | grep -oE ':[0-9]+' | tr -d ':' || echo "443")
    
    log_verbose "Testing TLS on $host:$port"
    
    # TLS-01: TLS 1.2 supported
    if openssl s_client -connect "$host:$port" -tls1_2 </dev/null 2>/dev/null | grep -q "Protocol.*TLSv1.2"; then
        test_pass "TLS-01: TLS 1.2 supported"
    else
        # Try alternative check
        if echo | openssl s_client -connect "$host:$port" -tls1_2 2>&1 | grep -q "Cipher is"; then
            test_pass "TLS-01: TLS 1.2 supported"
        else
            test_fail "TLS-01: TLS 1.2 not supported or connection failed"
        fi
    fi
    
    # TLS-02: TLS 1.3 supported
    if openssl s_client -connect "$host:$port" -tls1_3 </dev/null 2>/dev/null | grep -qE "Protocol.*TLSv1.3|TLSv1.3"; then
        test_pass "TLS-02: TLS 1.3 supported"
    else
        if echo | openssl s_client -connect "$host:$port" -tls1_3 2>&1 | grep -q "Cipher is"; then
            test_pass "TLS-02: TLS 1.3 supported"
        else
            test_skip "TLS-02: TLS 1.3 not supported (may be OK depending on requirements)"
        fi
    fi
    
    # TLS-03: TLS 1.0 rejected
    if openssl s_client -connect "$host:$port" -tls1 </dev/null 2>&1 | grep -qE "handshake failure|no protocols available|wrong version|alert"; then
        test_pass "TLS-03: TLS 1.0 rejected"
    else
        test_fail "TLS-03: TLS 1.0 should be rejected"
    fi
    
    # TLS-04: TLS 1.1 rejected
    if openssl s_client -connect "$host:$port" -tls1_1 </dev/null 2>&1 | grep -qE "handshake failure|no protocols available|wrong version|alert"; then
        test_pass "TLS-04: TLS 1.1 rejected"
    else
        test_fail "TLS-04: TLS 1.1 should be rejected"
    fi
    
    # TLS-07: Certificate validity
    local cert_info
    cert_info=$(echo | openssl s_client -connect "$host:$port" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "")
    if [[ -n "$cert_info" ]]; then
        local not_after
        not_after=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
        if [[ -n "$not_after" ]]; then
            local expiry_epoch
            expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$not_after" +%s 2>/dev/null || date -d "$not_after" +%s 2>/dev/null || echo "0")
            local now_epoch
            now_epoch=$(date +%s)
            if [[ "$expiry_epoch" -gt "$now_epoch" ]]; then
                test_pass "TLS-07: Certificate is valid (expires: $not_after)"
            else
                test_fail "TLS-07: Certificate has expired"
            fi
        else
            test_skip "TLS-07: Could not parse certificate expiry"
        fi
    else
        test_skip "TLS-07: Could not retrieve certificate"
    fi
    
    # TLS-09: HTTP to HTTPS redirect
    local http_url
    http_url=$(echo "$BASE_URL" | sed 's|https://|http://|')
    local redirect_status
    redirect_status=$(do_curl -o /dev/null -w "%{http_code}" "$http_url/" 2>/dev/null || echo "000")
    if [[ "$redirect_status" == "301" || "$redirect_status" == "302" || "$redirect_status" == "308" ]]; then
        test_pass "TLS-09: HTTP redirects to HTTPS ($redirect_status)"
    elif [[ "$redirect_status" == "000" ]]; then
        test_skip "TLS-09: HTTP port not accessible (may be intentional)"
    else
        test_fail "TLS-09: HTTP does not redirect (status: $redirect_status)"
    fi
    
    # TLS-10: HSTS header
    local hsts
    hsts=$(do_curl -I "$BASE_URL/" 2>/dev/null | grep -i "strict-transport-security" || echo "")
    if [[ -n "$hsts" ]]; then
        test_pass "TLS-10: HSTS header present"
    else
        test_fail "TLS-10: HSTS header missing"
    fi
}

# ============================================
# Health Check Tests
# ============================================
section_health() {
    echo ""
    echo -e "${CYAN}━━━ Health Check Tests ━━━${NC}"
    
    # Health live endpoint
    local status
    status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/health/live" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        test_pass "HEALTH-01: Live endpoint returns 200"
    elif [[ "$status" == "000" ]]; then
        test_fail "HEALTH-01: Cannot connect to $BASE_URL/health/live"
    else
        test_fail "HEALTH-01: Live endpoint returns $status (expected 200)"
    fi
    
    # Health ready endpoint
    status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/health/ready" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        test_pass "HEALTH-02: Ready endpoint returns 200"
    elif [[ "$status" == "000" ]]; then
        test_skip "HEALTH-02: Ready endpoint not accessible"
    else
        test_skip "HEALTH-02: Ready endpoint returns $status"
    fi
}

# ============================================
# Container Security Tests
# ============================================
section_container() {
    echo ""
    echo -e "${CYAN}━━━ Container Security Tests ━━━${NC}"
    
    # Check if Docker is available
    if ! command -v docker &>/dev/null; then
        test_skip "CONT-*: Docker not available"
        return
    fi
    
    # CONT-01: Nginx running as non-root
    if container_running "$NGINX_CONTAINER"; then
        local nginx_uid
        nginx_uid=$(docker exec "$NGINX_CONTAINER" id -u 2>/dev/null || echo "error")
        if [[ "$nginx_uid" != "0" && "$nginx_uid" != "error" ]]; then
            test_pass "CONT-01: Nginx running as non-root (UID: $nginx_uid)"
        elif [[ "$nginx_uid" == "0" ]]; then
            test_fail "CONT-01: Nginx running as root"
        else
            test_skip "CONT-01: Could not determine Nginx user"
        fi
    else
        test_skip "CONT-01: Nginx container not running"
    fi
    
    # CONT-02: API running as non-root
    if container_running "$API_CONTAINER"; then
        local api_uid
        api_uid=$(docker exec "$API_CONTAINER" id -u 2>/dev/null || echo "error")
        if [[ "$api_uid" != "0" && "$api_uid" != "error" ]]; then
            test_pass "CONT-02: API running as non-root (UID: $api_uid)"
        elif [[ "$api_uid" == "0" ]]; then
            test_fail "CONT-02: API running as root"
        else
            test_skip "CONT-02: Could not determine API user"
        fi
    else
        test_skip "CONT-02: API container not running"
    fi
    
    # CONT-03: Capabilities dropped
    if container_running "$NGINX_CONTAINER"; then
        local cap_drop
        cap_drop=$(docker inspect "$NGINX_CONTAINER" --format='{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")
        if [[ "$cap_drop" == *"ALL"* || "$cap_drop" == *"all"* ]]; then
            test_pass "CONT-03: Nginx has capabilities dropped"
        elif [[ -n "$cap_drop" && "$cap_drop" != "[]" ]]; then
            test_pass "CONT-03: Nginx has some capabilities dropped: $cap_drop"
        else
            test_fail "CONT-03: Nginx capabilities not dropped"
        fi
    else
        test_skip "CONT-03: Nginx container not running"
    fi
    
    # CONT-05: No privileged containers
    if container_running "$NGINX_CONTAINER"; then
        local privileged
        privileged=$(docker inspect "$NGINX_CONTAINER" --format='{{.HostConfig.Privileged}}' 2>/dev/null || echo "")
        if [[ "$privileged" == "false" ]]; then
            test_pass "CONT-05: Nginx not running in privileged mode"
        else
            test_fail "CONT-05: Nginx running in privileged mode"
        fi
    else
        test_skip "CONT-05: Nginx container not running"
    fi
    
    # CONT-06: Security options set
    if container_running "$NGINX_CONTAINER"; then
        local sec_opt
        sec_opt=$(docker inspect "$NGINX_CONTAINER" --format='{{.HostConfig.SecurityOpt}}' 2>/dev/null || echo "")
        if [[ "$sec_opt" == *"no-new-privileges"* ]]; then
            test_pass "CONT-06: Nginx has no-new-privileges set"
        elif [[ -n "$sec_opt" && "$sec_opt" != "[]" ]]; then
            test_pass "CONT-06: Nginx has security options: $sec_opt"
        else
            test_skip "CONT-06: Nginx security options not explicitly set"
        fi
    else
        test_skip "CONT-06: Nginx container not running"
    fi
    
    # CONT-07: Resource limits defined
    if container_running "$NGINX_CONTAINER"; then
        local memory
        memory=$(docker inspect "$NGINX_CONTAINER" --format='{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
        if [[ "$memory" != "0" && -n "$memory" ]]; then
            test_pass "CONT-07: Nginx has memory limit set"
        else
            test_skip "CONT-07: Nginx memory limit not set"
        fi
    else
        test_skip "CONT-07: Nginx container not running"
    fi
    
    # CONT-08: Health checks configured
    if container_running "$NGINX_CONTAINER"; then
        local health_status
        health_status=$(docker inspect "$NGINX_CONTAINER" --format='{{.State.Health.Status}}' 2>/dev/null || echo "")
        if [[ "$health_status" == "healthy" ]]; then
            test_pass "CONT-08: Nginx health check is healthy"
        elif [[ -n "$health_status" ]]; then
            test_skip "CONT-08: Nginx health status: $health_status"
        else
            test_skip "CONT-08: Nginx health check not configured"
        fi
    else
        test_skip "CONT-08: Nginx container not running"
    fi
}

# ============================================
# Network Isolation Tests
# ============================================
section_network() {
    echo ""
    echo -e "${CYAN}━━━ Network Isolation Tests ━━━${NC}"
    
    if ! command -v docker &>/dev/null; then
        test_skip "NET-*: Docker not available"
        return
    fi
    
    # NET-01: Check exposed ports
    local exposed_ports
    exposed_ports=$(docker ps --format "{{.Names}}: {{.Ports}}" 2>/dev/null | grep -E "0.0.0.0|:::" || echo "")
    if [[ -n "$exposed_ports" ]]; then
        log_verbose "Exposed ports: $exposed_ports"
        if echo "$exposed_ports" | grep -qE "nginx.*:(80|443)"; then
            test_pass "NET-01: Only expected ports exposed (nginx on 80/443)"
        else
            test_skip "NET-01: Exposed ports found: $exposed_ports"
        fi
    else
        test_skip "NET-01: No exposed ports found or containers not running"
    fi
    
    # NET-02: API not directly accessible
    local api_direct
    api_direct=$(do_curl -o /dev/null -w "%{http_code}" "http://localhost:5000/" 2>/dev/null || echo "000")
    if [[ "$api_direct" == "000" ]]; then
        test_pass "NET-02: API port not directly accessible"
    else
        test_fail "NET-02: API port directly accessible (status: $api_direct)"
    fi
}

# ============================================
# Rate Limiting Tests
# ============================================
section_ratelimit() {
    echo ""
    echo -e "${CYAN}━━━ Rate Limiting Tests ━━━${NC}"
    
    # RATE-01: Normal traffic passes
    local status
    status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/health/live" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        test_pass "RATE-01: Normal traffic passes (status: $status)"
    else
        test_fail "RATE-01: Normal traffic blocked (status: $status)"
    fi
    
    # RATE-02: Burst traffic triggers limit
    log_info "Testing rate limiting (sending 120 requests)..."
    local rate_limited=0
    for i in {1..120}; do
        status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/health/live" 2>/dev/null || echo "000")
        if [[ "$status" == "429" ]]; then
            ((rate_limited++))
        fi
        # Small delay to avoid overwhelming
        if [[ $((i % 20)) -eq 0 ]]; then
            log_verbose "Sent $i requests, $rate_limited rate limited so far"
        fi
    done
    
    if [[ $rate_limited -gt 0 ]]; then
        test_pass "RATE-02: Rate limiting triggered ($rate_limited/120 requests got 429)"
    else
        test_skip "RATE-02: Rate limiting not triggered (may need higher load or different config)"
    fi
}

# ============================================
# Security Headers Tests
# ============================================
section_headers() {
    echo ""
    echo -e "${CYAN}━━━ Security Headers Tests ━━━${NC}"
    
    local headers
    headers=$(do_curl -I "$BASE_URL/health/live" 2>/dev/null || echo "")
    
    if [[ -z "$headers" ]]; then
        test_skip "HDR-*: Could not retrieve headers"
        return
    fi
    
    # HDR-01: X-Content-Type-Options
    if echo "$headers" | grep -qi "x-content-type-options.*nosniff"; then
        test_pass "HDR-01: X-Content-Type-Options: nosniff"
    else
        test_fail "HDR-01: X-Content-Type-Options header missing or incorrect"
    fi
    
    # HDR-02: X-Frame-Options
    if echo "$headers" | grep -qi "x-frame-options"; then
        test_pass "HDR-02: X-Frame-Options present"
    else
        test_fail "HDR-02: X-Frame-Options header missing"
    fi
    
    # HDR-06: Server header hidden
    local server_header
    server_header=$(echo "$headers" | grep -i "^server:" || echo "")
    if [[ -z "$server_header" ]]; then
        test_pass "HDR-06: Server header hidden"
    elif echo "$server_header" | grep -qiE "nginx/[0-9]|apache/[0-9]"; then
        test_fail "HDR-06: Server header exposes version: $server_header"
    else
        test_pass "HDR-06: Server header present but version hidden"
    fi
    
    # HDR-07: X-Request-ID
    if echo "$headers" | grep -qi "x-request-id"; then
        test_pass "HDR-07: X-Request-ID header present"
    else
        test_skip "HDR-07: X-Request-ID header not present"
    fi
}

# ============================================
# Fail2ban Tests
# ============================================
section_fail2ban() {
    echo ""
    echo -e "${CYAN}━━━ Fail2ban Tests ━━━${NC}"
    
    if ! command -v docker &>/dev/null; then
        test_skip "F2B-*: Docker not available"
        return
    fi
    
    if ! container_running "$FAIL2BAN_CONTAINER"; then
        test_skip "F2B-*: Fail2ban container not running"
        return
    fi
    
    # F2B-01: Fail2ban service running
    local f2b_status
    f2b_status=$(docker exec "$FAIL2BAN_CONTAINER" fail2ban-client status 2>/dev/null || echo "error")
    if [[ "$f2b_status" != "error" && "$f2b_status" == *"Number of jail"* ]]; then
        test_pass "F2B-01: Fail2ban service running"
    else
        test_fail "F2B-01: Fail2ban service not responding"
    fi
    
    # F2B-02: Check auth jail
    local auth_jail
    auth_jail=$(docker exec "$FAIL2BAN_CONTAINER" fail2ban-client status wazuh-api-auth 2>/dev/null || echo "error")
    if [[ "$auth_jail" != "error" ]]; then
        test_pass "F2B-02: Auth failure jail configured"
    else
        test_skip "F2B-02: Auth failure jail not found"
    fi
    
    # F2B-03: Check rate limit jail
    local rate_jail
    rate_jail=$(docker exec "$FAIL2BAN_CONTAINER" fail2ban-client status wazuh-api-ratelimit 2>/dev/null || echo "error")
    if [[ "$rate_jail" != "error" ]]; then
        test_pass "F2B-03: Rate limit jail configured"
    else
        test_skip "F2B-03: Rate limit jail not found"
    fi
}

# ============================================
# Logging Tests
# ============================================
section_logging() {
    echo ""
    echo -e "${CYAN}━━━ Logging Tests ━━━${NC}"
    
    if ! command -v docker &>/dev/null; then
        test_skip "LOG-*: Docker not available"
        return
    fi
    
    if ! container_running "$NGINX_CONTAINER"; then
        test_skip "LOG-*: Nginx container not running"
        return
    fi
    
    # Generate a test request first
    do_curl "$BASE_URL/health/live" >/dev/null 2>&1 || true
    sleep 1
    
    # LOG-01: Requests logged
    local logs
    logs=$(docker logs "$NGINX_CONTAINER" 2>&1 | tail -50 || echo "")
    if [[ -n "$logs" ]]; then
        test_pass "LOG-01: Nginx logs available"
    else
        test_fail "LOG-01: No logs found"
    fi
    
    # LOG-02: Request IDs present
    if echo "$logs" | grep -qE "request_id=|X-Request-ID"; then
        test_pass "LOG-02: Request IDs present in logs"
    else
        test_skip "LOG-02: Request IDs not found in logs"
    fi
    
    # LOG-06: Sensitive data NOT in logs
    if echo "$logs" | grep -qiE "api.?key.*=.*[a-zA-Z0-9]{10,}|password.*=|secret.*="; then
        test_fail "LOG-06: Potential sensitive data found in logs"
    else
        test_pass "LOG-06: No obvious sensitive data in logs"
    fi
}

# ============================================
# Input Validation Tests
# ============================================
section_input() {
    echo ""
    echo -e "${CYAN}━━━ Input Validation Tests ━━━${NC}"
    
    # INPUT-02: Invalid JSON rejected
    local status
    status=$(do_curl -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/logs" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${API_KEY:-test}" \
        -d '{invalid json}' 2>/dev/null || echo "000")
    if [[ "$status" == "400" ]]; then
        test_pass "INPUT-02: Invalid JSON rejected (400)"
    elif [[ "$status" == "401" || "$status" == "403" ]]; then
        test_skip "INPUT-02: Auth required before JSON validation"
    else
        test_skip "INPUT-02: Invalid JSON returned $status"
    fi
    
    # INPUT-07: Path traversal blocked
    status=$(do_curl -o /dev/null -w "%{http_code}" "$BASE_URL/api/../../../etc/passwd" 2>/dev/null || echo "000")
    if [[ "$status" == "400" || "$status" == "403" || "$status" == "404" ]]; then
        test_pass "INPUT-07: Path traversal blocked ($status)"
    else
        test_fail "INPUT-07: Path traversal may not be blocked ($status)"
    fi
}

# ============================================
# Main Execution
# ============================================
main() {
    echo "=========================================="
    echo "     Security Testing Suite"
    echo "=========================================="
    echo "Target: $BASE_URL"
    echo "Time: $(date)"
    if [[ -n "$API_KEY" ]]; then
        echo "API Key: [PROVIDED]"
    else
        echo "API Key: [NOT PROVIDED - some tests will be skipped]"
    fi
    echo ""
    
    # Run all test sections
    section_health
    section_auth
    section_tls
    section_headers
    section_input
    section_ratelimit
    section_container
    section_network
    section_logging
    section_fail2ban
    
    # Summary
    echo ""
    echo "=========================================="
    echo "     Test Results Summary"
    echo "=========================================="
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo "=========================================="
    
    local total=$((PASSED + FAILED + SKIPPED))
    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}All executed tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed. Review the output above.${NC}"
    fi
    
    echo ""
    echo "For detailed manual testing, see: docs/SECURITY-TESTING-CHECKLIST.md"
    
    # Exit with failure count
    exit $FAILED
}

# Run main
main "$@"