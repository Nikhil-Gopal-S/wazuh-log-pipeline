# Secrets Directory

## Purpose

This directory stores sensitive credentials and API keys used by the Wazuh Log Pipeline application. Secrets stored here are read by the application at runtime, providing a more secure alternative to environment variables.

**Important:** This directory is designed to keep secrets out of version control while providing a structured way to manage them.

## Creating Secrets

### Automated Setup (Recommended)

Run the initialization script to automatically generate all required secrets:

```bash
./scripts/init-secrets.sh
```

This script will:
- Create the secrets directory if it doesn't exist
- Generate a secure API key (64 hex characters)
- Set proper file permissions (600 - owner read/write only)
- Skip generation if secrets already exist (idempotent)

### Manual Setup

1. Copy the example file to create your secret:
   ```bash
   cp secrets/api_key.txt.example secrets/api_key.txt
   ```

2. Generate a secure API key:
   ```bash
   openssl rand -hex 32 > secrets/api_key.txt
   ```

3. Set proper file permissions:
   ```bash
   chmod 600 secrets/api_key.txt
   ```

## File Naming Conventions

| File | Purpose | Format |
|------|---------|--------|
| `api_key.txt` | API authentication key | 64 hex characters (32 bytes) |
| `*.example` | Template files (safe to commit) | Placeholder values |

## Security Warnings

⚠️ **CRITICAL SECURITY GUIDELINES:**

1. **NEVER commit actual secret files to version control**
   - Only `.gitignore`, `README.md`, and `*.example` files should be committed
   - The `.gitignore` in this directory is configured to prevent accidental commits

2. **Set restrictive file permissions**
   - All secret files should have `600` permissions (owner read/write only)
   - Run: `chmod 600 secrets/*.txt`

3. **Rotate secrets regularly**
   - Regenerate API keys periodically
   - Update all dependent services when rotating

4. **Secure backup procedures**
   - If backing up secrets, ensure backups are encrypted
   - Never transmit secrets over unencrypted channels

5. **Access control**
   - Limit access to the secrets directory to authorized personnel only
   - Use appropriate filesystem ACLs in production environments

## Usage

### Initial Setup

```bash
# Make the init script executable (if not already)
chmod +x scripts/init-secrets.sh

# Run the initialization script
./scripts/init-secrets.sh
```

### Verifying Setup

```bash
# Check that secrets exist with proper permissions
ls -la secrets/

# Expected output should show:
# -rw------- api_key.txt (600 permissions)
```

### Reading Secrets in Application

The application reads secrets from this directory at startup. Ensure the secrets are created before starting the application.

## Troubleshooting

### Permission Denied Errors

If you encounter permission issues:
```bash
chmod 600 secrets/api_key.txt
```

### Missing Secrets

If the application reports missing secrets:
```bash
./scripts/init-secrets.sh
```

### Regenerating Secrets

To regenerate a secret (e.g., after a security incident):
```bash
# Remove the existing secret
rm secrets/api_key.txt

# Regenerate
./scripts/init-secrets.sh
```

## Integration with Docker

When running in Docker, secrets can be mounted as volumes:

```yaml
volumes:
  - ./secrets:/app/secrets:ro
```

The `:ro` flag mounts the secrets as read-only inside the container for additional security.