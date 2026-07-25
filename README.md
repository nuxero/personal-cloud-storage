# personal-cloud-storage

Personal cloud storage server using S3 + WebDAV. Serves multiple use cases (game saves, backups, media) from a single endpoint with logical separation via path prefixes.

## Architecture

```
┌─────────────┐          ┌────────────────────────────────────┐          ┌─────────────┐
│   Clients   │── HTTPS ►│         EC2 (t4g.nano)             │── S3 ───►│  S3 Bucket  │
│             │          │  ┌───────┐       ┌──────────────┐  │          │  (versioned)│
│ • RetroArch │◄─────────│  │ Caddy │──────►│ rclone serve │  │◄─────────│             │
│ • Backup    │          │  │ :443  │ proxy │ webdav :8080 │  │          └─────────────┘
│ • Media     │          │  │ TLS+  │       │ (localhost)  │  │
│ • Dolphin   │          │  │ Auth  │       └──────────────┘  │
└─────────────┘          │  └───────┘                         │
                         └────────────────────────────────────┘
```

Caddy handles TLS (auto Let's Encrypt) and authentication. rclone bridges WebDAV to S3.

**Cost:** ~$3/month (EC2) + pennies (S3).

## Storage layout

Each use case gets its own prefix in the bucket:

```
s3:bucket/
├── retroarch/   ← game saves and states
├── backups/     ← cold backups (databases, configs, etc.)
└── media/       ← photos, music, videos
```

Clients target their respective path on the WebDAV endpoint:
- `https://storage.yourdomain.com/retroarch/`
- `https://storage.yourdomain.com/backups/`
- `https://storage.yourdomain.com/media/`

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

Create an A record at your DNS provider: `storage.yourdomain.com → <ElasticIp>`

### 3. Configure the server

```bash
# Copy setup script and SSH in
scp -i your-key.pem setup-server.sh ec2-user@ELASTIC_IP:~
ssh -i your-key.pem ec2-user@ELASTIC_IP

# Run it (use bucket and region from stack outputs)
sudo ./setup-server.sh --domain storage.yourdomain.com --bucket retroarch-saves-ACCOUNTID --region us-east-1
```

The script prompts for a WebDAV password, then installs rclone, gets a TLS cert, and starts serving. Takes about 2 minutes.

## What stays running

| Concern | How |
|---------|-----|
| Service crashes | systemd `Restart=always` (both Caddy and rclone) |
| Hardware failure | CloudWatch auto-recovery (migrates instance) |
| Instance down 5+ min | Email alert |
| TLS cert expiry | Caddy auto-renews via built-in ACME client |
| OS vulnerabilities | `dnf-automatic` applies security patches |
| SSH brute force | fail2ban |

## Configure RetroArch

| Setting | Value |
|---------|-------|
| Cloud Sync | ON |
| Backend | WebDAV |
| URL | `https://storage.yourdomain.com/retroarch/` |
| Username | `retroarch` |
| Password | (as entered during setup) |
| Sync Saves | ON |
| Sync Configs | OFF |

All devices must match:
- Sort Saves into Folders by Core Name → **ON**
- Sort Save States into Folders by Core Name → **ON**

### Separate password for RetroArch (recommended)

RetroArch stores WebDAV passwords in plain text (`retroarch.cfg`). To limit exposure, create a dedicated user for RetroArch that can only access the `/retroarch/` path, and keep a separate primary account for everything else.

Example `/etc/caddy/Caddyfile`:

```caddyfile
storage.yourdomain.com {
    # RetroArch user — restricted to /retroarch/* only.
    # This password is stored in plain text by RetroArch, so treat it as
    # disposable. If compromised, only game saves are exposed.
    @retroarch path /retroarch/*
    handle @retroarch {
        basicauth {
            # Generate hash: caddy hash-password --plaintext 'YOUR_RETROARCH_PASSWORD'
            retroarch $2a$14$VmG/ADnFLVkwGmBj8wXOve...
            myuser    $2a$14$Uf1Qx0Mnbou73Lqh0gZSxe...
        }
        reverse_proxy localhost:8080
    }

    # Everything else — only the primary user can access /backups/*, /media/*, etc.
    handle {
        basicauth {
            # Generate hash: caddy hash-password --plaintext 'YOUR_MAIN_PASSWORD'
            myuser $2a$14$Uf1Qx0Mnbou73Lqh0gZSxe...
        }
        reverse_proxy localhost:8080
    }
}
```

After editing, reload without downtime:

```bash
sudo systemctl reload caddy
```

Then update RetroArch to use the `retroarch` username and dedicated password. Your other clients (rclone, Dolphin, curl) continue using `myuser` with the stronger primary password.

## Other clients

Any WebDAV-compatible tool can write to the other prefixes using the primary credentials:

```bash
# Set up an rclone remote (recommended for bulk/large uploads)
rclone config create saves webdav url=https://storage.yourdomain.com user=myuser pass=$(rclone obscure 'YOUR_MAIN_PASSWORD')

# Upload files
rclone copy ./photos saves:media/photos/ --progress

# Push a backup with curl
curl -T database.sql.gz -u myuser:PASSWORD "https://storage.yourdomain.com/backups/database.sql.gz"
```

### KDE Dolphin / KIO (known limitation)

KIO's WebDAV worker (used by Dolphin, kioclient, etc.) has a bug with HTTP/2 uploads: it drops the last ~983KB of files larger than ~500KB, resulting in **silently corrupted uploads**. The server reports a 502 error but KIO may still show the file as copied.

**Affected:** large file uploads via Dolphin, kioclient, or any KIO-based app.

**Not affected:** browsing, downloading, deleting, small file uploads.

**Workaround:** use `rclone copy` or `curl -T` for uploading files larger than ~500KB. Dolphin is fine for browsing and downloading.

```bash
# Browse in Dolphin (address bar):
webdavs://storage.yourdomain.com/

# Upload large files via rclone:
rclone copy "/path/to/files/" saves:"backups/folder/" --progress
```

### Recommended client setup

| Platform | Browsing | Uploading large files |
|----------|----------|----------------------|
| Linux (KDE) | Dolphin (`webdavs://...`) | `rclone copy` |
| Linux (GNOME) | Nautilus (`davs://...`) | `rclone copy` |
| Android | WebDAV Provider (SAF) | FolderSync |
| Any | — | `curl -T` or `rclone copy` |

## Notes on data safety

- The EC2 instance is **stateless** — it's just a WebDAV-to-S3 proxy. You can terminate and recreate it at any time.
- **S3 versioning** retains previous versions for 30 days, protecting against accidental deletion or overwrites.
- The instance role cannot delete object versions (`s3:DeleteObjectVersion` is not granted), so even a compromised server can't permanently destroy data within the retention window.
- **Encryption:** objects are encrypted at rest with AES-256 (SSE-S3). For sensitive backups, consider client-side encryption (e.g., `restic`, `duplicity`) before uploading.

## Maintenance

### Rotate WebDAV password

```bash
ssh -i your-key.pem ec2-user@ELASTIC_IP

# Generate new hash
caddy hash-password --plaintext 'NEW_PASSWORD'

# Edit /etc/caddy/Caddyfile — replace the old hash with the new one
sudo vim /etc/caddy/Caddyfile

# Reload Caddy (no downtime)
sudo systemctl reload caddy
```

Then update the password on all clients (RetroArch, backup scripts, etc.).

### Rotate SSH key pair

1. Create a new key pair in the AWS console
2. Add the new public key to `~/.ssh/authorized_keys` on the instance
3. Verify you can SSH with the new key
4. Remove the old key from `authorized_keys`
5. Delete the old key pair from AWS console

### Check disk usage

The 8GB EBS volume holds the OS and rclone VFS cache. It shouldn't fill up, but worth checking occasionally:

```bash
df -h /
sudo du -sh /home/ec2-user/.cache/rclone
```

### Review S3 storage and costs

```bash
# Total size of each prefix
sudo -u ec2-user rclone size s3-saves:BUCKET/retroarch
sudo -u ec2-user rclone size s3-saves:BUCKET/backups
sudo -u ec2-user rclone size s3-saves:BUCKET/media
```

Or check the S3 bucket metrics in the AWS console under CloudWatch → Storage Metrics.

### Verify TLS certificate renewal

Caddy auto-renews certificates. To confirm:

```bash
sudo caddy list-certs
sudo journalctl -u caddy --grep="certificate\|tls" --since "7 days ago"
```

### Update rclone

```bash
sudo curl -fsSL https://rclone.org/install.sh | sudo bash
sudo systemctl restart rclone-webdav
```

### OS patches

`dnf-automatic` applies security patches automatically. To manually check or force a full update:

```bash
sudo dnf check-update
sudo dnf upgrade -y
sudo reboot  # if kernel was updated
```

### Recommended cadence

| Task | Frequency |
|------|-----------|
| Rotate WebDAV password | Every 6–12 months |
| Rotate SSH key pair | Annually or if compromised |
| Check disk usage | Every few months |
| Review S3 costs | Monthly (check AWS billing) |
| Verify TLS cert | After any instance recovery |
| Update rclone | Every few months or when needed |
| Update Caddy | Every few months (re-download from GitHub releases) |
| OS patches | Automatic (verify after recovery) |

## Troubleshooting

```bash
ssh -i your-key.pem ec2-user@ELASTIC_IP

sudo systemctl status caddy              # Caddy (TLS + auth)
sudo systemctl status rclone-webdav      # rclone (WebDAV → S3)
sudo journalctl -u caddy -f             # Caddy logs
sudo journalctl -u rclone-webdav -f      # rclone logs
sudo -u ec2-user rclone ls s3-saves:BUCKET # List synced files
```

## Teardown

```bash
aws cloudformation delete-stack --stack-name retroarch-saves

# S3 bucket is retained — delete manually if wanted:
aws s3 rb s3://retroarch-saves-ACCOUNT_ID --force
```
