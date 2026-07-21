# retroarch-saves

Sync RetroArch save files across multiple devices using S3 + WebDAV.

## Architecture

```
┌─────────────┐                        ┌──────────────────┐                 ┌─────────────┐
│   Devices   │───── HTTPS/WebDAV ────►│  EC2 (t4g.nano)  │──── S3 API ───►│  S3 Bucket  │
│             │                        │  rclone serve    │                 │  (versioned)│
│ • Laptop    │◄── saves/states sync ──│  webdav          │◄── read/write ──│             │
│ • Phone     │                        └──────────────────┘                 └─────────────┘
│ • Handheld  │
└─────────────┘
```

A `t4g.nano` EC2 instance runs rclone as a WebDAV-to-S3 bridge. All devices connect over HTTPS with basic auth. RetroArch's built-in cloud sync handles conflict resolution and automatic sync on game close.

**Cost:** ~$3/month (EC2) + pennies (S3 storage for saves).

## Prerequisites

- AWS account with CLI configured
- A domain name with DNS you can manage
- An EC2 key pair in your target region
- RetroArch installed on all devices

## Deployment

### 1. Deploy infrastructure

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name retroarch-saves \
  --parameter-overrides \
    Domain=retroarch.yourdomain.com \
    KeyPairName=your-key-pair \
    SshCidr=YOUR_IP/32 \
  --capabilities CAPABILITY_NAMED_IAM
```

### 2. Get outputs

```bash
aws cloudformation describe-stacks \
  --stack-name retroarch-saves \
  --query 'Stacks[0].Outputs' \
  --output table
```

Note the `ElasticIp`, `AccessKeyId`, `SecretAccessKey`, and `BucketName`.

### 3. Point DNS

Create an A record: `retroarch.yourdomain.com` → Elastic IP from outputs.

Wait for DNS propagation (check with `dig retroarch.yourdomain.com`).

### 4. Configure the server

```bash
# Copy the script to the instance
scp -i your-key.pem setup-server.sh ec2-user@ELASTIC_IP:~

# SSH in and run it
ssh -i your-key.pem ec2-user@ELASTIC_IP
chmod +x setup-server.sh
./setup-server.sh retroarch.yourdomain.com
```

The script will prompt for:
- S3 bucket name (from CloudFormation output)
- AWS region
- IAM access key and secret (from CloudFormation output)
- WebDAV username and password (you choose, min 12 chars)

It then installs rclone, obtains a Let's Encrypt certificate, creates a systemd service, and hardens the instance.

### 5. Close port 80

After setup, port 80 is no longer needed (except for cert renewal). You can leave it open (harmless — nothing listens on it) or close it and temporarily re-open every ~90 days for renewal.

## Configure RetroArch

On each device, enable cloud sync:

| Setting | Value |
|---------|-------|
| Cloud Sync | ON |
| Backend | WebDAV |
| URL | `https://retroarch.yourdomain.com/` |
| Username | (your WebDAV username) |
| Password | (your WebDAV password) |
| Sync Saves | ON |
| Sync Configs | OFF |
| Sync System | OFF |
| Destructive | OFF |

**Critical:** All devices must have matching directory organization:
- Sort Saves into Folders by Core Name → **ON**
- Sort Save States into Folders by Core Name → **ON**

## What gets synced

- `.srm` save files (battery saves)
- Save states
- RetroArch's sync manifests

What does NOT sync:
- `retroarch.cfg` (device-specific)
- Playlists
- ROMs / BIOS files
- Shader presets

## Security

- TLS 1.2+ (Let's Encrypt certificate, auto-renewed)
- bcrypt-hashed passwords (htpasswd)
- Systemd sandboxing (ProtectSystem, NoNewPrivileges, PrivateTmp)
- Security group: only 443 open to internet, SSH restricted to your IP
- IAM least-privilege: rclone can only access this one S3 bucket
- S3 versioning: 30-day history protects against accidental corruption
- fail2ban: protects SSH from brute force
- Auto security updates via dnf-automatic

## Maintenance

```bash
# Check service status
sudo systemctl status rclone-webdav

# View logs
sudo journalctl -u rclone-webdav -f

# List synced saves
rclone ls s3-saves:BUCKET_NAME

# Restart after config change
sudo systemctl restart rclone-webdav

# Force cert renewal
sudo certbot renew && sudo systemctl restart rclone-webdav
```

## Usage tips

- Always close content (return to RetroArch menu) before quitting — this triggers sync
- Don't play the same game on two devices simultaneously
- First sync from a new device uploads all local saves — this is normal
- If conflicts appear, check `core_assets_directory/cloud_backups/` for recovered files

## Files

| File | Purpose |
|------|---------|
| `template.yaml` | CloudFormation template — creates S3, IAM, EC2, security group, EIP |
| `setup-server.sh` | Run on EC2 — installs rclone, certs, systemd service, hardens instance |

## Teardown

```bash
# Delete the stack (EC2, security group, EIP, IAM user)
aws cloudformation delete-stack --stack-name retroarch-saves

# The S3 bucket has DeletionPolicy: Retain — delete manually if wanted:
aws s3 rb s3://retroarch-saves-ACCOUNT_ID --force
```
