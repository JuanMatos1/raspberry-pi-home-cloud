#!/usr/bin/env python3
"""JuanCloud local monitor: read-only data collection, verified alerts, Gmail digests.
Python standard library only. It NEVER installs upgrades or restarts services.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import smtplib
import ssl
import subprocess
import sys
from email.message import EmailMessage
from urllib.request import urlopen

STATE_DIR = Path(os.environ.get('JUANCLOUD_STATE_DIR', '/var/lib/juancloud-health'))
SYSTEM_URL = 'http://127.0.0.1:3001/system'
DASHBOARD_URL = 'http://127.0.0.1:3000/api/status'
EXPECTED = [x.strip() for x in os.getenv('JUANCLOUD_REQUIRED_CONTAINERS',
    'juancloud-nextcloud-app-1,juancloud-nextcloud-db-1,juancloud-nextcloud-redis-1,dashboard-api-1,juancloud-ai'
).split(',') if x.strip()]
SEVERITIES = {'ok': 0, 'unknown': 1, 'warning': 2, 'critical': 3}


def now():
    return dt.datetime.now(dt.timezone.utc)


def read_json(url):
    with urlopen(url, timeout=15) as r:
        return json.load(r)


def num(value):
    try:
        return float(str(value).strip().rstrip('%'))
    except (TypeError, ValueError):
        return None


def gib(value):
    if value is None:
        return None
    m = re.fullmatch(r'\s*([0-9.]+)\s*(Ki|Mi|Gi|Ti|K|M|G|T|B)?(?:i?B)?\s*', str(value))
    if not m:
        return None
    amount = float(m.group(1)); unit = m.group(2) or 'B'
    return amount * {'B':1/1024**3,'Ki':1/1024**2,'Mi':1/1024,'Gi':1,'Ti':1024,
                     'K':1/1024**2,'M':1/1024,'G':1,'T':1024}[unit]


def add(checks, code, level, summary, evidence):
    checks.append({'code':code,'severity':level,'summary':summary,'evidence':str(evidence)})


def analyze(system, dashboard=None, timestamp=None):
    timestamp = timestamp or now()
    checks=[]
    if not system:
        add(checks, 'system-collector', 'critical', 'System collector unavailable',
            'GET /system did not return valid data')
        return checks
    temp = num((system.get('temperature') or {}).get('celsius'))
    if temp is None:
        add(checks, 'temperature', 'unknown', 'CPU temperature unavailable', 'Sensor returned no reading')
    else:
        level = 'critical' if temp >= 85 else 'warning' if temp >= 80 else 'ok'
        add(checks, 'temperature', level, 'CPU temperature' + (' is elevated' if level != 'ok' else ' normal'), f'{temp} °C')
    mem = gib((system.get('memory') or {}).get('available'))
    if mem is None:
        add(checks, 'memory', 'unknown', 'Available memory unavailable', 'free -h did not return available RAM')
    else:
        level = 'critical' if mem < 0.35 else 'warning' if mem < 0.75 else 'ok'
        add(checks, 'memory', level, 'Available memory' + (' is low' if level != 'ok' else ' normal'), f'{mem:.2f} GiB available')
    for kind, label in [('mainStorage', 'NVMe/main disk'),('backupStorage', 'Backup drive')]:
        drive=system.get(kind) or {}; usage=num(drive.get('usagePercent'))
        if usage is None:
            add(checks, 'disk-'+kind, 'critical', label + ' status unavailable', 'Disk usage missing; check mount')
        else:
            level='critical' if usage >= 95 else 'warning' if usage >= 85 else 'ok'
            add(checks, 'disk-'+kind, level, label + ' capacity'+(' high' if level != 'ok' else ' normal'), f'{usage}% used; {drive.get("available", "?")} available')
    containers={c.get('name'):c for c in system.get('containers', []) if isinstance(c,dict)}
    for cname in EXPECTED:
        c = containers.get(cname)
        if c is None:
            add(checks, 'container-'+cname, 'critical', cname + ' not found in running container list', 'Inspect docker ps -a; this is not proof the container was deleted')
        elif c.get('state') != 'running':
            add(checks, 'container-'+cname, 'critical', cname + ' is not running', c.get('status','Unknown state'))
        elif c.get('health') == 'unhealthy':
            add(checks, 'container-'+cname, 'critical', cname + ' failed its Docker health check', c.get('status','unhealthy'))
        elif c.get('health') in ('healthy', 'not configured', 'none', None):
            add(checks, 'container-'+cname, 'ok', cname + ' running', f'Health check: {c.get("health", "not configured")}; not configured is not a failure')
        else:
            add(checks, 'container-'+cname, 'unknown', cname + ' health not established', c.get('health','unknown'))
    backup=system.get('backup') or {}; result=str(backup.get('lastResult','unknown')).lower()
    timer=backup.get('timerState'); enabled=backup.get('timerEnabled')
    if result != 'success':
        add(checks, 'backup-result', 'critical' if result in ('failed','failure','error') else 'warning', 'Last backup did not report success', result)
    else:
        add(checks, 'backup-result', 'ok', 'Last backup job succeeded', backup.get('lastCompleted','unknown') + '; restore not verified')
    if timer != 'active' or enabled != 'enabled':
        add(checks, 'backup-timer', 'warning', 'Automatic backup timer needs checking', f'state={timer}, enabled={enabled}')
    else:
        add(checks, 'backup-timer', 'ok', 'Daily backup timer active', f'next={backup.get("nextBackup", "unknown")}')
    try:
        last=dt.datetime.strptime(backup.get('lastCompleted', ''), '%Y-%m-%d_%H-%M-%S').replace(tzinfo=dt.timezone.utc)
        if (timestamp - last).total_seconds() > 48*3600:
            add(checks, 'backup-stale','warning','Last backup may be stale', f'{backup.get("lastCompleted")} (assumed UTC, verify timezone)')
    except (ValueError, TypeError):
        pass
    return checks


def get_updates(force=False):
    STATE_DIR.mkdir(parents=True,exist_ok=True)
    path=STATE_DIR/'updates.json'
    if not force and path.exists():
        try:
            data=json.loads(path.read_text())
            age=(now()-dt.datetime.fromisoformat(data['checkedAt'])).total_seconds()
            if age < 6*3600:
                return data
        except (ValueError,KeyError, OSError):
            pass
    try:
        p=subprocess.run(['apt','list','--upgradable'],capture_output=True,text=True,timeout=45,
                        env={**os.environ,'LC_ALL':'C'},check=False)
        if p.returncode != 0:
            raise RuntimeError('apt list returned nonzero: ' + (p.stderr.strip()[:200] or str(p.returncode)))
        names=[]
        for line in p.stdout.splitlines():
            if '/' in line and '[upgradable from:' in line:
                names.append(line.split('/')[0].strip())
        result={'checkedAt':now().isoformat(),'count':len(names),'packages':names[:100],
                'cachedMetadata':True,'rebootRequired':Path('/var/run/reboot-required').exists(),
                'note':'Based on the local APT package index; no apt update or installation was performed.'}
    except (FileNotFoundError, subprocess.TimeoutExpired, RuntimeError) as e:
        result={'checkedAt':now().isoformat(),'count':None,'packages':[],
                'cachedMetadata':True,'rebootRequired':Path('/var/run/reboot-required').exists(),
                'error':str(e)[:250]}
    path.write_text(json.dumps(result,indent=2)+'\n')
    return result



def render_email_html(subject, body):
    """Gmail-friendly HTML; all user/system content is HTML-escaped."""
    from datetime import datetime
    from html import escape
    from zoneinfo import ZoneInfo

    lines = [line.strip() for line in body.splitlines() if line.strip()]

    def field(key, default='—'):
        prefix = key + ':'
        for line in lines:
            if line.lower().startswith(prefix.lower()):
                return line[len(prefix):].strip()
        return default

    status = field('JuanCloud health', 'TEST').upper()
    colors = {
        'OK': ('#15803d', '#dcfce7', 'All systems operational'),
        'WARNING': ('#b45309', '#fef3c7', 'Some checks need attention'),
        'CRITICAL': ('#b91c1c', '#fee2e2', 'Immediate attention required'),
        'UNKNOWN': ('#475569', '#e2e8f0', 'Status could not be verified'),
        'TEST': ('#1d4ed8', '#dbeafe', 'Email delivery test')
    }
    accent, pale, subtitle = colors.get(status, colors['UNKNOWN'])

    time_utc = field('Time (UTC)', '')
    shown_time = time_utc or 'Not supplied'
    if time_utc:
        try:
            local = datetime.fromisoformat(time_utc.replace('Z', '+00:00'))
            shown_time = local.astimezone(ZoneInfo('America/New_York')).strftime('%b %d, %Y at %I:%M %p %Z')
        except (ValueError, KeyError, OverflowError):
            pass

    count = field('Confirmed/warning findings', '0')
    updates = field('Pending Ubuntu APT updates (cached index)', '—')
    reboot = field('Reboot requested', 'unknown').strip().lower()
    reboot_label = 'YES' if reboot == 'yes' else ('No' if reboot == 'no' else 'Unknown')
    reboot_color = '#b91c1c' if reboot == 'yes' else '#334155'
    is_test = status == 'TEST'

    findings = []
    for line in lines:
        for severity in ('CRITICAL', 'WARNING', 'UNKNOWN'):
            if line.upper().startswith('[' + severity + ']'):
                tint = {'CRITICAL': ('#b91c1c', '#fef2f2'),
                        'WARNING': ('#b45309', '#fffbeb'),
                        'UNKNOWN': ('#475569', '#f1f5f9')}[severity]
                findings.append(
                    '<tr><td style="padding:12px 14px;border-bottom:1px solid #e2e8f0;'
                    'border-left:4px solid ' + tint[0] + ';background:' + tint[1] + ';">'
                    '<b style="color:' + tint[0] + ';">' + severity + '</b>'
                    '<div style="color:#1e293b;padding-top:5px;line-height:1.5;">'
                    + escape(line[len(severity) + 2:].strip()) + '</div></td></tr>'
                )
                break

    if findings:
        findings_html = '<table role="presentation" cellpadding="0" cellspacing="0" width="100%">' + ''.join(findings) + '</table>'
    elif status == 'OK':
        findings_html = '<p style="margin:0;color:#166534;font-weight:600;">&#10003; No confirmed problems found in available checks.</p>'
    elif is_test:
        findings_html = '<p style="margin:0;color:#334155;">JuanCloud can send styled email successfully.</p>'
    else:
        findings_html = '<p style="margin:0;color:#475569;">No individual findings were included. Review the dashboard for details.</p>'

    packages = field('Packages', '')
    if packages != '—' and packages:
        parts = [p.strip() for p in packages.split(',') if p.strip()]
        package_html = ''.join(
            '<span style="display:inline-block;margin:3px 4px 3px 0;'
            'padding:5px 8px;border-radius:6px;background:#f1f5f9;'
            'color:#334155;font-size:12px;">' + escape(p) + '</span>'
            for p in parts
        )
    else:
        package_html = '<span style="color:#64748b;">No package list available.</span>'

    def metric(label, value, value_color='#0f172a'):
        return (
            '<td style="width:33%;padding:12px 8px;text-align:center;vertical-align:top;'
            'border-right:1px solid #e2e8f0;">'
            '<div style="color:#64748b;font-size:11px;letter-spacing:.4px;">'
            + escape(label) + '</div>'
            '<div style="margin-top:7px;color:' + value_color + ';font-size:24px;font-weight:700;">'
            + escape(str(value)) + '</div></td>'
        )

    metrics = (
        '<table role="presentation" cellpadding="0" cellspacing="0" width="100%"'
        ' style="background:#fff;border:1px solid #e2e8f0;border-radius:12px;">'
        '<tr>' + metric('PROBLEMS', count, '#b91c1c' if count not in ('0', '—') else '#15803d')
        + metric('UPDATES', updates) + metric('REBOOT', reboot_label, reboot_color)
        + '</tr></table>'
    )

    note = (
        'Update counts use locally cached APT indexes; no updates were installed. '
        'A successful backup does not confirm that restoring it will work. '
        'This device cannot send alerts if it or its internet connection is offline.'
    )
    plain_test = '<p style="color:#475569;font-size:14px;">' + escape(body) + '</p>' if is_test else ''
    packages_section = '' if is_test else (
        '<tr><td style="padding:0 26px 20px;">'
        '<div style="font-size:15px;font-weight:700;margin-bottom:10px;">Ubuntu updates</div>'
        '<p style="font-size:13px;color:#475569;margin:0 0 10px;">Packages pending (cached APT metadata):</p>'
        + package_html + '</td></tr>'
    )

    return (
        '<!doctype html><html><body style="margin:0;padding:24px 10px;background:#f1f5f9;'
        'font-family:Arial,Helvetica,sans-serif;color:#0f172a;">'
        '<table role="presentation" cellpadding="0" cellspacing="0" width="100%"'
        ' style="max-width:640px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;'
        'border-radius:16px;">'
        '<tr><td style="padding:28px 26px;background:#0f172a;color:white;">'
        '<div style="font-size:13px;letter-spacing:2px;font-weight:700;color:#93c5fd;">JUANCLOUD</div>'
        '<div style="margin-top:7px;font-size:27px;font-weight:700;">Server Health Report</div>'
        '<div style="margin-top:8px;font-size:13px;color:#cbd5e1;">' + escape(shown_time) + '</div>'
        '</td></tr>'
        '<tr><td style="padding:24px 26px;">'
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"'
        ' style="border-left:5px solid ' + accent + ';background:' + pale + ';">'
        '<tr><td style="padding:17px 20px;">'
        '<div style="font-size:12px;color:' + accent + ';font-weight:700;">SYSTEM STATUS</div>'
        '<div style="font-size:28px;line-height:1.3;color:' + accent + ';font-weight:700;">'
        + escape(status) + '</div>'
        '<div style="font-size:13px;color:#334155;">' + escape(subtitle) + '</div>'
        '</td></tr></table></td></tr>'
        '<tr><td style="padding:0 26px 22px;">' + metrics + '</td></tr>'
        '<tr><td style="padding:0 26px 24px;">'
        '<div style="font-size:15px;font-weight:700;margin-bottom:10px;">Health findings</div>'
        + findings_html + plain_test + '</td></tr>'
        + packages_section +
        '<tr><td style="padding:18px 26px;border-top:1px solid #e2e8f0;'
        'background:#f8fafc;color:#64748b;font-size:12px;line-height:1.6;">'
        + escape(note) + '<br>Automated report from JuanCloud monitoring.'
        '</td></tr></table></body></html>'
    )


def send_email(subject, body):
    sender=os.getenv('JUANCLOUD_SMTP_USER','').strip()
    secret=os.getenv('JUANCLOUD_SMTP_APP_PASSWORD','').replace(' ','').strip()
    recipient=os.getenv('JUANCLOUD_EMAIL_TO','').strip()
    if not (sender and secret and recipient):
        print('Email not configured; wrote monitoring status only.')
        return False
    msg=EmailMessage()
    msg['Subject']=subject
    msg['From']=sender
    msg['To']=recipient
    msg.set_content(body)
    msg.add_alternative(render_email_html(subject, body), subtype='html')
    with smtplib.SMTP('smtp.gmail.com',587,timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        print("SMTP: TLS connection established", flush=True)
        print("SMTP AUTH methods:", smtp.esmtp_features.get("auth", "none"), flush=True)
        print("Sender format valid:", "@" in sender, flush=True)
        print("App password has 16 characters:", len(secret) == 16, flush=True)
        smtp.login(sender, secret, initial_response_ok=False)
        print("SMTP: Gmail authentication successful", flush=True)
        smtp.send_message(msg)
        print("SMTP: Gmail accepted message", flush=True)
    print('Gmail alert delivered to configured recipient.')
    return True


def overview(report):
    checks=report['checks']; notable=[c for c in checks if c['severity']!='ok']
    lines=[f'JuanCloud health: {report["overall"].upper()}',
           f'Time (UTC): {report["timestamp"]}',
           f'Confirmed/warning findings: {len(notable)}','']
    if notable:
        for c in notable:
            lines.append(f'[{c["severity"].upper()}] {c["summary"]}: {c["evidence"]}')
    else:
        lines.append('No confirmed health-check problems found in available measurements.')
    u=report.get('updates',{})
    lines.extend(['',f'Pending Ubuntu APT updates (cached index): {u.get("count", "unavailable")}',
                  f'APT check UTC: {u.get("checkedAt", "unknown")}',
                  f'Reboot requested: {"yes" if u.get("rebootRequired") else "no"}'])
    if u.get('packages'):
        lines.append('Packages: '+', '.join(u['packages'][:25]))
    lines.extend(['','Data source: existing JuanCloud system API and Ubuntu APT cache.',
                  'No updates installed. Backup success does not prove restorability.',
                  'This monitor cannot email if the Raspberry Pi or its internet connection is down.'])
    return '\n'.join(lines)


def run(mode):
    STATE_DIR.mkdir(parents=True,exist_ok=True)
    current=now(); error=None; system=None; dashboard=None
    try:
        system=read_json(SYSTEM_URL)
    except Exception as e:
        error=str(e)[:200]
    try:
        dashboard=read_json(DASHBOARD_URL)
    except Exception:
        pass
    checks=analyze(system,dashboard,current)
    overall=max((c['severity'] for c in checks),key=lambda x:SEVERITIES[x],default='unknown')
    updates=get_updates(force=(mode=='digest'))
    report={'timestamp':current.isoformat(),'overall':overall,'checks':checks,
            'updates':updates, 'temperatureC':((system or {}).get('temperature') or {}).get('celsius'),
            'memoryAvailable':((system or {}).get('memory') or {}).get('available'),
            'containerCount':len((system or {}).get('containers') or []),
            'sourceError':error}
    temp_file=STATE_DIR/'status.tmp'; temp_file.write_text(json.dumps(report,indent=2)+'\n')
    temp_file.replace(STATE_DIR/'status.json')
    with (STATE_DIR/'history.jsonl').open('a') as f:
        f.write(json.dumps({'time':report['timestamp'],'severity':overall,
                           'temperatureC':report['temperatureC'],
                           'memoryAvailable':report['memoryAvailable']})+'\n')
    # Bound retained history; 2,016 samples = 14 days at 10-minute intervals.
    hist=STATE_DIR/'history.jsonl'
    if hist.stat().st_size > 350000:
        hist.write_text(''.join(hist.read_text().splitlines(keepends=True)[-2016:]))
    if mode=='test-email':
        sent=send_email('[JuanCloud] Gmail delivery test','JuanCloud monitoring test message. No incident detected.')
        return 0 if sent else 2
    if mode=='digest':
        send_email(f'[JuanCloud] Daily report: {overall.upper()} | {updates.get("count", "?")} updates',overview(report))
    else:
        issues=sorted(c['code']+':'+c['severity'] for c in checks if c['severity'] in ('critical','warning'))
        previous_path=STATE_DIR/'last-alert.json'
        previous=json.loads(previous_path.read_text()) if previous_path.exists() else {'issues':[]}
        old=previous.get('issues',[])
        # No repeated mail for unchanged conditions. Send one recovery email on resolution.
        if issues != old:
            title='Problems detected' if issues else 'Recovered'
            sent=send_email('[JuanCloud] '+title,overview(report))
            if sent:
                previous_path.write_text(json.dumps({'issues':issues,'sentAt':current.isoformat()},indent=2))
    print(f'Health status written: {overall}; updates={updates.get("count", "unknown")}')
    return 0


if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--mode',choices=['check','digest','test-email'],default='check')
    try:
        sys.exit(run(p.parse_args().mode))
    except Exception as e:
        print(f'Monitor error: {e}',file=sys.stderr)
        sys.exit(1)
