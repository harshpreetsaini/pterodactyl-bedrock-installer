#!/bin/bash
set -euo pipefail

# ===================== CONFIG =====================
# Script uses files/ from the same directory – keep them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGG_FILE="$SCRIPT_DIR/files/egg-bedrock-modern.json"
THEME_FILE="$SCRIPT_DIR/files/theme-dark.css"
THEME_NAME="darkmodern"
PLAYIT_DIR="/opt/playit"
PANEL_PATH="/var/www/pterodactyl"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+] $1${NC}"; }
warn()  { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[-] $1${NC}"; exit 1; }

# ===================== USER PROMPTS =====================
read -rp "Panel domain (e.g. panel.example.com): " PANEL_DOMAIN
read -rp "Admin email: " ADMIN_EMAIL
if [[ -z "$ADMIN_EMAIL" ]]; then
  error "Admin email is required."
fi
ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
echo "Generated admin password: $ADMIN_PASS"

# ===================== SYSTEM PREP =====================
info "Updating system and installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget gnupg ca-certificates lsb-release ufw fail2ban certbot python3-certbot-nginx nginx-extras jq unzip sqlite3

info "Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 19132:19133/udp
ufw allow from 127.0.0.1 to any port 8080 proto tcp
ufw --force enable

info "Installing Docker..."
curl -fsSL https://get.docker.com | bash -s -- --version 24
systemctl enable --now docker

# ===================== PTERODACTYL INSTALLER =====================
info "Running Pterodactyl auto‑installer (panel + wings)..."
export PTERODACTYL_PANEL_DOMAIN="$PANEL_DOMAIN"
export PTERODACTYL_PANEL_SSL="letsencrypt"
export PTERODACTYL_PANEL_LETSENCRYPT_EMAIL="$ADMIN_EMAIL"
export PTERODACTYL_PANEL_ADMIN_EMAIL="$ADMIN_EMAIL"
export PTERODACTYL_PANEL_ADMIN_PASSWORD="$ADMIN_PASS"
export PTERODACTYL_TIMEZONE="UTC"
export PTERODACTYL_WINGS_ENABLED="true"
export PTERODACTYL_WINGS_NODE_NAME="Node1"
export PTERODACTYL_WINGS_USE_SSL="true"

curl -sSL https://pterodactyl-installer.se/install.sh | bash -s -- --panel --wings --node --skip-database-install

PANEL_URL="https://${PANEL_DOMAIN}"
info "Panel installed at $PANEL_URL"

# Wait for panel to fully start
sleep 30

# ===================== EXTRACT API KEY =====================
cd "$PANEL_PATH"
info "Generating admin API token..."
php artisan p:user:token:generate --user=1 --name="AutoInstall" > /tmp/ptero_token.txt
API_TOKEN=$(grep 'Token:' /tmp/ptero_token.txt | awk '{print $2}')
rm /tmp/ptero_token.txt

if [[ -z "$API_TOKEN" ]]; then
  error "Could not obtain API token. Check panel logs."
fi

# ===================== PLAYIT.GG AGENT (node‑level) =====================
info "Setting up Playit.gg agent..."
mkdir -p "$PLAYIT_DIR"
wget -qO "$PLAYIT_DIR/playit-agent" "https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-amd64"
chmod +x "$PLAYIT_DIR/playit-agent"

# Start briefly to capture claim URL
timeout 15 "$PLAYIT_DIR/playit-agent" --secret "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)" > /tmp/playit_init.log 2>&1 || true
CLAIM_URL=$(grep -o 'https://playit.gg/claim/[a-zA-Z0-9]*' /tmp/playit_init.log || echo "Claim URL not found – run agent manually")

# Create systemd service
cat > /etc/systemd/system/playit-agent.service <<EOF
[Unit]
Description=Playit.gg Tunnel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$PLAYIT_DIR/playit-agent --secret \$(cat $PLAYIT_DIR/secret)
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "REPLACE_WITH_YOUR_PLAYIT_SECRET" > "$PLAYIT_DIR/secret"
systemctl daemon-reload
systemctl enable playit-agent

# Public claim page
mkdir -p "$PANEL_PATH/public/playit"
cat > "$PANEL_PATH/public/playit/index.html" <<EOF
<html><body style="background:#121212;color:#fff;font-family:sans-serif;padding:2rem;">
<h1>Playit Agent Claim</h1>
<p>Claim link: <a href="$CLAIM_URL" style="color:#4caf50;">$CLAIM_URL</a></p>
<p>After claiming, replace the secret in <code>/opt/playit/secret</code> with your Playit secret key, then run <code>systemctl restart playit-agent</code>.</p>
</body></html>
EOF

# ===================== CUSTOM EGG IMPORT =====================
info "Importing custom Bedrock egg..."
if [ ! -f "$EGG_FILE" ]; then
  error "Egg file not found at $EGG_FILE. Place egg-bedrock-modern.json in files/."
fi

# Create nest
NEST_RESPONSE=$(curl -s -X POST "$PANEL_URL/api/application/nests" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Bedrock","description": "Custom Bedrock eggs"}')
NEST_ID=$(echo "$NEST_RESPONSE" | jq -r '.attributes.id')
if [[ "$NEST_ID" == "null" || -z "$NEST_ID" ]]; then
  error "Failed to create nest: $NEST_RESPONSE"
fi

# Import egg
EGG_RESPONSE=$(curl -s -X POST "$PANEL_URL/api/application/nests/$NEST_ID/eggs" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$EGG_FILE")
info "Egg imported (Nest ID: $NEST_ID)"

# ===================== DARK THEME =====================
info "Applying custom dark theme..."
mkdir -p "$PANEL_PATH/public/themes/$THEME_NAME/css"
cp "$THEME_FILE" "$PANEL_PATH/public/themes/$THEME_NAME/css/pterodactyl.css"

# Set as default theme
if grep -q "APP_THEME=" "$PANEL_PATH/.env"; then
  sed -i "s|APP_THEME=.*|APP_THEME=$THEME_NAME|" "$PANEL_PATH/.env"
else
  echo "APP_THEME=$THEME_NAME" >> "$PANEL_PATH/.env"
fi
php artisan config:cache && php artisan view:clear

# ===================== FAIL2BAN =====================
info "Configuring Fail2ban for panel..."
cat > /etc/fail2ban/filter.d/pterodactyl.conf <<'EOF'
[Definition]
failregex = ^.*Invalid credentials provided.*$
EOF
cat >> /etc/fail2ban/jail.local <<'EOF'
[pterodactyl]
enabled = true
port = http,https
filter = pterodactyl
logpath = /var/www/pterodactyl/storage/logs/laravel.log
maxretry = 5
bantime = 3600
EOF
systemctl restart fail2ban

# ===================== BACKUP CRON =====================
mkdir -p /backups
cat > /etc/cron.d/pterodactyl-backup <<'EOF'
0 3 * * * root mysqldump pterodactyl | gzip > /backups/pterodactyl-$(date +\%F).sql.gz
0 4 * * * root find /backups -name '*.sql.gz' -mtime +7 -delete
EOF

# ===================== OUTPUT =====================
echo -e "\n${GREEN}====================================${NC}"
echo -e "${GREEN}   PTERODACTYL INSTALL COMPLETE${NC}"
echo -e "${GREEN}====================================${NC}"
echo -e "Panel URL:      ${GREEN}$PANEL_URL${NC}"
echo -e "Admin Email:    ${GREEN}$ADMIN_EMAIL${NC}"
echo -e "Admin Password: ${GREEN}$ADMIN_PASS${NC}"
echo -e "Playit Claim:   ${GREEN}$CLAIM_URL${NC}  (also at $PANEL_URL/playit/)"
echo -e "Wings Node:     already configured"
echo -e "Bedrock Egg:    imported under Nest 'Bedrock'"
echo -e "Next Steps:     see README.md for creating a server and using Playit"
