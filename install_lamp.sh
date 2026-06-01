#!/bin/bash
# =============================================================================
# LAMP Stack Installation Script for Ubuntu
# =============================================================================
# Description: Automates the installation and configuration of a full LAMP
#              stack (Linux, Apache, MySQL, PHP) on Ubuntu 20.04/22.04/24.04
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
NC='\033[0m'  # No Color

# --------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --------------------------------------------------------------------------
# Check that the script is run as root
# --------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo bash $0"
    fi
}

# --------------------------------------------------------------------------
# Detect Ubuntu version
# --------------------------------------------------------------------------
check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS. This script requires Ubuntu."
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error "This script is designed for Ubuntu. Detected: $ID"
    fi
    info "Detected Ubuntu $VERSION_ID"
}

# --------------------------------------------------------------------------
# Update system packages
# --------------------------------------------------------------------------
update_system() {
    info "Updating system package list..."
    apt-get update -y
    apt-get upgrade -y
    success "System updated."
}

# --------------------------------------------------------------------------
# Install Apache2
# --------------------------------------------------------------------------
install_apache() {
    info "Installing Apache2..."
    apt-get install -y apache2
    systemctl enable apache2
    systemctl start apache2

    # Allow HTTP and HTTPS through UFW firewall if active
    if ufw status | grep -q "Status: active"; then
        ufw allow in "Apache Full"
        success "UFW: Apache Full rule added."
    fi

    success "Apache2 installed and running."
}

# --------------------------------------------------------------------------
# Install MySQL Server
# --------------------------------------------------------------------------
install_mysql() {
    info "Installing MySQL Server..."
    apt-get install -y mysql-server

    systemctl enable mysql
    systemctl start mysql

    # Run the security hardening script non-interactively
    info "Running MySQL secure installation..."
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24)

    mysql -u root <<-MYSQL_SCRIPT
        ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
MYSQL_SCRIPT

    # Save credentials to a secure file
    CREDS_FILE="/root/.mysql_credentials"
    echo "MySQL root password: ${MYSQL_ROOT_PASSWORD}" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"

    warning "MySQL root password saved to $CREDS_FILE -- keep this file secure!"
    success "MySQL installed and secured."
}

# --------------------------------------------------------------------------
# Install PHP and common extensions
# --------------------------------------------------------------------------
install_php() {
    info "Installing PHP and extensions..."
    apt-get install -y \
        php \
        php-mysql \
        php-cli \
        php-curl \
        php-gd \
        php-mbstring \
        php-xml \
        php-xmlrpc \
        php-soap \
        php-intl \
        php-zip \
        libapache2-mod-php

    # Restart Apache to load the PHP module
    systemctl restart apache2

    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    success "PHP $PHP_VERSION installed with common extensions."
}

# --------------------------------------------------------------------------
# Create a PHP info test page
# --------------------------------------------------------------------------
create_test_page() {
    TEST_PAGE="/var/www/html/info.php"
    info "Creating PHP info test page at $TEST_PAGE..."

    cat > "$TEST_PAGE" <<-'EOF'
<?php
phpinfo();
EOF

    chmod 644 "$TEST_PAGE"
    warning "PHP info page created at /info.php -- remove it after testing!"
    success "Test page created: http://YOUR_SERVER_IP/info.php"
}

# --------------------------------------------------------------------------
# Display installation summary
# --------------------------------------------------------------------------
print_summary() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "============================================================"
    success " LAMP Stack Installation Complete!"
    echo "============================================================"
    echo -e "  ${BLUE}Apache:${NC}  http://$SERVER_IP"
    echo -e "  ${BLUE}PHP Info:${NC} http://$SERVER_IP/info.php"
    echo -e "  ${BLUE}MySQL:${NC}   Credentials saved to /root/.mysql_credentials"
    echo ""
    warning "Remember to delete /var/www/html/info.php after testing!"
    echo "============================================================"
    echo ""
}

# --------------------------------------------------------------------------
# Main execution
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "============================================================"
    echo "   LAMP Stack Installer for Ubuntu"
    echo "============================================================"
    echo ""

    check_root
    check_ubuntu
    update_system
    install_apache
    install_mysql
    install_php
    create_test_page
    print_summary
}

main "$@"
