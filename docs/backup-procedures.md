# Backup and Restore Procedures

## Overview

This document describes backup and restore procedures for the Wazuh API configuration. Regular backups are essential for disaster recovery and maintaining business continuity.

## Backup Script

**Location:** `scripts/backup.sh`

### Features

- **Encrypted backups** - Sensitive files (secrets, certificates) are encrypted using AES-256-CBC
- **Configurable retention** - Automatically removes old backups based on retention policy
- **Verification** - Optional integrity verification after backup creation
- **Manifest generation** - Creates a detailed manifest with restore instructions

### Usage

```bash
./scripts/backup.sh [options]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --password` | Encryption password | Interactive prompt |
| `-o, --output` | Output directory | `./backups` |
| `-r, --retention` | Number of backups to keep | 7 |
| `-v, --verify` | Verify backup after creation | false |
| `-h, --help` | Show help message | - |

### Examples

```bash
# Interactive mode (prompts for password)
./scripts/backup.sh

# With password and verification
./scripts/backup.sh -p "your-secure-password" -v

# Custom output directory and retention
./scripts/backup.sh -p "$BACKUP_PASSWORD" -o /mnt/backups -r 14

# Using environment variable for password
export BACKUP_PASSWORD="your-secure-password"
./scripts/backup.sh -v
```

## What Gets Backed Up

### Configuration Files (Unencrypted)

| File/Directory | Description |
|----------------|-------------|
| `docker-compose.yml` | Docker Compose configuration |
| `Dockerfile` | Main Dockerfile |
| `Dockerfile.agent` | Agent Dockerfile |
| `.dockerignore` | Docker ignore patterns |
| `deploy/nginx/` | Nginx configuration |
| `deploy/fail2ban/` | Fail2ban configuration |
| `api/api.py` | API source code |
| `api/requirements.txt` | Python dependencies |
| `api/start.sh` | API startup script |
| `bin/` | Entrypoint scripts |
| `config/` | Configuration templates |
| `scripts/` | Utility scripts |

### Sensitive Files (Encrypted)

| Directory | Description |
|-----------|-------------|
| `secrets/` | API keys and secrets |
| `deploy/nginx/certs/` | SSL/TLS certificates |

## Backup Structure

Each backup creates an archive with the following structure:

```
wazuh-api-backup_YYYY-MM-DD_HHMMSS.tar.gz
├── docker-compose.yml
├── Dockerfile
├── Dockerfile.agent
├── .dockerignore
├── deploy/
│   ├── nginx/
│   └── fail2ban/
├── api/
│   ├── api.py
│   ├── requirements.txt
│   └── start.sh
├── bin/
├── config/
├── scripts/
├── secrets_.tar.gz.enc          # Encrypted
├── deploy_nginx_certs_.tar.gz.enc  # Encrypted
└── MANIFEST.txt
```

## Restore Script

**Location:** `scripts/restore.sh`

### Features

- **Automatic rollback** - Creates a rollback point before restore; automatically reverts on failure
- **Dry-run mode** - Preview what would be restored without making changes
- **Service management** - Automatically stops and restarts Docker services
- **Permission handling** - Sets correct permissions on restored files
- **Verification** - Validates restore completeness after operation
- **Logging** - Detailed logging to `restore.log` for audit trail

### Usage

```bash
./scripts/restore.sh <backup-file> [options]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --password` | Decryption password | Interactive prompt |
| `-d, --dry-run` | Show what would be restored | false |
| `-f, --force` | Skip confirmation prompts | false |
| `-n, --no-restart` | Don't restart services after restore | false |
| `-h, --help` | Show help message | - |

### Examples

```bash
# Interactive mode (prompts for password and confirmation)
./scripts/restore.sh backups/wazuh-api-backup_2024-01-15_020000.tar.gz

# With password and force (no confirmation)
./scripts/restore.sh backups/wazuh-api-backup_2024-01-15_020000.tar.gz -p "your-password" -f

# Dry run to preview restore
./scripts/restore.sh backups/wazuh-api-backup_2024-01-15_020000.tar.gz -d

# Restore without restarting services
./scripts/restore.sh backups/wazuh-api-backup_2024-01-15_020000.tar.gz -p "$BACKUP_PASSWORD" -n

# Using environment variable for password
export BACKUP_PASSWORD="your-secure-password"
./scripts/restore.sh backups/wazuh-api-backup_2024-01-15_020000.tar.gz -f
```

## Restore Procedure

### Prerequisites

- Access to the backup archive
- Encryption password used during backup
- OpenSSL installed on the system
- Docker and Docker Compose installed

### Automated Restore (Recommended)

Use the restore script for automated, safe restoration:

```bash
# 1. List available backups
ls -la backups/

# 2. Preview the restore (dry-run)
./scripts/restore.sh backups/wazuh-api-backup_YYYY-MM-DD_HHMMSS.tar.gz -d

# 3. Perform the restore
./scripts/restore.sh backups/wazuh-api-backup_YYYY-MM-DD_HHMMSS.tar.gz -p "$BACKUP_PASSWORD"

# 4. Verify services
docker-compose ps
docker-compose logs --tail=50
```

### Manual Restore (Step-by-Step)

If you need to perform a manual restore:

1. **Extract the backup archive:**

   ```bash
   tar -xzf wazuh-api-backup_YYYY-MM-DD_HHMMSS.tar.gz
   cd wazuh-api-backup_YYYY-MM-DD_HHMMSS
   ```

2. **Decrypt sensitive files (secrets):**

   ```bash
   openssl enc -d -aes-256-cbc -pbkdf2 \
     -in secrets_.tar.gz.enc \
     -pass pass:"$PASSWORD" | tar -xzf -
   ```

3. **Decrypt sensitive files (certificates):**

   ```bash
   openssl enc -d -aes-256-cbc -pbkdf2 \
     -in deploy_nginx_certs_.tar.gz.enc \
     -pass pass:"$PASSWORD" | tar -xzf -
   ```

4. **Copy files to the project directory:**

   ```bash
   # Copy all files to project root
   cp -r * /path/to/wazuh-log-pipeline/
   
   # Or selectively copy specific files
   cp docker-compose.yml /path/to/wazuh-log-pipeline/
   cp -r deploy/ /path/to/wazuh-log-pipeline/
   cp -r secrets/ /path/to/wazuh-log-pipeline/
   ```

5. **Verify file permissions:**

   ```bash
   # Ensure scripts are executable
   chmod +x scripts/*.sh
   chmod +x api/start.sh
   chmod +x bin/*.sh
   
   # Secure secrets directory
   chmod 700 secrets/
   chmod 600 secrets/*
   ```

6. **Restart services:**

   ```bash
   cd /path/to/wazuh-log-pipeline
   docker-compose down
   docker-compose up -d
   ```

7. **Verify services are running:**

   ```bash
   docker-compose ps
   docker-compose logs --tail=50
   ```

### Restore Script Workflow

The restore script performs the following steps:

```
┌─────────────────────────────────────────────────────────────┐
│                    RESTORE WORKFLOW                         │
├─────────────────────────────────────────────────────────────┤
│  1. Validate backup file and password                       │
│  2. Create rollback point (backup current state)            │
│  3. Stop running Docker services                            │
│  4. Extract backup archive to temp directory                │
│  5. Restore configuration files                             │
│  6. Decrypt and restore sensitive files                     │
│  7. Set correct file permissions                            │
│  8. Verify restore completeness                             │
│  9. Start Docker services (unless --no-restart)             │
│ 10. Clean up temp files and rollback point                  │
└─────────────────────────────────────────────────────────────┘

On failure at any step:
┌─────────────────────────────────────────────────────────────┐
│  → Automatic rollback to pre-restore state                  │
│  → Error logged to restore.log                              │
│  → Exit with error code                                     │
└─────────────────────────────────────────────────────────────┘
```

### Rollback Behavior

If the restore fails at any point:

1. The script automatically restores files from the rollback point
2. All changes are reverted to the pre-restore state
3. An error message indicates what went wrong
4. Check `restore.log` for detailed information

To manually trigger a rollback (if needed):

```bash
# The rollback directory is at .restore_rollback/
# If it exists after a failed restore, you can manually copy files back:
cp -r .restore_rollback/* ./
```

## Automated Backups

### Using Cron

Add to crontab for automated daily backups at 2 AM:

```bash
# Edit crontab
crontab -e

# Add the following line
0 2 * * * /path/to/wazuh-log-pipeline/scripts/backup.sh -p "$BACKUP_PASSWORD" -v >> /var/log/wazuh-backup.log 2>&1
```

### Using Systemd Timer

1. **Create service file:** `/etc/systemd/system/wazuh-backup.service`

   ```ini
   [Unit]
   Description=Wazuh API Configuration Backup
   After=network.target

   [Service]
   Type=oneshot
   User=root
   Environment=BACKUP_PASSWORD=your-secure-password
   ExecStart=/path/to/wazuh-log-pipeline/scripts/backup.sh -v
   StandardOutput=journal
   StandardError=journal
   ```

2. **Create timer file:** `/etc/systemd/system/wazuh-backup.timer`

   ```ini
   [Unit]
   Description=Daily Wazuh API Backup

   [Timer]
   OnCalendar=*-*-* 02:00:00
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

3. **Enable and start the timer:**

   ```bash
   systemctl daemon-reload
   systemctl enable wazuh-backup.timer
   systemctl start wazuh-backup.timer
   ```

## Security Considerations

### Password Management

- **Never store the backup password in plain text** in scripts or configuration files
- Use environment variables or a secrets manager for automation
- Consider using different passwords for different backup sets
- Rotate backup passwords periodically

### Backup Storage

- Store backups in a separate location from the production system
- Consider off-site or cloud storage for disaster recovery
- Encrypt backups at rest if stored on shared storage
- Implement access controls on backup storage

### Retention Policy

- Default retention is 7 backups
- Adjust based on storage capacity and recovery requirements
- Consider longer retention for compliance requirements
- Test restore procedures regularly

## Troubleshooting

### Common Issues

1. **"Encryption password is required" error:**
   - Provide password via `-p` option or `BACKUP_PASSWORD` environment variable

2. **"Backup archive is corrupted" error:**
   - Check disk space on backup destination
   - Verify source files are accessible
   - Check for I/O errors in system logs

3. **Decryption fails during restore:**
   - Verify you're using the correct password
   - Ensure the encrypted file wasn't modified or corrupted
   - Check OpenSSL version compatibility

4. **Permission denied errors:**
   - Run backup script with appropriate permissions
   - Ensure backup directory is writable
   - Check file ownership on source files

### Verification Commands

```bash
# Verify backup archive integrity
tar -tzf wazuh-api-backup_*.tar.gz

# List contents of backup
tar -tvf wazuh-api-backup_*.tar.gz

# Check encrypted file (will fail if corrupted)
openssl enc -d -aes-256-cbc -pbkdf2 -in secrets_.tar.gz.enc -pass pass:"$PASSWORD" | tar -tzf -
```

## Recovery Time Objectives

| Scenario | Estimated Recovery Time |
|----------|------------------------|
| Single file restore | 5-10 minutes |
| Full configuration restore | 15-30 minutes |
| Complete system rebuild | 1-2 hours |

## Backup Checklist

- [ ] Backup script is executable (`chmod +x scripts/backup.sh`)
- [ ] Backup password is securely stored
- [ ] Automated backup schedule is configured
- [ ] Backup storage has sufficient space
- [ ] Restore procedure has been tested
- [ ] Off-site backup copy exists
- [ ] Backup monitoring/alerting is configured