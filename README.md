# retroarch-saves

Sync RetroArch save files across devices using S3 + WebDAV.

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

**Cost:** ~$3/month (EC2) + pennies (S3).

## Prerequisites

- AWS account with CLI configured
- An EC2 key pair in your target region
- A domain name with DNS you control

## Setup

### 1. Deploy infrastructure

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name retroarch-saves \
  --parameter-overrides \
    KeyPairName=your-key \
    SshCidr=YOUR_IP/32 \
    AlertEmail=you@example.com \
  --capabilities CAPABILITY_IAM
```

### 2. Point DNS

Get the Elastic IP from the stack outputs:

```bash
aws cloudformation describe-stacks --stack-name retroarch-saves \
  --query 'Stacks[0].Outputs' --output table
```

Create an A record at your DNS provider: `saves.yourdomain.com → <ElasticIp>`

### 3. Configure the server

```bash
# Copy setup script and SSH in
scp -i your-key.pem setup.sh ec2-user@ELASTIC_IP:~
ssh -i your-key.pem ec2-user@ELASTIC_IP

# Run it (use bucket and region from stack outputs)
sudo ./setup.sh --domain saves.yourdomain.com --bucket retroarch-saves-ACCOUNTID --region us-east-1
```

The script prompts for a WebDAV password, then installs rclone, gets a TLS cert, and starts serving. Takes about 2 minutes.

## What stays running

| Concern | How |
|---------|-----|
| Service crashes | systemd `Restart=always` |
| Service unresponsive | Health check every 5 min, auto-restarts |
| Hardware failure | CloudWatch auto-recovery (migrates instance) |
| Instance down 5+ min | Email alert |
| TLS cert expiry | Auto-renewed daily via certbot timer |
| OS vulnerabilities | `dnf-automatic` applies security patches |
| SSH brute force | fail2ban |

## Configure RetroArch

| Setting | Value |
|---------|-------|
| Cloud Sync | ON |
| Backend | WebDAV |
| URL | `https://saves.yourdomain.com/` |
| Username | `retroarch` |
| Password | (as entered during setup) |
| Sync Saves | ON |
| Sync Configs | OFF |

All devices must match:
- Sort Saves into Folders by Core Name → **ON**
- Sort Save States into Folders by Core Name → **ON**

## Troubleshooting

```bash
ssh -i your-key.pem ec2-user@ELASTIC_IP

sudo systemctl status rclone-webdav        # Service status
sudo journalctl -u rclone-webdav -f        # Live logs
sudo -u ec2-user rclone ls s3-saves:BUCKET # List synced files
```

## Teardown

```bash
aws cloudformation delete-stack --stack-name retroarch-saves

# S3 bucket is retained — delete manually if wanted:
aws s3 rb s3://retroarch-saves-ACCOUNT_ID --force
```
