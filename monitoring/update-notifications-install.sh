#!/usr/bin/env bash
# JuanCloud package-change email notifications
# Monitors dpkg-installed package versions every five minutes; does not install updates.
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo 'Run as root: sudo bash ~/juancloud-update-notifications-install.sh' >&2
  exit 1
fi

CREDENTIALS=/etc/juancloud-health.env
if [[ ! -f "$CREDENTIALS" ]]; then
  echo "Missing $CREDENTIALS. Set up JuanCloud Gmail alerts first." >&2
  exit 1
fi
for cmd in /usr/bin/python3 /usr/bin/dpkg-query /usr/bin/apt /usr/bin/systemctl; do
  if [[ ! -x "$cmd" ]]; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

install -d -m 0755 /usr/local/lib/juancloud
install -d -m 0700 /var/lib/juancloud-update-notifier

SCRIPT=/usr/local/lib/juancloud/update-notifier.py
if [[ -e "$SCRIPT" ]]; then
  cp -a "$SCRIPT" "${SCRIPT}.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > "$SCRIPT" <<'PYTHON'
#!/usr/bin/env python3
"""JuanCloud: notify after APT/dpkg package changes (stdlib only).

Does not change packages, enable reboot, or modify Ubuntu's update schedule.
Initial run establishes a baseline; future installed version changes trigger Gmail.
"""
import argparse
import datetime as dt
import fcntl
from html import escape
import json
import os
from pathlib import Path
import smtplib
import ssl
import subprocess
import sys
from email.message import EmailMessage
from zoneinfo import ZoneInfo

STATE = Path('/var/lib/juancloud-update-notifier/state.json')
LOCK_PATHS = ['/var/lib/dpkg/lock', '/var/lib/dpkg/lock-frontend', '/var/lib/apt/lists/lock']
TZ = ZoneInfo('America/New_York')


def when():
    return dt.datetime.now(dt.timezone.utc).astimezone(TZ).strftime('%b %d, %Y at %I:%M %p %Z')


def apt_busy():
    """Observe APT/dpkg advisory locks without interfering with updates."""
    for path in LOCK_PATHS:
        if not os.path.exists(path):
            continue
        with open(path, 'rb') as lock:
            try:
                fcntl.lockf(lock.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)
            except BlockingIOError:
                return True
    return False


def installed_versions():
    cmd = ['/usr/bin/dpkg-query', '-W', '-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\n']
    result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=35)
    packages = {}
    for line in result.stdout.splitlines():
        cols = line.split('\t', 2)
        if len(cols) != 3:
            continue
        status, name, version = cols
        if status.startswith('ii') and name and version:
            packages[name] = version
    if not packages:
        raise RuntimeError('No installed packages found; refusing to replace baseline')
    return packages


def pending_updates():
    """Counts all APT-visible upgradable packages using the local cached index."""
    env = dict(os.environ, LC_ALL='C', LANGUAGE='C')
    p = subprocess.run(['/usr/bin/apt', 'list', '--upgradable'], env=env,
                       capture_output=True, text=True, timeout=45)
    if p.returncode != 0:
        raise RuntimeError('apt list --upgradable failed; will retry')
    return [line.split('/', 1)[0].strip() for line in p.stdout.splitlines()
            if '/' in line and '[upgradable from:' in line]


def reboot_required():
    return Path('/var/run/reboot-required').exists()


def read_state():
    if not STATE.exists():
        return None
    state = json.loads(STATE.read_text())
    if not isinstance(state, dict) or not isinstance(state.get('packages'), dict):
        raise RuntimeError('Invalid existing baseline state; not overwriting')
    return state


def save_state(packages):
    STATE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = STATE.with_suffix('.tmp')
    payload = {'packages': packages, 'checked_at': dt.datetime.now(dt.timezone.utc).isoformat()}
    with open(tmp, 'w') as f:
        os.fchmod(f.fileno(), 0o600)
        json.dump(payload, f, separators=(',', ':'), sort_keys=True)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def changes(old, new):
    upgraded = [(name, old[name], new[name]) for name in new
                if name in old and old[name] != new[name]]
    added = [(name, new[name]) for name in new if name not in old]
    removed = [(name, old[name]) for name in old if name not in new]
    return (sorted(upgraded), sorted(added), sorted(removed))


def make_text(upgraded, added, removed, pending, reboot, test=False):
    lines = [
        'JuanCloud package update notification' + (' — TEST ONLY' if test else ''),
        'Time (New York): ' + when(),
        f'Upgraded packages: {len(upgraded)}',
        f'New packages: {len(added)}',
        f'Removed packages: {len(removed)}',
        f'Pending APT updates: {len(pending)} (locally cached package index)',
        'Reboot required: ' + ('YES' if reboot else 'No'),
        '',
    ]
    if test:
        lines.append('This is a delivery test. No updates were installed by this notifier.')
    if upgraded:
        lines += ['Upgraded:', *[f'- {name}: {before} -> {after}' for name, before, after in upgraded]]
    if added:
        lines += ['', 'Installed:', *[f'- {name}: {version}' for name, version in added]]
    if removed:
        lines += ['', 'Removed:', *[f'- {name}: {version}' for name, version in removed]]
    if pending:
        lines += ['', 'Still pending:', ', '.join(pending[:40])]
        if len(pending) > 40:
            lines.append(f'... and {len(pending) - 40} more')
    lines += ['', 'APT counts use the latest cached package metadata. The notifier never installs updates or reboots JuanCloud.',
              'Docker container image updates, Snap apps and Ollama models are not tracked by this notifier.']
    return '\n'.join(lines)


def make_html(upgraded, added, removed, pending, reboot, test=False):
    def metric(label, value, foreground):
        return ('<td style="text-align:center;padding:17px 7px;width:33%;border-right:1px solid #e2e8f0;">'
                '<div style="font-size:11px;letter-spacing:1px;color:#64748b;">' + escape(label) + '</div>'
                '<div style="font-size:25px;font-weight:bold;margin-top:6px;color:' + foreground + ';">'
                + escape(str(value)) + '</div></td>')
    def section(title, rows, empty):
        if not rows:
            return '<p style="color:#64748b;margin:0 0 8px;">' + escape(empty) + '</p>'
        show = rows[:60]
        items = ''.join('<tr><td style="padding:10px 4px;border-bottom:1px solid #edf2f7;color:#334155;font-size:13px;">'
                        + escape(x) + '</td></tr>' for x in show)
        if len(rows) > 60:
            items += '<tr><td style="color:#64748b;padding:9px;">' + escape(f'... plus {len(rows)-60} more packages') + '</td></tr>'
        return '<div style="font-weight:bold;margin:0 0 8px;font-size:15px;">' + escape(title) + '</div>' + '<table width="100%" cellspacing="0" cellpadding="0">' + items + '</table>'

    rows = [f'{name}: {before} → {after}' for name, before, after in upgraded]
    banner_bg, banner_fg, subtitle = (('#dbeafe', '#1d4ed8', 'Notification test — no changes made') if test
                                      else ('#dcfce7', '#166534', 'Package changes detected'))
    pending_fg = '#b45309' if pending else '#15803d'
    reboot_fg = '#b91c1c' if reboot else '#15803d'
    pending_html = ', '.join(escape(n) for n in pending[:40]) if pending else 'No updates pending in the local APT index.'
    if len(pending) > 40:
        pending_html += escape(f' and {len(pending) - 40} more')
    return ( '<!doctype html><html><body style="margin:0;padding:26px 10px;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;color:#0f172a;">'
        '<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="max-width:650px;margin:auto;border-radius:14px;overflow:hidden;background:#fff;border:1px solid #e2e8f0;">'
        '<tr><td style="padding:28px;background:#0f172a;color:#fff;">'
        '<div style="font-size:12px;letter-spacing:2px;color:#93c5fd;font-weight:bold;">JUANCLOUD</div>'
        '<div style="margin-top:8px;font-size:26px;font-weight:bold;">Ubuntu Update Report</div>'
        '<div style="font-size:13px;color:#cbd5e1;margin-top:8px;">' + escape(when()) + '</div></td></tr>'
        '<tr><td style="padding:22px 25px 8px;">'
        '<table width="100%" role="presentation" cellpadding="0" cellspacing="0" style="background:' + banner_bg + ';border-left:5px solid ' + banner_fg + ';">'
        '<tr><td style="padding:14px 18px;color:' + banner_fg + ';font-weight:bold;">' + escape(subtitle) + '</td></tr></table></td></tr>'
        '<tr><td style="padding:18px 25px;">'
        '<table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e2e8f0;">'
        '<tr>' + metric('UPGRADED', len(upgraded), '#1d4ed8')
        + metric('PENDING', len(pending), pending_fg)
        + metric('REBOOT', 'YES' if reboot else 'NO', reboot_fg) + '</tr></table>'
        '<div style="font-size:12px;margin:10px 0 3px;color:#64748b;">'
        + escape(f'{len(added)} newly installed · {len(removed)} removed packages') + '</div></td></tr>'
        '<tr><td style="padding:0 25px 20px;">'
        '<div style="margin-bottom:13px;padding:12px 15px;background:' + ('#fef2f2' if reboot else '#f0fdf4') + ';color:' + reboot_fg + ';font-weight:bold;">'
        + ('Reboot required — schedule a safe maintenance window.' if reboot else 'No reboot requested by Ubuntu.')
        + '</div>'
        + section('Upgraded packages', rows, 'No packages upgraded in this test.')
        + section('Newly installed packages', [f'{n}: {v}' for n,v in added], '')
        + section('Removed packages', [f'{n}: {v}' for n,v in removed], '')
        + '<div style="font-size:15px;font-weight:bold;margin:18px 0 8px;">Still pending (' + str(len(pending)) + ')</div>'
        '<div style="font-size:12px;line-height:1.7;color:#475569;word-break:break-word;">' + pending_html + '</div></td></tr>'
        '<tr><td style="padding:16px 25px;background:#f8fafc;color:#64748b;font-size:12px;line-height:1.6;border-top:1px solid #e2e8f0;">'
        'Pending count comes from the locally cached APT index. This report never installs updates or reboots the server. '
        'Docker container image, Snap and Ollama model upgrades are not included.</td></tr></table></body></html>')


def email_report(upgraded, added, removed, pending, reboot, test=False):
    sender = os.getenv('JUANCLOUD_SMTP_USER', '').strip()
    receiver = os.getenv('JUANCLOUD_EMAIL_TO', '').strip()
    password = os.getenv('JUANCLOUD_SMTP_APP_PASSWORD', '').replace(' ', '').strip()
    if not sender or not receiver or not password:
        raise RuntimeError('Gmail variables missing in /etc/juancloud-health.env')
    subject = ('[JuanCloud] TEST: update notifications' if test else
               f'[JuanCloud] {len(upgraded)} upgraded, {len(pending)} pending' +
               (', REBOOT REQUIRED' if reboot else ''))
    if not test and not upgraded:
        subject = f'[JuanCloud] Package changes: {len(added)} installed, {len(removed)} removed | {len(pending)} pending' + (
            ' | REBOOT REQUIRED' if reboot else '')
    msg = EmailMessage()
    msg['Subject'], msg['From'], msg['To'] = subject, sender, receiver
    msg.set_content(make_text(upgraded, added, removed, pending, reboot, test))
    msg.add_alternative(make_html(upgraded, added, removed, pending, reboot, test), subtype='html')
    context = ssl.create_default_context()
    with smtplib.SMTP('smtp.gmail.com', 587, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        smtp.login(sender, password, initial_response_ok=False)
        smtp.send_message(msg)
    print('Gmail accepted JuanCloud update notification.')


def main():
    parser = argparse.ArgumentParser(description='JuanCloud package-change email watcher')
    parser.add_argument('--test', action='store_true', help='Send a TEST email without altering baseline')
    parser.add_argument('--baseline', action='store_true', help='Record current installed packages; no email')
    args = parser.parse_args()
    if apt_busy():
        print('APT/dpkg transaction in progress; retry on the next scheduled check.')
        return 0
    installed = installed_versions()
    if apt_busy():
        print('APT/dpkg began a transaction; defer this check.')
        return 0
    if args.baseline:
        if STATE.exists():
            print('Baseline already exists; preserving state.')
        else:
            save_state(installed)
            print(f'Baseline saved: {len(installed)} installed packages.')
        return 0
    pending = pending_updates()
    reboot = reboot_required()
    if args.test:
        email_report([], [], [], pending, reboot, test=True)
        return 0
    old = read_state()
    if old is None:
        save_state(installed)
        print(f'First run: saved baseline of {len(installed)} packages. No historical email sent.')
        return 0
    upgraded, added, removed = changes(old['packages'], installed)
    if not (upgraded or added or removed):
        print(f'No new package changes; {len(pending)} pending; reboot={reboot}. No email sent.')
        return 0
    email_report(upgraded, added, removed, pending, reboot)
    save_state(installed)  # Only advance on successful delivery, so failures get retried.
    print(f'Change email sent: {len(upgraded)} upgraded, {len(added)} installed, {len(removed)} removed; '
          f'{len(pending)} pending; reboot={reboot}.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        # Never log secrets, environment values or SMTP protocol transcripts.
        print('JuanCloud update notifier error: ' + type(e).__name__, file=sys.stderr)
        sys.exit(1)
PYTHON

chmod 0755 "$SCRIPT"
/usr/bin/python3 -m py_compile "$SCRIPT"

cat > /etc/systemd/system/juancloud-update-notify.service <<'SERVICE'
[Unit]
Description=JuanCloud Gmail notification after APT/dpkg package changes
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/juancloud-health.env
ExecStart=/usr/bin/python3 /usr/local/lib/juancloud/update-notifier.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/juancloud-update-notifier
UMask=0077
SERVICE

cat > /etc/systemd/system/juancloud-update-notify.timer <<'TIMER'
[Unit]
Description=Check JuanCloud for completed APT updates every five minutes
[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
AccuracySec=30s
Unit=juancloud-update-notify.service
[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/juancloud-update-notify-test.service <<'TESTSERVICE'
[Unit]
Description=Send safe JuanCloud update notifier test email
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/juancloud-health.env
ExecStart=/usr/bin/python3 /usr/local/lib/juancloud/update-notifier.py --test
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/juancloud-update-notifier
UMask=0077
TESTSERVICE

systemctl daemon-reload
# Set a baseline before starting timer. This never sends an email.
/usr/bin/python3 "$SCRIPT" --baseline
systemctl enable --now juancloud-update-notify.timer

echo
echo 'JuanCloud update notifications enabled.'
echo 'Monitors APT/dpkg changes every ~5 minutes and sends one email per detected batch.'
echo 'Nothing is installed or restarted by this notifier.'
echo
echo 'Send a safe TEST email (does not alter packages or baseline):'
echo '  sudo systemctl start juancloud-update-notify-test.service'
echo '  sudo journalctl -u juancloud-update-notify-test.service -n 15 --no-pager'
echo 'Regular checks are quiet unless new package changes are detected.'
echo 'To review the next automatic check:'
echo '  systemctl list-timers --all | grep juancloud-update'
