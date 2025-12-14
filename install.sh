#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/pelican"
SERVICE_USER="pelican"
PANEL_DIR="$INSTALL_DIR/panel"
WINGS_DIR="$INSTALL_DIR/wings"
OS_TYPE=""
OS_VERSION=""
PKG_MANAGER=""
INSTALL_WINGS=false

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

detect_os() {
    log_info "Detecting operating system..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/redhat-release ]; then
        if grep -q "CentOS" /etc/redhat-release; then
            OS_TYPE="centos"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        elif grep -q "Rocky" /etc/redhat-release; then
            OS_TYPE="rocky"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        elif grep -q "AlmaLinux" /etc/redhat-release; then
            OS_TYPE="almalinux"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        fi
    fi
    
    case "$OS_TYPE" in
        ubuntu)
            if [[ "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
                log_warning "Ubuntu $OS_VERSION detected. Supported versions: 22.04, 24.04"
            fi
            PKG_MANAGER="apt"
            ;;
        debian)
            if [[ "$OS_VERSION" != "11" && "$OS_VERSION" != "12" ]]; then
                log_warning "Debian $OS_VERSION detected. Supported versions: 11, 12"
            fi
            PKG_MANAGER="apt"
            ;;
        almalinux|rocky|centos)
            if [[ "$OS_VERSION" != "8" && "$OS_VERSION" != "9" && "$OS_VERSION" != "10" ]]; then
                log_warning "$OS_TYPE $OS_VERSION detected. Supported versions: 8, 9, 10"
            fi
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            log_error "Unsupported operating system: $OS_TYPE"
            log_info "Supported OS: Ubuntu 22.04/24.04, Debian 11/12, Alma Linux 8/9/10, Rocky Linux 8/9/10, CentOS 10"
            exit 1
            ;;
    esac
    
    log_success "Detected: $OS_TYPE $OS_VERSION"
}

install_system_dependencies() {
    log_info "Installing system dependencies for $OS_TYPE $OS_VERSION..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update
            apt-get install -y curl wget unzip git tar software-properties-common apt-transport-https ca-certificates gnupg lsb-release
            ;;
        dnf|yum)
            $PKG_MANAGER install -y curl wget unzip git tar ca-certificates
            ;;
    esac
    
    log_success "System dependencies installed"
}

install_php() {
    log_info "Installing PHP 8.2+..."
    
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
        PHP_MINOR=$(php -r 'echo PHP_VERSION;' | cut -d. -f2)
        if [ "$PHP_MINOR" -ge 2 ]; then
            log_info "PHP $PHP_VERSION already installed"
            return
        fi
    fi
    
    case "$PKG_MANAGER" in
        apt)
            add-apt-repository -y ppa:ondrej/php
            apt-get update
            apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-pgsql php8.2-sqlite3
            ;;
        dnf|yum)
            if [ "$OS_TYPE" == "almalinux" ] || [ "$OS_TYPE" == "rocky" ] || [ "$OS_TYPE" == "centos" ]; then
                $PKG_MANAGER install -y epel-release
                $PKG_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm
                $PKG_MANAGER module reset php -y
                $PKG_MANAGER module enable php:remi-8.2 -y
                $PKG_MANAGER install -y php php-cli php-fpm php-common php-mysqlnd php-zip php-gd php-mbstring php-curl php-xml php-bcmath php-intl php-pgsql php-sqlite3
            fi
            ;;
    esac
    
    log_success "PHP installed"
}

install_php_extensions() {
    log_info "Checking PHP extensions..."
    
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    REQUIRED_EXTENSIONS=("bcmath" "ctype" "curl" "dom" "fileinfo" "gd" "hash" "iconv" "intl" "json" "mbstring" "openssl" "pdo" "pdo_mysql" "pdo_pgsql" "pdo_sqlite" "session" "tokenizer" "xml" "zip")
    
    MISSING_EXTENSIONS=()
    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! php -m | grep -q "^$ext$"; then
            MISSING_EXTENSIONS+=("$ext")
        fi
    done
    
    if [ ${#MISSING_EXTENSIONS[@]} -gt 0 ]; then
        log_warning "Missing PHP extensions: ${MISSING_EXTENSIONS[*]}"
        log_info "Installing missing PHP extensions..."
        
        case "$PKG_MANAGER" in
            apt)
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    apt-get install -y "php${PHP_VERSION}-${ext}" 2>/dev/null || apt-get install -y "php-${ext}" 2>/dev/null || log_warning "Failed to install php-${ext}"
                done
                ;;
            dnf|yum)
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    $PKG_MANAGER install -y "php-${ext}" 2>/dev/null || log_warning "Failed to install php-${ext}"
                done
                ;;
        esac
    fi
    
    log_success "PHP extensions checked"
}

install_composer() {
    if ! command -v composer &> /dev/null; then
        log_info "Installing Composer..."
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || {
            log_error "Failed to install Composer"
            exit 1
        }
        chmod +x /usr/local/bin/composer
        log_success "Composer installed"
    else
        log_info "Composer already installed"
    fi
}

install_nodejs() {
    if ! command -v node &> /dev/null; then
        log_info "Installing Node.js..."
        
        case "$PKG_MANAGER" in
            apt)
                curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
                apt-get install -y nodejs
                ;;
            dnf|yum)
                curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
                $PKG_MANAGER install -y nodejs
                ;;
        esac
        
        log_success "Node.js installed"
    else
        log_info "Node.js already installed"
    fi
}

install_database() {
    log_info "Database installation..."
    
    read -p "Install MySQL/MariaDB? (y/n): " INSTALL_DB
    
    if [[ "$INSTALL_DB" =~ ^[Yy]$ ]]; then
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y mariadb-server mariadb-client
                systemctl enable mariadb
                systemctl start mariadb
                ;;
            dnf|yum)
                $PKG_MANAGER install -y mariadb-server mariadb
                systemctl enable mariadb
                systemctl start mariadb
                ;;
        esac
        log_success "MariaDB installed"
    else
        log_info "Skipping database installation"
    fi
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

install_panel() {
    log_info "Installing Pelican Panel..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    if [ -d "$PANEL_DIR" ]; then
        log_warning "Panel directory already exists, backing up..."
        mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    log_info "Cloning Pelican Panel repository..."
    if [ -d "$PANEL_DIR/.git" ]; then
        log_warning "Repository already exists, pulling latest changes..."
        cd "$PANEL_DIR"
        sudo -u "$SERVICE_USER" git pull || {
            log_error "Failed to pull latest changes"
            exit 1
        }
    else
        git clone https://github.com/pelican-dev/panel.git "$PANEL_DIR" || {
            log_error "Failed to clone Pelican Panel repository"
            exit 1
        }
    fi
    
    cd "$PANEL_DIR"
    
    log_info "Setting permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    log_success "Pelican Panel cloned"
}

install_panel_dependencies() {
    log_info "Installing Panel dependencies..."
    cd "$PANEL_DIR"
    
    COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$SERVICE_USER" composer install --no-dev --optimize-autoloader --no-interaction || {
        log_error "Failed to install PHP dependencies"
        exit 1
    }
    
    sudo -u "$SERVICE_USER" npm ci --only=production || {
        log_error "Failed to install Node.js dependencies"
        exit 1
    }
    
    log_success "Panel dependencies installed"
}

setup_panel_environment() {
    log_info "Setting up Panel environment..."
    cd "$PANEL_DIR"
    
    if [ ! -f .env ]; then
        log_info "Creating .env file..."
        if [ -f .env.example ]; then
            sudo -u "$SERVICE_USER" cp .env.example .env
        else
            sudo -u "$SERVICE_USER" touch .env
        fi
        
        log_info "Generating application key..."
        sudo -u "$SERVICE_USER" php artisan key:generate --force || {
            log_warning "Failed to generate application key"
        }
    else
        log_warning ".env file already exists"
    fi
    
    log_success "Panel environment configured"
}

build_panel_assets() {
    log_info "Building Panel frontend assets..."
    cd "$PANEL_DIR"
    
    sudo -u "$SERVICE_USER" npm run build
    
    log_success "Panel assets built"
}

install_wings() {
    log_info "Installing Pelican Wings..."
    
    read -p "Install Wings? (y/n): " INSTALL_WINGS_CHOICE
    
    if [[ ! "$INSTALL_WINGS_CHOICE" =~ ^[Yy]$ ]]; then
        log_info "Skipping Wings installation"
        return
    fi
    
    INSTALL_WINGS=true
    
    mkdir -p "$WINGS_DIR"
    cd "$INSTALL_DIR"
    
    if [ -d "$WINGS_DIR" ] && [ "$(ls -A $WINGS_DIR)" ]; then
        log_warning "Wings directory already exists, backing up..."
        mv "$WINGS_DIR" "${WINGS_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$WINGS_DIR"
    fi
    
    log_info "Downloading Wings..."
    
    WINGS_VERSION=$(curl -s https://api.github.com/repos/pelican-dev/wings/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$WINGS_VERSION" ]; then
        WINGS_VERSION="v1.0.0"
    fi
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WINGS_ARCH="amd64" ;;
        aarch64|arm64) WINGS_ARCH="arm64" ;;
        *) WINGS_ARCH="amd64" ;;
    esac
    
    WINGS_URL="https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
    
    curl -L -o "$WINGS_DIR/wings" "$WINGS_URL" || {
        log_error "Failed to download Wings"
        exit 1
    }
    
    chmod +x "$WINGS_DIR/wings"
    chown "$SERVICE_USER:$SERVICE_USER" "$WINGS_DIR/wings"
    
    log_success "Wings downloaded"
    
    log_info "Creating Wings configuration directory..."
    mkdir -p /etc/pelican
    chown "$SERVICE_USER:$SERVICE_USER" /etc/pelican
    
    log_info "Creating Wings systemd service..."
    cat > /etc/systemd/system/pelican-wings.service <<EOF
[Unit]
Description=Pelican Wings Daemon
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$WINGS_DIR
ExecStart=$WINGS_DIR/wings
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    log_success "Wings service created"
}

create_panel_systemd_service() {
    log_info "Creating Panel systemd service..."
    
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
    log_success "Panel systemd service created"
}

setup_nginx() {
    log_info "Setting up Nginx..."
    
    if ! command -v nginx &> /dev/null; then
        log_info "Installing Nginx..."
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y nginx
                ;;
            dnf|yum)
                $PKG_MANAGER install -y nginx
                ;;
        esac
        systemctl enable nginx
        systemctl start nginx
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

    if [ -d /etc/nginx/sites-enabled ]; then
        ln -sf /etc/nginx/sites-available/pelican-panel /etc/nginx/sites-enabled/
    else
        mkdir -p /etc/nginx/sites-enabled
        ln -sf /etc/nginx/sites-available/pelican-panel /etc/nginx/sites-enabled/
    fi
    
    nginx -t && systemctl reload nginx
    
    log_success "Nginx configured"
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
    log_success "Pelican installation completed!"
    echo ""
    echo "=== Installation Summary ==="
    echo "OS: $OS_TYPE $OS_VERSION"
    echo "Panel directory: $PANEL_DIR"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "Wings directory: $WINGS_DIR"
    fi
    echo "Service user: $SERVICE_USER"
    echo ""
    echo "=== Next Steps ==="
    echo "1. Configure database in $PANEL_DIR/.env"
    echo "2. Run migrations: cd $PANEL_DIR && php artisan migrate --seed"
    echo "3. Create admin user: cd $PANEL_DIR && php artisan p:user:make"
    echo "4. Start Panel queue: systemctl enable --now pelican-panel"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "5. Configure Wings: Edit /etc/pelican/config.yml"
        echo "6. Start Wings: systemctl enable --now pelican-wings"
    fi
    echo ""
    if [ -n "$DOMAIN" ]; then
        echo "Panel URL: http://$DOMAIN"
    else
        echo "Panel URL: http://$(hostname -I | awk '{print $1}')"
    fi
}

main() {
    log_info "Starting Pelican installation..."
    
    check_root
    detect_os
    install_system_dependencies
    install_php
    install_php_extensions
    install_composer
    install_nodejs
    install_database
    create_user
    install_panel
    install_panel_dependencies
    setup_panel_environment
    build_panel_assets
    create_panel_systemd_service
    setup_nginx
    setup_cron
    install_wings
    print_summary
    
    log_success "Installation completed successfully!"
}

main "$@"
