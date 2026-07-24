#!/bin/bash
# setup-server.sh
# Configures an EC2 instance (Amazon Linux 2023 / ARM64) as a secure
# rclone WebDAV server backed by S3 for RetroArch cloud saves.
#
# Usage:
#   sudo ./setup-server.sh --domain saves.example.com \
#     --bucket retroarch-saves-123456 --region us-east-1
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

echo "=== RetroArch WebDAV Server Setup ==="
echo "  Domain: $DOMAIN"
echo "  Bucket: $BUCKET"
echo "  Region: $REGION"
echo "  User:   $WEBDAV_USER"
echo ""

# --- Install dependencies ---
echo "[1/6] Installing packages..."
dnf install -y unzip httpd-tools certbot fail2ban dnf-automatic

# --- Install rclone ---
echo "[2/6] Installing rclone..."
if ! command -v rclone &>/dev/null; then
  curl -fsSL https://rclone.org/install.sh | bash
fi
RCLONE_BIN=$(command -v rclone)
echo "  $(rclone --version | head -1) (${RCLONE_BIN})"

# --- Configure rclone (uses IAM instance role — no access keys) ---
echo "[3/6] Configuring rclone..."
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

# --- Create htpasswd ---
htpasswd -Bbc /home/ec2-user/htpasswd "$WEBDAV_USER" "$WEBDAV_PASS"
chown ec2-user:ec2-user /home/ec2-user/htpasswd
chmod 600 /home/ec2-user/htpasswd
echo "  htpasswd created (bcrypt)"

# --- TLS certificate ---
echo "[4/6] Obtaining TLS certificate..."
certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "admin@${DOMAIN}" \
  -d "$DOMAIN"

CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ ! -f "$CERT_PATH" ]]; then
  echo "ERROR: Certificate not found at $CERT_PATH"
  echo "Ensure DNS A record points to this instance's Elastic IP."
  exit 1
fi

chmod 755 /etc/letsencrypt/live/
chmod 755 /etc/letsencrypt/archive/
chmod 644 "/etc/letsencrypt/archive/${DOMAIN}/"fullchain*.pem
chmod 640 "/etc/letsencrypt/archive/${DOMAIN}/"privkey*.pem
chgrp ec2-user "/etc/letsencrypt/archive/${DOMAIN}/"privkey*.pem
echo "  Certificate obtained"

# --- Systemd services ---
echo "[5/6] Creating services..."

cat > /etc/systemd/system/rclone-webdav.service << EOF
[Unit]
Description=rclone WebDAV server for RetroArch cloud saves
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
ExecStart=${RCLONE_BIN} serve webdav s3-saves:${BUCKET} \\
  --addr :443 \\
  --cert ${CERT_PATH} \\
  --key ${KEY_PATH} \\
  --htpasswd /home/ec2-user/htpasswd \\
  --vfs-cache-mode minimal \\
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
chown ec2-user:ec2-user /home/ec2-user/.cache/rclone

# Cert renewal
cat > /etc/systemd/system/certbot-renew.service << 'EOF'
[Unit]
Description=Certbot renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl restart rclone-webdav"
EOF

cat > /etc/systemd/system/certbot-renew.timer << 'EOF'
[Unit]
Description=Certbot renewal timer

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Health check — restarts rclone if unresponsive
cat > /usr/local/bin/webdav-healthcheck.sh << HEALTHEOF
#!/bin/bash
if ! systemctl is-active --quiet rclone-webdav; then
  systemctl restart rclone-webdav
  exit 0
fi
HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "${WEBDAV_USER}:${WEBDAV_PASS}" "https://localhost/" -k 2>/dev/null)
if [[ "\$HTTP_CODE" != "200" && "\$HTTP_CODE" != "207" ]]; then
  systemctl restart rclone-webdav
fi
HEALTHEOF
chmod 700 /usr/local/bin/webdav-healthcheck.sh

cat > /etc/systemd/system/webdav-healthcheck.service << 'EOF'
[Unit]
Description=WebDAV health check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/webdav-healthcheck.sh
EOF

cat > /etc/systemd/system/webdav-healthcheck.timer << 'EOF'
[Unit]
Description=WebDAV health check (every 5 min)

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- Hardening + auto-updates ---
echo "[6/6] Hardening..."
systemctl enable --now fail2ban
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic-install.timer

# --- Start everything ---
systemctl daemon-reload
systemctl enable --now rclone-webdav
systemctl enable --now certbot-renew.timer
systemctl enable --now webdav-healthcheck.timer

sleep 2
if systemctl is-active --quiet rclone-webdav; then
  echo ""
  echo "=========================================="
  echo "  SETUP COMPLETE"
  echo "=========================================="
  echo ""
  echo "  Endpoint: https://${DOMAIN}/"
  echo "  Username: ${WEBDAV_USER}"
  echo ""
  echo "  RetroArch Cloud Sync settings:"
  echo "    Backend:  WebDAV"
  echo "    URL:      https://${DOMAIN}/"
  echo "    Username: ${WEBDAV_USER}"
  echo "    Password: (as entered)"
  echo ""
  echo "  Commands:"
  echo "    sudo systemctl status rclone-webdav"
  echo "    sudo journalctl -u rclone-webdav -f"
  echo "    sudo -u ec2-user rclone ls s3-saves:${BUCKET}"
  echo "=========================================="
else
  echo "ERROR: Service failed to start."
  echo "Check: sudo journalctl -u rclone-webdav -n 20"
  exit 1
fi
