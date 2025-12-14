#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PANEL_DIR="/var/www/pelican"
SERVICE_USER="pelican"

info() {
    echo -e "${BLUE}*${NC} $1"
}

success() {
    echo -e "${GREEN}*${NC} $1"
}

warning() {
    echo -e "${YELLOW}*${NC} $1"
}

error() {
    echo -e "${RED}*${NC} $1"
}

info "Checking Pelican Panel installation..."

PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

info "PHP Version: $PHP_VERSION"
info "PHP-FPM Service: $PHP_FPM_SERVICE"

if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    warning "PHP-FPM is not running, starting it..."
    systemctl start "$PHP_FPM_SERVICE" || {
        PHP_FPM_SERVICE="php-fpm"
        systemctl start "$PHP_FPM_SERVICE" || {
            error "Failed to start PHP-FPM"
            exit 1
        }
    }
    systemctl enable "$PHP_FPM_SERVICE"
    success "PHP-FPM started"
else
    success "PHP-FPM is running"
fi

if ! systemctl is-active --quiet nginx; then
    warning "Nginx is not running, starting it..."
    systemctl start nginx || {
        error "Failed to start nginx"
        journalctl -u nginx --no-pager -n 20
        exit 1
    }
    success "Nginx started"
else
    success "Nginx is running"
fi

if [ -d "$PANEL_DIR" ]; then
    info "Fixing permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    if [ -d "$PANEL_DIR/storage" ]; then
        chmod -R 775 "$PANEL_DIR/storage"
        chown -R "$SERVICE_USER:www-data" "$PANEL_DIR/storage" 2>/dev/null || chown -R "$SERVICE_USER:nginx" "$PANEL_DIR/storage" 2>/dev/null || chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR/storage"
    fi
    
    if [ -d "$PANEL_DIR/bootstrap/cache" ]; then
        chmod -R 775 "$PANEL_DIR/bootstrap/cache"
        chown -R "$SERVICE_USER:www-data" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || chown -R "$SERVICE_USER:nginx" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR/bootstrap/cache"
    fi
    
    success "Permissions fixed"
else
    error "Panel directory not found: $PANEL_DIR"
    exit 1
fi

if [ -f "$PANEL_DIR/.env" ]; then
    info "Clearing config cache..."
    cd "$PANEL_DIR"
    sudo -u "$SERVICE_USER" php artisan config:clear
    sudo -u "$SERVICE_USER" php artisan cache:clear
    sudo -u "$SERVICE_USER" php artisan view:clear
    success "Cache cleared"
else
    error ".env file not found: $PANEL_DIR/.env"
    exit 1
fi

nginx -t && systemctl reload nginx

success "Panel should be accessible now"
info "Check panel at: http://$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')"
info "Check nginx error log: tail -f /var/log/nginx/error.log"
info "Check PHP-FPM error log: tail -f /var/log/php${PHP_VERSION}-fpm.log"
