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

**OS:** NixOS (stable channel) — entire server configuration is declarative and reproducible.

**Cost:** ~$12/month (EC2) + pennies (S3).

## Storage layout

```
s3:bucket/
├── retroarch/   ← game saves and states
├── backups/     ← cold backups (databases, configs, etc.)
└── media/       ← photos, music, videos
```

Clients target their respective path:
- `https://storage.yourdomain.com/retroarch/`
- `https://storage.yourdomain.com/backups/`
- `https://storage.yourdomain.com/media/`

## Setup

### Deploy the stack

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name cloud-storage \
  --parameter-overrides \
    KeyPairName=your-key \
    SshCidr=YOUR_IP/32 \
    AlertEmail=you@example.com \
    LatestAmiId=ami-XXXXXXXXXXXXXXXXX \
  --capabilities CAPABILITY_IAM
```

### Finding the NixOS AMI

| Source | Notes |
|--------|-------|
| [NixOS download page](https://nixos.org/download#nixos-amazon) | Official AMIs by region |
| [Determinate Systems](https://github.com/DeterminateSystems/nixos-amis) | Optimized AMIs for x86_64 and aarch64 |
| [AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-lomgvizeucgwe) | NixOS (stable) by Epok Systems |

### Configure the server

SSH in (NixOS AMIs use `root` with the EC2 key pair on first boot):

```bash
ssh -i your-key.pem root@ELASTIC_IP
```

Copy the configuration:

```bash
# From your local machine:
scp -i your-key.pem nixos/configuration.nix root@ELASTIC_IP:/etc/nixos/configuration.nix
```

Create the secrets file on the server:

```bash
cat > /etc/nixos/secrets.nix << 'EOF'
{
  stateVersion = "26.05";  # match the NixOS version of the AMI you launched
  domain = "storage.yourdomain.com";
  s3Bucket = "retroarch-saves-ACCOUNTID";
  s3Region = "us-east-1";
  retroarchUser = "retroarch";
  retroarchPasswordHash = "PASTE_HASH_HERE";
  adminUser = "myuser";
  adminPasswordHash = "PASTE_HASH_HERE";
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

Apply everything:

```bash
nixos-rebuild switch
```

From now on, SSH as `admin` (root login is disabled after the first rebuild):

```bash
ssh -i your-key.pem admin@ELASTIC_IP
```

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
| Password | (as set during setup) |
| Sync Saves | ON |
| Sync Configs | OFF |

All devices must match:
- Sort Saves into Folders by Core Name → **ON**
- Sort Save States into Folders by Core Name → **ON**

## Other clients

```bash
# rclone remote
rclone config create saves webdav url=https://storage.yourdomain.com user=retroarch pass=$(rclone obscure 'PASSWORD')
rclone copy ./photos saves:media/photos/ --progress

# curl
curl -T database.sql.gz -u retroarch:PASSWORD "https://storage.yourdomain.com/backups/database.sql.gz"
```

> **KDE Dolphin / KIO note:** KIO has a bug with HTTP/2 uploads — files larger than ~500KB may be silently corrupted. Use `rclone copy` for uploading. Dolphin is fine for browsing and downloading.

## Maintenance

All changes are made by editing `/etc/nixos/configuration.nix` and running:

```bash
sudo nixos-rebuild switch
```

### Rollback

```bash
sudo nixos-rebuild switch --rollback
# Or select a previous generation from the boot menu
```

### Rotate WebDAV password

```bash
nix-shell -p caddy --run "caddy hash-password --plaintext 'NEW_PASSWORD'"
sudo vim /etc/nixos/secrets.nix  # update webdavPasswordHash
sudo nixos-rebuild switch
```

### Check fail2ban

```bash
sudo fail2ban-client status
sudo fail2ban-client status caddy-auth
sudo fail2ban-client set caddy-auth unbanip 1.2.3.4
```

### Update NixOS

Happens automatically daily. To force:

```bash
sudo nix-channel --update
sudo nixos-rebuild switch
```

### Switch to unstable channel

Unstable is rolling release — no channel hops every 6 months. Trade-off is a small risk of occasional breakage (mitigated by NixOS rollback).

```bash
sudo nix-channel --add https://nixos.org/channels/nixos-unstable nixos
sudo nix-channel --update
sudo nixos-rebuild switch
```

### Upgrade to a new stable release

When a new stable release comes out (e.g., 26.11), point the channel to it:

```bash
sudo nix-channel --add https://nixos.org/channels/nixos-26.11 nixos
sudo nix-channel --update
sudo nixos-rebuild switch
```

No reinstall or new AMI needed. `system.stateVersion` in `secrets.nix` stays unchanged — it always reflects the version used at *initial* deployment.

## File structure

```
.
├── template.yaml              # CloudFormation (EC2, S3, IAM, alarms)
├── nixos/
│   ├── configuration.nix      # Full NixOS system config (→ /etc/nixos/)
│   └── secrets.nix.example    # Template for machine-specific secrets
└── README.md
```

## Data safety

- The EC2 instance is **stateless** — just a WebDAV-to-S3 proxy. Terminate and recreate freely.
- **S3 versioning** retains previous versions for 30 days.
- The instance role cannot delete object versions (`s3:DeleteObjectVersion` not granted).
- **NixOS rollback:** boot into any previous generation if a config change breaks things.

## Teardown

```bash
aws cloudformation delete-stack --stack-name cloud-storage
# S3 bucket is retained — delete manually if wanted:
aws s3 rb s3://retroarch-saves-ACCOUNT_ID --force
```
