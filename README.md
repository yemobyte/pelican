# Pelican Panel Installer

Automated installation script for Pelican Panel and Wings.

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

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/yemobyte/pelican/main/install.sh | bash
```

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
- Selects appropriate package manager

### System Dependencies
- Installs required system packages (curl, wget, unzip, git, tar)
- Installs PHP 8.2+ with all required extensions
- Installs Composer
- Installs Node.js 18.x
- Optional: Installs MySQL/MariaDB

### Pelican Panel
- Creates pelican system user
- Clones Pelican Panel repository
- Installs PHP and Node.js dependencies
- Sets up environment configuration
- Builds frontend assets
- Creates systemd service for queue worker
- Configures Nginx (optional)
- Sets up cron jobs

### Pelican Wings (Optional)
- Downloads latest Wings binary
- Creates Wings configuration directory
- Creates systemd service for Wings daemon

## Post-Installation Steps

### 1. Configure Database

Edit `/opt/pelican/panel/.env` and configure your database:

```env
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=pelican
DB_USERNAME=pelican
DB_PASSWORD=your_password
```

### 2. Run Migrations

```bash
cd /opt/pelican/panel
php artisan migrate --seed
```

### 3. Create Admin User

```bash
cd /opt/pelican/panel
php artisan p:user:make
```

### 4. Start Services

```bash
systemctl enable --now pelican-panel
```

If you installed Wings:

```bash
systemctl enable --now pelican-wings
```

### 5. Configure Wings (If Installed)

Edit `/etc/pelican/config.yml` with your Wings configuration.

## Service Management

### Panel Queue Worker

```bash
systemctl start pelican-panel
systemctl stop pelican-panel
systemctl restart pelican-panel
systemctl status pelican-panel
```

### Wings Daemon

```bash
systemctl start pelican-wings
systemctl stop pelican-wings
systemctl restart pelican-wings
systemctl status pelican-wings
```

## Directory Structure

```
/opt/pelican/
├── panel/          # Panel installation
└── wings/          # Wings binary (if installed)

/etc/pelican/       # Wings configuration
/etc/systemd/system/
├── pelican-panel.service
└── pelican-wings.service
```

## Troubleshooting

### Check PHP Version

```bash
php -v
```

Should be PHP 8.2 or higher.

### Check PHP Extensions

```bash
php -m
```

Required extensions: bcmath, ctype, curl, dom, fileinfo, gd, hash, iconv, intl, json, mbstring, openssl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, session, tokenizer, xml, zip

### Check Service Status

```bash
systemctl status pelican-panel
systemctl status pelican-wings
```

### View Logs

```bash
journalctl -u pelican-panel -f
journalctl -u pelican-wings -f
```

## Documentation

- [Pelican Panel Documentation](https://pelican.dev/docs/panel/getting-started)
- [Pelican Wings Documentation](https://pelican.dev/docs/wings/install)

## License

MIT
