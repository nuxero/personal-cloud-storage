# personal-cloud-storage

Personal cloud storage server using S3 + WebDAV, managed declaratively with NixOS. Serves multiple use cases (game saves, backups, media) from a single endpoint with logical separation via path prefixes.

## Architecture

```
┌─────────────┐          ┌────────────────────────────────────┐          ┌─────────────┐
│   Clients   │── HTTPS ►│       EC2 (t4g.nano, NixOS)        │── S3 ───►│  S3 Bucket  │
│             │          │  ┌───────┐       ┌──────────────┐  │          │  (versioned)│
│ • RetroArch │◄─────────│  │ Caddy │──────►│ rclone serve │  │◄─────────│             │
│ • Backup    │          │  │ :443  │ proxy │ webdav :8080 │  │          └─────────────┘
│ • Media     │          │  │ TLS+  │       │ (localhost)  │  │
│ • Dolphin   │          │  │ Auth  │       └──────────────┘  │
└─────────────┘          │  └───────┘                         │
                         └────────────────────────────────────┘
```

Caddy handles TLS (auto Let's Encrypt) and authentication. rclone bridges WebDAV to S3.

**OS:** NixOS 25.05 (stable) — entire server configuration is declarative and reproducible.

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
- A NixOS AMI ID for your region (see [Finding the AMI](#finding-the-nixos-ami) below)

## Setup

### 1. Deploy infrastructure

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name cloud-storage \
  --parameter-overrides \
    KeyPairName=your-key \
    SshCidr=YOUR_IP/32 \
    AlertEmail=you@example.com \
    NixOsAmiId=ami-XXXXXXXXXXXXXXXXX \
  --capabilities CAPABILITY_IAM
```

### 2. Point DNS

Get the Elastic IP from the stack outputs:

```bash
aws cloudformation describe-stacks --stack-name cloud-storage \
  --query 'Stacks[0].Outputs' --output table
```

Create an A record at your DNS provider: `storage.yourdomain.com → <ElasticIp>`

### 3. Configure the server

SSH in (NixOS AMIs use `root` on first boot with the EC2 key pair):

```bash
ssh -i your-key.pem root@ELASTIC_IP
```

Copy the configuration files:

```bash
# From your local machine:
scp -i your-key.pem nixos/configuration.nix root@ELASTIC_IP:/etc/nixos/configuration.nix
```

Create the secrets file on the server:

```bash
# On the server:
cat > /etc/nixos/secrets.nix << 'EOF'
{
  domain = "storage.yourdomain.com";
  s3Bucket = "retroarch-saves-ACCOUNTID";
  s3Region = "us-east-1";
  webdavUser = "retroarch";
  webdavPasswordHash = "PASTE_HASH_HERE";
  sshPublicKeys = [
    "ssh-ed25519 AAAAC3... your-key"
  ];
}
EOF
```

Generate the password hash:

```bash
nix-shell -p caddy --run "caddy hash-password --plaintext 'YOUR_PASSWORD'"
```

Apply the configuration:

```bash
nixos-rebuild switch
```

That's it. Caddy, rclone, fail2ban, firewall, auto-upgrades — everything is now running.

### 4. Verify

```bash
systemctl status caddy
systemctl status rclone-webdav
curl -u retroarch:PASSWORD https://storage.yourdomain.com/
```

## Finding the NixOS AMI

### Option A: Official NixOS AMIs

Check the [NixOS download page](https://nixos.org/download#nixos-amazon) for the latest stable AMI IDs by region.

### Option B: Determinate Systems AMIs (recommended)

[Determinate Systems](https://determinate.systems/blog/nixos-amis/) publishes optimized NixOS AMIs for both x86_64 and aarch64. See their [nixos-amis repo](https://github.com/DeterminateSystems/nixos-amis) for the latest IDs.

### Option C: AWS Marketplace

Search for "NixOS 25.05" in the AWS Marketplace — the [Epok Systems AMI](https://aws.amazon.com/marketplace/pp/prodview-lomgvizeucgwe) is available for arm64.

## What stays running

| Concern | How |
|---------|-----|
| Service crashes | systemd `Restart=always` (both Caddy and rclone) |
| Hardware failure | CloudWatch auto-recovery (migrates instance) |
| Instance down 5+ min | Email alert |
| TLS cert expiry | Caddy auto-renews via built-in ACME client |
| OS upgrades | NixOS `system.autoUpgrade` (daily at 04:00, auto-reboot) |
| SSH brute force | fail2ban (built-in NixOS sshd jail) |
| WebDAV brute force | fail2ban (`caddy-auth` jail) |
| Vulnerability scanning | fail2ban (`caddy-botscan` jail) |
| Old Nix generations | Garbage-collected weekly (older than 30 days) |

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

RetroArch stores WebDAV passwords in plain text (`retroarch.cfg`). To limit exposure, add a second user to the Caddy `basic_auth` block in `configuration.nix`:

```nix
# In services.caddy.virtualHosts.${secrets.domain}.extraConfig:
basic_auth {
    ${secrets.webdavUser} ${secrets.webdavPasswordHash}
    retroarch ${secrets.retroarchPasswordHash}  # weaker, disposable password
}
```

For path-restricted access, use Caddy's `handle` + matcher directives in the `extraConfig`.

## Other clients

Any WebDAV-compatible tool can write to the other prefixes using the same credentials:

```bash
# Set up an rclone remote
rclone config create saves webdav url=https://storage.yourdomain.com user=myuser pass=$(rclone obscure 'YOUR_PASSWORD')

# Upload files
rclone copy ./photos saves:media/photos/ --progress

# Push a backup with curl
curl -T database.sql.gz -u myuser:PASSWORD "https://storage.yourdomain.com/backups/database.sql.gz"
```

### Recommended client setup

| Platform | Browsing | Uploading large files |
|----------|----------|----------------------|
| Linux (KDE) | Dolphin (`webdavs://...`) | `rclone copy` |
| Linux (GNOME) | Nautilus (`davs://...`) | `rclone copy` |
| Android | WebDAV Provider (SAF) | FolderSync |
| Any | — | `curl -T` or `rclone copy` |

> **KDE Dolphin / KIO note:** KIO has a bug with HTTP/2 uploads — files larger than ~500KB may be silently corrupted. Use `rclone copy` for uploading. Dolphin is fine for browsing and downloading.

## Notes on data safety

- The EC2 instance is **stateless** — it's just a WebDAV-to-S3 proxy. You can terminate and recreate it at any time.
- **S3 versioning** retains previous versions for 30 days, protecting against accidental deletion or overwrites.
- The instance role cannot delete object versions (`s3:DeleteObjectVersion` is not granted), so even a compromised server can't permanently destroy data within the retention window.
- **Encryption:** objects are encrypted at rest with AES-256 (SSE-S3).
- **NixOS rollback:** if a config change breaks things, reboot and select a previous generation from the boot menu.

## Maintenance

### Change configuration

Edit `/etc/nixos/configuration.nix` on the server, then:

```bash
sudo nixos-rebuild switch
```

To roll back:

```bash
sudo nixos-rebuild switch --rollback
```

### Rotate WebDAV password

```bash
# Generate new hash
nix-shell -p caddy --run "caddy hash-password --plaintext 'NEW_PASSWORD'"

# Update /etc/nixos/secrets.nix with new hash
sudo vim /etc/nixos/secrets.nix

# Apply
sudo nixos-rebuild switch
```

### Update NixOS channel

```bash
sudo nix-channel --update
sudo nixos-rebuild switch
```

Or just wait — `system.autoUpgrade` does this daily.

### Review S3 storage

```bash
nix-shell -p rclone --run "rclone size :s3:BUCKET/retroarch --s3-provider AWS --s3-region us-east-1 --s3-env-auth"
```

### Check fail2ban status

```bash
sudo fail2ban-client status
sudo fail2ban-client status caddy-auth
sudo fail2ban-client set caddy-auth unbanip 1.2.3.4  # manually unban
```

## File structure

```
.
├── template.yaml                  # CloudFormation (EC2, S3, IAM, alarms)
├── nixos/
│   ├── configuration.nix          # Full NixOS system config (deploy to /etc/nixos/)
│   └── secrets.nix.example        # Template for machine-specific secrets
└── README.md
```

## Teardown

```bash
aws cloudformation delete-stack --stack-name cloud-storage

# S3 bucket is retained — delete manually if wanted:
aws s3 rb s3://retroarch-saves-ACCOUNT_ID --force
```

## Migration from AL2023

If you previously ran this on Amazon Linux 2023:

1. Deploy the new stack (or update the existing one with the new template + NixOS AMI)
2. Your S3 data is untouched — the new NixOS instance connects to the same bucket
3. Point DNS to the new Elastic IP (or reuse the old one)
4. The old `setup-server.sh` and `harden-fail2ban.sh` scripts are no longer needed — everything is in `configuration.nix`
