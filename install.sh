#!/bin/bash

# Pelican Panel & Wings Installer
# Copyright (c) 2025 yemobyte
# Based on Pterodactyl Installer style
# Supports Debian 11/12, Ubuntu 22.04/24.04, AlmaLinux 9/10, Rocky Linux 9/10

set -e

# Versioning
export SCRIPT_RELEASE="v2.4"
export PANEL_DIR="/var/www/pelican"
export SITE_URL="http://$(curl -4 -s ifconfig.me)"

# Colors
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

# -------------- Visual functions -------------- #
output() {
  echo -e "* $1"
}

success() {
  echo ""
  output "${COLOR_GREEN}SUCCESS${COLOR_NC}: $1"
  echo ""
}

error() {
  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1" 1>&2
  echo ""
}

warning() {
  echo ""
  output "${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

print_brake() {
  for ((n = 0; n < $1; n++)); do
    echo -n "#"
  done
  echo ""
}

welcome() {
  clear
  print_brake 70
  output "Pelican panel installation script @ $SCRIPT_RELEASE"
  output ""
  output "Copyright (C) 2025, yemobyte"
  output "https://pelican.dev"
  output ""
  output "Running $OS version $OS_VER."
  print_brake 70
}

# -------------- Core functions -------------- #
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    OS_VER=$VERSION_ID
  else
    error "Unsupported OS: could not detect os-release"
    exit 1
  fi

  case "$ID" in
    debian|ubuntu)
      export PACKAGE_MANAGER="apt"
      export PHP_USER="www-data"
      export NGINX_USER="www-data"
      export NGINX_CONF_DIR="/etc/nginx/sites-available"
      export NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
      ;;
    almalinux|rocky|centos|rhel)
      export PACKAGE_MANAGER="dnf"
      export PHP_USER="nginx" # Usually nginx or apache on RHEL
      export NGINX_USER="nginx"
      export NGINX_CONF_DIR="/etc/nginx/conf.d"
      export NGINX_ENABLED_DIR="" # RHEL doesn't use sites-enabled by default
      ;;
    *)
      error "Unsupported OS: $ID"
      exit 1
      ;;
  esac
}

configure_firewall() {
  output "Configuring firewall..."
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      if ! command -v ufw &> /dev/null; then
         apt install -y ufw
      fi
      ufw allow 22
      ufw allow 80
      ufw allow 443
      ufw allow 8080
      ufw allow 2022
      echo "y" | ufw enable
  elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
      if ! command -v firewall-cmd &> /dev/null; then
         dnf install -y firewalld
         systemctl enable --now firewalld
      fi
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --permanent --add-port=8080/tcp
      firewall-cmd --permanent --add-port=2022/tcp
      firewall-cmd --reload
  fi
}

install_dependencies() {
  output "Updating system and installing dependencies for $OS..."
  
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      apt update -q && apt upgrade -y -q
      apt install -y -q lsb-release ca-certificates apt-transport-https software-properties-common gnupg2 curl zip unzip git socat cron ufw

      # PHP Repo
      if [ "$ID" == "ubuntu" ]; then
           add-apt-repository -y ppa:ondrej/php
           apt update -q
      else
           if [ ! -f /etc/apt/sources.list.d/php.list ]; then
               curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
               sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
               apt update -q
           fi
      fi
  elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
      dnf update -y
      dnf install -y epel-release
      
      # Remi Repo for PHP
      if [ "$ID" == "centos" ] || [ "$ID" == "almalinux" ] || [ "$ID" == "rocky" ]; then
          dnf install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VER%.*}.rpm
      fi
      
      dnf install -y curl zip unzip git socat cronie
      systemctl enable --now crond
  fi
}

install_panel() {
  output "Installing Pelican Panel..."

  # Install PHP & Extensions
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      apt install -y -q php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,sqlite3,fpm}
      update-alternatives --set php /usr/bin/php8.3 2>/dev/null || true
  elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
      dnf module reset php -y
      dnf module enable php:remi-8.3 -y
      dnf install -y php php-{cli,common,gd,mysqlnd,mbstring,bcmath,xml,curl,zip,intl,pdo,fpm}
  fi

  # Database
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      apt install -y -q mariadb-server
      systemctl enable --now mariadb
  elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
      dnf install -y mariadb-server
      systemctl enable --now mariadb
  fi

  # Composer
  if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # Download Panel
  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv
  
  # Permissions
  chmod -R 755 storage/* bootstrap/cache/
  if [ "$PACKAGE_MANAGER" == "dnf" ]; then
      chown -R nginx:nginx "$PANEL_DIR"
      PHP_USER="nginx"
  else
      chown -R www-data:www-data "$PANEL_DIR"
      PHP_USER="www-data"
  fi

  # Install Deps
  export COMPOSER_ALLOW_SUPERUSER=1
  composer install --no-dev --optimize-autoloader

  # Setup Config
  output "Configuring Panel..."
  cp .env.example .env
  
  # Generate Passwords
  DB_PASS=$(openssl rand -base64 12)
  ADMIN_PASS=$(openssl rand -base64 12)
  
  # URL Input
  echo -n "* Enter your FQDN/IP (default: $SITE_URL): "
  read -r input_url
  if [[ ! -z "$input_url" ]]; then
      if [[ "$input_url" != http* ]]; then
           SITE_URL="http://$input_url"
      else
           SITE_URL="$input_url"
      fi
  fi

  # Update .env
  sed -i "s|APP_URL=http://localhost|APP_URL=${SITE_URL}|g" .env
  sed -i "s|APP_URL=http://panel.test|APP_URL=${SITE_URL}|g" .env
  sed -i "s|DB_CONNECTION=mysql|DB_CONNECTION=mysql|g" .env
  sed -i "s|DB_HOST=127.0.0.1|DB_HOST=127.0.0.1|g" .env
  sed -i "s|DB_PORT=3306|DB_PORT=3306|g" .env
  sed -i "s|DB_DATABASE=panel|DB_DATABASE=pelican|g" .env
  sed -i "s|DB_USERNAME=pelican|DB_USERNAME=pelican|g" .env
  sed -i "s|DB_PASSWORD=|DB_PASSWORD=${DB_PASS}|g" .env

  php artisan key:generate --force

  # Database Setup
  output "Setting up Database..."
  mysql -u root -e "CREATE OR REPLACE USER 'pelican'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS pelican;"
  mysql -u root -e "GRANT ALL PRIVILEGES ON pelican.* TO 'pelican'@'127.0.0.1' WITH GRANT OPTION;"
  mysql -u root -e "FLUSH PRIVILEGES;"

  php artisan migrate --seed --force

  # Create User
  output "Creating Admin User..."
  php artisan tinker --execute="\App\Models\User::where('email', 'admin@pelican.local')->delete();" 2>/dev/null || true
  
  php artisan p:user:make --email="admin@pelican.local" --username="admin" --password="$ADMIN_PASS" --admin=1 --no-interaction

  # Nginx
  output "Configuring Nginx..."
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      apt install -y -q nginx
      rm -f /etc/nginx/sites-enabled/default
  elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
      dnf install -y nginx
  fi
  
  systemctl enable --now nginx

  # Determine proper PHP-FPM socket path
  if [ "$PACKAGE_MANAGER" == "apt" ]; then
      FPM_SOCKET="unix:/run/php/php8.3-fpm.sock"
  else
      # RHEL usually uses /run/php-fpm/www.sock or requires specific config, assume default
      # Make sure php-fpm listens on socket or start service
      systemctl enable --now php-fpm
      FPM_SOCKET="unix:/run/php-fpm/www.sock"
      # Sometimes default is 127.0.0.1:9000 on RHEL, checking...
      # If using Remi, usually /var/opt/remi/php83/run/php-fpm/www.sock
      # We will try standard RHEL 9 config path
      if [ -S /run/php-fpm/www.sock ]; then
          FPM_SOCKET="unix:/run/php-fpm/www.sock"
      else
          # Fallback to standard
          FPM_SOCKET="unix:/var/run/php-fpm/www.sock"
      fi
  fi

  cat <<EOF > $NGINX_CONF_DIR/pelican.conf
server {
    listen 80;
    server_name _;
    root $PANEL_DIR/public;
    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass $FPM_SOCKET;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  if [ ! -z "$NGINX_ENABLED_DIR" ]; then
      ln -sf $NGINX_CONF_DIR/pelican.conf $NGINX_ENABLED_DIR/pelican.conf
  fi
  
  systemctl restart nginx

  # Queue Worker
  cat <<EOF > /etc/systemd/system/pelican-worker.service
[Unit]
Description=Pelican Queue Worker
After=network-online.target
Wants=network-online.target

[Service]
User=$PHP_USER
Group=$PHP_USER
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now pelican-worker

  # Cron
  (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -

  fix_permissions
  configure_firewall

  success "Panel Installation Complete"
  print_brake 70
  output "Pelican Panel $SCRIPT_RELEASE with Nginx on $OS $OS_VER"
  output "Database Name: pelican"
  output "Database User: pelican"
  output "Database Password: $DB_PASS"
  output "Website URL: $SITE_URL"
  output "User Email: admin@pelican.local"
  output "Username: admin"
  output "User Password: $ADMIN_PASS"
  output "Timezone: $(timedatectl | grep "Time zone" | awk '{print $3}')"
  output "Configure Firewall? true"
  print_brake 70
}

install_wings() {
  output "Installing Wings on $OS..."
  
  # Configure Firewall
  configure_firewall
  
  # Cloudflare Question
  echo -n "* Are you using Cloudflare Proxy for Wings? (y/N): "
  read -r USE_CF
  if [[ "$USE_CF" =~ [Yy] ]]; then
      output "Note: When using Cloudflare Proxy, ensure SSL is Full/Strict."
  fi

  # Docker
  curl -sSL https://get.docker.com/ | CHANNEL=stable sh
  systemctl enable --now docker

  # Wings Binary
  mkdir -p /etc/pelican /var/run/wings
  curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64"
  chmod u+x /usr/local/bin/wings

  # Check and kill likely existing wings process
  if lsof -i :8080 -t >/dev/null; then
    output "Freeing port 8080..."
    kill -9 $(lsof -i :8080 -t) 2>/dev/null || true
  fi

  # Systemd
  cat <<EOF > /etc/systemd/system/wings.service
[Unit]
Description=Pelican Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  
  # Wings SSL Setup
  echo -n "* Do you want to configure SSL for this Wings node? (y/N): "
  read -r CONFIRM_SSL
  if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
      echo -n "* Enter Node FQDN (e.g. node1.example.com): "
      read -r NODE_FQDN
      echo -n "* Enter Email for Let's Encrypt: "
      read -r SSL_EMAIL
      
      output "Installing Certbot..."
      if [ "$PACKAGE_MANAGER" == "apt" ]; then
          apt install -y certbot
      elif [ "$PACKAGE_MANAGER" == "dnf" ]; then
          dnf install -y certbot
      fi
      
      output "Stopping Webserver (Nginx) temporarily for certificate issuance..."
      systemctl stop nginx 2>/dev/null || true
      
      output "Generating Certificate..."
      certbot certonly --standalone -d "$NODE_FQDN" --email "$SSL_EMAIL" --agree-tos --non-interactive
      
      output "Restarting Webserver..."
      systemctl start nginx 2>/dev/null || true
      
      success "SSL Certificate Generated!"
      output "Certificate Path: /etc/letsencrypt/live/$NODE_FQDN/fullchain.pem"
      output "Private Key Path: /etc/letsencrypt/live/$NODE_FQDN/privkey.pem"
      output "IMPORTANT: Use these paths in Panel > Node > Configuration > SSL."
  fi

  success "Wings Installation Complete"
  output "Configure a Node in the Panel to finish setup."
  output "1. Go to Admin -> Nodes -> Create New."
  output "2. Paste the auto-deploy command from the Panel here:"
  output "   (Or manually edit /etc/pelican/config.yml)"
  echo -n "* Paste Command (or press Enter to skip): "
  read -r DEPLOY_CMD
  if [[ ! -z "$DEPLOY_CMD" ]]; then
      eval "$DEPLOY_CMD"
      systemctl enable --now wings
      success "Wings Configured & Started!"
  else
      systemctl enable wings
      output "Skipping auto-deploy. Remember to configure and start wings manually."
  fi
}

fix_permissions() {
  output "Fixing Panel Permissions..."
  chmod -R 755 $PANEL_DIR/storage $PANEL_DIR/bootstrap/cache
  chown -R $PHP_USER:$PHP_USER $PANEL_DIR
  output "Permissions fixed."
}

troubleshooting() {
  print_brake 70
  output "Troubleshooting Guide"
  output "Documentation: https://pelican.dev/docs/troubleshooting"
  output ""
  output "What would you like to do?"
  output "[0] Check Services Status"
  output "[1] Fix Panel Permissions (Fixes 500 Errors)"
  output "[2] View Panel Logs (Last 100 lines)"
  output "[3] View Nginx Logs (Last 50 Error lines)"
  output "[4] Check Panel Database Connectivity"
  
  echo -n "* Input 0-4: "
  read -r t_action
  
  case $t_action in
    0)
      output "Checking Services..."
      systemctl is-active --quiet nginx && echo "  - Nginx: UP" || echo "  - Nginx: DOWN"
      systemctl is-active --quiet pelican-worker && echo "  - Queue: UP" || echo "  - Queue: DOWN"
      systemctl is-active --quiet docker && echo "  - Docker: UP" || echo "  - Docker: DOWN"
      (crontab -l 2>/dev/null | grep -q "artisan schedule:run") && echo "  - Cron: INSTALLED" || echo "  - Cron: MISSING"
      ;;
    1)
      fix_permissions
      ;;
    2)
      if [ -f "$PANEL_DIR/storage/logs/laravel.log" ]; then
          tail -n 100 "$PANEL_DIR/storage/logs/laravel.log"
      else
          error "Panel log file not found."
      fi
      ;;
    3)
      if [ -f "/var/log/nginx/error.log" ]; then
          tail -n 50 "/var/log/nginx/error.log"
      else
          error "Nginx error log not found."
      fi
      ;;
    4)
      output "Checking Database Connection..."
      if [ -f "$PANEL_DIR/.env" ]; then
          cd "$PANEL_DIR"
          php artisan db:monitor
      else
          error ".env file not found."
      fi
      ;;
    *)
      error "Invalid option"
      ;;
  esac
  
  print_brake 70
}

uninstall_panel() {
  output "Removing Panel files..."
  rm -rf /var/www/pelican
  
  output "Removing Nginx config..."
  rm -f $NGINX_CONF_DIR/pelican.conf
  if [ ! -z "$NGINX_ENABLED_DIR" ]; then
      rm -f $NGINX_ENABLED_DIR/pelican.conf
  fi
  systemctl restart nginx
  
  output "Removing Queue Worker..."
  systemctl disable --now pelican-worker 2>/dev/null || true
  rm -f /etc/systemd/system/pelican-worker.service
  systemctl daemon-reload
  
  output "Dropping Database..."
  mysql -u root -e "DROP DATABASE IF EXISTS pelican; DROP USER IF EXISTS 'pelican'@'127.0.0.1';"
  
  success "Panel Uninstalled Successfully"
}

uninstall_wings() {
  output "Stopping Wings..."
  systemctl disable --now wings 2>/dev/null || true
  
  output "Removing Wings files..."
  rm -f /usr/local/bin/wings
  rm -f /etc/systemd/system/wings.service
  rm -rf /etc/pelican
  systemctl daemon-reload
  
  success "Wings Uninstalled Successfully"
}

# Sub-menu logic
perform_uninstall() {
  output "What would you like to do?"
  options=(
    "Uninstall Panel"
    "Uninstall Wings"
  )

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#options[@]} - 1)): "
  read -r action

  case $action in
    0)
      uninstall_panel
      ;;
    1)
      uninstall_wings
      ;;
    *)
      error "Invalid option"
      ;;
  esac
}

# Main Loop
check_root
detect_os

done=false
while [ "$done" == false ]; do
  welcome
  options=(
    "Install the panel"
    "Install Wings"
    "Install Panel and Wings"
    "Uninstall Panel or Wings"
    "Troubleshooting"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    "uninstall"
    "troubleshooting"
  )

  output "What would you like to do?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"

  if [[ " ${valid_input[*]} " =~ ${action} ]]; then
    
    # Handle selection
    case ${actions[$action]} in
      "panel")
        install_dependencies
        install_panel
        ;;
      "wings")
        install_dependencies
        install_wings
        ;;
      "panel;wings")
        install_dependencies
        install_panel
        install_wings
        ;;
      "uninstall")
        perform_uninstall
        ;;
      "troubleshooting")
        troubleshooting
        ;;
    esac

    # Ask to exit or continue?
    echo -n "* Do you want to perform another action? (y/N): "
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ [Yy] ]]; then
       done=true
    fi
  fi
done
