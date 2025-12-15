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
        if grep -qi "CentOS" /etc/redhat-release; then
            OS_TYPE="centos"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        elif grep -qi "Rocky" /etc/redhat-release; then
            OS_TYPE="rocky"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        elif grep -qi "AlmaLinux" /etc/redhat-release; then
            OS_TYPE="almalinux"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        fi
    fi
    
    case "$OS_TYPE" in
        ubuntu)
            if [[ "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]]; then
                if [[ "$OS_VERSION" == "24.04" ]]; then
                    success "Detected: $OS_TYPE $OS_VERSION (Recommended)"
                else
                    success "Detected: $OS_TYPE $OS_VERSION"
                fi
            else
                error "Ubuntu $OS_VERSION is not fully supported!"
                error "Fully supported versions: 22.04, 24.04 (Recommended)"
                echo -n "Continue anyway? (y/n) [n]: "
                read CONTINUE
                CONTINUE=${CONTINUE:-n}
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
                warning "Continuing with unsupported Ubuntu version"
            fi
            PKG_MANAGER="apt"
            ;;
        debian)
            if [[ "$OS_VERSION" == "12" ]]; then
                success "Detected: $OS_TYPE $OS_VERSION"
            elif [[ "$OS_VERSION" == "11" ]]; then
                warning "Debian $OS_VERSION detected - Partially Supported (No SQLite Support)"
                echo -n "Continue anyway? (y/n) [n]: "
                read CONTINUE
                CONTINUE=${CONTINUE:-n}
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            else
                error "Debian $OS_VERSION is not supported!"
                error "Supported versions: 12 (Fully), 11 (Partially - No SQLite)"
                exit 1
            fi
            PKG_MANAGER="apt"
            ;;
        almalinux|rocky|centos)
            if [[ "$OS_VERSION" == "10" ]]; then
                success "Detected: $OS_TYPE $OS_VERSION"
            elif [[ "$OS_VERSION" == "9" || "$OS_VERSION" == "8" ]]; then
                warning "$OS_TYPE $OS_VERSION detected - Partially Supported (No SQLite Support)"
                echo -n "Continue anyway? (y/n) [n]: "
                read CONTINUE
                CONTINUE=${CONTINUE:-n}
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            else
                error "$OS_TYPE $OS_VERSION is not supported!"
                error "Supported versions: 10 (Fully), 9/8 (Partially - No SQLite)"
                exit 1
            fi
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            error "Unsupported operating system: $OS_TYPE"
            info "Fully Supported: Ubuntu 22.04/24.04, Debian 12, Alma Linux 10, Rocky Linux 10, CentOS 10"
            info "Partially Supported: Debian 11, Alma Linux 9/8, Rocky Linux 9/8 (No SQLite)"
            exit 1
            ;;
    esac
}

wait_for_apt_lock() {
    local max_wait=300
    local wait_time=0
    local check_interval=5
    
    while [ $wait_time -lt $max_wait ]; do
        if ! lsof /var/lib/dpkg/lock-frontend &>/dev/null && ! lsof /var/lib/dpkg/lock &>/dev/null && ! fuser /var/lib/apt/lists/lock &>/dev/null && ! fuser /var/cache/apt/archives/lock &>/dev/null; then
            return 0
        fi
        
        if [ $wait_time -eq 0 ]; then
            info "Waiting for apt/dpkg lock to be released..."
            info "If another package manager is running, please wait for it to finish."
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done
    
    error "Timeout waiting for apt/dpkg lock. Another process may be using the package manager."
    error "Please wait for other package operations to complete and try again."
    exit 1
}

install_system_dependencies() {
    info "Installing system dependencies for $OS_TYPE $OS_VERSION..."
    
    case "$PKG_MANAGER" in
        apt)
            wait_for_apt_lock
            apt-get update
            apt-get install -y curl wget unzip git tar software-properties-common apt-transport-https ca-certificates gnupg lsb-release build-essential
            ;;
        dnf|yum)
            $PKG_MANAGER install -y curl wget unzip git tar ca-certificates gcc gcc-c++ make
            ;;
    esac
    
    if ! command -v systemctl &> /dev/null; then
        error "systemd is required but not found. Please use a systemd-based distribution."
        exit 1
    fi
    
    success "System dependencies installed"
}

install_php() {
    info "Installing PHP 8.4/8.3/8.2..."
    
    PHP_NEEDS_INSTALL=false
    PHP_FPM_NEEDS_INSTALL=false
    
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -r 'echo PHP_VERSION;' | cut -d. -f1,2)
        PHP_MINOR=$(php -r 'echo PHP_VERSION;' | cut -d. -f2)
        if [ "$PHP_MINOR" -ge 2 ]; then
            info "PHP $PHP_VERSION already installed"
        else
            PHP_NEEDS_INSTALL=true
        fi
    else
        PHP_NEEDS_INSTALL=true
    fi
    
    PHP_FPM_SERVICE=""
    if [ -n "$PHP_VERSION" ]; then
        if systemctl list-unit-files | grep -q "php${PHP_VERSION}-fpm.service"; then
            PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
        elif systemctl list-unit-files | grep -q "php-fpm.service"; then
            PHP_FPM_SERVICE="php-fpm"
        fi
    fi
    
    if [ -z "$PHP_FPM_SERVICE" ]; then
        PHP_FPM_NEEDS_INSTALL=true
    elif ! systemctl is-enabled "$PHP_FPM_SERVICE" &>/dev/null; then
        PHP_FPM_NEEDS_INSTALL=true
    fi
    
    if [ "$PHP_NEEDS_INSTALL" = true ] || [ "$PHP_FPM_NEEDS_INSTALL" = true ]; then
    case "$PKG_MANAGER" in
        apt)
            wait_for_apt_lock
            if [ "$OS_TYPE" = "ubuntu" ]; then
                if ! grep -q "ondrej/php" /etc/apt/sources.list.d/*.list 2>/dev/null; then
                    add-apt-repository -y ppa:ondrej/php
                fi
            elif [ "$OS_TYPE" = "debian" ]; then
                if ! grep -q "packages.sury.org" /etc/apt/sources.list.d/*.list 2>/dev/null && ! grep -q "packages.sury.org" /etc/apt/sources.list 2>/dev/null; then
                    info "Adding Sury PHP repository for Debian..."
                    wait_for_apt_lock
                    apt-get install -y ca-certificates apt-transport-https lsb-release gnupg2
                    wget -qO - https://packages.sury.org/php/apt.gpg | apt-key add - 2>/dev/null || {
                        wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
                    }
                    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
                fi
            fi
            wait_for_apt_lock
            apt-get update
            
            if [ "$PHP_NEEDS_INSTALL" = true ]; then
                if apt-cache show php8.4-fpm &>/dev/null; then
                    apt-get install -y php8.4 php8.4-cli php8.4-fpm php8.4-common php8.4-mysql php8.4-zip php8.4-gd php8.4-mbstring php8.4-curl php8.4-xml php8.4-bcmath php8.4-intl php8.4-sqlite3 || {
                        error "Failed to install PHP 8.4, trying PHP 8.3..."
                        apt-get install -y php8.3 php8.3-cli php8.3-fpm php8.3-common php8.3-mysql php8.3-zip php8.3-gd php8.3-mbstring php8.3-curl php8.3-xml php8.3-bcmath php8.3-intl php8.3-sqlite3
                        PHP_VERSION="8.3"
                    } || {
                        error "Failed to install PHP 8.3, trying PHP 8.2..."
                        apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-sqlite3
                        PHP_VERSION="8.2"
                    } || {
                        error "Failed to install PHP. Please check repository configuration."
                        exit 1
                    }
                    if [ -z "$PHP_VERSION" ]; then
                        PHP_VERSION="8.4"
                    fi
                elif apt-cache show php8.3-fpm &>/dev/null; then
                    apt-get install -y php8.3 php8.3-cli php8.3-fpm php8.3-common php8.3-mysql php8.3-zip php8.3-gd php8.3-mbstring php8.3-curl php8.3-xml php8.3-bcmath php8.3-intl php8.3-sqlite3 || {
                        error "Failed to install PHP 8.3, trying PHP 8.2..."
                        apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-sqlite3
                        PHP_VERSION="8.2"
                    } || {
                        error "Failed to install PHP. Please check repository configuration."
                        exit 1
                    }
                    if [ -z "$PHP_VERSION" ]; then
                        PHP_VERSION="8.3"
                    fi
                else
                    apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-sqlite3 || {
                        error "Failed to install PHP 8.2. Please check repository configuration."
                        exit 1
                    }
                    PHP_VERSION="8.2"
                fi
            elif [ "$PHP_FPM_NEEDS_INSTALL" = true ]; then
                    if apt-cache show php${PHP_VERSION}-fpm &>/dev/null; then
                        apt-get install -y php${PHP_VERSION}-fpm || {
                            error "Failed to install PHP${PHP_VERSION}-FPM"
                            exit 1
                        }
                    elif apt-cache show php8.4-fpm &>/dev/null; then
                        apt-get install -y php8.4-fpm || {
                            error "Failed to install PHP 8.4-FPM"
                            exit 1
                        }
                        PHP_VERSION="8.4"
                    elif apt-cache show php8.3-fpm &>/dev/null; then
                        apt-get install -y php8.3-fpm || {
                            error "Failed to install PHP 8.3-FPM"
                            exit 1
                        }
                        PHP_VERSION="8.3"
                    else
                        apt-get install -y php8.2-fpm || {
                            error "Failed to install PHP 8.2-FPM"
                            exit 1
                        }
                        PHP_VERSION="8.2"
                    fi
                fi
                ;;
            dnf|yum)
                if [ "$OS_TYPE" = "almalinux" ] || [ "$OS_TYPE" = "rocky" ] || [ "$OS_TYPE" = "centos" ]; then
                    if ! rpm -q epel-release &>/dev/null; then
                        info "Installing EPEL repository..."
                        $PKG_MANAGER install -y epel-release || {
                            error "Failed to install EPEL repository"
                            exit 1
                        }
                    fi
                    
                    if [ ! -f /etc/yum.repos.d/remi.repo ]; then
                        info "Installing Remi repository..."
                        if [ "$OS_VERSION" = "10" ]; then
                            REMI_URL="https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm"
                        elif [ "$OS_VERSION" = "9" ]; then
                            REMI_URL="https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
                        elif [ "$OS_VERSION" = "8" ]; then
                            REMI_URL="https://rpms.remirepo.net/enterprise/remi-release-8.rpm"
                        else
                            REMI_URL="https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm"
                        fi
                        
                        $PKG_MANAGER install -y "$REMI_URL" || {
                            error "Failed to install Remi repository"
                            exit 1
                        }
                    fi
                    
                    $PKG_MANAGER module reset php -y 2>/dev/null || true
                    
                    if [ "$PKG_MANAGER" = "dnf" ]; then
                        $PKG_MANAGER module enable php:remi-8.4 -y 2>/dev/null || \
                        $PKG_MANAGER module enable php:remi-8.3 -y 2>/dev/null || \
                        $PKG_MANAGER module enable php:remi-8.2 -y || {
                            error "Failed to enable PHP module"
                            exit 1
                        }
                    fi
                    
                    if [ "$PHP_NEEDS_INSTALL" = true ]; then
                        info "Installing PHP packages..."
                        $PKG_MANAGER install -y php php-cli php-fpm php-common php-mysqlnd php-zip php-gd php-mbstring php-curl php-xml php-bcmath php-intl || {
                            error "Failed to install PHP packages"
                            exit 1
                        }
                        
                        if [ "$OS_VERSION" = "10" ]; then
                            $PKG_MANAGER install -y php-sqlite3 || {
                                warning "Failed to install php-sqlite3, continuing without SQLite support"
                            }
                        else
                            warning "SQLite not available for $OS_TYPE $OS_VERSION (partially supported)"
                        fi
                    elif [ "$PHP_FPM_NEEDS_INSTALL" = true ]; then
                        $PKG_MANAGER install -y php-fpm || {
                            error "Failed to install PHP-FPM"
                            exit 1
                        }
                    fi
                fi
                ;;
        esac
    fi
    
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
    
    if [ -z "$PHP_FPM_SERVICE" ]; then
        error "PHP-FPM service not found after installation. Please install PHP-FPM manually."
        exit 1
    fi
    
    info "PHP-FPM service detected: $PHP_FPM_SERVICE"
    
    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        info "Starting PHP-FPM service..."
        systemctl start "$PHP_FPM_SERVICE" || {
            error "Failed to start PHP-FPM service: $PHP_FPM_SERVICE"
            exit 1
        }
    fi
    
    systemctl enable "$PHP_FPM_SERVICE" 2>/dev/null || true
    
    success "PHP $PHP_VERSION and PHP-FPM installed and started"
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
                    if [ "$OS_TYPE" = "debian" ] && [ "$OS_VERSION" = "11" ]; then
                        warning "SQLite not available for Debian 11 (partially supported)"
                    elif apt-get install -y "php${PHP_VERSION}-sqlite3" 2>/dev/null; then
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
                    if [ "$OS_VERSION" = "10" ]; then
                        if $PKG_MANAGER install -y "php-sqlite3" 2>/dev/null; then
                            info "Installed php-sqlite3 (pdo_sqlite)"
                        else
                            warning "Failed to install php-sqlite3"
                        fi
                    else
                        warning "SQLite not available for $OS_TYPE $OS_VERSION (partially supported)"
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
    info "Installing Node.js 22.x..."
    
    NODE_NEEDS_INSTALL=false
    NODE_NEEDS_UPGRADE=false
    
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d. -f1)
        if [ "$NODE_VERSION" -ge 22 ]; then
            info "Node.js 22.x or higher already installed"
            return
        else
            NODE_NEEDS_UPGRADE=true
            info "Node.js $NODE_VERSION detected, upgrading to 22.x..."
        fi
    else
        NODE_NEEDS_INSTALL=true
    fi
    
    case "$PKG_MANAGER" in
        apt)
            if [ "$NODE_NEEDS_UPGRADE" = true ]; then
                if command -v node &> /dev/null; then
                    apt-get remove -y nodejs npm 2>/dev/null || true
                    rm -rf /usr/lib/node_modules /usr/include/node /usr/share/man/man1/node* 2>/dev/null || true
                fi
            fi
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - || {
                error "Failed to add NodeSource repository"
                exit 1
            }
            apt-get install -y nodejs || {
                error "Failed to install Node.js"
                exit 1
            }
            ;;
        dnf|yum)
            if [ "$NODE_NEEDS_UPGRADE" = true ]; then
                if command -v node &> /dev/null; then
                    $PKG_MANAGER remove -y nodejs npm 2>/dev/null || true
                fi
            fi
            curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - || {
                error "Failed to add NodeSource repository"
                exit 1
            }
            $PKG_MANAGER install -y nodejs || {
                error "Failed to install Node.js"
                exit 1
            }
            ;;
    esac
    
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v)
        NODE_MAJOR=$(node -v | cut -d'v' -f2 | cut -d. -f1)
        if [ "$NODE_MAJOR" -ge 22 ]; then
            success "Node.js $NODE_VERSION installed"
        else
            error "Node.js installation failed or wrong version installed"
            exit 1
        fi
    else
        error "Node.js installation failed"
        exit 1
    fi
}

install_database() {
    info "Installing MariaDB..."
    
    case "$PKG_MANAGER" in
        apt)
            wait_for_apt_lock
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
    
    if mysql -u root -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null | grep -q "^$DB_NAME$" 2>/dev/null; then
        warning "Database '$DB_NAME' already exists!"
        echo ""
        echo "The database '$DB_NAME' is already in use. Please choose a different database name."
        while true; do
            echo -n "Enter new database name: "
            read NEW_DB_NAME
            if [ -z "$NEW_DB_NAME" ]; then
                error "Database name cannot be empty!"
                continue
            fi
            if mysql -u root -e "SHOW DATABASES LIKE '$NEW_DB_NAME';" 2>/dev/null | grep -q "^$NEW_DB_NAME$" 2>/dev/null; then
                warning "Database '$NEW_DB_NAME' also exists! Please choose another name."
                continue
            fi
            DB_NAME="$NEW_DB_NAME"
            info "Using database name: $DB_NAME"
            break
        done
    fi
    
    if mysql -u root -e "SELECT User FROM mysql.user WHERE User='$DB_USER' AND Host='localhost';" 2>/dev/null | grep -q "^$DB_USER$" 2>/dev/null; then
        warning "Database user '$DB_USER' already exists!"
        echo ""
        echo "The database user '$DB_USER' is already in use. Please choose a different username."
        while true; do
            echo -n "Enter new database username: "
            read NEW_DB_USER
            if [ -z "$NEW_DB_USER" ]; then
                error "Database username cannot be empty!"
                continue
            fi
            if mysql -u root -e "SELECT User FROM mysql.user WHERE User='$NEW_DB_USER' AND Host='localhost';" 2>/dev/null | grep -q "^$NEW_DB_USER$" 2>/dev/null; then
                warning "Database user '$NEW_DB_USER' also exists! Please choose another username."
                continue
            fi
            DB_USER="$NEW_DB_USER"
            info "Using database username: $DB_USER"
            break
        done
    fi
    
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        mysql -u root -proot -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
            error "Could not create database. Please check MariaDB installation and root password."
            exit 1
        }
    }
    
    mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || {
        mysql -u root -proot -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
    }
    
    DB_PASS_ESCAPED=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
    
    mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS_ESCAPED';" 2>/dev/null || {
        mysql -u root -proot -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS_ESCAPED';" 2>/dev/null || {
            error "Could not create database user. Please check MariaDB installation and root password."
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
    
    info "Verifying database connection..."
    sleep 2
    if mysql -u "$DB_USER" -p"$DB_PASS" -e "USE \`$DB_NAME\`; SELECT 1;" 2>/dev/null; then
        success "Database connection verified"
    else
        error "Could not verify database connection!"
        error "User: $DB_USER, Database: $DB_NAME"
        error "Please check if password is correct. Trying to recreate user..."
        
        mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || {
            mysql -u root -proot -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
        }
        
        mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
            mysql -u root -proot -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>/dev/null || {
                error "Failed to recreate user"
                exit 1
            }
        }
        
        mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || {
            mysql -u root -proot -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>/dev/null || true
        }
        
        mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || {
            mysql -u root -proot -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        }
        
        sleep 1
        if mysql -u "$DB_USER" -p"$DB_PASS" -e "USE \`$DB_NAME\`; SELECT 1;" 2>/dev/null; then
            success "Database connection verified after recreation"
        else
            error "Still cannot connect. Password may contain special characters."
            error "Please check .env file manually and ensure DB_PASSWORD is correct."
            exit 1
        fi
    fi
    
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
    
    if [ -d "$PANEL_DIR" ] && [ "$(ls -A $PANEL_DIR 2>/dev/null)" ]; then
        warning "Panel directory already exists, backing up..."
        mv "$PANEL_DIR" "${PANEL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    mkdir -p "$PANEL_DIR"
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    info "Downloading Pelican Panel..."
    curl -L -o panel.tar.gz https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz || {
        error "Failed to download Pelican Panel"
        rm -rf "$TEMP_DIR"
        exit 1
    }
    
    info "Extracting Pelican Panel..."
    tar -xzf panel.tar.gz || {
        error "Failed to extract Pelican Panel"
        rm -rf "$TEMP_DIR"
        exit 1
    }
    
    if [ -d "panel" ]; then
        mv panel/* "$PANEL_DIR/" 2>/dev/null || cp -r panel/* "$PANEL_DIR/"
        mv panel/.* "$PANEL_DIR/" 2>/dev/null || true
    elif [ -f "composer.json" ]; then
        mv * "$PANEL_DIR/" 2>/dev/null || cp -r * "$PANEL_DIR/"
        mv .* "$PANEL_DIR/" 2>/dev/null || true
    else
        EXTRACTED_DIR=$(find . -maxdepth 1 -type d ! -name . | head -1)
        if [ -n "$EXTRACTED_DIR" ] && [ -f "$EXTRACTED_DIR/composer.json" ]; then
            mv "$EXTRACTED_DIR"/* "$PANEL_DIR/" 2>/dev/null || cp -r "$EXTRACTED_DIR"/* "$PANEL_DIR/"
            mv "$EXTRACTED_DIR"/.* "$PANEL_DIR/" 2>/dev/null || true
        else
            error "Could not find panel files in extracted archive"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi
    
    rm -rf "$TEMP_DIR"
    
    if [ ! -f "$PANEL_DIR/composer.json" ]; then
        error "composer.json not found after extraction. Panel installation may have failed."
        exit 1
    fi
    
    chown -R "$SERVICE_USER:$SERVICE_USER" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR"
    
    success "Pelican Panel downloaded and extracted"
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
    
    DB_PASS_ENV=$(printf '%s' "$DB_PASS" | sed 's/"/\\"/g')
    if ! grep -q "DB_PASSWORD" .env; then
        echo "DB_PASSWORD=\"$DB_PASS_ENV\"" >> .env
    else
        sudo -u "$SERVICE_USER" sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=\"$DB_PASS_ENV\"|g" .env
    fi
    
    info "Verifying .env file..."
    if grep -q "DB_PASSWORD=\"$DB_PASS_ENV\"" .env || grep -q "DB_PASSWORD=$DB_PASS" .env; then
        success ".env file configured correctly"
    else
        warning ".env file may not have correct password, but continuing..."
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
    
    info "Verifying database connection..."
    if mysql -u "$DB_USER" -p"$DB_PASS" -e "USE \`$DB_NAME\`; SELECT 1;" 2>/dev/null; then
        success "Database connection verified"
    else
        error "Cannot connect to database with user '$DB_USER'"
        error "Please check database credentials in .env file"
        exit 1
    fi
    
    info "Clearing database cache..."
    sudo -u "$SERVICE_USER" php artisan config:clear
    sudo -u "$SERVICE_USER" php artisan cache:clear
    
    info "Testing database connection from Laravel..."
    if sudo -u "$SERVICE_USER" php artisan tinker --execute="DB::connection()->getPdo(); echo 'OK';" 2>/dev/null | grep -q "OK"; then
        success "Laravel database connection verified"
    else
        warning "Laravel database connection test failed, but continuing..."
    fi
    
    info "Running migrations..."
    sudo -u "$SERVICE_USER" php artisan migrate --force || {
        error "Migrations failed. Please check your database configuration in .env"
        error "Database: $DB_NAME, User: $DB_USER"
        error "You can verify connection with: mysql -u $DB_USER -p$DB_PASS $DB_NAME"
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
    
    echo "$ADMIN_EMAIL" | sudo -u "$SERVICE_USER" php artisan p:user:make \
        --email "$ADMIN_EMAIL" \
        --username "$ADMIN_USERNAME" \
        --password "$ADMIN_PASSWORD" \
        --admin <<EOF
yes
EOF
    if [ $? -eq 0 ]; then
        success "Admin user created"
    else
        if sudo -u "$SERVICE_USER" php artisan tinker --execute="echo App\Models\User::where('email', '$ADMIN_EMAIL')->exists() ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
            success "Admin user already exists"
        else
            warning "Failed to create admin user automatically, creating manually..."
            sudo -u "$SERVICE_USER" php artisan tinker <<PHPEOF
\$user = new App\Models\User();
\$user->email = '$ADMIN_EMAIL';
\$user->username = '$ADMIN_USERNAME';
\$user->password = Hash::make('$ADMIN_PASSWORD');
\$user->root_admin = 1;
\$user->save();
PHPEOF
            if [ $? -eq 0 ]; then
                success "Admin user created manually"
            else
                error "Failed to create admin user"
            fi
        fi
    fi
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
    
    PHP_FPM_SOCK=""
    if [ -S "/var/run/php/php${PHP_VERSION}-fpm.sock" ]; then
        PHP_FPM_SOCK="unix:/var/run/php/php${PHP_VERSION}-fpm.sock"
    elif [ -S "/var/run/php-fpm/php-fpm.sock" ]; then
        PHP_FPM_SOCK="unix:/var/run/php-fpm/php-fpm.sock"
    else
        for sock in /var/run/php/php8.4-fpm.sock /var/run/php/php8.3-fpm.sock /var/run/php/php8.2-fpm.sock /var/run/php-fpm/php-fpm.sock; do
            if [ -S "$sock" ]; then
                PHP_FPM_SOCK="unix:$sock"
                break
            fi
        done
    fi
    
    if [ -z "$PHP_FPM_SOCK" ]; then
        warning "PHP-FPM socket not found, using default path"
        PHP_FPM_SOCK="unix:/var/run/php/php${PHP_VERSION}-fpm.sock"
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
    
    if [ -z "$PHP_FPM_SERVICE" ]; then
        error "PHP-FPM service not found. Please install PHP-FPM first."
        exit 1
    fi
    
    info "Detected PHP-FPM service: $PHP_FPM_SERVICE"
    
    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        info "Starting PHP-FPM service..."
        systemctl start "$PHP_FPM_SERVICE" || {
            error "Failed to start PHP-FPM service: $PHP_FPM_SERVICE"
            systemctl status "$PHP_FPM_SERVICE" --no-pager -l
            exit 1
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
        info "IP address detected, using HTTP without SSL"
    else
        info "Domain detected: $DOMAIN"
        DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
        PUBLIC_IP=$(curl -4 -s https://api.ipify.org || hostname -I | awk '{print $1}')
        if [ -n "$DOMAIN_IP" ] && [ -n "$PUBLIC_IP" ] && [ "$DOMAIN_IP" = "$PUBLIC_IP" ]; then
            info "Domain resolves to this server ($PUBLIC_IP), attempting SSL issuance"
            wait_for_apt_lock
            apt-get install -y certbot python3-certbot-nginx
            SSL_EMAIL="${ADMIN_EMAIL:-admin@pelican.local}"
            if certbot --nginx --non-interactive --agree-tos -m "$SSL_EMAIL" -d "$DOMAIN" --redirect; then
                success "SSL certificate issued for $DOMAIN"
            else
                warning "SSL issuance failed. You can retry: certbot --nginx -d $DOMAIN"
            fi
        else
            warning "Domain does not resolve to this server (public IP: $PUBLIC_IP, domain IP: ${DOMAIN_IP:-unknown}). Skipping SSL."
        fi
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
PartOf=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pelican-wings

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    success "Wings service created"
    if [ -f "$PANEL_DIR/.env" ] && [ -f "$PANEL_DIR/artisan" ]; then
        PANEL_URL_FROM_ENV=$(grep "^APP_URL=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d '"' || echo "$PANEL_URL")
        info "To configure Wings manually:"
        info "1. Login to Panel: $PANEL_URL_FROM_ENV"
        info "2. Go to Admin -> API -> Application API"
        info "   - Create an Application API key with permissions for Nodes"
        info "   - Copy the API key (token)"
        info "3. Go to Admin -> Nodes -> Create New"
        info "   - Fill in node details (Name, FQDN, ports, resources)"
        info "4. Open the node 'Configuration' tab"
        info "   - Copy the full YAML configuration"
        info "   - Ensure the token from step 2 is present"
        info "5. Save YAML to /etc/pelican/config.yml"
        info "   sudo nano /etc/pelican/config.yml"
        info "6. Set permissions:"
        info "   sudo chown pelican:pelican /etc/pelican/config.yml"
        info "   sudo chmod 600 /etc/pelican/config.yml"
        info "7. Start Wings:"
        info "   sudo systemctl enable --now pelican-wings"
        info "8. Check status and logs:"
        info "   sudo systemctl status pelican-wings"
        info "   sudo journalctl -u pelican-wings -f"
        warning "Node stays red until config.yml is in place and Wings is running."
    else
        info "To configure Wings manually:"
        info "1. Login to Panel: $PANEL_URL"
        info "2. Go to Admin -> API -> Application API, create key, copy token"
        info "3. Go to Admin -> Nodes -> Create New, then Configuration tab"
        info "4. Copy config YAML, include token, save to /etc/pelican/config.yml"
        info "5. Set permissions: chown pelican:pelican /etc/pelican/config.yml && chmod 600 /etc/pelican/config.yml"
        info "6. Start Wings: systemctl enable --now pelican-wings"
        warning "Node stays red until config.yml is present and Wings is running."
    fi
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
    
    if [ -z "$INSTALL_WINGS" ]; then
        INSTALL_WINGS=false
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
    
    REMOVE_DB="y"
    REMOVE_WINGS="y"
    REMOVE_NGINX="y"
    
    info "Stopping services..."
    systemctl stop pelican-panel 2>/dev/null || true
    systemctl disable pelican-panel 2>/dev/null || true
    systemctl stop pelican-wings 2>/dev/null || true
    systemctl disable pelican-wings 2>/dev/null || true
    
    info "Removing systemd services..."
    rm -f /etc/systemd/system/pelican-panel.service
    rm -f /etc/systemd/system/pelican-wings.service
    systemctl daemon-reload
    
    info "Removing Panel files..."
    if [ -d "$PANEL_DIR" ]; then
        rm -rf "$PANEL_DIR"
        success "Panel directory removed: $PANEL_DIR"
    fi
    
    info "Removing Wings..."
    rm -f /usr/local/bin/wings
    rm -rf /etc/pelican
    rm -rf /var/lib/pelican
    rm -rf /var/log/pelican
    rm -rf /var/run/wings
    success "Wings removed"
    
    info "Removing Nginx configuration..."
    rm -f /etc/nginx/sites-enabled/pelican.conf
    rm -f /etc/nginx/sites-available/pelican.conf
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    fi
    success "Nginx configuration removed"
    
    info "Removing cron jobs..."
    if id "$SERVICE_USER" &>/dev/null; then
        crontab -u "$SERVICE_USER" -l 2>/dev/null | grep -v "pelican" | crontab -u "$SERVICE_USER" - 2>/dev/null || true
    fi
    
    info "Detecting databases and users..."
    
    DB_LIST=$(mysql -u root -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(Database|information_schema|performance_schema|mysql|sys)$" || mysql -u root -proot -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(Database|information_schema|performance_schema|mysql|sys)$" || echo "")
    
    if [ -n "$DB_LIST" ]; then
        echo ""
        info "Found databases:"
        echo "$DB_LIST" | while read db; do
            if [ -n "$db" ]; then
                echo "  - $db"
            fi
        done
        echo ""
        echo "Enter database names to remove (comma-separated, or 'all' to remove all, or 'skip' to skip):"
        echo -n "> "
        read DB_NAMES_TO_REMOVE
        
        if [ "$DB_NAMES_TO_REMOVE" = "all" ]; then
            echo "$DB_LIST" | while read db; do
                if [ -n "$db" ]; then
                    mysql -u root -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || mysql -u root -proot -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || true
                    success "Database removed: $db"
                fi
            done
        elif [ "$DB_NAMES_TO_REMOVE" != "skip" ] && [ -n "$DB_NAMES_TO_REMOVE" ]; then
            echo "$DB_NAMES_TO_REMOVE" | tr ',' '\n' | while read db; do
                db=$(echo "$db" | tr -d ' ')
                if [ -n "$db" ]; then
                    mysql -u root -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || mysql -u root -proot -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null || true
                    success "Database removed: $db"
                fi
            done
        fi
    fi
    
    USER_LIST=$(mysql -u root -e "SELECT User FROM mysql.user WHERE Host='localhost' AND User NOT IN ('root', 'mysql.sys', 'mysql.session', 'mysql.infoschema');" 2>/dev/null | grep -v "^User$" || mysql -u root -proot -e "SELECT User FROM mysql.user WHERE Host='localhost' AND User NOT IN ('root', 'mysql.sys', 'mysql.session', 'mysql.infoschema');" 2>/dev/null | grep -v "^User$" || echo "")
    
    if [ -n "$USER_LIST" ]; then
        echo ""
        info "Found database users:"
        echo "$USER_LIST" | while read user; do
            if [ -n "$user" ]; then
                echo "  - $user"
            fi
        done
        echo ""
        echo "Enter usernames to remove (comma-separated, or 'all' to remove all, or 'skip' to skip):"
        echo -n "> "
        read USERS_TO_REMOVE
        
        if [ "$USERS_TO_REMOVE" = "all" ]; then
            echo "$USER_LIST" | while read user; do
                if [ -n "$user" ]; then
                    mysql -u root -e "DROP USER IF EXISTS '$user'@'localhost';" 2>/dev/null || mysql -u root -proot -e "DROP USER IF EXISTS '$user'@'localhost';" 2>/dev/null || true
                    success "Database user removed: $user"
                fi
            done
        elif [ "$USERS_TO_REMOVE" != "skip" ] && [ -n "$USERS_TO_REMOVE" ]; then
            echo "$USERS_TO_REMOVE" | tr ',' '\n' | while read user; do
                user=$(echo "$user" | tr -d ' ')
                if [ -n "$user" ]; then
                    mysql -u root -e "DROP USER IF EXISTS '$user'@'localhost';" 2>/dev/null || mysql -u root -proot -e "DROP USER IF EXISTS '$user'@'localhost';" 2>/dev/null || true
                    success "Database user removed: $user"
                fi
            done
        fi
        
        mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || mysql -u root -proot -e "FLUSH PRIVILEGES;" 2>/dev/null || true
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

update_panel() {
    info "Updating Pelican Panel..."
    
    if [ ! -d "$PANEL_DIR" ] || [ ! -f "$PANEL_DIR/.env" ]; then
        error "Panel is not installed. Please install Panel first."
        exit 1
    fi
    
    check_root
    
    OWNER=$(stat -c '%U' "$PANEL_DIR" 2>/dev/null || echo "$SERVICE_USER")
    GROUP=$(stat -c '%G' "$PANEL_DIR" 2>/dev/null || echo "$SERVICE_USER")
    
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d "\"' " || echo "mysql")
    
    info "Creating backup..."
    BACKUP_DIR="$PANEL_DIR/backup"
    mkdir -p "$BACKUP_DIR/storage/app" || {
        error "Failed to create backup directory"
        exit 1
    }
    
    cp -a "$PANEL_DIR/.env" "$BACKUP_DIR/.env.backup" || {
        error "Failed to backup .env file"
        exit 1
    }
    
    if [ -d "$PANEL_DIR/storage/app/public" ]; then
        cp -a "$PANEL_DIR/storage/app/public" "$BACKUP_DIR/storage/app/" || {
            warning "Failed to backup storage/app/public"
        }
    fi
    
    if [ "$DB_CONNECTION" = "sqlite" ]; then
        DB_DATABASE=$(grep "^DB_DATABASE=" "$PANEL_DIR/.env" | cut -d'=' -f2 | tr -d "\"' " || echo "database.sqlite")
        if [[ "$DB_DATABASE" != *.sqlite ]]; then
            DB_DATABASE="$DB_DATABASE.sqlite"
        fi
        if [ -f "$PANEL_DIR/database/$DB_DATABASE" ]; then
            cp -a "$PANEL_DIR/database/$DB_DATABASE" "$BACKUP_DIR/$DB_DATABASE.backup" || {
                warning "Failed to backup SQLite database"
            }
        fi
    fi
    
    info "Downloading latest Panel release..."
    cd "$PANEL_DIR"
    curl -L -o panel.tar.gz https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz || {
        error "Failed to download Panel update"
        exit 1
    }
    
    info "Deleting old files..."
    find "$PANEL_DIR" -mindepth 1 -maxdepth 1 ! -name 'backup' ! -name 'panel.tar.gz' -exec rm -rf {} + || {
        error "Failed to delete old files"
        exit 1
    }
    
    info "Extracting update..."
    tar -xzf panel.tar.gz -C "$PANEL_DIR" || {
        error "Failed to extract update"
        exit 1
    }
    rm -f panel.tar.gz
    
    info "Restoring .env..."
    cp -a "$BACKUP_DIR/.env.backup" "$PANEL_DIR/.env" || {
        error "Failed to restore .env file"
        exit 1
    }
    
    if [ -d "$BACKUP_DIR/storage/app/public" ]; then
        info "Restoring storage/app/public..."
        cp -a "$BACKUP_DIR/storage/app/public" "$PANEL_DIR/storage/app/" || {
            warning "Failed to restore storage/app/public"
        }
    fi
    
    if [ "$DB_CONNECTION" = "sqlite" ] && [ -f "$BACKUP_DIR/$DB_DATABASE.backup" ]; then
        info "Restoring SQLite database..."
        cp -a "$BACKUP_DIR/$DB_DATABASE.backup" "$PANEL_DIR/database/$DB_DATABASE" || {
            warning "Failed to restore SQLite database"
        }
    fi
    
    cd "$PANEL_DIR"
    
    info "Ensuring writable storage and cache directories..."
    sudo -u "$OWNER" mkdir -p \
        "$PANEL_DIR/storage/app/public" \
        "$PANEL_DIR/storage/logs" \
        "$PANEL_DIR/storage/framework/cache" \
        "$PANEL_DIR/storage/framework/sessions" \
        "$PANEL_DIR/storage/framework/views" \
        "$PANEL_DIR/bootstrap/cache"
    TODAY_LOG="$PANEL_DIR/storage/logs/laravel-$(date +%F).log"
    sudo -u "$OWNER" touch "$TODAY_LOG" 2>/dev/null || true
    chown -R "$OWNER:$GROUP" "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
    chmod -R 775 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    find "$PANEL_DIR/storage/logs" -type f -name "*.log" -exec chmod 664 {} \; 2>/dev/null || true
    chown -R "$OWNER:$GROUP" "$PANEL_DIR/public"
    find "$PANEL_DIR/public" -type d -exec chmod 775 {} \; 2>/dev/null || true
    find "$PANEL_DIR/public" -type f -exec chmod 664 {} \; 2>/dev/null || true
    rm -rf "$PANEL_DIR/public/js/filament" "$PANEL_DIR/public/css/filament" 2>/dev/null || true
    
    info "Installing PHP dependencies..."
    COMPOSER_ALLOW_SUPERUSER=1 sudo -u "$OWNER" composer install --no-dev --optimize-autoloader --no-interaction || {
        error "Failed to install PHP dependencies"
        exit 1
    }
    
    info "Optimizing..."
    sudo -u "$OWNER" php artisan optimize:clear
    sudo -u "$OWNER" php artisan filament:optimize 2>/dev/null || true
    
    info "Creating storage symlinks..."
    sudo -u "$OWNER" php artisan storage:link 2>/dev/null || true
    
    info "Updating database..."
    sudo -u "$OWNER" php artisan migrate --seed --force || {
        warning "Database migration/seeding failed"
    }
    
    info "Setting permissions..."
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    chown -R "$OWNER:$GROUP" "$PANEL_DIR"
    
    info "Restarting queue worker..."
    sudo -u "$OWNER" php artisan queue:restart 2>/dev/null || true
    
    systemctl restart pelican-panel 2>/dev/null || true
    
    success "Panel updated successfully!"
}

update_wings() {
    info "Updating Pelican Wings..."
    
    if [ ! -f "/usr/local/bin/wings" ]; then
        error "Wings is not installed. Please install Wings first."
        exit 1
    fi
    
    check_root
    
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    else
        ARCH="amd64"
    fi
    
    info "Stopping Wings service..."
    systemctl stop pelican-wings 2>/dev/null || true
    
    info "Downloading latest Wings..."
    curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_${ARCH}" || {
        error "Failed to download Wings"
        systemctl start pelican-wings 2>/dev/null || true
        exit 1
    }
    
    chmod u+x /usr/local/bin/wings
    chown "$SERVICE_USER:$SERVICE_USER" /usr/local/bin/wings
    
    info "Starting Wings service..."
    systemctl start pelican-wings || {
        error "Failed to start Wings service"
        exit 1
    }
    
    success "Wings updated successfully!"
}

update_both() {
    info "Updating Pelican Panel and Wings..."
    
    if [ ! -d "$PANEL_DIR" ] || [ ! -f "$PANEL_DIR/.env" ]; then
        error "Panel is not installed. Please install Panel first."
        exit 1
    fi
    
    update_panel
    
    if [ -f "/usr/local/bin/wings" ]; then
        update_wings
    else
        info "Wings not installed, skipping Wings update"
    fi
    
    success "Panel and Wings updated successfully!"
}

show_menu() {
    echo ""
    info "Pelican Installation Menu"
    echo ""
    echo "1. Install Panel only"
    echo "2. Install Wings only"
    echo "3. Install Panel + Wings"
    echo "4. Update Panel"
    echo "5. Update Wings"
    echo "6. Update Panel + Wings"
    echo "7. Uninstall"
    echo "8. Exit"
    echo ""
    echo -n "Select option [1-8]: "
    read MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1)
            INSTALL_PANEL=true
            INSTALL_WINGS=false
            ;;
        2)
            INSTALL_PANEL=false
            INSTALL_WINGS=true
            ;;
        3)
            INSTALL_PANEL=true
            INSTALL_WINGS=true
            ;;
        4)
            check_root
            detect_os
            update_panel
            exit 0
            ;;
        5)
            check_root
            detect_os
            update_wings
            exit 0
            ;;
        6)
            check_root
            detect_os
            update_both
            exit 0
            ;;
        7)
            check_root
            detect_os
            uninstall_panel
            exit 0
            ;;
        8)
            info "Exiting..."
            exit 0
            ;;
        *)
            error "Invalid option"
            exit 1
            ;;
    esac
}

install_panel_only() {
    info "Installing Pelican Panel..."
    
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
    setup_firewall
    start_services
    print_summary
    
    success "Panel installation completed successfully!"
}

install_wings_only() {
    info "Installing Pelican Wings..."
    
    check_root
    detect_os
    
    if [ ! -d "$PANEL_DIR" ] || [ ! -f "$PANEL_DIR/.env" ]; then
        error "Panel is not installed. Please install Panel first or use option 3 to install both."
        exit 1
    fi
    
    install_docker
    install_wings
    setup_firewall
    
    success "Wings installation completed!"
    info "To configure Wings:"
    info "1. Login to Panel: $(grep '^APP_URL=' "$PANEL_DIR/.env" | cut -d'=' -f2)"
    info "2. Go to Admin -> Nodes -> Configuration"
    info "3. Copy the configuration and save to /etc/pelican/config.yml"
    info "4. Start Wings: systemctl enable --now pelican-wings"
}

install_both() {
    info "Installing Pelican Panel + Wings..."
    
    check_root
    detect_os
    get_user_input
    INSTALL_WINGS=true
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
    install_docker
    install_wings
    setup_firewall
    start_services
    print_summary
    
    success "Installation completed successfully!"
}

main() {
    if [ "$1" = "uninstall" ]; then
        check_root
        detect_os
        uninstall_panel
        exit 0
    fi
    
    if [ "$1" = "update" ] || [ "$1" = "update-panel" ]; then
        check_root
        detect_os
        update_panel
        exit 0
    fi
    
    if [ "$1" = "update-wings" ]; then
        check_root
        detect_os
        update_wings
        exit 0
    fi
    
    if [ "$1" = "update-both" ]; then
        check_root
        detect_os
        update_both
        exit 0
    fi
    
    if [ "$1" = "panel" ]; then
        install_panel_only
        exit 0
    fi
    
    if [ "$1" = "wings" ]; then
        install_wings_only
        exit 0
    fi
    
    if [ "$1" = "both" ]; then
        install_both
        exit 0
    fi
    
    show_menu
    
    if [ "$INSTALL_PANEL" = true ] && [ "$INSTALL_WINGS" = true ]; then
        install_both
    elif [ "$INSTALL_PANEL" = true ]; then
        install_panel_only
    elif [ "$INSTALL_WINGS" = true ]; then
        install_wings_only
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" = "uninstall" ]; then
        main uninstall
    elif [ "$1" = "update" ] || [ "$1" = "update-panel" ]; then
        main update
    elif [ "$1" = "update-wings" ]; then
        main update-wings
    elif [ "$1" = "update-both" ]; then
        main update-both
    elif [ "$1" = "panel" ]; then
        main panel
    elif [ "$1" = "wings" ]; then
        main wings
    elif [ "$1" = "both" ]; then
        main both
    else
        main "$@"
    fi
fi
