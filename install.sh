#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PELICAN_VERSION="1.0.0"
INSTALL_DIR="/opt/pelican"
SERVICE_USER="pelican"
PANEL_DIR="$INSTALL_DIR/panel"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_system() {
    log_info "Checking system requirements..."
    
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v unzip &> /dev/null; then
        log_warning "unzip not found, installing..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y unzip
        elif command -v yum &> /dev/null; then
            yum install -y unzip
        elif command -v dnf &> /dev/null; then
            dnf install -y unzip
        fi
    fi
    
    if ! command -v php &> /dev/null; then
        log_error "PHP is required but not installed"
        log_info "Please install PHP 8.1 or higher first"
        exit 1
    fi
    
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    REQUIRED_VERSION="8.1"
    
    if (( $(echo "$PHP_VERSION < $REQUIRED_VERSION" | bc -l) )); then
        log_error "PHP 8.1 or higher is required. Found: $PHP_VERSION"
        exit 1
    fi
    
    if ! command -v composer &> /dev/null; then
        log_warning "Composer not found, installing..."
        curl -sS https://getcomposer.org/installer | php
        mv composer.phar /usr/local/bin/composer
        chmod +x /usr/local/bin/composer
    fi
    
    if ! command -v node &> /dev/null; then
        log_warning "Node.js not found, installing..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt-get install -y nodejs
    fi
    
    if ! command -v npm &> /dev/null; then
        log_error "npm is required but not installed"
        exit 1
    fi
    
    log_success "System requirements check passed"
}

create_user() {
    log_info "Creating pelican user..."
    
    if id "$SERVICE_USER" &>/dev/null; then
        log_warning "User $SERVICE_USER already exists"
    else
        useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$SERVICE_USER"
        log_success "User $SERVICE_USER created"
    fi
}

install_pelican() {
    log_info "Installing Pelican Panel..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    if [ -d "$PANEL_DIR" ]; then
        log_warning "Panel directory already exists, backing up..."
        mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    log_info "Downloading Pelican Panel..."
    curl -L -o pelican-panel.zip https://github.com/pelican-dev/panel/releases/latest/download/panel.zip
    
    if [ ! -f pelican-panel.zip ]; then
        log_error "Failed to download Pelican Panel"
        exit 1
    fi
    
    log_info "Extracting Pelican Panel..."
    unzip -q pelican-panel.zip -d "$PANEL_DIR"
    rm pelican-panel.zip
    
    cd "$PANEL_DIR"
    
    log_info "Setting permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    log_success "Pelican Panel extracted"
}

install_dependencies() {
    log_info "Installing PHP dependencies..."
    cd "$PANEL_DIR"
    
    sudo -u "$SERVICE_USER" composer install --no-dev --optimize-autoloader --no-interaction
    
    log_info "Installing Node.js dependencies..."
    sudo -u "$SERVICE_USER" npm ci --only=production
    
    log_success "Dependencies installed"
}

setup_environment() {
    log_info "Setting up environment..."
    cd "$PANEL_DIR"
    
    if [ ! -f .env ]; then
        log_info "Creating .env file..."
        sudo -u "$SERVICE_USER" cp .env.example .env
        
        APP_KEY=$(sudo -u "$SERVICE_USER" php artisan key:generate --show 2>/dev/null || echo "")
        if [ -n "$APP_KEY" ]; then
            sudo -u "$SERVICE_USER" php artisan key:generate --force
        fi
    else
        log_warning ".env file already exists"
    fi
    
    log_success "Environment configured"
}

setup_database() {
    log_info "Database setup..."
    log_warning "Please configure your database in $PANEL_DIR/.env"
    log_info "After configuration, run: php artisan migrate --seed"
}

build_assets() {
    log_info "Building frontend assets..."
    cd "$PANEL_DIR"
    
    sudo -u "$SERVICE_USER" npm run build
    
    log_success "Frontend assets built"
}

create_systemd_service() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/pelican-panel.service <<EOF
[Unit]
Description=Pelican Panel Queue Worker
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$PANEL_DIR
ExecStart=/usr/bin/php artisan queue:work --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Systemd service created"
}

setup_nginx() {
    log_info "Setting up Nginx configuration..."
    
    if ! command -v nginx &> /dev/null; then
        log_warning "Nginx not found, skipping Nginx configuration"
        return
    fi
    
    read -p "Enter your domain name (or press Enter to skip): " DOMAIN
    
    if [ -z "$DOMAIN" ]; then
        log_warning "Skipping Nginx configuration"
        return
    fi
    
    cat > /etc/nginx/sites-available/pelican-panel <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $PANEL_DIR/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/pelican-panel /etc/nginx/sites-enabled/
    
    nginx -t && systemctl reload nginx
    
    log_success "Nginx configuration created"
}

setup_cron() {
    log_info "Setting up cron jobs..."
    
    CRON_FILE="/etc/cron.d/pelican-panel"
    
    cat > "$CRON_FILE" <<EOF
* * * * * $SERVICE_USER cd $PANEL_DIR && php artisan schedule:run >> /dev/null 2>&1
EOF

    chmod 0644 "$CRON_FILE"
    
    log_success "Cron jobs configured"
}

print_summary() {
    log_success "Pelican Panel installation completed!"
    echo ""
    echo "Installation directory: $PANEL_DIR"
    echo "Service user: $SERVICE_USER"
    echo ""
    echo "Next steps:"
    echo "1. Configure database in $PANEL_DIR/.env"
    echo "2. Run: cd $PANEL_DIR && php artisan migrate --seed"
    echo "3. Create admin user: cd $PANEL_DIR && php artisan p:user:make"
    echo "4. Start queue worker: systemctl enable --now pelican-panel"
    echo ""
    echo "Panel URL: http://$(hostname -I | awk '{print $1}')"
    if [ -n "$DOMAIN" ]; then
        echo "Panel URL: http://$DOMAIN"
    fi
}

main() {
    log_info "Starting Pelican Panel installation..."
    
    check_root
    check_system
    create_user
    install_pelican
    install_dependencies
    setup_environment
    setup_database
    build_assets
    create_systemd_service
    setup_nginx
    setup_cron
    print_summary
    
    log_success "Installation completed successfully!"
}

main "$@"
