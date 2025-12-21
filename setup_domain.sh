#!/bin/bash
# =============================================================================
# ERPNext Domain & SSL Setup Script (Host Nginx Reverse Proxy)
# =============================================================================
# This script installs Nginx on the host, configures it as a reverse proxy
# for the ERPNext Docker container (running on port 8080), and secures it
# with a free Let's Encrypt SSL certificate via Certbot.
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# Check root
if [ "$EUID" -ne 0 ]; then
  log_error "Please run as root"
  exit 1
fi

# 1. Ask for Domain
echo ""
echo "=========================================="
echo "      ERPNext Domain Setup Wizard"
echo "=========================================="
read -p "Enter your Domain Name (e.g., erp.example.com): " DOMAIN_NAME

if [ -z "$DOMAIN_NAME" ]; then
    log_error "Domain name cannot be empty."
    exit 1
fi

log_info "Setting up domain: $DOMAIN_NAME"

# 2. Install Nginx and Certbot
log_info "Installing Nginx and Certbot..."
apt-get update
apt-get install -y nginx python3-certbot-nginx

# 3. Configure Firewall (if UFW is active)
if ufw status | grep -q "Status: active"; then
    log_info "Configuring UFW firewall for Nginx..."
    ufw allow 'Nginx Full'
    ufw reload
fi

# 4. Create Nginx Proxy Config
log_info "Creating Nginx configuration..."
cat > "/etc/nginx/sites-available/$DOMAIN_NAME" <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Websocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 5. Enable Site
rm -f "/etc/nginx/sites-enabled/$DOMAIN_NAME"
ln -s "/etc/nginx/sites-available/$DOMAIN_NAME" "/etc/nginx/sites-enabled/"

# Disable default if it exists (avoids conflicts)
rm -f /etc/nginx/sites-enabled/default

# Test config
nginx -t

# Reload Nginx to apply basic config
systemctl reload nginx

log_info "Nginx configured. Starting SSL setup..."

# 6. Obtain SSL Certificate
# Non-interactive mode requires email, or use register-unsafely-without-email
read -p "Enter your email for SSL renewal notifications: " EMAIL_ADDRESS

if [ -z "$EMAIL_ADDRESS" ]; then
    certbot --nginx -d "$DOMAIN_NAME" --register-unsafely-without-email --agree-tos --no-eff-email --redirect
else
    certbot --nginx -d "$DOMAIN_NAME" -m "$EMAIL_ADDRESS" --agree-tos --no-eff-email --redirect
fi

log_info "=========================================="
log_info "SUCCESS! Domain configured."
log_info "You can now access your site at:"
log_info "https://$DOMAIN_NAME"
log_info "=========================================="
