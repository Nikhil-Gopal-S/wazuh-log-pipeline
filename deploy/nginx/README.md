# Nginx Reverse Proxy Configuration

This directory contains the Nginx configuration for the Wazuh Log Ingestion API reverse proxy.

## Directory Structure

```
deploy/nginx/
├── nginx.conf              # Main Nginx configuration
├── Dockerfile              # Nginx container build file
├── README.md               # This documentation
├── certs/                  # SSL/TLS certificates
│   └── .gitignore          # Excludes certificates from version control
└── conf.d/                 # Additional configuration files
    ├── default.conf        # Server block configuration
    ├── ssl.conf            # SSL/TLS settings
    ├── ip-whitelist.conf   # IP whitelist for rate limit bypass
    └── rate-limiting.conf  # Rate limiting configuration
```

## Configuration Files

### Main Configuration (`nginx.conf`)

The main configuration file includes:
- Worker process settings
- Security headers (X-Frame-Options, X-Content-Type-Options, etc.)
- Timeout settings to prevent slow HTTP attacks
- Buffer size limits
- Gzip compression
- Upstream server definition
- Include directives for modular configuration

### IP Whitelist (`conf.d/ip-whitelist.conf`)

Controls which IP addresses bypass rate limiting. Uses Nginx's `geo` and `map` modules.

**How it works:**
1. The `geo` block checks if the client IP is in the whitelist
2. The `map` block converts the whitelist status to a rate limit key
3. Whitelisted IPs get an empty key (bypasses rate limit)
4. Non-whitelisted IPs use their IP address as the key (subject to rate limit)

**Default Whitelisted Networks:**
- `127.0.0.1` / `::1` - Localhost
- `10.0.0.0/8` - Private network (Class A)
- `172.16.0.0/12` - Private network (Class B)
- `192.168.0.0/16` - Private network (Class C)
- `172.17.0.0/16` - `172.20.0.0/16` - Docker networks

### Rate Limiting (`conf.d/rate-limiting.conf`)

Protects the API from abuse and DoS attacks.

**Configuration:**
- Zone: `api_limit` (10MB shared memory)
- Rate: 100 requests per second per IP
- Status code: 429 (Too Many Requests)
- Log level: warn

**Note:** Rate limiting uses `$limit_key` from `ip-whitelist.conf`, allowing whitelisted IPs to bypass the limit.

### SSL/TLS (`conf.d/ssl.conf`)

Contains SSL/TLS protocol and cipher configuration. Certificates should be placed in the `certs/` directory.

## IP Whitelist Management

### Using the Management Script

A helper script is provided at `scripts/update-whitelist.sh` for managing the IP whitelist.

#### Add an IP Address

```bash
# Add a single IP
./scripts/update-whitelist.sh add 203.0.113.50 "Partner API server"

# Add a CIDR range
./scripts/update-whitelist.sh add 198.51.100.0/24 "Office network"
```

#### Remove an IP Address

```bash
./scripts/update-whitelist.sh remove 203.0.113.50
```

#### List Whitelisted IPs

```bash
./scripts/update-whitelist.sh list
```

#### Validate Configuration

```bash
./scripts/update-whitelist.sh validate
```

### Manual Configuration

To manually add trusted IPs, edit `conf.d/ip-whitelist.conf`:

1. Find the section marked `# === ADD TRUSTED EXTERNAL IPs BELOW THIS LINE ===`
2. Add entries in the format: `<IP> 1;  # <Description>`
3. Save the file
4. Reload Nginx

**Example:**
```nginx
# === ADD TRUSTED EXTERNAL IPs BELOW THIS LINE ===
    203.0.113.50 1;        # Partner API server - Added 2024-01-15 by admin
    198.51.100.0/24 1;     # Office network - Added 2024-01-15 by admin
# === END TRUSTED EXTERNAL IPs ===
```

### Applying Changes

After modifying the whitelist, reload Nginx for changes to take effect:

```bash
# If using Docker Compose
docker-compose exec nginx nginx -s reload

# Or directly with Docker
docker exec nginx-proxy nginx -s reload

# Or restart the container
docker-compose restart nginx
```

## Security Considerations

### Rate Limiting

- Default rate: 100 requests/second per IP
- Adjust in `rate-limiting.conf` based on expected traffic
- Monitor logs for rate-limited requests (`limit_req_log_level warn`)

### IP Whitelisting

- Only whitelist IPs that you trust completely
- Document the purpose of each whitelisted IP
- Regularly audit the whitelist
- Use CIDR notation for ranges instead of individual IPs when possible
- Private networks (RFC 1918) are whitelisted by default for internal services

### SSL/TLS

- Use strong ciphers (configured in `ssl.conf`)
- Keep certificates up to date
- Store certificates securely (excluded from version control)

## Troubleshooting

### Check Nginx Configuration

```bash
# Test configuration syntax
docker exec nginx-proxy nginx -t

# View current configuration
docker exec nginx-proxy nginx -T
```

### View Logs

```bash
# Access logs
docker logs nginx-proxy

# Error logs
docker exec nginx-proxy tail -f /var/log/nginx/error.log

# Rate limit violations (look for "limiting requests")
docker exec nginx-proxy grep "limiting requests" /var/log/nginx/error.log
```

### Common Issues

1. **Rate limit not working for whitelisted IPs**
   - Verify the IP is correctly added to `ip-whitelist.conf`
   - Check that `ip-whitelist.conf` is loaded before `rate-limiting.conf`
   - Reload Nginx after changes

2. **Configuration syntax errors**
   - Run `nginx -t` to check syntax
   - Ensure all geo block entries end with `;`
   - Verify CIDR notation is valid

3. **Changes not taking effect**
   - Reload Nginx: `nginx -s reload`
   - Check for typos in IP addresses
   - Verify file permissions

## Load Order

Configuration files are loaded in a specific order (defined in `nginx.conf`):

1. `ssl.conf` - SSL/TLS settings (no dependencies)
2. `ip-whitelist.conf` - Defines `$whitelist` and `$limit_key` variables
3. `rate-limiting.conf` - Uses `$limit_key` from ip-whitelist.conf
4. `default.conf` - Server blocks that use rate limit zones

**Important:** Do not change this order as it will break variable dependencies.