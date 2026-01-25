# ACME UniFi Certificate Renewal

Automated SSL certificate renewal for UniFi UCG Max gateway using Let's Encrypt and Route53 DNS validation.

Uses [acme.sh](https://github.com/acmesh-official/acme.sh) - a pure shell ACME client that works on BusyBox environments.

## Features

- **Automatic Renewal**: Daily cron job checks certificate expiry and renews when needed
- **Auto-Discovery**: Automatically finds the active certificate UUID on your gateway
- **Route53 DNS Challenge**: No need to open ports or modify firewall rules
- **ECC & RSA Support**: Supports modern Elliptic Curve (ECC) and standard RSA certificates
- **Webhook Notifications**: Get notified via Slack, Discord, or Healthchecks.io on success/failure
- **Firmware Upgrade Safe**: Cron job persists across UniFi OS updates
- **BusyBox Compatible**: POSIX shell scripts work on UCG Max's minimal environment
- **Backup & Rollback**: Existing certificates are backed up before replacement
- **Staging Support**: Test with Let's Encrypt staging server before production
- **Auto-Updates**: Weekly task keeps acme.sh and scripts up to date

## Requirements

- UniFi UCG Max (or compatible UniFi OS device)
- Domain name with DNS hosted on AWS Route53
- AWS IAM credentials with Route53 permissions
- SSH/root access to the UCG Max
- **A custom certificate must be imported first** (see Prerequisites below)

## Prerequisites

Before installing this automation, you must import a custom certificate through the UniFi UI:

1. Go to **UniFi Network Settings > System > Advanced**
2. Upload any custom certificate (can be self-signed initially)
3. This creates the UUID-named certificate files (`<UUID>.crt` and `<UUID>.key`) that this automation will manage

This step is required because the automation replaces existing certificate files. Without an imported certificate, there are no UUID-named files to replace.

## Quick Start

1. **Import a certificate via UniFi UI first** (if not already done)
   - Go to UniFi Network Settings > System > Advanced
   - Upload any custom certificate (self-signed is fine for initial setup)
   - This creates the UUID-named files the automation will manage

2. **Copy files to UCG Max**
   ```bash
   scp -r ./* root@gateway:/data/acme-unifi/
   ```

3. **SSH to UCG Max**
   ```bash
   ssh root@gateway
   cd /data/acme-unifi
   ```

4. **Verify certificate UUID exists**
   ```bash
   ls /data/unifi-core/config/*.crt
   # Should show: /data/unifi-core/config/7f132919-e141-43b7-8ee3-ad7c3fee4c39.crt
   # If no UUID-named file exists, complete step 1 first
   ```

5. **Edit configuration**
   ```bash
   vi acme-unifi.env
   ```
   Update:
   - `CERT_DOMAIN` - Your gateway's domain name
   - `CERT_UUID` - Set to `auto` or the UUID from step 4
   - `CERT_TYPE` - `ecc` (recommended) or `rsa`
   - `ACME_EMAIL` - Your email for Let's Encrypt notifications
   - `WEBHOOK_URL` - (Optional) URL for Slack/Discord/Healthchecks notifications

6. **Create AWS credentials**
   ```bash
   cp aws-credentials.example .secrets/aws-credentials
   chmod 600 .secrets/aws-credentials
   vi .secrets/aws-credentials
   ```

7. **Run installer**
   ```bash
   ./install.sh
   ```

8. **Test with staging server**
   ```bash
   # Edit config and set USE_STAGING="true"
   vi acme-unifi.env

   # Force renewal to test
   ./acme-unifi.sh force-renew

   # Check status
   ./acme-unifi.sh status
   ```

9. **Switch to production**
   ```bash
   # Edit config and set USE_STAGING="false"
   vi acme-unifi.env

   # Force renewal for real certificate
   ./acme-unifi.sh force-renew
   ```

## Files

| File | Description |
|------|-------------|
| `acme-unifi.sh` | Main renewal script |
| `acme-unifi.env` | Configuration file |
| `install.sh` | One-time installer |
| `aws-credentials.example` | AWS credentials template |
| `on-boot-cron.sh` | Boot persistence script |

## Directory Structure (after installation)

```
/data/acme-unifi/
├── acme-unifi.sh           # Main script
├── acme-unifi.env          # Configuration
├── install.sh              # Installer
├── acme.sh/                # acme.sh client (cloned from GitHub)
├── certs/                  # Certificate storage
├── backup/                 # Certificate backups
├── logs/                   # Log files
└── .secrets/
    └── aws-credentials     # AWS credentials (600 permissions)

/data/on_boot.d/
└── 10-acme-cron.sh         # Cron persistence

/data/cronjobs/
└── acme-unifi              # Cron job definition

/data/unifi-core/config/
├── <UUID>.crt              # Deployed certificate
└── <UUID>.key              # Deployed private key
```

## AWS IAM Policy

Create an IAM user with this minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:GetChange"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID",
      "Condition": {
        "ForAllValues:StringLike": {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
            "_acme-challenge.*"
          ]
        }
      }
    }
  ]
}
```

Replace `YOUR_ZONE_ID` with your Route53 hosted zone ID.

## Usage

```bash
# Check status
./acme-unifi.sh status

# Check and renew if needed (runs automatically via cron)
./acme-unifi.sh renew

# Force renewal regardless of expiry
./acme-unifi.sh force-renew

# Update acme.sh and scripts
./acme-unifi.sh update

# Help
./acme-unifi.sh help
```

## Configuration Options

Edit `acme-unifi.env`:

| Variable | Description | Default |
|----------|-------------|---------|
| `CERT_DOMAIN` | Domain for the certificate | (required) |
| `CERT_UUID` | Certificate UUID (or `auto`) | `auto` |
| `CERT_TYPE` | Certificate type (`ecc` or `rsa`) | `ecc` |
| `ACME_EMAIL` | Email for Let's Encrypt | (required) |
| `RENEWAL_DAYS` | Days before expiry to renew | 30 |
| `USE_STAGING` | Use staging server for testing | false |
| `WEBHOOK_URL` | Webhook URL for notifications | (empty) |
| `RESTART_UNIFI_CORE` | Restart unifi-core service | false |
| `LOG_RETENTION_DAYS` | Days to keep log files | 30 |

## Cron Schedule

The installer sets up two cron jobs:

```
# Daily certificate renewal check at 3:00 AM
0 3 * * * root /data/acme-unifi/acme-unifi.sh renew

# Weekly acme.sh update on Sunday at 4:00 AM
0 4 * * 0 root /data/acme-unifi/acme-unifi.sh update
```

The renewal script checks if renewal is needed (certificate expiring within `RENEWAL_DAYS`) before making any changes.

## Verification

After renewal, verify the certificate:

```bash
# Check certificate details
openssl x509 -in /data/unifi-core/config/<UUID>.crt -noout -text

# Check nginx status
systemctl status nginx

# Test HTTPS connection
curl -v https://gateway.yourdomain.com

# Check DNS challenge record (during renewal)
nslookup -type=TXT _acme-challenge.gateway.yourdomain.com
```

## Troubleshooting

### Check logs
```bash
cat /data/acme-unifi/logs/acme-unifi.log
tail -f /data/acme-unifi/logs/cron.log
```

### Certificate not deploying
- Verify CERT_UUID matches existing certificate filename
- Check permissions on /data/unifi-core/config/

### DNS challenge failing
- Verify AWS credentials are correct
- Check IAM policy includes your hosted zone
- Wait for DNS propagation (can take 1-5 minutes)

### nginx not restarting
```bash
systemctl status nginx
journalctl -u nginx
```

### Cron not running after reboot
```bash
# Check if boot script ran
logger -t test "checking boot scripts"
journalctl | grep acme-unifi

# Manually restore cron
/data/on_boot.d/10-acme-cron.sh
```

## Security Notes

- AWS credentials are stored in `.secrets/` with 700/600 permissions
- Credentials are loaded only during renewal and cleared after
- Use IAM policy with minimal permissions (only `_acme-challenge` records)
- Consider using IAM roles if UCG Max supports it in future firmware

## License

MIT
