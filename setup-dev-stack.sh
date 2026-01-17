#!/usr/bin/env bash

# --- Technical Specification ---
# Name: setup-dev-stack.sh
# Version: 7.0 (NPM/GitHub Edition)
# ----------------------------------------------------------------

# 1. Self-Elevate to sudo if not already
if [[ $EUID -ne 0 ]]; then
   exec sudo "$0" "$@"
   exit $?
fi

clear
echo "------------------------------------------------"
echo "🚀 SETUP-DEV-STACK: INTERACTIVE SETUP"
echo "------------------------------------------------"

# 2. Prompts
read -p "Enter Client Slug (e.g., companyx): " CLIENT
read -p "Enter Domain (e.g., companyx.com): " DOMAIN

CURRENT_DIR=$(pwd)
echo "Current folder: $CURRENT_DIR"
read -p "Is this the project root? (y/n): " IS_CURRENT

if [[ "$IS_CURRENT" == "y" || "$IS_CURRENT" == "Y" ]]; then
    PROJECT_DIR=$CURRENT_DIR
else
    read -p "Enter full path to project: " PROJECT_DIR
fi

# 3. Variables (Constants for your specific stack)
H_PORT=8081
K_PORT=8080
PG_PORT=5050
KONG_PORT=8000
MINIO_PORT=9000

# 4. Dependency Sync
echo "Step 1/5: Syncing Native Dependencies..."
for tool in nginx mkcert; do
    command -v $tool >/dev/null 2>&1 || brew install $tool
done
mkcert -install >/dev/null 2>&1

# 5. SSL Automation
echo "Step 2/5: Automating SSL Trust..."
CERT_DIR="$HOME/certs/$CLIENT"
mkdir -p "$CERT_DIR"
mkcert -cert-file "$CERT_DIR/cert.pem" -key-file "$CERT_DIR/key.pem" \
    "$DOMAIN" "*.$DOMAIN" "localhost" "127.0.0.1" >/dev/null 2>&1

# 6. DNS Spoofing
echo "Step 3/5: Updating /etc/hosts..."
sed -i '' "/$DOMAIN/d" /etc/hosts
echo "127.0.0.1  api.$DOMAIN auth.$DOMAIN console.$DOMAIN db-admin.$DOMAIN app.$DOMAIN $DOMAIN" >> /etc/hosts

# 7. Nginx Logic
echo "Step 4/5: Configuring Nginx Gateway..."
NGINX_SERVERS="/opt/homebrew/etc/nginx/servers"
cat <<EOF > "$NGINX_SERVERS/$CLIENT.conf"
server {
    listen 443 ssl;
    server_name api.$DOMAIN;
    ssl_certificate $CERT_DIR/cert.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    location /graphql {
        proxy_pass http://localhost:$H_PORT/v1/graphql;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location /auth {
        proxy_pass http://localhost:$K_PORT/auth;
        proxy_set_header Host \$host;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }

    location /files {
        proxy_pass http://localhost:$MINIO_PORT;
        proxy_set_header Host \$host;
    }

    location / {
        proxy_pass http://localhost:$KONG_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    server_name auth.$DOMAIN;
    ssl_certificate $CERT_DIR/cert.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    location / {
        proxy_pass http://localhost:$K_PORT;
        proxy_set_header Host \$host;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
EOF

# 8. Docker Bridge
echo "Step 5/5: Generating Docker Override..."
cat <<EOF > "$PROJECT_DIR/docker-compose.override.yml"
version: '3.8'
services:
  hasura:
    extra_hosts:
      - "api.$DOMAIN:host.docker.internal"
      - "auth.$DOMAIN:host.docker.internal"
  auth-webhook:
    extra_hosts:
      - "auth.$DOMAIN:host.docker.internal"
  kong:
    extra_hosts:
      - "api.$DOMAIN:host.docker.internal"
      - "auth.$DOMAIN:host.docker.internal"
EOF

# Reset Ownership
REAL_USER=${SUDO_USER:-$(whoami)}
chown "$REAL_USER" "$PROJECT_DIR/docker-compose.override.yml"
chown -R "$REAL_USER" "$CERT_DIR"

# 9. Reload
/opt/homebrew/bin/nginx -t && sudo /opt/homebrew/bin/brew services restart nginx

echo "------------------------------------------------"
echo "✅ SETUP SUCCESSFUL: $DOMAIN"
echo "------------------------------------------------"