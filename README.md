# Pelican Panel Installer

Automated installation script for Pelican Panel.

## Requirements

- Ubuntu/Debian or CentOS/RHEL
- PHP 8.1 or higher
- MySQL/MariaDB or PostgreSQL
- Nginx or Apache
- Root access

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pelican-panel-installer/main/install.sh | bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/pelican-panel-installer/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## What it does

- Checks system requirements
- Installs missing dependencies (Composer, Node.js)
- Creates pelican user
- Downloads and installs Pelican Panel
- Installs PHP and Node.js dependencies
- Sets up environment configuration
- Creates systemd service for queue worker
- Configures Nginx (optional)
- Sets up cron jobs

## Post-Installation

1. Configure database in `/opt/pelican/panel/.env`
2. Run migrations: `cd /opt/pelican/panel && php artisan migrate --seed`
3. Create admin user: `cd /opt/pelican/panel && php artisan p:user:make`
4. Start queue worker: `systemctl enable --now pelican-panel`

## License

MIT
