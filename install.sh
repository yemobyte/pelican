#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/var/www/pelican"
SERVICE_USER="pelican"
PANEL_DIR="$INSTALL_DIR"
OS_TYPE=""
OS_VERSION=""
PKG_MANAGER=""
INSTALL_WINGS=false
DOMAIN=""
DB_NAME=""
DB_USER=""
DB_PASS=""
ADMIN_EMAIL=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
PANEL_URL=""
WINGS_TOKEN=""

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

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

get_user_input() {
    log_info "Pelican Panel Installation"
    echo ""
    log_info "Please provide the following information:"
    echo ""
    
    while [ -z "$DOMAIN" ]; do
        echo -n "Domain name (or IP address): "
        read DOMAIN
        if [ -z "$DOMAIN" ]; then
            log_error "Domain is required! Please enter your domain or IP address."
        fi
    done
    
    echo ""
    log_info "Database Configuration:"
    echo -n "Database name [pelican]: "
    read DB_NAME
    DB_NAME=${DB_NAME:-pelican}
    
    echo -n "Database username [pelican]: "
    read DB_USER
    DB_USER=${DB_USER:-pelican}
    
    echo -n "Database password (press Enter for auto-generate): "
    read -s DB_PASS
    echo ""
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(generate_password)
        log_info "Auto-generated database password"
    fi
    
    echo ""
    log_info "Admin User Configuration:"
    echo -n "Admin email [admin@pelican.local]: "
    read ADMIN_EMAIL
    ADMIN_EMAIL=${ADMIN_EMAIL:-admin@pelican.local}
    
    echo -n "Admin username [admin]: "
    read ADMIN_USERNAME
    ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
    
    echo -n "Admin password (press Enter for auto-generate): "
    read -s ADMIN_PASSWORD
    echo ""
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(generate_password)
        log_info "Auto-generated admin password"
    fi
    
    echo ""
    echo -n "Install Wings? (y/n) [y]: "
    read INSTALL_WINGS_CHOICE
    INSTALL_WINGS_CHOICE=${INSTALL_WINGS_CHOICE:-y}
    if [[ "$INSTALL_WINGS_CHOICE" =~ ^[Yy]$ ]]; then
        INSTALL_WINGS=true
        echo -n "Wings API token (leave empty to configure later): "
        read WINGS_TOKEN
    fi
    
    PANEL_URL="http://$DOMAIN"
    
    echo ""
    log_info "Configuration Summary:"
    echo "Domain: $DOMAIN"
    echo "Database: $DB_NAME"
    echo "Database User: $DB_USER"
    echo "Admin Email: $ADMIN_EMAIL"
    echo "Admin Username: $ADMIN_USERNAME"
    echo "Install Wings: $INSTALL_WINGS"
    echo ""
    echo -n "Continue with installation? (y/n) [y]: "
    read CONFIRM
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
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
            log_warning "Unsupported operating system detected: $OS_TYPE"
            if [ -f /etc/debian_version ]; then
                PKG_MANAGER="apt"
                log_info "Assuming Debian-based system, using apt"
            elif [ -f /etc/redhat-release ]; then
                if command -v dnf &> /dev/null; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
                log_info "Assuming RHEL-based system, using $PKG_MANAGER"
            else
                log_warning "Unknown OS type, attempting to detect package manager..."
                if command -v apt-get &> /dev/null; then
                    PKG_MANAGER="apt"
                    log_info "Detected apt package manager"
                elif command -v dnf &> /dev/null; then
                    PKG_MANAGER="dnf"
                    log_info "Detected dnf package manager"
                elif command -v yum &> /dev/null; then
                    PKG_MANAGER="yum"
                    log_info "Detected yum package manager"
                else
                    log_error "Cannot determine package manager for $OS_TYPE"
                    exit 1
                fi
            fi
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
    log_info "Installing PHP 8.4/8.3/8.2..."
    
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
            if ! grep -q "ondrej/php" /etc/apt/sources.list.d/*.list 2>/dev/null; then
                add-apt-repository -y ppa:ondrej/php
            fi
            apt-get update
            if apt-cache show php8.4-fpm &>/dev/null; then
                apt-get install -y php8.4 php8.4-cli php8.4-fpm php8.4-common php8.4-mysql php8.4-zip php8.4-gd php8.4-mbstring php8.4-curl php8.4-xml php8.4-bcmath php8.4-intl php8.4-sqlite3
                PHP_VERSION="8.4"
            elif apt-cache show php8.3-fpm &>/dev/null; then
                apt-get install -y php8.3 php8.3-cli php8.3-fpm php8.3-common php8.3-mysql php8.3-zip php8.3-gd php8.3-mbstring php8.3-curl php8.3-xml php8.3-bcmath php8.3-intl php8.3-sqlite3
                PHP_VERSION="8.3"
            else
                apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-sqlite3
                PHP_VERSION="8.2"
            fi
            ;;
        dnf|yum)
            if [ "$OS_TYPE" == "almalinux" ] || [ "$OS_TYPE" == "rocky" ] || [ "$OS_TYPE" == "centos" ]; then
                if ! rpm -q epel-release &>/dev/null; then
                    $PKG_MANAGER install -y epel-release
                fi
                if [ ! -f /etc/yum.repos.d/remi.repo ]; then
                    $PKG_MANAGER install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm
                fi
                $PKG_MANAGER module reset php -y 2>/dev/null || true
                $PKG_MANAGER module enable php:remi-8.4 -y 2>/dev/null || $PKG_MANAGER module enable php:remi-8.3 -y 2>/dev/null || $PKG_MANAGER module enable php:remi-8.2 -y
                $PKG_MANAGER install -y php php-cli php-fpm php-common php-mysqlnd php-zip php-gd php-mbstring php-curl php-xml php-bcmath php-intl php-sqlite3
            fi
            ;;
    esac
    
    log_success "PHP installed"
}

install_php_extensions() {
    log_info "Checking PHP extensions..."
    
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    
    REQUIRED_EXTENSIONS=("bcmath" "ctype" "curl" "dom" "fileinfo" "gd" "hash" "iconv" "intl" "json" "mbstring" "openssl" "session" "tokenizer" "xml" "zip")
    
    MISSING_EXTENSIONS=()
    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! php -m | grep -q "^$ext$"; then
            MISSING_EXTENSIONS+=("$ext")
        fi
    done
    
    PDO_MYSQL_MISSING=false
    PDO_PGSQL_MISSING=false
    PDO_SQLITE_MISSING=false
    
    if ! php -m | grep -q "^pdo_mysql$"; then
        PDO_MYSQL_MISSING=true
    fi
    if ! php -m | grep -q "^pdo_pgsql$"; then
        PDO_PGSQL_MISSING=true
    fi
    if ! php -m | grep -q "^pdo_sqlite$"; then
        PDO_SQLITE_MISSING=true
    fi
    
    if [ ${#MISSING_EXTENSIONS[@]} -gt 0 ] || [ "$PDO_MYSQL_MISSING" = true ] || [ "$PDO_PGSQL_MISSING" = true ] || [ "$PDO_SQLITE_MISSING" = true ]; then
        if [ ${#MISSING_EXTENSIONS[@]} -gt 0 ]; then
            log_warning "Missing PHP extensions: ${MISSING_EXTENSIONS[*]}"
        fi
        if [ "$PDO_MYSQL_MISSING" = true ] || [ "$PDO_PGSQL_MISSING" = true ] || [ "$PDO_SQLITE_MISSING" = true ]; then
            PDO_MISSING_LIST=()
            [ "$PDO_MYSQL_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_mysql")
            [ "$PDO_PGSQL_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_pgsql")
            [ "$PDO_SQLITE_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_sqlite")
            log_warning "Missing PDO extensions: ${PDO_MISSING_LIST[*]}"
        fi
        log_info "Installing missing PHP extensions..."
        
        case "$PKG_MANAGER" in
            apt)
                apt-get update
                
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    log_info "Installing php${PHP_VERSION}-${ext}..."
                    if apt-get install -y "php${PHP_VERSION}-${ext}" 2>/dev/null; then
                        log_info "Installed php${PHP_VERSION}-${ext}"
                    elif apt-get install -y "php-${ext}" 2>/dev/null; then
                        log_info "Installed php-${ext}"
                    else
                        log_warning "Failed to install php-${ext}"
                    fi
                done
                
                if [ "$PDO_MYSQL_MISSING" = true ]; then
                    log_info "Installing php${PHP_VERSION}-mysql for pdo_mysql..."
                    if apt-get install -y "php${PHP_VERSION}-mysql" 2>/dev/null; then
                        log_info "Installed php${PHP_VERSION}-mysql (pdo_mysql)"
                    else
                        log_warning "Failed to install php${PHP_VERSION}-mysql"
                    fi
                fi
                
                if [ "$PDO_PGSQL_MISSING" = true ]; then
                    log_info "Installing php${PHP_VERSION}-pgsql for pdo_pgsql..."
                    if apt-get install -y "php${PHP_VERSION}-pgsql" 2>/dev/null; then
                        log_info "Installed php${PHP_VERSION}-pgsql (pdo_pgsql)"
                    else
                        log_warning "Failed to install php${PHP_VERSION}-pgsql"
                    fi
                fi
                
                if [ "$PDO_SQLITE_MISSING" = true ]; then
                    log_info "Installing php${PHP_VERSION}-sqlite3 for pdo_sqlite..."
                    if apt-get install -y "php${PHP_VERSION}-sqlite3" 2>/dev/null; then
                        log_info "Installed php${PHP_VERSION}-sqlite3 (pdo_sqlite)"
                    else
                        log_warning "Failed to install php${PHP_VERSION}-sqlite3"
                    fi
                fi
                ;;
            dnf|yum)
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    log_info "Installing php-${ext}..."
                    if $PKG_MANAGER install -y "php-${ext}" 2>/dev/null; then
                        log_info "Installed php-${ext}"
                    else
                        log_warning "Failed to install php-${ext}"
                    fi
                done
                
                if [ "$PDO_MYSQL_MISSING" = true ]; then
                    log_info "Installing php-mysqlnd for pdo_mysql..."
                    if $PKG_MANAGER install -y "php-mysqlnd" 2>/dev/null; then
                        log_info "Installed php-mysqlnd (pdo_mysql)"
                    else
                        log_warning "Failed to install php-mysqlnd"
                    fi
                fi
                
                if [ "$PDO_PGSQL_MISSING" = true ]; then
                    log_info "Installing php-pgsql for pdo_pgsql..."
                    if $PKG_MANAGER install -y "php-pgsql" 2>/dev/null; then
                        log_info "Installed php-pgsql (pdo_pgsql)"
                    else
                        log_warning "Failed to install php-pgsql"
                    fi
                fi
                
                if [ "$PDO_SQLITE_MISSING" = true ]; then
                    log_info "Installing php-sqlite3 for pdo_sqlite..."
                    if $PKG_MANAGER install -y "php-sqlite3" 2>/dev/null; then
                        log_info "Installed php-sqlite3 (pdo_sqlite)"
                    else
                        log_warning "Failed to install php-sqlite3"
                    fi
                fi
                ;;
        esac
    fi
    
    log_info "Verifying PHP extensions..."
    FINAL_MISSING=()
    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! php -m | grep -q "^$ext$"; then
            FINAL_MISSING+=("$ext")
        fi
    done
    
    if ! php -m | grep -q "^pdo_mysql$"; then
        FINAL_MISSING+=("pdo_mysql")
    fi
    if ! php -m | grep -q "^pdo_pgsql$"; then
        FINAL_MISSING+=("pdo_pgsql")
    fi
    if ! php -m | grep -q "^pdo_sqlite$"; then
        FINAL_MISSING+=("pdo_sqlite")
    fi
    
    if [ ${#FINAL_MISSING[@]} -gt 0 ]; then
        log_warning "Still missing extensions: ${FINAL_MISSING[*]}"
        log_info "You may need to install them manually"
    else
        log_success "All required PHP extensions are installed"
    fi
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
    log_info "Installing MariaDB..."
    
    case "$PKG_MANAGER" in
        apt)
            debconf-set-selections <<< "mariadb-server mariadb-server/root_password password root"
            debconf-set-selections <<< "mariadb-server mariadb-server/root_password_again password root"
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
    
    sleep 5
    
    log_success "MariaDB installed"
}

setup_database_auto() {
    log_info "Setting up database automatically..."
    
    if ! systemctl is-active --quiet mariadb && ! systemctl is-active --quiet mysql; then
        log_warning "Database service not running, attempting to start..."
        systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
        sleep 3
    fi
    
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
            log_error "Could not create database. Please check MariaDB installation."
            exit 1
        }
    }
    
    mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || {
        mysql -u root -proot -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
    }
    
    mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
        mysql -u root -proot -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
            log_error "Could not create database user."
            exit 1
        }
    }
    
    mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || {
        mysql -u root -proot -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || {
            log_error "Could not grant privileges."
            exit 1
        }
    }
    
    mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || {
        mysql -u root -proot -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    }
    
    log_success "Database '$DB_NAME' and user '$DB_USER' created"
}

create_user() {
    log_info "Creating pelican user..."
    
    if id "$SERVICE_USER" &>/dev/null; then
        log_warning "User $SERVICE_USER already exists"
    else
        useradd -r -s /bin/bash -d /home/pelican -m "$SERVICE_USER"
        log_success "User $SERVICE_USER created"
    fi
}

install_panel() {
    log_info "Installing Pelican Panel..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    if [ -d "$PANEL_DIR" ] && [ "$(ls -A $PANEL_DIR)" ]; then
        log_warning "Panel directory already exists, backing up..."
        mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$PANEL_DIR"
    fi
    
    log_info "Downloading Pelican Panel..."
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv || {
        log_error "Failed to download Pelican Panel"
        exit 1
    }
    
    log_info "Setting permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    log_success "Pelican Panel downloaded"
}

install_panel_dependencies() {
    log_info "Installing Panel dependencies..."
    cd "$PANEL_DIR"
    
    COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$SERVICE_USER" composer install --no-dev --optimize-autoloader --no-interaction || {
        log_error "Failed to install PHP dependencies"
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
    fi
    
    log_info "Configuring .env file..."
    
    if [ -z "$PANEL_URL" ]; then
        if [ -n "$DOMAIN" ]; then
            PANEL_URL="http://$DOMAIN"
        else
            PANEL_URL="http://$(hostname -I | awk '{print $1}')"
        fi
    fi
    
    sudo -u "$SERVICE_USER" php artisan key:generate --force
    
    sudo -u "$SERVICE_USER" sed -i "s|APP_URL=.*|APP_URL=$PANEL_URL|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_PORT=.*|DB_PORT=3306|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|g" .env
    sudo -u "$SERVICE_USER" sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|g" .env
    
    sudo -u "$SERVICE_USER" php artisan config:cache
    sudo -u "$SERVICE_USER" php artisan config:clear
    
    log_info "Setting up storage link..."
    sudo -u "$SERVICE_USER" php artisan storage:link || {
        log_warning "Failed to create storage link"
    }
    
    log_success "Panel environment configured"
}

build_panel_assets() {
    log_info "Building Panel frontend assets..."
    cd "$PANEL_DIR"
    
    if [ -f package.json ]; then
        if ! command -v npm &> /dev/null; then
            install_nodejs
        fi
        if [ -f package-lock.json ]; then
            sudo -u "$SERVICE_USER" npm ci --only=production || {
                log_warning "Failed to install Node.js dependencies with npm ci, trying npm install"
                sudo -u "$SERVICE_USER" npm install --only=production || {
                    log_warning "Failed to install Node.js dependencies, skipping build"
                    return
                }
            }
        else
            sudo -u "$SERVICE_USER" npm install --only=production || {
                log_warning "Failed to install Node.js dependencies, skipping build"
                return
            }
        fi
        sudo -u "$SERVICE_USER" npm run build || {
            log_warning "Failed to build assets"
        }
    fi
    
    log_success "Panel assets built"
}

install_docker() {
    log_info "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker already installed"
        return
    fi
    
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    CHANNEL=stable sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    
    usermod -aG docker "$SERVICE_USER"
    
    systemctl enable docker
    systemctl start docker
    
    log_success "Docker installed"
}

install_wings() {
    log_info "Installing Pelican Wings..."
    
    install_docker
    
    mkdir -p "$WINGS_DIR" /var/run/wings
    cd "$INSTALL_DIR"
    
    if [ -d "$WINGS_DIR" ] && [ "$(ls -A $WINGS_DIR)" ]; then
        log_warning "Wings directory already exists, backing up..."
        mv "$WINGS_DIR" "${WINGS_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$WINGS_DIR"
    fi
    
    log_info "Downloading Wings..."
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WINGS_ARCH="amd64" ;;
        aarch64|arm64) WINGS_ARCH="arm64" ;;
        *) WINGS_ARCH="amd64" ;;
    esac
    
    WINGS_URL="https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
    
    curl -L -o /usr/local/bin/wings "$WINGS_URL" || {
        log_error "Failed to download Wings"
        exit 1
    }
    
    chmod +x /usr/local/bin/wings
    
    log_success "Wings downloaded"
    
    log_info "Creating Wings configuration directory..."
    mkdir -p /etc/pelican /var/run/wings
    chown -R "$SERVICE_USER:$SERVICE_USER" /etc/pelican /var/run/wings
    
    log_info "Wings config.yml will be created from Panel configuration"
    log_info "After Panel setup, go to Admin -> Nodes -> Configuration to get the config"
    
    log_info "Creating Wings systemd service..."
    cat > /etc/systemd/system/pelican-wings.service <<EOF
[Unit]
Description=Pelican Wings Daemon
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=/etc/pelican
ExecStart=/usr/local/bin/wings
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pelican-wings

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    log_success "Wings service created"
    log_info "To configure Wings:"
    log_info "1. Login to Panel: $PANEL_URL"
    log_info "2. Go to Admin -> Nodes -> Configuration"
    log_info "3. Copy the configuration and save to /etc/pelican/config.yml"
    log_info "4. Start Wings: systemctl enable --now pelican-wings"
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
    
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(hostname -f 2>/dev/null || hostname)
        if [ "$DOMAIN" = "localhost" ] || [ -z "$DOMAIN" ]; then
            DOMAIN=$(hostname -I | awk '{print $1}')
        fi
        log_info "Using domain/hostname: $DOMAIN"
    fi
    
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    PHP_FPM_SOCK="unix:/var/run/php/php${PHP_VERSION}-fpm.sock"
    
    if [ ! -S "/var/run/php/php${PHP_VERSION}-fpm.sock" ]; then
        if [ -S "/var/run/php/php-fpm.sock" ]; then
            PHP_FPM_SOCK="unix:/var/run/php/php-fpm.sock"
        elif [ -S "/var/run/php-fpm/php-fpm.sock" ]; then
            PHP_FPM_SOCK="unix:/var/run/php-fpm/php-fpm.sock"
        else
            PHP_FPM_SOCK="unix:/var/run/php/php${PHP_VERSION}-fpm.sock"
        fi
    fi
    
    cat > /etc/nginx/sites-available/pelican.conf <<EOF
server_tokens off;

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
        fastcgi_pass $PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    
    if [ -d /etc/nginx/sites-enabled ]; then
        ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/
    else
        mkdir -p /etc/nginx/sites-enabled
        ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/
    fi
    
    nginx -t || {
        log_error "Nginx configuration test failed"
        exit 1
    }
    
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx || {
            log_error "Failed to start nginx"
            exit 1
        }
    fi
    
    log_success "Nginx configured"
    
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_info "IP address detected, skipping SSL setup"
    else
        log_info "Domain detected: $DOMAIN"
        log_info "You can setup SSL later with: certbot --nginx -d $DOMAIN"
    fi
}

setup_ssl() {
    log_info "Setting up SSL with Let's Encrypt..."
    
    if ! command -v certbot &> /dev/null; then
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y certbot python3-certbot-nginx
                ;;
            dnf|yum)
                $PKG_MANAGER install -y certbot python3-certbot-nginx
                ;;
        esac
    fi
    
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || {
        log_warning "SSL setup failed. You can run 'certbot --nginx -d $DOMAIN' manually"
    }
    
    log_success "SSL configured"
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

setup_database() {
    log_info "Running database migrations and seeding..."
    cd "$PANEL_DIR"
    
    log_info "Running migrations..."
    sudo -u "$SERVICE_USER" php artisan migrate --force || {
        log_error "Migrations failed. Please check your database configuration in .env"
        exit 1
    }
    
    log_info "Seeding database..."
    sudo -u "$SERVICE_USER" php artisan db:seed --force || {
        log_warning "Database seeding failed"
    }
    
    log_success "Database setup completed"
}

create_admin_user() {
    log_info "Creating admin user..."
    cd "$PANEL_DIR"
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(generate_password)
    fi
    
    sudo -u "$SERVICE_USER" php artisan p:user:make \
        --email "$ADMIN_EMAIL" \
        --username "$ADMIN_USERNAME" \
        --password "$ADMIN_PASSWORD" \
        --admin || {
        log_warning "Failed to create admin user automatically"
        return
    }
    
    log_success "Admin user created"
    echo ""
    echo "=== Admin Credentials ==="
    echo "Email: $ADMIN_EMAIL"
    echo "Username: $ADMIN_USERNAME"
    echo "Password: $ADMIN_PASSWORD"
    echo ""
}

setup_firewall() {
    log_info "Setting up firewall..."
    
    if command -v ufw &> /dev/null; then
        log_info "Configuring UFW firewall..."
        ufw --force allow 22/tcp
        ufw --force allow 80/tcp
        ufw --force allow 443/tcp
        if [ "$INSTALL_WINGS" = true ]; then
            ufw --force allow 2022/tcp
            ufw --force allow 8080/tcp
        fi
        log_success "UFW firewall rules added"
    elif command -v firewall-cmd &> /dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        if [ "$INSTALL_WINGS" = true ]; then
            firewall-cmd --permanent --add-port=2022/tcp
            firewall-cmd --permanent --add-port=8080/tcp
        fi
        firewall-cmd --reload
        log_success "Firewalld configured"
    else
        log_info "No firewall detected, skipping firewall setup"
    fi
}

setup_permissions() {
    log_info "Setting up permissions..."
    
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    chmod -R 775 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    
    if [ "$INSTALL_WINGS" = true ]; then
        mkdir -p /var/lib/pelican /var/log/pelican
        chown -R "$SERVICE_USER:$SERVICE_USER" /var/lib/pelican /var/log/pelican
    fi
    
    log_success "Permissions configured"
}

print_summary() {
    log_success "Pelican installation completed!"
    echo ""
    echo "=== Installation Summary ==="
    echo "OS: $OS_TYPE $OS_VERSION"
    echo "Panel directory: $PANEL_DIR"
    echo "Database: $DB_NAME"
    echo "Database user: $DB_USER"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "Wings binary: /usr/local/bin/wings"
        echo "Wings config: /etc/pelican/config.yml"
    fi
    echo "Service user: $SERVICE_USER"
    echo ""
    echo "=== Access Information ==="
    if [ -n "$DOMAIN" ] && [[ ! "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Panel URL: http://$DOMAIN"
    else
        echo "Panel URL: $PANEL_URL"
    fi
    echo ""
    echo "=== Admin Credentials ==="
    echo "Email: $ADMIN_EMAIL"
    echo "Username: $ADMIN_USERNAME"
    echo "Password: $ADMIN_PASSWORD"
    echo ""
    echo "=== Database Credentials ==="
    echo "Database: $DB_NAME"
    echo "Username: $DB_USER"
    echo "Password: $DB_PASS"
    echo ""
    if [ "$INSTALL_WINGS" = true ] && [ -z "$WINGS_TOKEN" ]; then
        echo "=== Wings Configuration ==="
        echo "1. Login to Panel: $PANEL_URL"
        echo "2. Go to Admin -> Nodes -> Configuration"
        echo "3. Copy the configuration code"
        echo "4. Edit /etc/pelican/config.yml and paste the configuration"
        echo "5. Start Wings: systemctl enable --now pelican-wings"
        echo ""
    fi
    echo "=== Service Management ==="
    echo "Panel: systemctl {start|stop|restart|status} pelican-panel"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "Wings: systemctl {start|stop|restart|status} pelican-wings"
    fi
    echo ""
    echo "=== Logs ==="
    echo "Panel: journalctl -u pelican-panel -f"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "Wings: journalctl -u pelican-wings -f"
    fi
    echo ""
    echo "=== Important Files ==="
    echo "Panel .env: $PANEL_DIR/.env"
    if [ "$INSTALL_WINGS" = true ]; then
        echo "Wings config: /etc/pelican/config.yml"
    fi
}

main() {
    log_info "Starting Pelican installation..."
    
    check_root
    detect_os
    get_user_input
    install_system_dependencies
    install_php
    install_php_extensions
    install_composer
    install_nodejs
    install_database
    setup_database_auto
    create_user
    install_panel
    install_panel_dependencies
    setup_panel_environment
    build_panel_assets
    setup_permissions
    setup_database
    create_admin_user
    create_panel_systemd_service
    setup_nginx
    setup_cron
    if [ "$INSTALL_WINGS" = true ]; then
        install_wings
    fi
    setup_firewall
    start_services
    print_summary
    
    log_success "Installation completed successfully!"
}

start_services() {
    log_info "Starting services..."
    
    systemctl enable pelican-panel
    systemctl start pelican-panel
    
    if [ "$INSTALL_WINGS" = true ]; then
        if [ -n "$WINGS_TOKEN" ] && [ -n "$PANEL_URL" ]; then
            systemctl enable pelican-wings
            systemctl start pelican-wings
            log_success "Wings service started"
        else
            log_info "Wings service created but not started (needs API token configuration)"
        fi
    fi
    
    log_success "Services started"
}

main "$@"
