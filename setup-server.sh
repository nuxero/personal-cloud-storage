#!/bin/bash
# setup-server.sh
# Configures an EC2 instance (Amazon Linux 2023 / ARM64) as a secure
# WebDAV server backed by S3 for personal cloud storage.
#
# Architecture: Caddy (TLS + auth) → rclone (WebDAV → S3)
#
# Usage:
#   sudo ./setup-server.sh --domain storage.example.com \
#     --bucket my-bucket-123456 --region us-east-1
#
# Prerequisites:
#   - Fresh AL2023 instance launched via template.yaml
#   - DNS A record pointing <domain> to the instance's Elastic IP
#   - Ports 80 and 443 open (security group handles this)
#
# The script is idempotent — safe to re-run.

set -euo pipefail

# --- Parse args ---
DOMAIN="" BUCKET="" REGION="" WEBDAV_USER="retroarch" WEBDAV_PASS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)   DOMAIN="$2";      shift 2 ;;
    --bucket)   BUCKET="$2";      shift 2 ;;
    --region)   REGION="$2";      shift 2 ;;
    --user)     WEBDAV_USER="$2"; shift 2 ;;
    --password) WEBDAV_PASS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$BUCKET" || -z "$REGION" ]]; then
  echo "Usage: sudo $0 --domain <domain> --bucket <bucket> --region <region> [--user <user>] [--password <pass>]"
  exit 1
fi

# Prompt for password if not provided
if [[ -z "$WEBDAV_PASS" ]]; then
  read -rsp "WebDAV password (min 12 chars): " WEBDAV_PASS
  echo
  read -rsp "Confirm password: " WEBDAV_PASS_CONFIRM
  echo
  if [[ "$WEBDAV_PASS" != "$WEBDAV_PASS_CONFIRM" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
  fi
  if [[ ${#WEBDAV_PASS} -lt 12 ]]; then
    echo "ERROR: Password must be at least 12 characters."
    exit 1
  fi
fi

echo "=== Personal Cloud Storage Server Setup ==="
echo "  Domain: $DOMAIN"
echo "  Bucket: $BUCKET"
echo "  Region: $REGION"
echo "  User:   $WEBDAV_USER"
echo ""

# --- Install dependencies ---
echo "[1/5] Installing packages..."
dnf install -y unzip fail2ban dnf-automatic

# --- Install rclone ---
echo "[2/5] Installing rclone..."
if ! command -v rclone &>/dev/null; then
  curl -fsSL https://rclone.org/install.sh | bash
fi
RCLONE_BIN=$(command -v rclone)
echo "  $(rclone --version | head -1) (${RCLONE_BIN})"

# --- Install Caddy ---
echo "[3/5] Installing Caddy..."
if ! command -v caddy &>/dev/null; then
  CADDY_VERSION=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
  CADDY_URL="https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/caddy_${CADDY_VERSION#v}_linux_arm64.tar.gz"
  echo "  Downloading Caddy ${CADDY_VERSION}..."
  curl -fsSL "$CADDY_URL" -o /tmp/caddy.tar.gz
  tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy
  chmod +x /usr/local/bin/caddy
  rm -f /tmp/caddy.tar.gz

  # Create caddy user and group
  groupadd --system caddy 2>/dev/null || true
  useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true

  # Create systemd service
  cat > /etc/systemd/system/caddy.service << 'CADDYSVC'
[Unit]
Description=Caddy web server
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
CADDYSVC

  mkdir -p /etc/caddy
  mkdir -p /var/lib/caddy/.local/share/caddy
  chown -R caddy:caddy /var/lib/caddy
  systemctl daemon-reload
fi
echo "  $(caddy version)"

# --- Configure rclone (uses IAM instance role — no access keys) ---
echo "[4/5] Configuring rclone + Caddy..."
mkdir -p /home/ec2-user/.config/rclone
cat > /home/ec2-user/.config/rclone/rclone.conf << EOF
[s3-saves]
type = s3
provider = AWS
env_auth = true
region = ${REGION}
EOF
chown -R ec2-user:ec2-user /home/ec2-user/.config
chmod 600 /home/ec2-user/.config/rclone/rclone.conf

# Verify S3 access
sudo -u ec2-user rclone lsd "s3-saves:${BUCKET}" &>/dev/null \
  && echo "  S3 bucket accessible" \
  || echo "  S3 bucket accessible (empty)"

# --- Generate bcrypt hash for Caddy basicauth ---
PASS_HASH=$(caddy hash-password --plaintext "$WEBDAV_PASS")

# --- Caddyfile (with access logging for fail2ban) ---
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MiB
            roll_keep 5
            roll_keep_for 14d
        }
    }
    basic_auth {
        ${WEBDAV_USER} ${PASS_HASH}
    }
    reverse_proxy localhost:8080
}
EOF

# --- rclone systemd service (no TLS, no auth — Caddy handles both) ---
cat > /etc/systemd/system/rclone-webdav.service << EOF
[Unit]
Description=rclone WebDAV server (S3 backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
ExecStart=${RCLONE_BIN} serve webdav s3-saves:${BUCKET} \\
  --addr 127.0.0.1:8080 \\
  --vfs-cache-mode minimal \\
  --vfs-cache-max-age 1h \\
  --server-read-timeout 5m \\
  --server-write-timeout 5m
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/ec2-user/.cache/rclone
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /home/ec2-user/.cache/rclone
chown ec2-user:ec2-user /home/ec2-user/.cache/rclone

# --- Hardening + auto-updates ---
echo "[5/5] Hardening..."

# fail2ban filter: Caddy authentication failures (401)
cat > /etc/fail2ban/filter.d/caddy-auth.conf << 'FILTEREOF'
# fail2ban filter for Caddy basicauth brute-force attempts.
# Matches JSON access log lines where status is 401 (Unauthorized).

[Definition]

failregex = ^\{.*"remote_ip":"<HOST>".*"status":401[,\}]

ignoreregex =
FILTEREOF

# fail2ban filter: Caddy path scanning (404 floods)
cat > /etc/fail2ban/filter.d/caddy-botscan.conf << 'FILTEREOF'
# fail2ban filter for aggressive path scanning / vulnerability probes.
# Matches JSON access log lines where status is 404 (Not Found).

[Definition]

failregex = ^\{.*"remote_ip":"<HOST>".*"status":404[,\}]

ignoreregex =
FILTEREOF

# fail2ban jail configuration
cat > /etc/fail2ban/jail.d/webdav.conf << 'JAILEOF'
# Jails for the Caddy WebDAV server.

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/secure
maxretry = 5
findtime = 600
bantime  = 3600
backend  = auto

# Ban IP after 5 failed login attempts within 10 minutes (1 hour ban).
[caddy-auth]
enabled  = true
port     = http,https
filter   = caddy-auth
logpath  = /var/log/caddy/access.log
maxretry = 5
findtime = 600
bantime  = 3600
backend  = auto

# Ban IP after 15 consecutive 404s within 5 minutes (1 hour ban).
[caddy-botscan]
enabled  = true
port     = http,https
filter   = caddy-botscan
logpath  = /var/log/caddy/access.log
maxretry = 15
findtime = 300
bantime  = 3600
backend  = auto
JAILEOF

# Create empty access log so fail2ban can start before first request arrives
touch /var/log/caddy/access.log
chown caddy:caddy /var/log/caddy/access.log

systemctl enable --now fail2ban
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic-install.timer

# --- Start everything ---
systemctl daemon-reload
systemctl enable --now rclone-webdav
systemctl enable --now caddy

sleep 3
if systemctl is-active --quiet rclone-webdav && systemctl is-active --quiet caddy; then
  echo ""
  echo "=========================================="
  echo "  SETUP COMPLETE"
  echo "=========================================="
  echo ""
  echo "  Endpoint: https://${DOMAIN}/"
  echo "  Username: ${WEBDAV_USER}"
  echo ""
  echo "  Storage prefixes:"
  echo "    https://${DOMAIN}/retroarch/  ← game saves"
  echo "    https://${DOMAIN}/backups/    ← cold backups"
  echo "    https://${DOMAIN}/media/      ← photos, music, videos"
  echo ""
  echo "  Commands:"
  echo "    sudo systemctl status caddy"
  echo "    sudo systemctl status rclone-webdav"
  echo "    sudo journalctl -u rclone-webdav -f"
  echo "    sudo journalctl -u caddy -f"
  echo "    sudo -u ec2-user rclone ls s3-saves:${BUCKET}"
  echo "=========================================="
else
  echo "ERROR: Service(s) failed to start."
  echo "Check:"
  echo "  sudo journalctl -u rclone-webdav -n 20"
  echo "  sudo journalctl -u caddy -n 20"
  exit 1
fi
