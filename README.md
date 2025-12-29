# Pelican Panel & Wings Installer

A fully automated installation script for **Pelican Panel** and **Wings**, designed with a user-friendly menu interface similar to the popular Pterodactyl installer.

## Features

*   **Pterodactyl-like Interface**: Familiar, easy-to-use menu system.
*   **Automatic OS Detection**: Supports Debian 12, Ubuntu 22.04/24.04, AlmaLinux 9/10, Rocky Linux 9/10.
*   **Complete Stack**: Installs Nginx, PHP 8.3, MariaDB, and all dependencies.
*   **Secure Defaults**: Generates strong passwords and configures UFW/Firewalld.
*   **Wings Automation**:
    *   **Interactive SSL Setup**: Automates Certbot (LetsEncrypt) for standalone nodes.
    *   **Auto-Deploy**: Paste your Panel command to instantly configure Wings.
    *   **Conflict Resolution**: Automatically frees port 8080 if in use.
*   **Troubleshooting Suite**:
    *   **Fix Permissions**: One-click fix for "500 Server Error".
    *   **Log Viewer**: View Panel, Nginx, and System logs directly.
    *   **Diagnostics**: Checks Database, Cron, and Service status.
*   **Uninstaller**: Cleanly removes Panel or Wings.

## Installation

Run the following command as root:

```bash
curl -L https://raw.githubusercontent.com/yemobyte/pelican/main/install.sh -o install.sh && chmod +x install.sh && ./install.sh
```

## Supported Operating Systems

| Operating System | Version | Supported | Notes |
| :--- | :--- | :--- | :--- |
| **Debian** | 12 (Bookworm) | ✅ Verified | Primary development OS. |
| **Ubuntu** | 22.04 / 24.04 | ✅ Verified | Fully supported. |
| **AlmaLinux** | 9 / 10 | ✅ Verified | Supported via DNF. |
| **Rocky Linux** | 9 / 10 | ✅ Verified | Supported via DNF. |
| **CentOS Stream** | 9 / 10 | ✅ Verified | Supported via DNF. |
| **RHEL** | 9 / 10 | ✅ Verified | Supported via DNF. |

## Usage
The script provides an interactive menu:
1.  **Install Panel**: Sets up the web dashboard.
2.  **Install Wings**: Sets up the game server daemon.
3.  **Install Panel and Wings**: Sets up both on a single server (All-in-One).
4.  **Uninstall Panel or Wings**: deeply cleans files and databases.
5.  **Troubleshooting**: Checks status of Nginx, Docker, and Queue Worker.

## Screenshots
_(You can add screenshots here later)_

## Disclaimer
This script is not associated with the official Pelican project. Use at your own risk.

Copyright (c) 2025 yemobyte
