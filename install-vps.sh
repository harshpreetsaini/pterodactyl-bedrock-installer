#!/bin/bash
set -uo pipefail

# Check that we are on a real VPS with systemd
if ! pidof systemd >/dev/null 2>&1; then
  echo "ERROR: This script requires a real Ubuntu VPS with systemd. This container won't work."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGG_FILE="$SCRIPT_DIR/files/egg-bedrock-modern.json"
THEME_FILE="$SCRIPT_DIR/files/theme-dark.css"
THEME_NAME="darkmodern"
PLAYIT_DIR="/opt/playit"
PANEL_PATH="/var/www/pterodactyl"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+] $1${NC}"; }
error() { echo -e "${RED}[-] $1${NC}"; exit 1; }

PUBLIC_IP=$(curl -s ifconfig.me)
[[ -z "$PUBLIC_IP" ]] && error "No public IP found."

read -rp "Panel domain (press Enter for automatic $PUBLIC_IP.nip.io): " PANEL_DOMAIN
if [[ -z "$PANEL_DOMAIN" ]]; then
    PANEL_DOMAIN="$PUBLIC_IP.nip.io"
    info "Using nip.io domain: $PANEL_DOMAIN"
fi

read -rp "Admin email: " ADMIN_EMAIL
[[ -z "$ADMIN_EMAIL" ]] && error "Admin email required."
ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
echo "Admin password: $ADMIN_PASS"

info "Updating system and fixing packages..."
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget gnupg ca-certificates lsb-release ufw fail2ban certbot python3-certbot-nginx nginx-extras jq unzip sqlite3 software-properties-common expect
add-apt-repository universe -y || true

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
sleep 2

info "Running Pterodactyl installer with automatic answers..."
export PTERODACTYL_PANEL_DOMAIN="$PANEL_DOMAIN"
export PTERODACTYL_PANEL_SSL="letsencrypt"
export PTERODACTYL_PANEL_LETSENCRYPT_EMAIL="$ADMIN_EMAIL"
export PTERODACTYL_PANEL_ADMIN_EMAIL="$ADMIN_EMAIL"
export PTERODACTYL_PANEL_ADMIN_PASSWORD="$ADMIN_PASS"
export PTERODACTYL_TIMEZONE="UTC"
export PTERODACTYL_WINGS_ENABLED="true"
export PTERODACTYL_WINGS_NODE_NAME="Node1"
export PTERODACTYL_WINGS_USE_SSL="true"

curl -sSL -o /tmp/ptero-install.sh https://pterodactyl-installer.se/install.sh

expect << 'EXPECTEOF'
set timeout 600
spawn bash /tmp/ptero-install.sh --panel --wings --node --skip-database-install
expect {
  "Input 0-6:" { send "2\r"; exp_continue }
  "Database name (panel):" { send "panel\r"; exp_continue }
  "Database username (pterodactyl):" { send "pterodactyl\r"; exp_continue }
  "Do you want to proceed to wings installation? (y/N):" { send "y\r"; exp_continue }
  eof
}
EXPECTEOF

PANEL_URL="https://${PANEL_DOMAIN}"
info "Panel installed at $PANEL_URL"
sleep 30

if [ ! -d "$PANEL_PATH" ]; then
  error "Panel path /var/www/pterodactyl not found. Installation failed."
fi

cd "$PANEL_PATH"
php artisan p:user:token:generate --user=1 --name="AutoInstall" > /tmp/ptero_token.txt
API_TOKEN=$(grep 'Token:' /tmp/ptero_token.txt | awk '{print $2}')
rm /tmp/ptero_token.txt
[[ -z "$API_TOKEN" ]] && error "Failed to get API token."

info "Setting up Playit.gg..."
mkdir -p "$PLAYIT_DIR"
wget -qO "$PLAYIT_DIR/playit-agent" "https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-amd64"
chmod +x "$PLAYIT_DIR/playit-agent"
timeout 15 "$PLAYIT_DIR/playit-agent" --secret "$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)" > /tmp/playit_init.log 2>&1 || true
CLAIM_URL=$(grep -o 'https://playit.gg/claim/[a-zA-Z0-9]*' /tmp/playit_init.log || echo "Not yet available")
cat > /etc/systemd/system/playit-agent.service <<EOF
[Unit]
Description=Playit.gg Agent
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
echo "REPLACE_WITH_PLAYIT_SECRET" > "$PLAYIT_DIR/secret"
systemctl daemon-reload
systemctl enable playit-agent
mkdir -p "$PANEL_PATH/public/playit"
cat > "$PANEL_PATH/public/playit/index.html" <<EOF
<html><body style="background:#121212;color:#fff;"><h1>Playit Claim</h1><p>$CLAIM_URL</p></body></html>
EOF

# Import the custom Bedrock egg
info "Importing Bedrock egg..."
if [ ! -f "$EGG_FILE" ]; then
  # try to download from your own repo as fallback
  wget -qO /tmp/egg-bedrock-modern.json https://raw.githubusercontent.com/harshpreetsaini/pterodactyl-bedrock-installer/main/files/egg-bedrock-modern.json
  EGG_FILE=/tmp/egg-bedrock-modern.json
fi

NEST_RESPONSE=$(curl -s -X POST "$PANEL_URL/api/application/nests" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Bedrock","description": "Custom Bedrock eggs"}')
NEST_ID=$(echo "$NEST_RESPONSE" | jq -r '.attributes.id')
[[ "$NEST_ID" == "null" || -z "$NEST_ID" ]] && error "Failed to create nest."
curl -s -X POST "$PANEL_URL/api/application/nests/$NEST_ID/eggs" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$EGG_FILE" > /dev/null

# Dark theme
info "Applying dark theme..."
mkdir -p "$PANEL_PATH/public/themes/$THEME_NAME/css"
if [ -f "$THEME_FILE" ]; then
  cp "$THEME_FILE" "$PANEL_PATH/public/themes/$THEME_NAME/css/pterodactyl.css"
else
  wget -qO "$PANEL_PATH/public/themes/$THEME_NAME/css/pterodactyl.css" \
    https://raw.githubusercontent.com/harshpreetsaini/pterodactyl-bedrock-installer/main/files/theme-dark.css
fi
grep -q "APP_THEME=" "$PANEL_PATH/.env" && sed -i "s|APP_THEME=.*|APP_THEME=$THEME_NAME|" "$PANEL_PATH/.env" || echo "APP_THEME=$THEME_NAME" >> "$PANEL_PATH/.env"
php artisan config:cache && php artisan view:clear

# Fail2ban & backups
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

mkdir -p /backups
cat > /etc/cron.d/pterodactyl-backup <<'EOF'
0 3 * * * root mysqldump pterodactyl | gzip > /backups/pterodactyl-$(date +\%F).sql.gz
0 4 * * * root find /backups -name '*.sql.gz' -mtime +7 -delete
EOF

echo -e "\n${GREEN}====================================${NC}"
echo -e "${GREEN}   INSTALL COMPLETE${NC}"
echo -e "${GREEN}====================================${NC}"
echo -e "Panel URL:      ${GREEN}$PANEL_URL${NC}"
echo -e "Admin Email:    ${GREEN}$ADMIN_EMAIL${NC}"
echo -e "Admin Password: ${GREEN}$ADMIN_PASS${NC}"
echo -e "Playit Claim:   ${GREEN}$CLAIM_URL${NC}"
