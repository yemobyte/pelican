#!/bin/bash

# Pelican Panel & Wings Installer
# Copyright (c) 2025 yemobyte
# Based on Pterodactyl Installer style
# Supports Debian 12

set -e

# Versioning
export SCRIPT_RELEASE="v2.3"
export OS="Debian"
export OS_VER="12"
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

configure_firewall() {
  output "Configuring firewall (UFW)..."
  if ! command -v ufw &> /dev/null; then
     apt install -y ufw
  fi
  
  ufw allow 22
  ufw allow 80
  ufw allow 443
  ufw allow 8080
  ufw allow 2022
  echo "y" | ufw enable
}

install_dependencies() {
  output "Updating system and installing dependencies..."
  apt update -q && apt upgrade -y -q
  apt install -y -q lsb-release ca-certificates apt-transport-https software-properties-common gnupg2 curl zip unzip git socat cron ufw

  # PHP Repo
  if [ ! -f /etc/apt/sources.list.d/php.list ]; then
    curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
    apt update -q
  fi
}

install_panel() {
  output "Installing Pelican Panel..."

  # PHP 8.3
  apt install -y -q php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,sqlite3,fpm}
  update-alternatives --set php /usr/bin/php8.3 2>/dev/null || true

  # MariaDB
  apt install -y -q mariadb-server

  # Composer
  if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # Download Panel
  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv
  chmod -R 755 storage/* bootstrap/cache/

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
  apt install -y -q nginx
  systemctl enable nginx
  rm -f /etc/nginx/sites-enabled/default

  cat <<EOF > /etc/nginx/sites-available/pelican.conf
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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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
  ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
  systemctl restart nginx

  # Queue Worker
  cat <<EOF > /etc/systemd/system/pelican-worker.service
[Unit]
Description=Pelican Queue Worker
After=network-online.target
Wants=network-online.target

[Service]
User=www-data
Group=www-data
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

  configure_firewall

  success "Panel Installation Complete"
  output "URL: ${SITE_URL}"
  output "User: admin"
  output "Pass: ${ADMIN_PASS}"
}

install_wings() {
  output "Installing Wings..."
  
  # Configure firewall for Wings
  output "Configuring Firewall for Wings..."
  if ! command -v ufw &> /dev/null; then
     apt install -y ufw
  fi
  ufw allow 8080
  ufw allow 2022
  echo "y" | ufw enable

  # Cloudflare Question
  echo -n "* Are you using Cloudflare Proxy for Wings? (y/N): "
  read -r USE_CF
  if [[ "$USE_CF" =~ [Yy] ]]; then
      output "Note: When using Cloudflare Proxy (Orange Cloud), ensure SSL is set to Full/Strict in Cloudflare."
      output "You will need to manually configure trusted_proxies in config if needed later."
  fi

  # Docker
  curl -sSL https://get.docker.com/ | CHANNEL=stable sh
  systemctl enable --now docker

  # Wings Binary
  mkdir -p /etc/pelican /var/run/wings
  curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64"
  chmod u+x /usr/local/bin/wings

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
  
  success "Wings Installation Complete"
  output "Configure a Node in the Panel to finish setup."
}

troubleshooting() {
  print_brake 70
  output "Troubleshooting Guide"
  output "Documentation: https://pelican.dev/docs/troubleshooting"
  output ""
  output "Common checks running now..."
  
  output "1. Checking Services..."
  systemctl is-active --quiet nginx && echo "  - Nginx: UP" || echo "  - Nginx: DOWN"
  systemctl is-active --quiet pelican-worker && echo "  - Queue: UP" || echo "  - Queue: DOWN"
  systemctl is-active --quiet docker && echo "  - Docker: UP" || echo "  - Docker: DOWN"
  
  output "2. Checking Disk Space..."
  df -h / | tail -1 | awk '{print "  - Available: "$4}'
  
  print_brake 70
}

uninstall_panel() {
  output "Removing Panel files..."
  rm -rf /var/www/pelican
  
  output "Removing Nginx config..."
  rm -f /etc/nginx/sites-enabled/pelican.conf
  rm -f /etc/nginx/sites-available/pelican.conf
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
  
  output "Removing Wings binary and configs..."
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
welcome

done=false
while [ "$done" == false ]; do
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
