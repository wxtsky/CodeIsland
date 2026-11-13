#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# One-Click Setup Script for CodeIsland Distribution Node (Debian)
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (sudo)." >&2
   exit 1
fi

WEB_ROOT="/var/www/codeisland-updates"
SCRIPTS_DIR="$WEB_ROOT/scripts"
CONF_DIR="/etc/webhook"
CONF_FILE="$CONF_DIR/webhook.json"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> 1. Installing dependencies (webhook, curl, jq) ..."
apt-get update -y
apt-get install -y webhook curl jq

echo "==> 2. Preparing directory layout at $WEB_ROOT ..."
mkdir -p "$WEB_ROOT/releases"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$CONF_DIR"

# Copy deployment script
cp "$SCRIPT_SRC/deploy-codeisland.sh" "$SCRIPTS_DIR/deploy-codeisland.sh"
chmod +x "$SCRIPTS_DIR/deploy-codeisland.sh"

# Initialize base appcast.xml if not present
if [[ ! -f "$WEB_ROOT/appcast.xml" ]]; then
    echo "==> Generating base appcast.xml template ..."
    cat > "$WEB_ROOT/appcast.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     version="2.0">
  <channel>
    <title>CodeIsland Updates</title>
    <description>Official CodeIsland update feed</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

# Set ownership and permissions
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 775 "$WEB_ROOT"

echo "==> 3. Configuring Webhook Daemon ..."
GENERATED_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)

cat > "$CONF_FILE" <<EOF
[
  {
    "id": "deploy-codeisland",
    "execute-command": "$SCRIPTS_DIR/deploy-codeisland.sh",
    "command-working-directory": "$WEB_ROOT",
    "response-message": "Deployment job received and executing",
    "include-command-output-in-response": true,
    "pass-arguments-to-command": [
      {
        "source": "payload",
        "name": "version"
      },
      {
        "source": "payload",
        "name": "tag"
      },
      {
        "source": "payload",
        "name": "repository"
      },
      {
        "source": "payload",
        "name": "sha256"
      }
    ],
    "trigger-rule": {
      "match": {
        "type": "value",
        "value": "$GENERATED_SECRET",
        "parameter": {
          "source": "header",
          "name": "X-Webhook-Secret"
        }
      }
    }
  }
]
EOF

chown root:www-data "$CONF_FILE"
chmod 640 "$CONF_FILE"

echo "==> 4. Configuring and starting codeisland-webhook systemd service ..."
cat > /etc/systemd/system/codeisland-webhook.service <<EOF
[Unit]
Description=CodeIsland Webhook Receiver Daemon
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/webhook -hooks $CONF_FILE -ip 127.0.0.1 -port 9000 -verbose
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now codeisland-webhook.service

echo ""
echo "=========================================================================="
echo "SETUP COMPLETED SUCCESSFULLY"
echo "=========================================================================="
echo "Configuration Details:"
echo "- Web Root Directory : $WEB_ROOT"
echo "- Webhook Endpoint   : http://127.0.0.1:9000/hooks/deploy-codeisland"
echo "- WEBHOOK_SECRET     : $GENERATED_SECRET"
echo ""
echo "NEXT STEPS ON GITHUB:"
echo "1. Navigate to: Repo Settings > Secrets and variables > Actions"
echo "2. Add repository secret:"
echo "   - Name  : WEBHOOK_SECRET"
echo "   - Value : $GENERATED_SECRET"
echo "3. Ensure your Nginx virtual host (nginx-updates.conf) is active and"
echo "   Cloudflare Tunnel routes the update domain to Nginx port 80."
echo "=========================================================================="
