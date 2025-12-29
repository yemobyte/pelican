# Pelican Panel & Wings Installer

A fully automated installation script for **Pelican Panel** and **Wings**, designed with a user-friendly menu interface similar to the popular Pterodactyl installer.

## Features
*   **Automated Installation**: Install Panel, Wings, or both on the same machine.
*   **Smart Configuration**: Automatically configures Database, Nginx, PHP 8.3, and Docker.
*   **Security**: Sets up UFW firewall and offers Cloudflare Proxy support.
*   **Uninstaller**: Built-in menu to cleanly remove Panel, Wings, or both.
*   **Troubleshooting**: Quick diagnostic tool to check service health.

## Installation

Run the following command in your terminal:

```bash
bash <(curl -s https://raw.githubusercontent.com/yemobyte/pelican/main/install.sh)
```

## Supported Operating Systems

| Operating System | Version | Supported |
| :--- | :--- | :--- |
| **Debian** | **12 (Bookworm)** | ✅ **Verified** |
| Ubuntu | 22.04 / 24.04 | ⚠️ Should work (Untested) |
| CentOS / RHEL | Any | ❌ Not Supported |

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
