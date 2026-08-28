# Raspberry Pi Home Cloud

A secure, self-hosted private cloud and backend development server built with a Raspberry Pi 5, Ubuntu Server, Docker, Nextcloud, PostgreSQL, Redis, Tailscale, and dedicated backup storage.

![Raspberry Pi Home Cloud hardware](images/overview/components.jpeg)

## Project Overview

This project transforms a Raspberry Pi 5 into a home server capable of:

- Hosting a private Nextcloud instance
- Synchronizing files across computers and mobile devices
- Running containerized backend applications
- Providing a private system-monitoring dashboard
- Storing backups on a dedicated external drive
- Recovering services automatically after a reboot
- Supporting future portfolio and API deployments

## Hardware

| Component | Purpose |
|---|---|
| Raspberry Pi 5, 8 GB RAM | Main ARM64 server |
| Argon NEO 5 M.2 NVMe case | Cooling and NVMe integration |
| Kingston NV3 1 TB NVMe SSD | Operating system, applications, and primary data |
| WD Elements 2 TB external drive | Dedicated backup storage |
| SanDisk Ultra 32 GB microSD | Installation and recovery media |
| Official Raspberry Pi 27 W USB-C power supply | Stable power delivery |
| Cat 6 Ethernet cable | Gigabit network connection |
| Micro-HDMI to HDMI cable | Optional initial local setup |

A monitor and USB keyboard were used only during the initial installation. The server is now administered remotely through SSH.

## Software Stack

- Ubuntu Server 24.04 LTS ARM64
- Docker Engine and Docker Compose
- Nextcloud
- PostgreSQL
- Redis
- Node.js and Express
- Tailscale
- UFW firewall
- OpenSSH
- ext4 backup storage

## Architecture

```mermaid
flowchart TD
    Devices["Authorized devices"] --> Tailscale["Tailscale encrypted network"]
    Tailscale --> Pi["Raspberry Pi 5"]
    Pi --> Nextcloud["Nextcloud"]
    Pi --> Dashboard["JuanCloud Dashboard"]
    Nextcloud --> Database["PostgreSQL"]
    Nextcloud --> Cache["Redis"]
    Pi --> NVMe["1 TB NVMe primary storage"]
    Pi --> Backup["2 TB external backup drive"]
```

See [Architecture](docs/architecture.md) for service boundaries and network exposure details.

## Storage Layout

| Storage | Role |
|---|---|
| 1 TB NVMe | Ubuntu, Docker, Nextcloud, databases, dashboard, and backend projects |
| 2 TB external drive | Backups of Nextcloud, databases, and server configuration |
| 32 GB microSD | Recovery media |

The external drive is mounted persistently at `/srv/backups`, and backend projects are stored under `/srv/projects`.

## Nextcloud Deployment

Nextcloud runs as a Docker Compose stack containing:

- Nextcloud Apache application
- PostgreSQL database
- Redis cache
- Nextcloud cron service

The application listens only on the host loopback interface. It is not directly exposed through the router. Secrets are stored in a local `.env` file excluded from Git; only `.env.example` is included here.

## JuanCloud Dashboard

The private Node.js and Express dashboard displays CPU, memory, temperature, load, uptime, architecture, NVMe usage, and external backup-drive usage.

Its container runs as a non-root user with a read-only filesystem, dropped Linux capabilities, no privilege escalation, no Docker socket, and read-only access only to dedicated metrics directories. It does not expose logs, secrets, IP addresses, or administrative controls.

## Security

- SSH public-key authentication
- Password authentication disabled
- Root SSH login disabled
- UFW enabled with incoming traffic denied by default
- Tailscale access restricted to authenticated devices
- HTTPS provided through Tailscale Serve
- Docker services bound to localhost
- Separate PostgreSQL and Redis credentials
- Automatic Ubuntu security updates
- No router port forwarding
- No public Tailscale Funnel
- Secrets excluded through `.gitignore`

See [Security](docs/security.md) for the implemented controls and safe verification commands.

## Recovery Testing

The Raspberry Pi was rebooted to verify automatic recovery. Ubuntu, the external backup mount, Docker, Nextcloud, PostgreSQL, Redis, cron, the dashboard, and the private Tailscale Serve routes returned successfully.

## Documentation

- [Architecture](docs/architecture.md)
- [Hardware assembly](docs/hardware-assembly.md)
- [Security](docs/security.md)
- [Backups](docs/backups.md)
- [Troubleshooting](docs/troubleshooting.md)

## Project Gallery

| Assembly | Validation |
|---|---|
| ![NVMe thermal pad installation](images/assembly/nvme-thermal-pad.jpeg) | ![First successful boot](images/screenshots/first-boot.jpeg) |
| ![PCIe ribbon and microSD installation](images/assembly/pcie-microsd.jpeg) | ![NVMe detection](images/screenshots/nvme-detected.jpeg) |

Additional build photographs are available in [`images/assembly`](images/assembly).

## Repository Structure

```text
.
├── dashboard/
│   ├── public/
│   ├── Dockerfile
│   ├── compose.yaml
│   ├── package.json
│   ├── server.js
│   └── storage.js
├── docs/
│   ├── architecture.md
│   ├── backups.md
│   ├── hardware-assembly.md
│   ├── security.md
│   └── troubleshooting.md
├── images/
│   ├── assembly/
│   ├── overview/
│   └── screenshots/
├── nextcloud/
│   ├── .env.example
│   └── compose.yaml
├── .gitignore
├── LICENSE
└── README.md
```

## Current Status

- [x] Ubuntu Server installed on NVMe
- [x] SSH key authentication configured
- [x] UFW firewall enabled
- [x] Docker installed and tested
- [x] Nextcloud deployed
- [x] PostgreSQL and Redis configured
- [x] Private remote access configured
- [x] iPhone synchronization tested
- [x] External backup drive configured
- [x] Initial backup completed
- [x] Monitoring dashboard deployed
- [x] Automatic recovery tested
- [x] Project documentation and build photographs added
- [ ] Automated scheduled backups
- [ ] Restore procedure testing
- [ ] Public portfolio deployment

## Privacy Notice

This repository intentionally excludes passwords, production environment files, SSH keys, Tailscale addresses and domain names, Nextcloud user data, database contents, backup archives, public IP addresses, and hardware serial numbers.

## Author

Juan Carlos Matos Soriano  
Computer Science student and backend developer
