#!/bin/bash
# Basic WordPress Setup with Caddy, PHP, UFW, and minimal dependencies for Ubuntu Minimal

set -e

# Installation directory and basic configuration
INSTALL_DIR="/opt/wordpress-installer"
DOMAIN="localhost"  # This can be updated via the WordPress UI later
WP_DIR="/var/www/html"
LOG_FILE="/var/log/wp-install.log"
SERVER_IP=$(hostname -I | awk '{print $1}')  # Automatically get the server's IP address

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Install essential dependencies for Ubuntu minimal
install_deps() {
    log "Installing minimal dependencies..."

    apt-get update -y
    apt-get install -y \
        curl \
        wget \
        gnupg \
        ca-certificates \
        software-properties-common \
        lsb-release \
        dialog \
        unzip \
        build-essential \
        libcurl4-openssl-dev \
        libxml2-dev \
        libjpeg-dev \
        libpng-dev \
        libfreetype6-dev \
        libmcrypt-dev \
        libssl-dev \
        libzip-dev \
        libxslt-dev \
        libgd-dev \
        libmemcached-dev \
        python3-software-properties \
        ufw  # Install UFW (Uncomplicated Firewall)
}

# Install PHP (latest version from the Ondrej PHP repository)
install_php() {
    log "Installing PHP..."

    # Add the PHP repository for the latest versions
    add-apt-repository ppa:ondrej/php -y
    apt-get update -y

    # Install PHP and necessary extensions
    apt-get install -y \
        php-fpm \
        php-mysql \
        php-curl \
        php-xml \
        php-mbstring \
        php-zip \
        php-gd \
        php-opcache \
        php-xsl \
        php-intl \
        php-bz2

    # Get the PHP version installed and in use
    PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}' | cut -d. -f1,2)
    PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

    log "PHP version installed: $PHP_VERSION"
}

# Install Caddy web server
install_caddy() {
    log "Installing Caddy..."

    # Caddy installation
    curl -fsSL https://get.caddyserver.com | bash

    # Enable and start Caddy
    systemctl enable caddy
    systemctl start caddy
}

# Install WordPress
install_wordpress() {
    log "Installing WordPress..."

    # Download and extract the latest WordPress
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz
    tar -xzf /tmp/wordpress.tar.gz -C $WP_DIR && rm /tmp/wordpress.tar.gz

    # Set permissions for WordPress
    chown -R www-data:www-data $WP_DIR
    chmod -R 755 $WP_DIR
}

# Configure Caddy to serve WordPress
configure_caddy() {
    log "Configuring Caddy..."

    # Dynamically use the correct PHP version for the Caddyfile
    cat > /etc/caddy/Caddyfile <<EOF
# Make WordPress accessible on the server's IP (e.g., 0.0.0.0)
$SERVER_IP {
    root * $WP_DIR
    php_fastcgi unix:$PHP_FPM_SOCKET
    file_server
}

# Optionally, listen on all interfaces as well (so it’s accessible externally)
:80 {
    root * $WP_DIR
    php_fastcgi unix:$PHP_FPM_SOCKET
    file_server
}
EOF

    # Restart Caddy service to apply configuration
    systemctl restart caddy
}

# Install and configure UFW firewall
install_and_configure_ufw() {
    log "Installing and configuring UFW firewall..."

    # Enable UFW and allow HTTP and HTTPS traffic
    ufw enable
    ufw allow 80,443/tcp
    ufw reload

    # Check UFW status
    ufw status
}

# Main installation flow
main() {
    # Install minimal dependencies
    install_deps

    # Install PHP and identify the PHP version in use
    install_php

    # Install Caddy
    install_caddy

    # Install WordPress
    install_wordpress

    # Configure Caddy to serve WordPress with the correct PHP version
    configure_caddy

    # Install and configure UFW firewall to allow HTTP and HTTPS
    install_and_configure_ufw

    log "Installation complete. You can now access WordPress via http://$SERVER_IP."

    # Inform the user to finish setup via the WordPress web interface
    echo "WordPress installation is complete! Visit http://$SERVER_IP to complete the setup using the WordPress built-in wizard."
}

# Run the installation
main
