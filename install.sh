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
DOMAIN=""
DB_NAME=""
DB_USER=""
DB_PASS=""
ADMIN_EMAIL=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
PANEL_URL=""
INSTALL_WINGS=false
WINGS_TOKEN=""

output() {
    echo -e "* ${1}"
}

error() {
    COLOR=${RED}
    output "${COLOR}${1}${NC}" >&2
}

success() {
    COLOR=${GREEN}
    output "${COLOR}${1}${NC}"
}

warning() {
    COLOR=${YELLOW}
    output "${COLOR}${1}${NC}"
}

info() {
    COLOR=${BLUE}
    output "${COLOR}${1}${NC}"
}

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    info "Detecting operating system..."
    
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
                warning "Ubuntu $OS_VERSION detected. Supported versions: 22.04, 24.04"
            fi
            PKG_MANAGER="apt"
            ;;
        debian)
            if [[ "$OS_VERSION" != "11" && "$OS_VERSION" != "12" ]]; then
                warning "Debian $OS_VERSION detected. Supported versions: 11, 12"
            fi
            PKG_MANAGER="apt"
            ;;
        almalinux|rocky|centos)
            if [[ "$OS_VERSION" != "8" && "$OS_VERSION" != "9" && "$OS_VERSION" != "10" ]]; then
                warning "$OS_TYPE $OS_VERSION detected. Supported versions: 8, 9, 10"
            fi
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            error "Unsupported operating system: $OS_TYPE"
            info "Supported OS: Ubuntu 22.04/24.04, Debian 11/12, Alma Linux 8/9/10, Rocky Linux 8/9/10, CentOS 10"
            exit 1
            ;;
    esac
    
    success "Detected: $OS_TYPE $OS_VERSION"
}

install_system_dependencies() {
    info "Installing system dependencies for $OS_TYPE $OS_VERSION..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update
            apt-get install -y curl wget unzip git tar software-properties-common apt-transport-https ca-certificates gnupg lsb-release
            ;;
        dnf|yum)
            $PKG_MANAGER install -y curl wget unzip git tar ca-certificates
            ;;
    esac
    
    success "System dependencies installed"
}

install_php() {
    info "Installing PHP 8.4/8.3/8.2..."
    
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
        PHP_MINOR=$(php -r 'echo PHP_VERSION;' | cut -d. -f2)
        if [ "$PHP_MINOR" -ge 2 ]; then
            info "PHP $PHP_VERSION already installed"
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
    
    success "PHP installed"
}

install_php_extensions() {
    info "Checking PHP extensions..."
    
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
            warning "Missing PHP extensions: ${MISSING_EXTENSIONS[*]}"
        fi
        if [ "$PDO_MYSQL_MISSING" = true ] || [ "$PDO_PGSQL_MISSING" = true ] || [ "$PDO_SQLITE_MISSING" = true ]; then
            PDO_MISSING_LIST=()
            [ "$PDO_MYSQL_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_mysql")
            [ "$PDO_PGSQL_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_pgsql")
            [ "$PDO_SQLITE_MISSING" = true ] && PDO_MISSING_LIST+=("pdo_sqlite")
            warning "Missing PDO extensions: ${PDO_MISSING_LIST[*]}"
        fi
        info "Installing missing PHP extensions..."
        
        case "$PKG_MANAGER" in
            apt)
                apt-get update
                
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    if apt-get install -y "php${PHP_VERSION}-${ext}" 2>/dev/null; then
                        info "Installed php${PHP_VERSION}-${ext}"
                    elif apt-get install -y "php-${ext}" 2>/dev/null; then
                        info "Installed php-${ext}"
                    else
                        warning "Failed to install php-${ext}"
                    fi
                done
                
                if [ "$PDO_MYSQL_MISSING" = true ]; then
                    if apt-get install -y "php${PHP_VERSION}-mysql" 2>/dev/null; then
                        info "Installed php${PHP_VERSION}-mysql (pdo_mysql)"
                    else
                        warning "Failed to install php${PHP_VERSION}-mysql"
                    fi
                fi
                
                if [ "$PDO_PGSQL_MISSING" = true ]; then
                    if apt-get install -y "php${PHP_VERSION}-pgsql" 2>/dev/null; then
                        info "Installed php${PHP_VERSION}-pgsql (pdo_pgsql)"
                    else
                        warning "Failed to install php${PHP_VERSION}-pgsql"
                    fi
                fi
                
                if [ "$PDO_SQLITE_MISSING" = true ]; then
                    if apt-get install -y "php${PHP_VERSION}-sqlite3" 2>/dev/null; then
                        info "Installed php${PHP_VERSION}-sqlite3 (pdo_sqlite)"
                    else
                        warning "Failed to install php${PHP_VERSION}-sqlite3"
                    fi
                fi
                ;;
            dnf|yum)
                for ext in "${MISSING_EXTENSIONS[@]}"; do
                    if $PKG_MANAGER install -y "php-${ext}" 2>/dev/null; then
                        info "Installed php-${ext}"
                    else
                        warning "Failed to install php-${ext}"
                    fi
                done
                
                if [ "$PDO_MYSQL_MISSING" = true ]; then
                    if $PKG_MANAGER install -y "php-mysqlnd" 2>/dev/null; then
                        info "Installed php-mysqlnd (pdo_mysql)"
                    else
                        warning "Failed to install php-mysqlnd"
                    fi
                fi
                
                if [ "$PDO_PGSQL_MISSING" = true ]; then
                    if $PKG_MANAGER install -y "php-pgsql" 2>/dev/null; then
                        info "Installed php-pgsql (pdo_pgsql)"
                    else
                        warning "Failed to install php-pgsql"
                    fi
                fi
                
                if [ "$PDO_SQLITE_MISSING" = true ]; then
                    if $PKG_MANAGER install -y "php-sqlite3" 2>/dev/null; then
                        info "Installed php-sqlite3 (pdo_sqlite)"
                    else
                        warning "Failed to install php-sqlite3"
                    fi
                fi
                ;;
        esac
    fi
    
    info "Verifying PHP extensions..."
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
        warning "Still missing extensions: ${FINAL_MISSING[*]}"
        info "You may need to install them manually"
    else
        success "All required PHP extensions are installed"
    fi
}

install_composer() {
    if ! command -v composer &> /dev/null; then
        info "Installing Composer..."
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || {
            error "Failed to install Composer"
            exit 1
        }
        chmod +x /usr/local/bin/composer
        success "Composer installed"
    else
        info "Composer already installed"
    fi
}

install_nodejs() {
    if ! command -v node &> /dev/null; then
        info "Installing Node.js 22.x..."
        
        case "$PKG_MANAGER" in
            apt)
                curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
                apt-get install -y nodejs
                ;;
            dnf|yum)
                curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
                $PKG_MANAGER install -y nodejs
                ;;
        esac
        
        success "Node.js installed"
    else
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -lt 20 ]; then
            info "Node.js version is too old, upgrading to 22.x..."
            case "$PKG_MANAGER" in
                apt)
                    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
                    apt-get install -y nodejs
                    ;;
                dnf|yum)
                    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
                    $PKG_MANAGER install -y nodejs
                    ;;
            esac
            success "Node.js upgraded to 22.x"
        else
            info "Node.js already installed"
        fi
    fi
}

install_database() {
    info "Installing MariaDB..."
    
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
    
    success "MariaDB installed"
}

setup_database() {
    info "Setting up database..."
    
    if ! systemctl is-active --quiet mariadb && ! systemctl is-active --quiet mysql; then
        warning "Database service not running, attempting to start..."
        systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
        sleep 3
    fi
    
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
            error "Could not create database. Please check MariaDB installation."
            exit 1
        }
    }
    
    mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || {
        mysql -u root -proot -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
    }
    
    mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
        mysql -u root -proot -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
            error "Could not create database user."
            exit 1
        }
    }
    
    mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || {
        mysql -u root -proot -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || {
            error "Could not grant privileges."
            exit 1
        }
    }
    
    mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || {
        mysql -u root -proot -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    }
    
    success "Database '$DB_NAME' and user '$DB_USER' created"
}

create_user() {
    info "Creating pelican user..."
    
    if id "$SERVICE_USER" &>/dev/null; then
        warning "User $SERVICE_USER already exists"
    else
        useradd -r -s /bin/bash -d /home/pelican -m "$SERVICE_USER"
        success "User $SERVICE_USER created"
    fi
}

install_panel() {
    info "Installing Pelican Panel..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    if [ -d "$PANEL_DIR" ] && [ "$(ls -A $PANEL_DIR)" ]; then
        warning "Panel directory already exists, backing up..."
        mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$PANEL_DIR"
    fi
    
    info "Downloading Pelican Panel..."
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv || {
        error "Failed to download Pelican Panel"
        exit 1
    }
    
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    success "Pelican Panel downloaded"
}

install_panel_dependencies() {
    info "Installing Panel dependencies..."
    cd "$PANEL_DIR"
    
    if [ ! -f composer.json ]; then
        error "composer.json not found in $PANEL_DIR"
        exit 1
    fi
    
    if [ -d vendor ] && [ -f composer.lock ]; then
        info "Dependencies already installed, checking for updates..."
        COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$SERVICE_USER" composer update --no-dev --optimize-autoloader --no-interaction || {
            warning "Failed to update dependencies, trying fresh install..."
            rm -rf vendor composer.lock
            COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$SERVICE_USER" composer install --no-dev --optimize-autoloader --no-interaction || {
                error "Failed to install PHP dependencies"
                exit 1
            }
        }
    else
        COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$SERVICE_USER" composer install --no-dev --optimize-autoloader --no-interaction || {
            error "Failed to install PHP dependencies"
            exit 1
        }
    fi
    
    success "Panel dependencies installed"
}

setup_panel_environment() {
    info "Setting up Panel environment..."
    cd "$PANEL_DIR"
    
    if [ ! -f .env ]; then
        if [ -f .env.example ]; then
            sudo -u "$SERVICE_USER" cp .env.example .env
        else
            sudo -u "$SERVICE_USER" touch .env
        fi
    fi
    
    info "Configuring .env file..."
    
    sudo -u "$SERVICE_USER" php artisan key:generate --force
    
    if ! grep -q "APP_URL" .env; then
        echo "APP_URL=$PANEL_URL" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|APP_URL=.*|APP_URL=$PANEL_URL|g" .env
    fi
    
    if ! grep -q "DB_CONNECTION" .env; then
        echo "DB_CONNECTION=mysql" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
    fi
    
    if ! grep -q "DB_HOST" .env; then
        echo "DB_HOST=127.0.0.1" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
    fi
    
    if ! grep -q "DB_PORT" .env; then
        echo "DB_PORT=3306" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_PORT=.*|DB_PORT=3306|g" .env
    fi
    
    if ! grep -q "DB_DATABASE" .env; then
        echo "DB_DATABASE=$DB_NAME" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|g" .env
    fi
    
    if ! grep -q "DB_USERNAME" .env; then
        echo "DB_USERNAME=$DB_USER" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|g" .env
    fi
    
    if ! grep -q "DB_PASSWORD" .env; then
        echo "DB_PASSWORD=$DB_PASS" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|g" .env
    fi
    
    sudo -u "$SERVICE_USER" php artisan config:clear
    sudo -u "$SERVICE_USER" php artisan config:cache
    
    info "Setting up storage link..."
    sudo -u "$SERVICE_USER" php artisan storage:link || {
        warning "Failed to create storage link"
    }
    
    success "Panel environment configured"
}

build_panel_assets() {
    info "Building Panel frontend assets..."
    cd "$PANEL_DIR"
    
    if [ -f package.json ]; then
        if ! command -v npm &> /dev/null; then
            install_nodejs
        fi
        if [ -f package-lock.json ]; then
            sudo -u "$SERVICE_USER" npm ci --legacy-peer-deps || {
                warning "Failed to install Node.js dependencies with npm ci, trying npm install"
                sudo -u "$SERVICE_USER" npm install --legacy-peer-deps || {
                    warning "Failed to install Node.js dependencies, skipping build"
                    return
                }
            }
        else
            sudo -u "$SERVICE_USER" npm install --legacy-peer-deps || {
                warning "Failed to install Node.js dependencies, skipping build"
                return
            }
        fi
        sudo -u "$SERVICE_USER" npm run build || {
            warning "Failed to build assets"
        }
    fi
    
    success "Panel assets built"
}

setup_database_migrations() {
    info "Running database migrations and seeding..."
    cd "$PANEL_DIR"
    
    info "Running migrations..."
    sudo -u "$SERVICE_USER" php artisan migrate --force || {
        error "Migrations failed. Please check your database configuration in .env"
        exit 1
    }
    
    info "Seeding database..."
    sudo -u "$SERVICE_USER" php artisan db:seed --force || {
        warning "Database seeding failed"
    }
    
    success "Database setup completed"
}

create_admin_user() {
    info "Creating admin user..."
    cd "$PANEL_DIR"
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(generate_password)
    fi
    
    info "Checking if admin user already exists..."
    USER_EXISTS=$(sudo -u "$SERVICE_USER" php artisan tinker --execute="echo App\Models\User::where('email', '$ADMIN_EMAIL')->orWhere('username', '$ADMIN_USERNAME')->exists() ? 'yes' : 'no';" 2>/dev/null || echo "no")
    
    if [ "$USER_EXISTS" = "yes" ]; then
        warning "Admin user with email '$ADMIN_EMAIL' or username '$ADMIN_USERNAME' already exists"
        info "Skipping admin user creation"
        return
    fi
    
    sudo -u "$SERVICE_USER" php artisan p:user:make \
        --email "$ADMIN_EMAIL" \
        --username "$ADMIN_USERNAME" \
        --password "$ADMIN_PASSWORD" \
        --admin 2>&1 | grep -v "Duplicate entry" || {
        if sudo -u "$SERVICE_USER" php artisan tinker --execute="echo App\Models\User::where('email', '$ADMIN_EMAIL')->exists() ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
            warning "Admin user already exists, skipping creation"
        else
            warning "Failed to create admin user automatically"
        fi
        return
    }
    
    success "Admin user created"
}

create_panel_systemd_service() {
    info "Creating Panel systemd service..."
    
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
    success "Panel systemd service created"
}

setup_nginx() {
    info "Setting up Nginx..."
    
    if ! command -v nginx &> /dev/null; then
        info "Installing Nginx..."
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y nginx
                ;;
            dnf|yum)
                $PKG_MANAGER install -y nginx
                ;;
        esac
        systemctl enable nginx
    fi
    
    if command -v lsof &> /dev/null; then
        if lsof -i:80 &>/dev/null; then
            info "Port 80 is already in use, checking what's using it..."
            PORT_80_PID=$(lsof -ti:80 2>/dev/null | head -1)
            if [ -n "$PORT_80_PID" ]; then
                PORT_80_CMD=$(ps -p $PORT_80_PID -o comm= 2>/dev/null)
                warning "Port 80 is used by: $PORT_80_CMD (PID: $PORT_80_PID)"
                if [ "$PORT_80_CMD" = "nginx" ] || [ "$PORT_80_CMD" = "nginx:" ]; then
                    systemctl stop nginx
                    sleep 2
                elif [ "$PORT_80_CMD" = "apache2" ] || [ "$PORT_80_CMD" = "httpd" ]; then
                    warning "Apache is running on port 80, stopping it..."
                    systemctl stop apache2 2>/dev/null || systemctl stop httpd 2>/dev/null
                    systemctl disable apache2 2>/dev/null || systemctl disable httpd 2>/dev/null
                    sleep 2
                else
                    warning "Unknown service using port 80, attempting to stop nginx anyway..."
                    systemctl stop nginx 2>/dev/null || true
                    sleep 2
                fi
            fi
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ':80 '; then
            if systemctl is-active --quiet apache2; then
                warning "Apache2 is running, stopping it..."
                systemctl stop apache2
                systemctl disable apache2
                sleep 2
            fi
            if systemctl is-active --quiet nginx; then
                systemctl stop nginx
                sleep 2
            fi
        fi
    fi
    
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
        sleep 2
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

    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    
    if [ -d /etc/nginx/sites-enabled ]; then
        ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
    else
        mkdir -p /etc/nginx/sites-enabled
        ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
    fi
    
    nginx -t || {
        error "Nginx configuration test failed"
        exit 1
    }
    
    if command -v lsof &> /dev/null; then
        if lsof -i:80 &>/dev/null; then
            PORT_80_PID=$(lsof -ti:80 2>/dev/null | head -1)
            if [ -n "$PORT_80_PID" ]; then
                PORT_80_CMD=$(ps -p $PORT_80_PID -o comm= 2>/dev/null)
                if [ "$PORT_80_CMD" != "nginx" ] && [ "$PORT_80_CMD" != "nginx:" ]; then
                    error "Port 80 is still in use by $PORT_80_CMD (PID: $PORT_80_PID)"
                    error "Please stop the service using port 80 manually: kill $PORT_80_PID"
                    exit 1
                fi
            fi
        fi
    fi
    
    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        info "Starting PHP-FPM service..."
        systemctl start "$PHP_FPM_SERVICE" || {
            PHP_FPM_SERVICE="php-fpm"
            systemctl start "$PHP_FPM_SERVICE" || {
                error "Failed to start PHP-FPM"
                exit 1
            }
        }
        systemctl enable "$PHP_FPM_SERVICE"
    fi
    
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx || {
            error "Failed to start nginx"
            if command -v lsof &> /dev/null && lsof -i:80 &>/dev/null; then
                error "Port 80 is still in use. Checking..."
                lsof -i:80
            fi
            journalctl -u nginx --no-pager -n 20
            exit 1
        }
    fi
    
    sleep 3
    
    if ! systemctl is-active --quiet nginx; then
        error "Nginx is not running after start attempt"
        journalctl -u nginx --no-pager -n 20
        exit 1
    fi
    
    SOCKET_PATH=$(echo $PHP_FPM_SOCK | cut -d: -f2)
    if [ ! -S "$SOCKET_PATH" ]; then
        warning "PHP-FPM socket not found: $SOCKET_PATH"
        warning "Trying to find PHP-FPM socket..."
        if [ -S "/var/run/php/php${PHP_VERSION}-fpm.sock" ]; then
            PHP_FPM_SOCK="unix:/var/run/php/php${PHP_VERSION}-fpm.sock"
            info "Found PHP-FPM socket: $PHP_FPM_SOCK"
        elif [ -S "/var/run/php-fpm/php-fpm.sock" ]; then
            PHP_FPM_SOCK="unix:/var/run/php-fpm/php-fpm.sock"
            info "Found PHP-FPM socket: $PHP_FPM_SOCK"
        else
            error "PHP-FPM socket not found. Please check PHP-FPM service status"
            systemctl status "$PHP_FPM_SERVICE" --no-pager -l
            exit 1
        fi
    fi
    
    success "Nginx configured"
    
    info "Verifying Nginx and PHP-FPM are running..."
    if systemctl is-active --quiet nginx && systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        success "Nginx and PHP-FPM are running"
    else
        warning "Nginx or PHP-FPM may not be running properly"
        systemctl status nginx --no-pager -l
        systemctl status "$PHP_FPM_SERVICE" --no-pager -l
    fi
    
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        info "IP address detected, skipping SSL setup"
    else
        info "Domain detected: $DOMAIN"
        info "You can setup SSL later with: certbot --nginx -d $DOMAIN"
    fi
}

setup_cron() {
    info "Setting up cron jobs..."
    
    CRON_FILE="/etc/cron.d/pelican-panel"
    
    cat > "$CRON_FILE" <<EOF
* * * * * $SERVICE_USER cd $PANEL_DIR && php artisan schedule:run >> /dev/null 2>&1
EOF

    chmod 0644 "$CRON_FILE"
    
    success "Cron jobs configured"
}

install_docker() {
    info "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        info "Docker already installed"
        return
    fi
    
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    CHANNEL=stable sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    
    usermod -aG docker "$SERVICE_USER"
    
    systemctl enable docker
    systemctl start docker
    
    success "Docker installed"
}

install_wings() {
    info "Installing Pelican Wings..."
    
    install_docker
    
    mkdir -p /var/run/wings
    cd /tmp
    
    info "Downloading Wings..."
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WINGS_ARCH="amd64" ;;
        aarch64|arm64) WINGS_ARCH="arm64" ;;
        *) WINGS_ARCH="amd64" ;;
    esac
    
    WINGS_URL="https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
    
    curl -L -o /usr/local/bin/wings "$WINGS_URL" || {
        error "Failed to download Wings"
        exit 1
    }
    
    chmod +x /usr/local/bin/wings
    
    success "Wings downloaded"
    
    info "Creating Wings configuration directory..."
    mkdir -p /etc/pelican /var/run/wings
    chown -R "$SERVICE_USER:$SERVICE_USER" /etc/pelican /var/run/wings
    
    info "Creating Wings systemd service..."
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
    
    success "Wings service created"
    info "To configure Wings:"
    info "1. Login to Panel: $PANEL_URL"
    info "2. Go to Admin -> Nodes -> Configuration"
    info "3. Copy the configuration and save to /etc/pelican/config.yml"
    info "4. Start Wings: systemctl enable --now pelican-wings"
}

setup_firewall() {
    info "Setting up firewall..."
    
    if command -v ufw &> /dev/null; then
        info "Configuring UFW firewall..."
        echo "y" | ufw allow 22/tcp 2>/dev/null || ufw allow 22/tcp
        echo "y" | ufw allow 80/tcp 2>/dev/null || ufw allow 80/tcp
        echo "y" | ufw allow 443/tcp 2>/dev/null || ufw allow 443/tcp
        if [ "$INSTALL_WINGS" = true ]; then
            echo "y" | ufw allow 2022/tcp 2>/dev/null || ufw allow 2022/tcp
            echo "y" | ufw allow 8080/tcp 2>/dev/null || ufw allow 8080/tcp
        fi
        success "UFW firewall rules added"
    elif command -v firewall-cmd &> /dev/null; then
        info "Configuring firewalld..."
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        if [ "$INSTALL_WINGS" = true ]; then
            firewall-cmd --permanent --add-port=2022/tcp
            firewall-cmd --permanent --add-port=8080/tcp
        fi
        firewall-cmd --reload
        success "Firewalld configured"
    else
        info "No firewall detected, skipping firewall setup"
    fi
}

setup_permissions() {
    info "Setting up permissions..."
    
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
    
    if [ -d "$PANEL_DIR/public" ]; then
        chmod -R 755 "$PANEL_DIR/public"
    fi
    
    if [ "$INSTALL_WINGS" = true ]; then
        mkdir -p /var/lib/pelican /var/log/pelican
        chown -R "$SERVICE_USER:$SERVICE_USER" /var/lib/pelican /var/log/pelican
    fi
    
    success "Permissions configured"
}

start_services() {
    info "Starting services..."
    
    PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    
    PHP_FPM_SERVICE=""
    if systemctl list-unit-files | grep -q "php${PHP_VERSION}-fpm.service"; then
        PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    elif systemctl list-unit-files | grep -q "php-fpm.service"; then
        PHP_FPM_SERVICE="php-fpm"
    elif [ -f "/etc/systemd/system/php${PHP_VERSION}-fpm.service" ] || [ -f "/lib/systemd/system/php${PHP_VERSION}-fpm.service" ]; then
        PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    elif [ -f "/etc/systemd/system/php-fpm.service" ] || [ -f "/lib/systemd/system/php-fpm.service" ]; then
        PHP_FPM_SERVICE="php-fpm"
    else
        for service in php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
            if systemctl list-unit-files | grep -q "${service}.service"; then
                PHP_FPM_SERVICE="$service"
                break
            fi
        done
    fi
    
    if [ -n "$PHP_FPM_SERVICE" ]; then
        if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            info "Starting PHP-FPM service: $PHP_FPM_SERVICE"
            systemctl start "$PHP_FPM_SERVICE" || {
                warning "Failed to start PHP-FPM service: $PHP_FPM_SERVICE, but continuing..."
            }
            systemctl enable "$PHP_FPM_SERVICE"
        else
            info "PHP-FPM service already running: $PHP_FPM_SERVICE"
        fi
    else
        warning "PHP-FPM service not found, but continuing..."
    fi
    
    if ! systemctl is-active --quiet nginx; then
        systemctl start nginx || {
            error "Failed to start nginx"
            exit 1
        }
    fi
    
    systemctl enable pelican-panel
    systemctl start pelican-panel
    
    sleep 2
    
    if ! systemctl is-active --quiet pelican-panel; then
        warning "Panel service may not be running properly"
        systemctl status pelican-panel --no-pager -l
    fi
    
    if [ "$INSTALL_WINGS" = true ]; then
        if [ -n "$WINGS_TOKEN" ] && [ -n "$PANEL_URL" ]; then
            systemctl enable pelican-wings
            systemctl start pelican-wings
            success "Wings service started"
        else
            info "Wings service created but not started (needs API token configuration)"
        fi
    fi
    
    success "Services started"
}

get_user_input() {
    echo ""
    info "Pelican Panel Installation"
    echo ""
    info "Please provide the following information:"
    echo ""
    
    while [ -z "$DOMAIN" ]; do
        echo -n "Domain name (or IP address): "
        read DOMAIN
        if [ -z "$DOMAIN" ]; then
            error "Domain is required! Please enter your domain or IP address."
        fi
    done
    
    echo ""
    info "Database Configuration:"
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
        info "Auto-generated database password"
    fi
    
    echo ""
    info "Admin User Configuration:"
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
        info "Auto-generated admin password"
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
    info "Configuration Summary:"
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
        info "Installation cancelled"
        exit 0
    fi
}

print_summary() {
    success "Pelican installation completed!"
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
    echo "Panel URL: $PANEL_URL"
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
    echo ""
    echo "=== Troubleshooting ==="
    echo "If panel is not accessible, check:"
    echo "1. Nginx status: systemctl status nginx"
    echo "2. PHP-FPM status: systemctl status php${PHP_VERSION}-fpm"
    echo "3. Panel service: systemctl status pelican-panel"
    echo "4. Nginx error log: tail -f /var/log/nginx/error.log"
    echo "5. PHP-FPM error log: tail -f /var/log/php${PHP_VERSION}-fpm.log"
    echo "6. Panel permissions: ls -la $PANEL_DIR/public"
}

uninstall_panel() {
    info "Starting Pelican Panel uninstallation..."
    
    echo ""
    warning "This will remove Pelican Panel and all its data!"
    echo -n "Are you sure you want to continue? (yes/no): "
    read CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        info "Uninstallation cancelled"
        exit 0
    fi
    
    echo ""
    echo -n "Remove database and database user? (y/n) [y]: "
    read REMOVE_DB
    REMOVE_DB=${REMOVE_DB:-y}
    
    echo -n "Remove Wings? (y/n) [y]: "
    read REMOVE_WINGS
    REMOVE_WINGS=${REMOVE_WINGS:-y}
    
    echo -n "Remove Nginx configuration? (y/n) [y]: "
    read REMOVE_NGINX
    REMOVE_NGINX=${REMOVE_NGINX:-y}
    
    info "Stopping services..."
    systemctl stop pelican-panel 2>/dev/null || true
    systemctl disable pelican-panel 2>/dev/null || true
    
    if [ "$REMOVE_WINGS" = "y" ]; then
        systemctl stop pelican-wings 2>/dev/null || true
        systemctl disable pelican-wings 2>/dev/null || true
    fi
    
    info "Removing systemd services..."
    rm -f /etc/systemd/system/pelican-panel.service
    if [ "$REMOVE_WINGS" = "y" ]; then
        rm -f /etc/systemd/system/pelican-wings.service
    fi
    systemctl daemon-reload
    
    info "Removing Panel files..."
    if [ -d "$PANEL_DIR" ]; then
        rm -rf "$PANEL_DIR"
        success "Panel directory removed: $PANEL_DIR"
    fi
    
    if [ "$REMOVE_WINGS" = "y" ]; then
        info "Removing Wings..."
        rm -f /usr/local/bin/wings
        rm -rf /etc/pelican
        rm -rf /var/lib/pelican
        rm -rf /var/log/pelican
        rm -rf /var/run/wings
        success "Wings removed"
    fi
    
    if [ "$REMOVE_NGINX" = "y" ]; then
        info "Removing Nginx configuration..."
        rm -f /etc/nginx/sites-enabled/pelican.conf
        rm -f /etc/nginx/sites-available/pelican.conf
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        fi
        success "Nginx configuration removed"
    fi
    
    info "Removing cron jobs..."
    if id "$SERVICE_USER" &>/dev/null; then
        crontab -u "$SERVICE_USER" -l 2>/dev/null | grep -v "pelican" | crontab -u "$SERVICE_USER" - 2>/dev/null || true
    fi
    
    if [ "$REMOVE_DB" = "y" ]; then
        info "Removing database..."
        DB_NAME=""
        DB_USER=""
        if [ -f "$PANEL_DIR/.env" ]; then
            DB_NAME=$(grep "^DB_DATABASE=" "$PANEL_DIR/.env" | cut -d'=' -f2)
            DB_USER=$(grep "^DB_USERNAME=" "$PANEL_DIR/.env" | cut -d'=' -f2)
        fi
        
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
            echo -n "Database name: "
            read DB_NAME
            echo -n "Database user: "
            read DB_USER
        fi
        
        if [ -n "$DB_NAME" ]; then
            mysql -u root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null || true
            success "Database removed: $DB_NAME"
        fi
        
        if [ -n "$DB_USER" ]; then
            mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
            mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            success "Database user removed: $DB_USER"
        fi
    fi
    
    echo ""
    echo -n "Remove service user '$SERVICE_USER'? (y/n) [n]: "
    read REMOVE_USER
    REMOVE_USER=${REMOVE_USER:-n}
    
    if [ "$REMOVE_USER" = "y" ]; then
        info "Removing service user..."
        if id "$SERVICE_USER" &>/dev/null; then
            userdel -r "$SERVICE_USER" 2>/dev/null || true
            success "Service user removed: $SERVICE_USER"
        fi
    fi
    
    success "Pelican Panel uninstallation completed!"
    info "Note: PHP, Node.js, Nginx, and other system packages were not removed"
    info "You can remove them manually if needed"
}

main() {
    if [ "$1" = "uninstall" ]; then
        check_root
        detect_os
        uninstall_panel
        exit 0
    fi
    
    info "Starting Pelican installation..."
    
    check_root
    detect_os
    get_user_input
    install_system_dependencies
    install_php
    install_php_extensions
    install_composer
    install_nodejs
    install_database
    setup_database
    create_user
    install_panel
    install_panel_dependencies
    setup_panel_environment
    build_panel_assets
    setup_permissions
    setup_database_migrations
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
    
    success "Installation completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" = "uninstall" ]; then
        main uninstall
    else
        main "$@"
    fi
fi
