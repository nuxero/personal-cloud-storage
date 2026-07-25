#!/bin/bash
# harden-fail2ban.sh
# Configures fail2ban to protect both SSH and the Caddy WebDAV endpoint
# against brute-force attacks.
#
# This script is safe to re-run (idempotent). It can be used on:
#   - An existing server that was set up before this protection was added
#   - A fresh server (setup-server.sh calls this automatically)
#
# What it does:
#   1. Enables Caddy access logging (required for fail2ban to see 401s)
#   2. Installs a fail2ban filter for Caddy auth failures (401 responses)
#   3. Installs a fail2ban filter for Caddy aggressive scanning (404 floods)
#   4. Creates jail definitions for both filters + SSH
#   5. Restarts fail2ban and reloads Caddy
#
# Usage:
#   sudo ./harden-fail2ban.sh

set -euo pipefail

# --- Must be root ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)."
  exit 1
fi

echo "=== fail2ban Hardening ==="
echo ""

# --- Step 1: Enable Caddy access logging ---
echo "[1/4] Enabling Caddy access logging..."

CADDYFILE="/etc/caddy/Caddyfile"

if [[ ! -f "$CADDYFILE" ]]; then
  echo "ERROR: Caddyfile not found at $CADDYFILE"
  exit 1
fi

# Add log directive if not already present.
if ! grep -q "output file /var/log/caddy/access.log" "$CADDYFILE"; then
  # Find the first line that ends with ' {' (the site block opener, e.g. "example.com {")
  LINE_NUM=$(grep -n '{[[:space:]]*$' "$CADDYFILE" | head -1 | cut -d: -f1)

  if [[ -z "$LINE_NUM" ]]; then
    echo "ERROR: Could not find site block opening brace in Caddyfile."
    echo "       Please add the log directive manually. See README."
    exit 1
  fi

  # Insert the log block after the site block opening line using sed
  sed -i "${LINE_NUM}a\\
    log {\\
        output file /var/log/caddy/access.log {\\
            roll_size 10MiB\\
            roll_keep 5\\
            roll_keep_for 14d\\
        }\\
    }" "$CADDYFILE"

  echo "  Added log directive to Caddyfile"
else
  echo "  Log directive already present"
fi

# Create log directory and empty log file (fail2ban needs the file to exist)
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy
if [[ ! -f /var/log/caddy/access.log ]]; then
  touch /var/log/caddy/access.log
  chown caddy:caddy /var/log/caddy/access.log
fi

# --- Step 2: Install fail2ban filters ---
echo "[2/4] Installing fail2ban filters..."

# Filter: Caddy authentication failures (401 responses)
# Matches Caddy's JSON access log format:
#   {"...","request":{"remote_ip":"1.2.3.4",...},"...","status":401,...}
cat > /etc/fail2ban/filter.d/caddy-auth.conf << 'EOF'
# fail2ban filter for Caddy basic_auth brute-force attempts.
# Matches JSON access log lines where status is 401 (Unauthorized).
#
# Caddy log format (single-line JSON):
#   {"level":"info","ts":1684090060.43,...,"request":{"remote_ip":"<IP>",...},...,"status":401,...}
#
# Requires fail2ban v0.11.0+ for Epoch datepattern support.

[Definition]

failregex = "remote_ip":"<HOST>".*"status":401

datepattern = "ts":{Epoch}

ignoreregex =
EOF

# Filter: Caddy path scanning (repeated 404s from same IP)
# Catches bots probing for /wp-admin, /.env, /phpmyadmin, etc.
cat > /etc/fail2ban/filter.d/caddy-botscan.conf << 'EOF'
# fail2ban filter for aggressive path scanning / vulnerability probes.
# Matches JSON access log lines where status is 404 (Not Found).
# Uses a higher maxretry threshold since legitimate 404s can occur.
#
# Caddy log format (single-line JSON):
#   {"level":"info","ts":1684090060.43,...,"request":{"remote_ip":"<IP>",...},...,"status":404,...}
#
# Requires fail2ban v0.11.0+ for Epoch datepattern support.

[Definition]

failregex = "remote_ip":"<HOST>".*"status":404

datepattern = "ts":{Epoch}

ignoreregex =
EOF

echo "  Installed /etc/fail2ban/filter.d/caddy-auth.conf"
echo "  Installed /etc/fail2ban/filter.d/caddy-botscan.conf"

# --- Step 3: Install jail configuration ---
echo "[3/4] Installing fail2ban jails..."

# Determine the correct SSH log path for this system.
# AL2023 uses /var/log/secure; Debian/Ubuntu use /var/log/auth.log.
if [[ -f /var/log/secure ]]; then
  SSH_LOGPATH="/var/log/secure"
elif [[ -f /var/log/auth.log ]]; then
  SSH_LOGPATH="/var/log/auth.log"
else
  SSH_LOGPATH="%(sshd_log)s"
fi

cat > /etc/fail2ban/jail.d/webdav.conf << EOF
# Jails for the Caddy WebDAV server.
# These supplement the default sshd jail.

# --- SSH (override defaults for tighter protection) ---
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = ${SSH_LOGPATH}
maxretry = 5
findtime = 600
bantime  = 3600
backend  = auto

# --- Caddy WebDAV authentication brute-force ---
# Ban IP after 5 failed login attempts within 10 minutes.
# Ban lasts 1 hour. Protects the basic_auth endpoint.
[caddy-auth]
enabled  = true
port     = http,https
filter   = caddy-auth
logpath  = /var/log/caddy/access.log
maxretry = 5
findtime = 600
bantime  = 3600
backend  = auto

# --- Caddy path scanning / vulnerability probes ---
# Ban IP after 15 consecutive 404s within 5 minutes.
# Catches bots probing for /wp-admin, /.env, /phpmyadmin, etc.
# Higher threshold to avoid false positives from typos.
[caddy-botscan]
enabled  = true
port     = http,https
filter   = caddy-botscan
logpath  = /var/log/caddy/access.log
maxretry = 15
findtime = 300
bantime  = 3600
backend  = auto
EOF

echo "  Installed /etc/fail2ban/jail.d/webdav.conf"
echo "  SSH log path: ${SSH_LOGPATH}"

# --- Step 4: Restart services ---
echo "[4/4] Restarting services..."

# Reload Caddy to pick up log directive
systemctl reload caddy 2>/dev/null || systemctl restart caddy
echo "  Caddy reloaded (access logging active)"

# Restart fail2ban to load new filters and jails
systemctl restart fail2ban
echo "  fail2ban restarted"

# Give fail2ban a moment to initialize
sleep 3

# --- Verify ---
echo ""
echo "=== Verification ==="
echo ""

# Show active jails
echo "Active jails:"
fail2ban-client status 2>/dev/null | grep "Jail list" || echo "  (fail2ban still starting — run 'sudo fail2ban-client status' in a few seconds)"
echo ""

# Show status of each jail
for jail in sshd caddy-auth caddy-botscan; do
  echo "--- $jail ---"
  fail2ban-client status "$jail" 2>/dev/null || echo "  (not yet active — check: sudo journalctl -u fail2ban -n 20)"
  echo ""
done

echo "=========================================="
echo "  HARDENING COMPLETE"
echo "=========================================="
echo ""
echo "  Jails configured:"
echo "    - sshd:          5 failures / 10 min → 1 hour ban"
echo "    - caddy-auth:    5 failures / 10 min → 1 hour ban"
echo "    - caddy-botscan: 15 hits    /  5 min → 1 hour ban"
echo ""
echo "  Useful commands:"
echo "    sudo fail2ban-client status              # list active jails"
echo "    sudo fail2ban-client status caddy-auth   # check auth jail"
echo "    sudo fail2ban-client set caddy-auth unbanip <IP>  # manually unban"
echo "    sudo tail -f /var/log/caddy/access.log   # watch requests"
echo "    sudo journalctl -u fail2ban -f           # watch bans"
echo ""
echo "  If fail2ban failed to start, check:"
echo "    sudo journalctl -u fail2ban -n 30"
echo "    sudo fail2ban-client -t                  # test config"
echo ""
