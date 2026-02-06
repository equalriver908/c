#!/bin/bash
# WordPress Minimal Installer with Caddy + MariaDB
# Features: Error handling, progress feedback, minimal footprint

set -euo pipefail

# Configuration
INSTALL_DIR="/var/www/html"
LOG_FILE="/var/log/wp-install.log"
CADDYFILE="/etc/caddy/Caddyfile"
DOMAIN="localhost"
PHP_VERSION="8.2"  # Using stable PHP 8.2 instead of 8.4 for compatibility
SERVER_IP=$(hostname -I | awk '{print $1}')

# Generate secure passwords
MARIADB_ROOT_PASS=$(openssl rand -base64 16)
WP_DB_PASS=$(openssl rand -base64 16)
WP_DB_NAME="wordpress"
WP_DB_USER="wpuser"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Error handling
trap 'echo -e "${RED}Script failed at line $LINENO. Check $LOG_FILE for details.${NC}"; exit 1' ERR

# Logging function
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Progress indicator
show_progress() {
    local step="$1"
    local total="$2"
    local message="$3"
    local percentage=$((step * 100 / total))
    
    # Simple progress bar
    echo -ne "\r${BLUE}["
    for ((i=0; i<percentage/2; i++)); do echo -n "="; done
    for ((i=percentage/2; i<50; i++)); do echo -n " "; done
    echo -ne "] ${percentage}% - ${message}${NC}"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}This script must be run as root. Use sudo.${NC}"
        exit 1
    fi
}

# Install essential dependencies
install_deps() {
    log "INFO" "Updating package list and installing dependencies"
    
    # Update package list
    apt-get update -y >> "$LOG_FILE" 2>&1
    
    # Install required packages
    apt-get install -y \
        curl \
        wget \
        gnupg \
        ca-certificates \
        software-properties-common \
        lsb-release \
        unzip \
        dialog \
        ufw \
        apt-transport-https \
        debian-archive-keyring \
        debian-keyring >> "$LOG_FILE" 2>&1
    
    # Add Ondrej PHP repository for latest PHP versions
    add-apt-repository ppa:ondrej/php -y >> "$LOG_FILE" 2>&1
    
    # Update again after adding repository
    apt-get update -y >> "$LOG_FILE" 2>&1
}

# Install and configure MariaDB
install_mariadb() {
    log "INFO" "Installing and configuring MariaDB"
    
    # Install MariaDB
    apt-get install -y mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
    
    # Start and enable MariaDB
    systemctl start mariadb >> "$LOG_FILE" 2>&1
    systemctl enable mariadb >> "$LOG_FILE" 2>&1
    
    # Secure MariaDB installation
    log "INFO" "Securing MariaDB installation"
    
    # Create SQL commands for secure installation
    cat > /tmp/mariadb_secure.sql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    
    # Execute secure installation
    mysql -u root < /tmp/mariadb_secure.sql >> "$LOG_FILE" 2>&1
    rm -f /tmp/mariadb_secure.sql
    
    # Create WordPress database and user
    log "INFO" "Creating WordPress database and user"
    
    cat > /tmp/wp_db_setup.sql <<EOF
CREATE DATABASE IF NOT EXISTS ${WP_DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    mysql -u root -p"${MARIADB_ROOT_PASS}" < /tmp/wp_db_setup.sql >> "$LOG_FILE" 2>&1
    rm -f /tmp/wp_db_setup.sql
    
    log "INFO" "MariaDB installation completed"
}

# Install PHP and required extensions
install_php() {
    log "INFO" "Installing PHP ${PHP_VERSION} and extensions"
    
    # Install PHP and common extensions
    apt-get install -y \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-imagick >> "$LOG_FILE" 2>&1
    
    # Configure PHP for WordPress
    cat > /etc/php/${PHP_VERSION}/fpm/conf.d/99-wordpress.ini <<EOF
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
max_input_vars = 3000
EOF
    
    # Restart PHP-FPM
    systemctl restart php${PHP_VERSION}-fpm >> "$LOG_FILE" 2>&1
    systemctl enable php${PHP_VERSION}-fpm >> "$LOG_FILE" 2>&1
    
    log "INFO" "PHP ${PHP_VERSION} installation completed"
}

# Install Caddy web server
install_caddy() {
    log "INFO" "Installing Caddy web server"
    
    # Add Caddy repository
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    
    # Update and install Caddy
    apt-get update -y >> "$LOG_FILE" 2>&1
    apt-get install -y caddy >> "$LOG_FILE" 2>&1
    
    log "INFO" "Caddy installation completed"
}

# Install WordPress
install_wordpress() {
    log "INFO" "Installing WordPress"
    
    # Create web directory if it doesn't exist
    mkdir -p "${INSTALL_DIR}"
    
    # Download latest WordPress
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz
    tar -xzf /tmp/wordpress.tar.gz -C /tmp
    
    # Copy WordPress files
    cp -r /tmp/wordpress/* "${INSTALL_DIR}/"
    
    # Set permissions
    chown -R www-data:www-data "${INSTALL_DIR}"
    chmod -R 755 "${INSTALL_DIR}"
    chmod 644 "${INSTALL_DIR}/wp-config-sample.php"
    
    # Clean up
    rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
    
    log "INFO" "WordPress files installed"
}

# Configure Caddy for WordPress
configure_caddy() {
    log "INFO" "Configuring Caddy for WordPress"
    
    # Stop Caddy if running
    systemctl stop caddy 2>/dev/null || true
    
    # Create Caddyfile
    cat > "${CADDYFILE}" <<EOF
# WordPress site configuration
:80 {
    root * ${INSTALL_DIR}
    php_fastcgi unix:/run/php/php${PHP_VERSION}-fpm.sock
    file_server
    
    # WordPress-specific routing
    @wordpress {
        file {
            try_files {path} {path}/ /index.php?{query}
        }
    }
    rewrite @wordpress /index.php?{query}
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
    }
    
    # Handle static files
    @static {
        file
        path *.css *.js *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot
    }
    header @static Cache-Control "public, max-age=31536000"
    
    # Logging
    log {
        output file /var/log/caddy/access.log
    }
}
EOF
    
    # Create log directory
    mkdir -p /var/log/caddy
    chown -R caddy:caddy /var/log/caddy
    
    # Start Caddy
    systemctl start caddy >> "$LOG_FILE" 2>&1
    systemctl enable caddy >> "$LOG_FILE" 2>&1
    
    log "INFO" "Caddy configuration completed"
}

# Configure firewall
configure_firewall() {
    log "INFO" "Configuring firewall"
    
    # Enable UFW if not enabled
    ufw --force enable >> "$LOG_FILE" 2>&1
    
    # Allow SSH (keep existing)
    ufw allow OpenSSH >> "$LOG_FILE" 2>&1
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    
    # Reload firewall
    ufw reload >> "$LOG_FILE" 2>&1
    
    log "INFO" "Firewall configured"
}

# Create WordPress configuration
create_wp_config() {
    log "INFO" "Creating WordPress configuration file"
    
    # Copy sample config
    cp "${INSTALL_DIR}/wp-config-sample.php" "${INSTALL_DIR}/wp-config.php"
    
    # Generate unique salts
    SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    
    # Update wp-config.php with database settings
    cat > "${INSTALL_DIR}/wp-config.php" <<EOF
<?php
/**
 * WordPress Configuration File
 */

// ** Database settings ** //
define('DB_NAME', '${WP_DB_NAME}');
define('DB_USER', '${WP_DB_USER}');
define('DB_PASSWORD', '${WP_DB_PASS}');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

/**#@+
 * Authentication Unique Keys and Salts.
 */
${SALTS}
/**#@-*/

/**
 * WordPress Database Table prefix.
 */
\$table_prefix = 'wp_';

/**
 * For developers: WordPress debugging mode.
 */
define('WP_DEBUG', false);

/* Add any custom values between this line and the "stop editing" line. */



/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';
EOF
    
    # Set permissions
    chown www-data:www-data "${INSTALL_DIR}/wp-config.php"
    chmod 644 "${INSTALL_DIR}/wp-config.php"
    
    log "INFO" "WordPress configuration created"
}

# Verify installation
verify_installation() {
    log "INFO" "Verifying installation"
    
    echo -e "\n${YELLOW}Verifying services...${NC}"
    
    # Check MariaDB
    if systemctl is-active --quiet mariadb; then
        echo -e "${GREEN}✓ MariaDB is running${NC}"
    else
        echo -e "${RED}✗ MariaDB is not running${NC}"
        return 1
    fi
    
    # Check PHP-FPM
    if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
        echo -e "${GREEN}✓ PHP-FPM is running${NC}"
    else
        echo -e "${RED}✗ PHP-FPM is not running${NC}"
        return 1
    fi
    
    # Check Caddy
    if systemctl is-active --quiet caddy; then
        echo -e "${GREEN}✓ Caddy is running${NC}"
    else
        echo -e "${RED}✗ Caddy is not running${NC}"
        return 1
    fi
    
    # Test WordPress accessibility
    if curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}" | grep -q "200\|302"; then
        echo -e "${GREEN}✓ WordPress is accessible${NC}"
    else
        echo -e "${RED}✗ Cannot access WordPress${NC}"
        return 1
    fi
    
    return 0
}

# Display installation summary
show_summary() {
    clear
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           WORDPRESS INSTALLATION COMPLETE                 ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Access Information:${NC}"
    echo -e "  Website URL:    http://${SERVER_IP}"
    echo -e "                  http://${DOMAIN}"
    echo ""
    echo -e "${YELLOW}Database Information (for WordPress setup):${NC}"
    echo -e "  Database Name:  ${WP_DB_NAME}"
    echo -e "  Database User:  ${WP_DB_USER}"
    echo -e "  Database Pass:  ${WP_DB_PASS}"
    echo -e "  Database Host:  localhost"
    echo ""
    echo -e "${YELLOW}MariaDB Root Password (keep secure):${NC}"
    echo -e "  ${MARIADB_ROOT_PASS}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Open your browser and go to: http://${SERVER_IP}"
    echo -e "  2. Complete the WordPress 5-minute installation"
    echo -e "  3. Use the database credentials above when prompted"
    echo ""
    echo -e "${YELLOW}Services Status:${NC}"
    systemctl status mariadb --no-pager | grep -E "Active:|Loaded:"
    systemctl status php${PHP_VERSION}-fpm --no-pager | grep -E "Active:|Loaded:"
    systemctl status caddy --no-pager | grep -E "Active:|Loaded:"
    echo ""
    echo -e "${YELLOW}Log File: ${LOG_FILE}${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    
    # Keep the script running for monitoring
    echo -e "\n${YELLOW}Monitoring services (press Ctrl+C to exit)...${NC}"
    echo ""
    
    # Show real-time status for a while
    for i in {1..60}; do
        echo -ne "\r[$(date '+%H:%M:%S')] Services running: "
        if systemctl is-active --quiet mariadb; then echo -ne "${GREEN}MARIADB${NC} "; else echo -ne "${RED}MARIADB${NC} "; fi
        if systemctl is-active --quiet php${PHP_VERSION}-fpm; then echo -ne "${GREEN}PHP${NC} "; else echo -ne "${RED}PHP${NC} "; fi
        if systemctl is-active --quiet caddy; then echo -ne "${GREEN}CADDY${NC} "; else echo -ne "${RED}CADDY${NC} "; fi
        echo -n "| Elapsed: ${i}s"
        sleep 1
    done
    
    echo -e "\n\n${GREEN}Installation stable. You can now configure WordPress via the web interface.${NC}"
}

# Main installation process
main_installation() {
    local total_steps=8
    local current_step=1
    
    echo -e "${GREEN}Starting WordPress installation...${NC}"
    echo -e "Log file: ${LOG_FILE}"
    echo ""
    
    # Step 1: Check root and update system
    show_progress $current_step $total_steps "Checking system and updating packages"
    check_root
    install_deps
    ((current_step++))
    
    # Step 2: Install MariaDB
    show_progress $current_step $total_steps "Installing and configuring MariaDB"
    install_mariadb
    ((current_step++))
    
    # Step 3: Install PHP
    show_progress $current_step $total_steps "Installing PHP ${PHP_VERSION} and extensions"
    install_php
    ((current_step++))
    
    # Step 4: Install Caddy
    show_progress $current_step $total_steps "Installing Caddy web server"
    install_caddy
    ((current_step++))
    
    # Step 5: Install WordPress
    show_progress $current_step $total_steps "Downloading and installing WordPress"
    install_wordpress
    ((current_step++))
    
    # Step 6: Configure Caddy
    show_progress $current_step $total_steps "Configuring Caddy for WordPress"
    configure_caddy
    ((current_step++))
    
    # Step 7: Configure firewall
    show_progress $current_step $total_steps "Configuring firewall"
    configure_firewall
    ((current_step++))
    
    # Step 8: Create WordPress config
    show_progress $current_step $total_steps "Creating WordPress configuration"
    create_wp_config
    
    echo -e "\n${GREEN}✓ Installation steps completed${NC}"
    
    # Verify installation
    if verify_installation; then
        show_summary
    else
        echo -e "${RED}Installation verification failed. Check $LOG_FILE for details.${NC}"
        exit 1
    fi
}

# Main execution
main() {
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}     WordPress Minimal Installer (Caddy + MariaDB)          ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}This script will install:${NC}"
    echo -e "  • WordPress (latest version)"
    echo -e "  • Caddy web server (with automatic HTTPS)"
    echo -e "  • MariaDB database server"
    echo -e "  • PHP ${PHP_VERSION} with required extensions"
    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "  • Installation directory: ${INSTALL_DIR}"
    echo -e "  • Domain: ${DOMAIN}"
    echo -e "  • Server IP: ${SERVER_IP}"
    echo ""
    
    # Ask for confirmation
    read -p "Do you want to proceed with the installation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
    
    # Clear log file
    > "$LOG_FILE"
    
    # Start installation
    main_installation
}

# Run main function
main "$@"
