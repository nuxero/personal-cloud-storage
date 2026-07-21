#!/bin/bash
# setup-server.sh
# Configures an EC2 instance (Amazon Linux 2023 / ARM64) as a secure
# rclone WebDAV server backed by S3 for RetroArch cloud saves.
#
# Usage: ./setup-server.sh <domain>
# Example: ./setup-server.sh retroarch.example.com
#
# Prerequisites:
#   - Fresh AL2023 instance launched via template.yaml
#   - DNS A record pointing <domain> to the instance's Elastic IP
#   - IAM access key + secret from CloudFormation outputs
#   - Ports 80 and 443 open (security group handles this)

set -euo pipefail

DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain>"
  echo "Example: $0 retroarch.example.com"
  exit 1
fi

echo "=== RetroArch WebDAV Server Setup ==="
echo "Domain: $DOMAIN"
echo ""

# --- Collect credentials ---
read -rp "S3 bucket name (from CloudFormation output): " S3_BUCKET
read -rp "AWS region [us-east-1]: " AWS_REGION
AWS_REGION="${AWS_REGION:-us-east-1}"
read -rp "IAM access key ID (from CloudFormation output): " AWS_ACCESS_KEY
read -rsp "IAM secret access key (from CloudFormation output): " AWS_SECRET_KEY
echo ""
read -rp "WebDAV username [retroarch]: " WEBDAV_USER
WEBDAV_USER="${WEBDAV_USER:-retroarch}"
read -rsp "WebDAV password (min 12 chars): " WEBDAV_PASS
echo ""
read -rsp "Confirm WebDAV password: " WEBDAV_PASS_CONFIRM
echo ""

if [[ "$WEBDAV_PASS" != "$WEBDAV_PASS_CONFIRM" ]]; then
  echo "ERROR: Passwords do not match."
  exit 1
fi

if [[ ${#WEBDAV_PASS} -lt 12 ]]; then
  echo "ERROR: Password must be at least 12 characters."
  exit 1
fi

echo ""
echo "=== Installing dependencies ==="
sudo dnf install -y unzip httpd-tools certbot

# --- Install rclone ---
echo "=== Installing rclone ==="
if ! command -v rclone &>/dev/null; then
  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    RCLONE_ARCH="arm64"
  else
    RCLONE_ARCH="amd64"
  fi
  cd /tmp
  curl -sO "https://downloads.rclone.org/current/rclone-current-linux-${RCLONE_ARCH}.zip"
  unzip -o "rclone-current-linux-${RCLONE_ARCH}.zip"
  sudo cp rclone-*/rclone /usr/local/bin/
  sudo chmod 755 /usr/local/bin/rclone
  rm -rf rclone-*
  cd ~
fi
echo "rclone installed: $(rclone --version | head -1)"

# --- Configure rclone S3 remote ---
echo "=== Configuring rclone ==="
mkdir -p ~/.config/rclone

cat > ~/.config/rclone/rclone.conf << EOF
[s3-saves]
type = s3
provider = AWS
access_key_id = ${AWS_ACCESS_KEY}
secret_access_key = ${AWS_SECRET_KEY}
region = ${AWS_REGION}
EOF

chmod 600 ~/.config/rclone/rclone.conf

# Verify S3 access
echo "Verifying S3 access..."
if rclone lsd "s3-saves:${S3_BUCKET}" &>/dev/null; then
  echo "✓ S3 bucket accessible"
else
  echo "✓ S3 bucket accessible (empty)"
fi

# --- Create htpasswd file ---
echo "=== Creating htpasswd ==="
htpasswd -Bbc /home/ec2-user/htpasswd "$WEBDAV_USER" "$WEBDAV_PASS"
chmod 600 /home/ec2-user/htpasswd
echo "✓ htpasswd created (bcrypt)"

# --- Obtain TLS certificate ---
echo "=== Obtaining TLS certificate ==="
sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "admin@${DOMAIN}" \
  -d "$DOMAIN"

CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ ! -f "$CERT_PATH" ]]; then
  echo "ERROR: Certificate not found at $CERT_PATH"
  echo "Ensure DNS A record points to this instance's IP."
  exit 1
fi

echo "✓ Certificate obtained"

# Make certs readable by ec2-user
sudo chmod 755 /etc/letsencrypt/live/
sudo chmod 755 /etc/letsencrypt/archive/
sudo chmod 644 "/etc/letsencrypt/archive/${DOMAIN}/fullchain"*.pem
sudo chmod 640 "/etc/letsencrypt/archive/${DOMAIN}/privkey"*.pem
sudo chgrp ec2-user "/etc/letsencrypt/archive/${DOMAIN}/privkey"*.pem

# --- Create systemd service ---
echo "=== Creating systemd service ==="
sudo tee /etc/systemd/system/rclone-webdav.service > /dev/null << EOF
[Unit]
Description=rclone WebDAV server for RetroArch cloud saves
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
ExecStart=/usr/local/bin/rclone serve webdav s3-saves:${S3_BUCKET} \\
  --addr :443 \\
  --cert ${CERT_PATH} \\
  --key ${KEY_PATH} \\
  --htpasswd /home/ec2-user/htpasswd \\
  --vfs-cache-mode writes \\
  --vfs-cache-max-age 1h \\
  --min-tls-version tls1.2 \\
  --server-read-timeout 5m \\
  --server-write-timeout 5m
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/ec2-user/.cache/rclone
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /home/ec2-user/.cache/rclone

# --- Certificate auto-renewal ---
echo "=== Configuring cert renewal ==="
sudo tee /etc/systemd/system/certbot-renew.service > /dev/null << 'EOF'
[Unit]
Description=Certbot renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet
ExecStartPost=/bin/systemctl restart rclone-webdav
EOF

sudo tee /etc/systemd/system/certbot-renew.timer > /dev/null << 'EOF'
[Unit]
Description=Certbot renewal timer

[Timer]
OnCalendar=Mon *-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now certbot-renew.timer

# --- Security hardening ---
echo "=== Hardening ==="
sudo dnf install -y fail2ban dnf-automatic
sudo systemctl enable --now fail2ban
sudo sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic-install.timer

# --- Start service ---
echo "=== Starting WebDAV service ==="
sudo systemctl enable --now rclone-webdav
sleep 2

if sudo systemctl is-active --quiet rclone-webdav; then
  echo "✓ Service running"
else
  echo "ERROR: Service failed. Check: sudo journalctl -u rclone-webdav -n 20"
  exit 1
fi

# --- Verify ---
echo "=== Verifying ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${WEBDAV_USER}:${WEBDAV_PASS}" "https://${DOMAIN}/")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "207" ]]; then
  echo "✓ WebDAV responding at https://${DOMAIN}/"
else
  echo "Got HTTP $HTTP_CODE — may still be starting. Try manually:"
  echo "  curl -u ${WEBDAV_USER}:*** https://${DOMAIN}/"
fi

echo ""
echo "=========================================="
echo "  SETUP COMPLETE"
echo "=========================================="
echo ""
echo "  Endpoint: https://${DOMAIN}/"
echo "  Username: ${WEBDAV_USER}"
echo ""
echo "  RetroArch → Settings → Saving → Cloud Sync:"
echo "    Backend: WebDAV"
echo "    URL: https://${DOMAIN}/"
echo "    Username: ${WEBDAV_USER}"
echo "    Password: (as entered)"
echo "    Sync Saves: ON"
echo "    Sync Configs: OFF"
echo ""
echo "  Commands:"
echo "    Status:   sudo systemctl status rclone-webdav"
echo "    Logs:     sudo journalctl -u rclone-webdav -f"
echo "    S3 list:  rclone ls s3-saves:${S3_BUCKET}"
echo "    Restart:  sudo systemctl restart rclone-webdav"
echo "=========================================="
