#!/bin/bash
# =============================================================================
# Full Stack Server Setup Script for Ubuntu
# =============================================================================
# Description: Automates the installation and configuration of:
#              - LAMP Stack  (Apache, MySQL, PHP)
#              - Nginx       (as a reverse proxy in front of Apache)
#              - Docker      (with Docker Compose)
#              - WordPress   (deployed via Docker Compose + Nginx + MySQL)
#
# Tested on:   Ubuntu 20.04 / 22.04 / 24.04
# Author:      DPowell34
# Usage:       sudo bash install_lamp.sh
# =============================================================================

set -e  # Exit immediately on error

# --------------------------------------------------------------------------
# Color codes for output formatting
# --------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

# --------------------------------------------------------------------------
# Configuration — edit these variables before running
# --------------------------------------------------------------------------
WP_DOMAIN="example.com"          # Domain / IP for Nginx server_name
WP_DB_NAME="wordpress"
WP_DB_USER="wpuser"
WP_DB_PASSWORD=$(openssl rand -base64 18)
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)
WP_DIR="/opt/wordpress"           # Directory for Docker Compose project

# --------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${NC}    $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }
section() { echo -e "\n${BLUE}==============================${NC}\n${BLUE}  $1${NC}\n${BLUE}==============================${NC}"; }

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run this script as root: sudo bash $0"
    fi
}

check_ubuntu() {
    [[ -f /etc/os-release ]] || error "Cannot detect OS."
    source /etc/os-release
    [[ "$ID" == "ubuntu" ]] || error "This script requires Ubuntu. Detected: $ID"
    info "Detected Ubuntu $VERSION_ID ($VERSION_CODENAME)"
}

# --------------------------------------------------------------------------
# Update system packages
# --------------------------------------------------------------------------
update_system() {
    section "System Update"
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl wget gnupg2 ca-certificates lsb-release         software-properties-common apt-transport-https unzip openssl
    success "System updated and base dependencies installed."
}

# --------------------------------------------------------------------------
# Install Apache2
# --------------------------------------------------------------------------
install_apache() {
    section "Apache2"
    apt-get install -y apache2

    # Enable required modules for reverse proxy use with Nginx
    a2enmod proxy proxy_http headers rewrite
    systemctl enable apache2

    # Move Apache to port 8080 so Nginx can own port 80
    sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf
    sed -i 's/<VirtualHost *:80>/<VirtualHost *:8080>/'         /etc/apache2/sites-available/000-default.conf

    systemctl restart apache2
    success "Apache2 installed and listening on port 8080."
}

# --------------------------------------------------------------------------
# Install MySQL Server
# --------------------------------------------------------------------------
install_mysql() {
    section "MySQL Server"
    apt-get install -y mysql-server
    systemctl enable mysql
    systemctl start mysql

    info "Securing MySQL installation..."
    mysql -u root <<-MYSQL_SCRIPT
        ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
        GRANT ALL PRIVILEGES ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
MYSQL_SCRIPT

    CREDS_FILE="/root/.db_credentials"
    cat > "$CREDS_FILE" <<-CREDS
MySQL root password : ${MYSQL_ROOT_PASSWORD}
WordPress DB name   : ${WP_DB_NAME}
WordPress DB user   : ${WP_DB_USER}
WordPress DB pass   : ${WP_DB_PASSWORD}
CREDS
    chmod 600 "$CREDS_FILE"
    warning "Database credentials saved to $CREDS_FILE — keep this file secure!"
    success "MySQL installed, secured, and WordPress database created."
}

# --------------------------------------------------------------------------
# Install PHP and common extensions
# --------------------------------------------------------------------------
install_php() {
    section "PHP"
    apt-get install -y         php         php-mysql         php-cli         php-curl         php-gd         php-mbstring         php-xml         php-xmlrpc         php-soap         php-intl         php-zip         php-bcmath         php-imagick         libapache2-mod-php

    systemctl restart apache2
    PHP_VER=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    success "PHP $PHP_VER installed with common extensions."
}

# --------------------------------------------------------------------------
# Install Docker and Docker Compose
# --------------------------------------------------------------------------
install_docker() {
    section "Docker & Docker Compose"

    # Remove any old Docker packages
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker's official GPG key and repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg         -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"         > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io         docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    DOCKER_VER=$(docker --version)
    COMPOSE_VER=$(docker compose version)
    success "Docker installed: $DOCKER_VER"
    success "Compose installed: $COMPOSE_VER"
}

# --------------------------------------------------------------------------
# Install Nginx (as reverse proxy on port 80)
# --------------------------------------------------------------------------
install_nginx() {
    section "Nginx (Reverse Proxy)"
    apt-get install -y nginx
    systemctl enable nginx

    # Create a server block for WordPress (proxies to Docker on port 8000)
    cat > /etc/nginx/sites-available/wordpress <<-NGINX_CONF
server {
    listen 80;
    server_name ${WP_DOMAIN} www.${WP_DOMAIN};

    client_max_body_size 64M;

    # Proxy all requests to WordPress container
    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg)$ {
        proxy_pass http://127.0.0.1:8000;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }
}
NGINX_CONF

    # Enable the site
    ln -sf /etc/nginx/sites-available/wordpress         /etc/nginx/sites-enabled/wordpress
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl restart nginx
    success "Nginx installed and configured as reverse proxy on port 80."
}

# --------------------------------------------------------------------------
# Deploy WordPress via Docker Compose
# --------------------------------------------------------------------------
deploy_wordpress() {
    section "WordPress (Docker Compose)"
    mkdir -p "$WP_DIR"

    cat > "$WP_DIR/docker-compose.yml" <<-COMPOSE
version: "3.9"

services:
  db:
    image: mysql:8.0
    container_name: wp_db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${WP_DB_NAME}
      MYSQL_USER: ${WP_DB_USER}
      MYSQL_PASSWORD: ${WP_DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - wp_net

  wordpress:
    image: wordpress:latest
    container_name: wp_app
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "8000:80"
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${WP_DB_NAME}
      WORDPRESS_DB_USER: ${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASSWORD}
    volumes:
      - wp_data:/var/www/html
    networks:
      - wp_net

volumes:
  db_data:
  wp_data:

networks:
  wp_net:
    driver: bridge
COMPOSE

    # Write an .env file for Docker Compose variable substitution
    cat > "$WP_DIR/.env" <<-ENVFILE
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
WP_DB_NAME=${WP_DB_NAME}
WP_DB_USER=${WP_DB_USER}
WP_DB_PASSWORD=${WP_DB_PASSWORD}
ENVFILE
    chmod 600 "$WP_DIR/.env"

    # Launch WordPress stack
    cd "$WP_DIR"
    docker compose up -d

    success "WordPress Docker stack deployed at http://127.0.0.1:8000"
}

# --------------------------------------------------------------------------
# Configure UFW firewall
# --------------------------------------------------------------------------
configure_firewall() {
    section "UFW Firewall"
    if command -v ufw &>/dev/null; then
        ufw allow OpenSSH
        ufw allow "Nginx Full"
        ufw --force enable
        success "UFW enabled: SSH, HTTP(80), HTTPS(443) allowed."
    else
        warning "UFW not found — skipping firewall configuration."
    fi
}

# --------------------------------------------------------------------------
# Create a PHP info test page (for Apache verification)
# --------------------------------------------------------------------------
create_test_page() {
    TEST_PAGE="/var/www/html/info.php"
    cat > "$TEST_PAGE" <<-'EOF'
<?php phpinfo(); ?>
EOF
    chmod 644 "$TEST_PAGE"
    warning "PHP info page created — remove /var/www/html/info.php after testing!"
}

# --------------------------------------------------------------------------
# Print summary
# --------------------------------------------------------------------------
print_summary() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}   Full Stack Server Setup Complete!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo -e "  ${CYAN}WordPress:${NC}      http://$SERVER_IP  (via Nginx -> Docker)"
    echo -e "  ${CYAN}Apache (direct):${NC} http://$SERVER_IP:8080"
    echo -e "  ${CYAN}PHP Info:${NC}       http://$SERVER_IP:8080/info.php"
    echo -e "  ${CYAN}DB Credentials:${NC} /root/.db_credentials"
    echo -e "  ${CYAN}WP Docker dir:${NC}  $WP_DIR"
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "    1. Visit http://$SERVER_IP to complete the WordPress setup wizard."
    echo -e "    2. Point your domain DNS ($WP_DOMAIN) to $SERVER_IP."
    echo -e "    3. Install Certbot for free HTTPS: apt install certbot python3-certbot-nginx"
    echo -e "    4. Delete /var/www/html/info.php after testing."
    echo -e "${GREEN}============================================================${NC}"
    echo ""
}

# --------------------------------------------------------------------------
# Main execution
# --------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}   Full Stack Server Installer for Ubuntu${NC}"
    echo -e "${BLUE}   (LAMP + Nginx + Docker + WordPress)${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""

    check_root
    check_ubuntu
    update_system
    install_apache
    install_mysql
    install_php
    install_docker
    install_nginx
    deploy_wordpress
    configure_firewall
    create_test_page
    print_summary
}

main "$@"
