# Changelog

Notable project milestones and changes. Operational status is distinguished from code prepared for deployment.

## [JuanCloud v3] — Disaster Recovery & External Heartbeat (October 26, 2026)

### Verified on the running Raspberry Pi
- Verified SHA256 checksums of the October 26 Nextcloud data archive and SQL dump.
- Restored 126 PostgreSQL tables after recreating the missing `oc_admin` role in an isolated database.
- Extracted approximately 1.1 GB of Nextcloud files, including `data/.ncdata`; completed two 15-second CLI recovery tests.
- Confirmed HTTP application status 200 and browser login/file visibility through a private SSH tunnel.
- Verified removal of temporary disaster-recovery Docker containers, networks, and volumes.
- Implemented a five-minute external Healthchecks.io heartbeat with a five-minute grace period; simulated missed heartbeats, received a real DOWN email, and restarted the timer successfully.

### Open work
- Test recovery from replacement hardware and define measured end-to-end RTO/RPO objectives.
- Automate secure PostgreSQL role/global backup handling and add encrypted off-site backups.
- Add periodic recovery drills and separate application-level uptime checks.

## [Unreleased] — JuanCloud v2: Observability & Maintenance (October 2026)

### Demonstrated on the live server
- Added a verified health dashboard with checks for CPU temperature, free memory, disk usage, Docker service status, and backup state.
- Integrated a lightweight local Ollama assistant for interpreting metrics. Deterministic checks, not AI text, determine health status.
- Added a daily Gmail health digest with an HTML layout and severity colors; validated actual delivery.
- Enabled Ubuntu's `unattended-upgrades` with security and stable update origins, daily APT timers, and automatic reboot disabled; validated configuration and a dry-run.
- Displayed pending APT updates on the dashboard. Counts are based on the local package index, and the health monitor may cache counts for up to six hours.

### Prepared tooling; verify deployment separately
- Added an APT/dpkg package-change notifier that tracks installed package-version changes, checks pending upgrades and reboot requirements, and emails via Gmail. The installation and end-to-end alert test should be confirmed on each server before describing it as operational.

### Safety and design decisions
- Kept secrets in a local root-owned environment file outside Git.
- Preserved read-only health collection and disabled unattended reboots.
- Excluded Docker image, Nextcloud application, PostgreSQL major-version, and Ollama model upgrades from unattended automation.
- Documented the limitation that on-device email cannot alert when the entire device or its network is offline.

## Initial release — August–September 2026

- Deployed Raspberry Pi 5 home-cloud hardware, Ubuntu Server, Nextcloud, PostgreSQL, Redis, private Tailscale access, scheduled backup storage, and a custom Express metrics dashboard.
- Added architecture, security, and recovery documentation.
