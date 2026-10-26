#!/usr/bin/env bash
# JuanCloud — enable daily official Ubuntu security + stable package updates.
# Does NOT update Docker images, Nextcloud, PostgreSQL, Ollama models, or the Ubuntu release.
# Does NOT automatically reboot the server.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo 'Please run this script with sudo: sudo bash ~/juancloud-enable-auto-updates.sh' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo 'Cannot identify this operating system.' >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != 'ubuntu' ]]; then
  echo "This script is for Ubuntu, not ${ID:-unknown}." >&2
  exit 1
fi

printf '\n== JuanCloud automatic Ubuntu updates ==\n'
printf 'OS: %s\n\n' "${PRETTY_NAME:-Ubuntu}"
printf 'Installing the official unattended-upgrades package...\n'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades

# Override settings using late-loading drop-ins. Do not change Ubuntu's vendor files.
# List entries here append the stable -updates pocket to default allowed origins.
cat > /etc/apt/apt.conf.d/90juancloud-unattended-upgrades <<'APTCONFIG'
// JuanCloud: apply official stable Ubuntu package fixes as well as security patches.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-updates";
};
// Never reboot this server automatically after installing packages.
Unattended-Upgrade::Automatic-Reboot "false";
APTCONFIG
chmod 0644 /etc/apt/apt.conf.d/90juancloud-unattended-upgrades

cat > /etc/apt/apt.conf.d/90juancloud-periodic <<'APTCONFIG'
// JuanCloud: refresh package lists and apply unattended upgrades daily.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTCONFIG
chmod 0644 /etc/apt/apt.conf.d/90juancloud-periodic

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

printf '\nConfiguration installed. Relevant APT settings:\n'
apt-config dump | grep -E '^(APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|Unattended-Upgrade::Automatic-Reboot)' || true
printf '\nNext scheduled APT runs:\n'
systemctl list-timers --all apt-daily.timer apt-daily-upgrade.timer --no-pager || true
printf '\nInstalled! Security and stable Ubuntu package updates will run unattended.\n'
printf 'Automatic reboots are disabled; some running services may still restart when libraries update.\n'
printf 'Docker images, Nextcloud, PostgreSQL, and Ollama require separate maintenance.\n'
printf 'Logs: /var/log/unattended-upgrades/unattended-upgrades.log\n'
printf 'Dry-run check: sudo unattended-upgrade --dry-run -v\n'
