# personal-cloud-storage

Personal cloud storage server using S3 + WebDAV, managed declaratively with NixOS. Serves multiple use cases (game saves, backups, media) from a single endpoint with logical separation via path prefixes.

## Architecture

```
┌─────────────┐          ┌────────────────────────────────────┐          ┌─────────────┐
│   Clients   │── HTTPS ►│       EC2 (t4g.nano, NixOS)        │── S3 ───►│  S3 Bucket  │
│             │          │  ┌───────┐       ┌──────────────┐  │          │  (versioned)│
│ • RetroArch │◄─────────│  │ Caddy │──────►│ rclone serve │  │◄─────────│             │
│ • Backup    │          │  │ :443  │ proxy │ webdav :8080 │  │          └─────────────┘
│ • Diffuse   │          │  │ TLS+  │       │ (localhost)  │  │
│ • Dolphin   │          │  │ Auth+ │       └──────────────┘  │
│             │          │  │ CORS  │                         │
└─────────────┘          │  └───────┘                         │
                         └────────────────────────────────────┘
```

**OS:** NixOS (unstable/rolling channel) — entire server configuration is declarative and reproducible.

**Cost:** ~$12/month (EC2) + pennies (S3).

## Storage layout

```
s3:bucket/
├── retroarch/       ← game saves and states
├── backups/         ← cold backups (databases, configs, etc.)
└── media/
    ├── music/       ← music library (Diffuse player)
    ├── photos/      ← photos
    └── videos/      ← videos
```

Clients target their respective path:
- `https://storage.yourdomain.com/retroarch/`
- `https://storage.yourdomain.com/backups/`
- `https://storage.yourdomain.com/media/`
- `https://storage.yourdomain.com/media/music/` (Diffuse)

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

### The NixOS AMI — use the custom larger-`/boot` build

> **Important:** launch from the **custom AMI** built via [`ami/`](ami/README.md),
> not a stock NixOS AMI. The stock image's 256MiB `/boot` is too small for arm64
> kernels and fills up after a few generations. The custom AMI is identical to
> stock except `/boot` is 1GiB. Build it once, then reuse its AMI ID.

Stock AMIs (only if you understand the `/boot` limitation):

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
  djUser = "dj";
  djPassword = "PASTE_HASH_HERE";
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
| OS upgrades | NixOS `system.autoUpgrade` (weekly Mon 04:00, nixos-unstable, auto-reboot) |
| SSH brute force | fail2ban (built-in NixOS sshd jail) |
| WebDAV brute force | fail2ban (`caddy-auth` jail) |
| Vulnerability scanning | fail2ban (`caddy-botscan` jail) |
| Old Nix generations | Garbage-collected daily (older than 3 days); GRUB keeps last 3 boot entries |

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

## Configure Diffuse

[Diffuse](https://diffuse.sh) is a static web-based music player that connects directly to your WebDAV server. Since it runs in the browser at `https://diffuse.sh`, CORS headers are configured in Caddy to allow cross-origin requests.

### Upload your music

```bash
# Using rclone (recommended for bulk uploads)
rclone copy ~/Music saves:media/music/ --progress

# Or curl for individual files
curl -T song.mp3 -u dj:PASSWORD "https://storage.yourdomain.com/media/music/song.mp3"
```

### Add the source in Diffuse

1. Open [diffuse.sh](https://diffuse.sh)
2. Go to **Sources** (⚙ icon)
3. Click **Add source** → **WebDAV**
4. Fill in:

| Field | Value |
|-------|-------|
| URL | `https://storage.yourdomain.com/media/music/` |
| Username | `dj` |
| Password | (as set during setup) |

5. Click **Save** and then **Process sources** to scan your library

### Supported formats

Diffuse plays whatever your browser supports — typically MP3, FLAC, OGG, WAV, AAC, and OPUS. Organize your files however you like (folders by artist, album, etc.) — Diffuse reads metadata from the files themselves.

### Access control

The `dj` user can only access `/media/*`. If you prefer, you can use your admin credentials instead for full access to all paths.

## Other clients

```bash
# rclone remote
rclone config create saves webdav url=https://storage.yourdomain.com user=retroarch pass=$(rclone obscure 'PASSWORD')
rclone copy ./photos saves:media/photos/ --progress

# curl
curl -T database.sql.gz -u retroarch:PASSWORD "https://storage.yourdomain.com/backups/database.sql.gz"
```

> **KDE Dolphin / KIO note:** KIO uses non-preemptive auth (sends each request without credentials first, gets a 401, then retries with auth). The fail2ban `caddy-auth` filter only matches 401s where an `Authorization` header was present (wrong credentials), so Dolphin's challenge-response 401s are never counted. Additionally, KIO has a bug with HTTP/2 uploads — files larger than ~500KB may be silently corrupted. Use `rclone copy` for uploading. Dolphin is fine for browsing and downloading.

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

The server tracks **nixos-unstable** (rolling release) and upgrades
automatically every **Monday at 04:00**, rebooting if the kernel changed, via
`system.autoUpgrade` in `configuration.nix`.

Because the custom AMI (see [`ami/`](ami/README.md)) is built from
nixos-unstable, root's system channel is already unstable at first boot. So both
automatic upgrades and manual rebuilds track unstable with **no extra steps and
no stable/unstable split** — there's no `channel` override to maintain.

To force an upgrade manually:

```bash
sudo nixos-rebuild switch --upgrade
```

> If you ever launch from a **stock stable AMI** instead of the custom one,
> either re-point the channel once (`sudo nix-channel --add
> https://channels.nixos.org/nixos-unstable nixos && sudo nix-channel --update`)
> or add `channel = "https://channels.nixos.org/nixos-unstable";` to
> `system.autoUpgrade`.

Rolling release means no 6-month channel hops. Trade-off is a small risk of
occasional breakage, mitigated by NixOS rollback (and the weekly cadence lets
you catch issues without being on the bleeding edge daily).

`system.stateVersion` in `secrets.nix` stays unchanged regardless of upgrades —
it always reflects the version used at *initial* deployment and is a
compatibility marker, not a channel selector.

## File structure

```
.
├── template.yaml              # CloudFormation (EC2, S3, IAM, alarms)
├── nixos/
│   ├── configuration.nix      # Full NixOS system config (→ /etc/nixos/)
│   └── secrets.nix.example    # Template for machine-specific secrets
├── ami/                       # Custom AMI with larger /boot (see ami/README.md)
│   ├── image.nix              # Nix expression for the aarch64 amazon image
│   ├── build.sh               # Build VHD → import snapshot → register AMI
│   └── setup-vmimport-role.sh # One-time vmimport IAM role setup
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
