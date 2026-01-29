# Certificate Management

## Overview

This document describes TLS certificate management for the Wazuh API Gateway. It covers certificate generation, rotation, backup, and best practices for maintaining secure HTTPS connections.

## Certificate Files

### Locations

| File | Path | Description |
|------|------|-------------|
| Certificate | `deploy/nginx/certs/server.crt` | TLS certificate (public) |
| Private Key | `deploy/nginx/certs/server.key` | TLS private key (keep secure) |
| Backups | `deploy/nginx/certs/backup/` | Timestamped certificate backups |

### File Permissions

```bash
# Certificate (readable by nginx)
chmod 644 deploy/nginx/certs/server.crt

# Private key (restricted access)
chmod 600 deploy/nginx/certs/server.key
```

## Certificate Generation

### Initial Certificate Generation

Use the [`generate-certs.sh`](../scripts/generate-certs.sh) script for initial certificate creation:

```bash
./scripts/generate-certs.sh
```

This creates a self-signed certificate valid for 365 days.

### Manual Generation

For custom certificates, use OpenSSL directly:

```bash
# Generate self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout deploy/nginx/certs/server.key \
    -out deploy/nginx/certs/server.crt \
    -subj "/CN=api.example.com/O=Wazuh API/C=US" \
    -addext "subjectAltName=DNS:api.example.com,DNS:localhost,IP:127.0.0.1"
```

## Certificate Rotation Script

### Location

[`scripts/rotate-certs.sh`](../scripts/rotate-certs.sh)

### Usage

```bash
./scripts/rotate-certs.sh [options]
```

### Options

| Option | Description |
|--------|-------------|
| `-t, --type` | Certificate type: `self-signed` (default) or `letsencrypt` |
| `-d, --domain` | Domain name (default: `localhost`) |
| `-e, --email` | Email for Let's Encrypt registration |
| `-c, --check` | Check certificate expiration only (no rotation) |
| `-f, --force` | Force rotation even if certificate is not expiring |
| `-h, --help` | Show help message |

### Examples

#### Check Certificate Expiration

```bash
# Check if certificate needs rotation
./scripts/rotate-certs.sh -c
```

Output:
```
[INFO] Certificate expiration: Mar 15 12:00:00 2025 GMT
[INFO] Days remaining: 45
[INFO] Certificate is valid for 45 more days
```

#### Rotate Self-Signed Certificate

```bash
# Rotate with default settings (localhost)
./scripts/rotate-certs.sh -f

# Rotate for specific domain
./scripts/rotate-certs.sh -t self-signed -d api.example.com -f
```

#### Rotate with Let's Encrypt

```bash
# Obtain Let's Encrypt certificate
./scripts/rotate-certs.sh -t letsencrypt -d api.example.com -e admin@example.com
```

**Note:** Let's Encrypt requires:
- Port 80 to be accessible from the internet
- Valid DNS pointing to your server
- A real domain name (not localhost)

### Rotation Process

The script performs these steps:

1. **Check Expiration** - Determines if rotation is needed (< 30 days remaining)
2. **Backup** - Creates timestamped backup of current certificates
3. **Generate** - Creates new certificate (self-signed or Let's Encrypt)
4. **Validate** - Verifies certificate and key match
5. **Reload** - Reloads nginx to apply new certificate
6. **Test** - Tests HTTPS connection
7. **Cleanup** - Removes old backups (keeps last 5)

### Rollback

If validation fails, the script automatically rolls back to the previous certificate:

```bash
[ERROR] Certificate and key do not match
[ERROR] Rolling back to previous certificates...
[INFO] Rollback completed
```

## Automated Rotation

### Using Cron

Add to crontab for automatic monthly rotation:

```bash
# Edit crontab
crontab -e

# Add monthly rotation (1st of each month at midnight)
0 0 1 * * /path/to/wazuh-log-pipeline/scripts/rotate-certs.sh -f >> /var/log/cert-rotation.log 2>&1
```

### Using Systemd Timer

Create a systemd timer for more control:

**`/etc/systemd/system/cert-rotation.service`**
```ini
[Unit]
Description=TLS Certificate Rotation
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=/path/to/wazuh-log-pipeline
ExecStart=/path/to/wazuh-log-pipeline/scripts/rotate-certs.sh -f
User=root

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/cert-rotation.timer`**
```ini
[Unit]
Description=Monthly Certificate Rotation

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable the timer:
```bash
sudo systemctl daemon-reload
sudo systemctl enable cert-rotation.timer
sudo systemctl start cert-rotation.timer
```

## Certificate Monitoring

### Check Expiration Manually

```bash
# Using the rotation script
./scripts/rotate-certs.sh -c

# Using OpenSSL directly
openssl x509 -enddate -noout -in deploy/nginx/certs/server.crt
```

### Monitoring with Prometheus

If using Prometheus, add certificate expiration monitoring:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'ssl_expiry'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - https://localhost/health/live
```

### Alert on Expiration

Set up alerts when certificates are expiring soon:

```yaml
# alertmanager rules
groups:
  - name: ssl
    rules:
      - alert: SSLCertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 86400 * 30
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "SSL certificate expiring soon"
          description: "Certificate expires in less than 30 days"
```

## Best Practices

### Security

1. **Protect Private Keys**
   - Never commit private keys to version control
   - Use restrictive file permissions (600)
   - Store backups securely

2. **Use Strong Key Sizes**
   - Minimum 2048-bit RSA keys
   - Consider 4096-bit for higher security
   - ECDSA P-256 or P-384 for better performance

3. **Regular Rotation**
   - Rotate certificates at least annually
   - Use shorter validity periods for higher security
   - Automate rotation to prevent expiration

### Operations

1. **Test Before Production**
   - Validate certificates before deployment
   - Test HTTPS connections after rotation
   - Have rollback procedures ready

2. **Monitor Expiration**
   - Set up alerts for expiring certificates
   - Check expiration regularly
   - Plan rotation before expiration

3. **Backup Strategy**
   - Keep multiple backup copies
   - Store backups in secure location
   - Test restore procedures

## Troubleshooting

### Certificate and Key Mismatch

```bash
# Check if certificate and key match
openssl x509 -noout -modulus -in server.crt | md5sum
openssl rsa -noout -modulus -in server.key | md5sum
# Both should output the same hash
```

### Nginx Won't Start

```bash
# Test nginx configuration
docker exec wazuh-nginx nginx -t

# Check certificate validity
openssl x509 -noout -text -in deploy/nginx/certs/server.crt
```

### Let's Encrypt Issues

```bash
# Check certbot logs
docker logs certbot

# Verify domain DNS
dig +short api.example.com

# Test HTTP challenge
curl -v http://api.example.com/.well-known/acme-challenge/test
```

### Permission Denied

```bash
# Fix certificate permissions
chmod 644 deploy/nginx/certs/server.crt
chmod 600 deploy/nginx/certs/server.key

# Fix ownership (if needed)
chown root:root deploy/nginx/certs/server.*
```

## Related Documentation

- [Nginx Reverse Proxy Configuration](../plans/nginx-reverse-proxy-configuration.md)
- [Internal Encryption (mTLS)](../plans/internal-encryption-mtls-configuration.md)
- [Security Implementation Master Plan](../plans/SECURITY-IMPLEMENTATION-MASTER-PLAN.md)