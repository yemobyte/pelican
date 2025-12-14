# Pelican Panel Installer

Automated installation script for Pelican Panel and Wings following official Pelican documentation.

## Supported Operating Systems

### Fully Supported ✅

| Operating System | Version | Status |
|-----------------|---------|--------|
| **Ubuntu** | 22.04 | ✅ Fully Supported |
| **Ubuntu** | 24.04 | ✅ Fully Supported (Recommended) |
| **Debian** | 12 | ✅ Fully Supported |
| **Alma Linux** | 10 | ✅ Fully Supported |
| **Rocky Linux** | 10 | ✅ Fully Supported |
| **CentOS** | 10 | ✅ Fully Supported |

### Partially Supported ⚠️

| Operating System | Version | Status | Notes |
|-----------------|---------|--------|-------|
| **Debian** | 11 | ⚠️ Partially Supported | No SQLite Support |
| **Alma Linux** | 9 | ⚠️ Partially Supported | No SQLite Support |
| **Alma Linux** | 8 | ⚠️ Partially Supported | No SQLite Support |
| **Rocky Linux** | 9 | ⚠️ Partially Supported | No SQLite Support |
| **Rocky Linux** | 8 | ⚠️ Partially Supported | No SQLite Support |

## Requirements

- Root access
- Internet connection
- At least 2GB RAM
- At least 10GB disk space
- PHP 8.4, 8.3, or 8.2 (installed automatically)
- MySQL 8+ or MariaDB 10.6+ (installed automatically)

## Installation

### Quick Install

```bash
bash <(curl -s https://raw.githubusercontent.com/yemobyte/pelican/main/install.sh)
```

The installer will:
- Auto-detect your operating system
- Ask for domain name (required)
- Ask for database configuration (with defaults)
- Ask for admin user configuration (with defaults)
- Ask for Wings installation (optional)

### Manual Install

```bash
wget https://raw.githubusercontent.com/yemobyte/pelican/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## What the Installer Does

### Automatic Detection
- Detects your operating system (Ubuntu, Debian, Alma Linux, Rocky Linux, CentOS)
- Detects OS version
- Selects appropriate package manager (`apt`, `dnf`, or `yum`)

### System Dependencies
- Installs required system packages (curl, wget, unzip, git, tar, software-properties-common)
- Installs PHP 8.4/8.3/8.2 with all required extensions:
  - `gd`, `mysql`, `mbstring`, `bcmath`, `xml`, `curl`, `zip`, `intl`, `sqlite3`, `fpm`
- Installs Composer
- Installs Node.js 18.x (if needed for frontend assets)
- Installs MariaDB/MySQL 10.6+

### Pelican Panel
- Creates pelican system user
- Downloads latest Pelican Panel release from GitHub
- Installs PHP dependencies via Composer
- Sets up environment configuration (.env)
- Builds frontend assets (if package.json exists)
- Creates systemd service for queue worker
- Configures Nginx web server
- Sets up cron jobs for scheduled tasks
- Runs database migrations and seeding
- Creates admin user automatically

### Pelican Wings (Optional)
- Installs Docker CE automatically
- Downloads latest Wings binary to `/usr/local/bin/wings`
- Creates Wings configuration directory (`/etc/pelican`)
- Creates systemd service for Wings daemon
- Provides instructions for getting configuration from Panel

## Installation Process

1. **Input Configuration**:
   - Domain name or IP address (required)
   - Database name, username, password (with defaults)
   - Admin email, username, password (with defaults)
   - Wings installation choice

2. **Automatic Installation**:
   - All dependencies are installed automatically
   - Database is created and configured
   - Panel is downloaded and configured
   - Admin user is created
   - Services are started

## Post-Installation

### Access Information

After installation, you will see:
- Panel URL
- Admin credentials (email, username, password)
- Database credentials

### Service Management

```bash
# Panel Queue Worker
systemctl start pelican-panel
systemctl stop pelican-panel
systemctl restart pelican-panel
systemctl status pelican-panel

# Wings Daemon (if installed)
systemctl start pelican-wings
systemctl stop pelican-wings
systemctl restart pelican-wings
systemctl status pelican-wings
```

### Configure Wings (If Installed)

1. Login to Panel
2. Go to **Admin → Nodes → Configuration**
3. Copy the configuration code
4. Save to `/etc/pelican/config.yml`
5. Start Wings: `systemctl enable --now pelican-wings`

## Directory Structure

```
/var/www/pelican/          # Panel installation
/etc/pelican/              # Wings configuration
/usr/local/bin/wings       # Wings binary
/etc/systemd/system/
├── pelican-panel.service
└── pelican-wings.service
```

## Troubleshooting

### Check PHP Version

```bash
php -v
```

Should be PHP 8.4, 8.3, or 8.2.

### Check PHP Extensions

```bash
php -m
```

Required extensions: `gd`, `mysql`, `mbstring`, `bcmath`, `xml`, `curl`, `zip`, `intl`, `sqlite3`, `fpm`

### Check Service Status

```bash
systemctl status pelican-panel
systemctl status pelican-wings
```

### View Logs

```bash
# Panel logs
journalctl -u pelican-panel -f

# Wings logs
journalctl -u pelican-wings -f

# Nginx logs
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/access.log
```

### Check Database Connection

```bash
mysql -u pelican -p -e "SHOW DATABASES;"
```

### Reset Admin Password

```bash
cd /var/www/pelican
php artisan p:user:make
```

## Documentation

- [Pelican Panel Documentation](https://pelican.dev/docs/panel/getting-started)
- [Pelican Wings Documentation](https://pelican.dev/docs/wings/install)
- [Pelican Web Server Configuration](https://pelican.dev/docs/panel/webserver-config)

## Notes

- The installer follows official Pelican documentation
- Panel is installed to `/var/www/pelican` (official default)
- Wings binary is installed to `/usr/local/bin/wings` (official default)
- All passwords are auto-generated if not provided
- Domain name must be entered manually during installation

## Support

For issues related to:
- **Installer**: Open an issue on [GitHub](https://github.com/yemobyte/pelican)
- **Pelican Panel**: Visit [Pelican Documentation](https://pelican.dev/docs)
- **Pelican Support**: Visit [Pelican Support](https://pelican.dev/support)
