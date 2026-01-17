#!/usr/bin/env bash

# --- Technical Specification ---
# Name: setup-dev-stack.sh
# Version: 1.1.0 (Self-Healing Edition)
# ----------------------------------------------------------------

# MODULE 0: NATIVE DEPENDENCY CHECK (Runs as User)
echo "Step 1/6: Verifying Native Dependencies..."

# Check for Homebrew
if ! command -v brew >/dev/null 2>&1; then
    echo "Fact: Homebrew not detected. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Check and Install Nginx/mkcert
for tool in nginx mkcert; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "Fact: $tool missing. Installing via Homebrew..."
        brew install $tool
    else
        echo "Fact: $tool detected."
    fi
done

# MODULE 1: PRIVILEGE ELEVATION (The Switch)
if [[ $EUID -ne 0 ]]; then
   echo "Fact: Dependencies synced. Elevating to sudo for Networking/Nginx..."
   exec sudo "$0" "$@"
   exit $?
fi

# From here on, we are ROOT
clear
echo "------------------------------------------------"
echo "🚀 NHAGUE DEV-STACK: INTERACTIVE SETUP"
echo "------------------------------------------------"

# MODULE 2: PROMPTS
read -p "Enter Client Slug (e.g., companyx): " CLIENT
read -p "Enter Domain (e.g., companyx.com): " DOMAIN

CURRENT_DIR=$(pwd)
read -p "Is this the project root? ($CURRENT_DIR) (y/n): " IS_CURRENT
if [[ "$IS_CURRENT" == "y" || "$IS_CURRENT" == "Y" ]]; then
    PROJECT_DIR=$CURRENT_DIR
else
    read -p "Enter full path to project: " PROJECT_DIR
fi

# MODULE 3: SSL AUTOMATION
echo "Step 3/6: Automating SSL Trust..."
# Fact: We must use the REAL_USER path for certs so they are accessible
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(eval echo "~$REAL_USER")
CERT_DIR="$USER_HOME/certs/$CLIENT"

mkdir -p "$CERT_DIR"
# Run mkcert as the real user to ensure it touches their local keychain
sudo -u "$REAL_USER" mkcert -install >/dev/null 2>&1
sudo -u "$REAL_USER" mkcert -cert-file "$CERT_DIR/cert.pem" -key-file "$CERT_DIR/key.pem" \
    "$DOMAIN" "*.$DOMAIN" "localhost" "127.0.0.1" >/dev/null 2>&1

# MODULE 4: DNS SPOOFING
echo "Step 4/6: Updating /etc/hosts..."
sed -i '' "/$DOMAIN/d" /etc/hosts
echo "127.0.0.1  api.$DOMAIN auth.$DOMAIN console.$DOMAIN db-admin.$DOMAIN app.$DOMAIN $DOMAIN" >> /etc/hosts

# MODULE 5: NGINX GATEWAY
echo "Step 5/6: Configuring Nginx Gateway..."
NGINX_ROOT="/opt/homebrew/etc/nginx"
NGINX_SERVERS="$NGINX_ROOT/servers"
mkdir -p "$NGINX_SERVERS"

# Fact: Mapping your Five Star stack ports
H_PORT=8081
K_PORT=8080
KONG_PORT=8000

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
    }

    location / {
        proxy_pass http://localhost:$KONG_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# MODULE 6: DOCKER BRIDGE
echo "Step 6/6: Generating Docker Override..."
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
EOF

chown "$REAL_USER" "$PROJECT_DIR/docker-compose.override.yml"
chown -R "$REAL_USER" "$CERT_DIR"

# RELOAD
echo "Reloading Nginx Native..."
/opt/homebrew/bin/nginx -t && /opt/homebrew/bin/brew services restart nginx

echo "------------------------------------------------"
echo "✅ SETUP SUCCESSFUL: $DOMAIN"
echo "------------------------------------------------"