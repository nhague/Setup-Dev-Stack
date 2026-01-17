#!/usr/bin/env bash

# --- Technical Specification ---
# Name: setup-dev-stack.sh
# Version: 2.2.2 (Master Edition)
# Author: australiawow (NPM) / nhague (GitHub)
# Architecture: Native Nginx (Mac) -> Docker Bridge (M1)
# ----------------------------------------------------------------

# MODULE 1: DEPENDENCY SYNC (Runs as Standard User)
# Fact: Homebrew forbids running as root. We check this before sudo.
echo "Step 1/6: Verifying Native Dependencies..."

if ! command -v brew >/dev/null 2>&1; then
    echo "Fact: Homebrew not detected. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Determine Homebrew Prefix (M1 vs Intel)
BREW_PREFIX=$(brew --prefix)

for tool in nginx mkcert; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "Fact: $tool missing. Installing via Homebrew..."
        brew install $tool
    else
        echo "Fact: $tool detected."
    fi
done

# MODULE 2: PRIVILEGE ESCALATION
# Fact: Sudo is required for /etc/hosts and Nginx privileged ports (443)
if [[ $EUID -ne 0 ]]; then
   echo "Fact: Dependencies synced. Elevating to sudo for System Config..."
   exec sudo "$0" "$@"
   exit $?
fi

# Define User Identity
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(eval echo "~$REAL_USER")

clear
echo "------------------------------------------------"
echo "🚀 STACK-MASTER: INTERACTIVE SETUP"
echo "------------------------------------------------"

# MODULE 3: INTERACTIVE PROMPTS
read -p "Enter Client Slug (e.g., companyx): " CLIENT
read -p "Enter Domain (e.g., companyx.com): " DOMAIN

CURRENT_DIR=$(pwd)
read -p "Is this the project root? ($CURRENT_DIR) (y/n): " IS_CURRENT
if [[ "$IS_CURRENT" == "y" || "$IS_CURRENT" == "Y" ]]; then
    PROJECT_DIR=$CURRENT_DIR
else
    read -p "Enter full path to project: " PROJECT_DIR
fi

# MODULE 4: SSL AUTOMATION (Permissions Safe)
echo "Step 3/6: Automating SSL Trust for $DOMAIN..."
CERT_DIR="$USER_HOME/certs/$CLIENT"

# Fix: Create dir as root but immediately give to user so mkcert works
mkdir -p "$CERT_DIR"
chown "$REAL_USER" "$CERT_DIR"

# Action: Run mkcert as the local user
sudo -u "$REAL_USER" "$BREW_PREFIX/bin/mkcert" -install >/dev/null 2>&1
sudo -u "$REAL_USER" "$BREW_PREFIX/bin/mkcert" -cert-file "$CERT_DIR/cert.pem" -key-file "$CERT_DIR/key.pem" \
    "$DOMAIN" "*.$DOMAIN" "localhost" "127.0.0.1" >/dev/null 2>&1

if [ ! -f "$CERT_DIR/cert.pem" ]; then
    echo "❌ Error: SSL Generation Failed. Check permissions on $CERT_DIR"
    exit 1
fi

# MODULE 5: DNS SPOOFING
echo "Step 4/6: Updating /etc/hosts..."
sed -i '' "/$DOMAIN/d" /etc/hosts
echo "127.0.0.1  api.$DOMAIN auth.$DOMAIN console.$DOMAIN db-admin.$DOMAIN app.$DOMAIN $DOMAIN" >> /etc/hosts

# MODULE 6: NGINX GATEWAY (Buffer Safe & Ghost-Config Proof)
echo "Step 5/6: Configuring Nginx Gateway..."
NGINX_CONF_ROOT="$BREW_PREFIX/etc/nginx"
NGINX_SERVERS="$NGINX_CONF_ROOT/servers"
mkdir -p "$NGINX_SERVERS"

# Fix: Prevent "Ghost Configs" from breaking Nginx test
if ! "$BREW_PREFIX/bin/nginx" -t >/dev/null 2>&1; then
    echo "⚠️  Fact: Nginx is currently blocked by an old/broken config."
    read -p "Would you like to clear all old dev configs now? (y/n): " CLEAR_OLD
    if [[ "$CLEAR_OLD" == "y" ]]; then
        rm -f "$NGINX_SERVERS"/*.conf
        echo "Fact: Stale configs removed."
    fi
fi

# Port Mapping (Five Star Stack)
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
        # Fact: Standard buffer math for large JWT tokens
        proxy_buffer_size          128k;
        proxy_buffers              4 256k;
        proxy_busy_buffers_size    256k;
    }

    location / {
        proxy_pass http://localhost:$KONG_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# MODULE 7: DOCKER BRIDGE
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
  kong:
    extra_hosts:
      - "api.$DOMAIN:host.docker.internal"
      - "auth.$DOMAIN:host.docker.internal"
EOF

# Reset Ownership
chown "$REAL_USER" "$PROJECT_DIR/docker-compose.override.yml"
chown -R "$REAL_USER" "$CERT_DIR"

# RELOAD
echo "Reloading Native Nginx..."
"$BREW_PREFIX/bin/nginx" -t && brew services restart nginx

echo "------------------------------------------------"
echo "✅ SETUP SUCCESSFUL: $DOMAIN"
echo "------------------------------------------------"
echo "URL: https://api.$DOMAIN"
echo "Path: $PROJECT_DIR"
echo "------------------------------------------------"