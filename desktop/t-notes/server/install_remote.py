"""First-time deployment only. Does not modify existing web servers."""
import json
import os
import pwd
import socket
import subprocess
import sys
import ipaddress
import re
from pathlib import Path

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

settings = json.load(sys.stdin)
hostname = settings['hostname']
port = settings.get('port', 18443)
if not isinstance(hostname, str) or not hostname or len(hostname) > 253:
    raise ValueError('A valid public hostname or IP is required')
try:
    address = ipaddress.ip_address(hostname)
    subject_alt_name = 'IP:' + str(address)
except ValueError:
    if not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in hostname.split('.')):
        raise ValueError('Invalid DNS hostname')
    subject_alt_name = 'DNS:' + hostname
if type(port) is not int or not 1 <= port <= 65535:
    raise ValueError('Invalid HTTPS port')
if not re.fullmatch(r'[0-9a-f]{64}', settings.get('enrollment_digest', '')):
    raise ValueError('Invalid enrollment digest')
root = Path('/opt/tnotes')
data = Path('/var/lib/tnotes')
if (root / 'config.json').exists() or data.exists():
    raise RuntimeError('Existing installation or data found; refusing to overwrite')
with socket.socket() as probe:
    probe.bind(('0.0.0.0', port))
for unit in ('tnotes.service', 'tnotes-backup.service', 'tnotes-backup.timer'):
    if (Path('/etc/systemd/system') / unit).exists():
        raise RuntimeError('Existing unit found; refusing to overwrite')
try:
    pwd.getpwnam('tnotes')
    raise RuntimeError('Unexpected existing service user')
except KeyError:
    run('useradd', '--system', '--home-dir', str(data), '--shell', '/sbin/nologin', 'tnotes')
user = pwd.getpwnam('tnotes')
data.mkdir(mode=0o700)
root.mkdir(mode=0o755, exist_ok=True)
os.chown(data, user.pw_uid, user.pw_gid)
run('openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
    '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem'), '-days', '730',
    '-subj', '/CN=TNotes Private Sync', '-addext', 'subjectAltName=' + subject_alt_name,
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign')
config = {'database': str(data / 'vault.sqlite3'), 'host': '0.0.0.0', 'port': port,
          'enrollment_digest': settings['enrollment_digest'], 'cert': str(root / 'cert.pem'), 'key': str(root / 'key.pem')}
(root / 'config.json').write_text(json.dumps(config))
for name in ('key.pem','config.json'):
    (root / name).chmod(0o640)
    os.chown(root / name, 0, user.pw_gid)
(root / 'cert.pem').chmod(0o644)
service = '''[Unit]
Description=T Notes encrypted sync
After=network.target
[Service]
Type=simple
User=tnotes
Group=tnotes
WorkingDirectory=/opt/tnotes
ExecStart=/usr/bin/python3 /opt/tnotes/server.py --config /opt/tnotes/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/tnotes
UMask=0077
MemoryMax=256M
TasksMax=48
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
'''
backup = '''[Unit]
Description=T Notes encrypted database backup
[Service]
Type=oneshot
User=tnotes
Group=tnotes
ExecStart=/usr/bin/python3 /opt/tnotes/backup.py
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/tnotes
UMask=0077
'''
timer = '''[Unit]
Description=Daily T Notes backup
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
'''
for name, text in [('tnotes.service',service),('tnotes-backup.service',backup),('tnotes-backup.timer',timer)]:
    target = Path('/etc/systemd/system') / name
    if target.exists():
        raise RuntimeError('Existing unit found; refusing to overwrite')
    target.write_text(text)
run('systemctl', 'daemon-reload')
run('systemctl', 'enable', '--now', 'tnotes.service', 'tnotes-backup.timer')
if subprocess.run(['systemctl','is-active','--quiet','firewalld']).returncode == 0:
    run('firewall-cmd','--add-port='+str(port)+'/tcp')
    run('firewall-cmd','--permanent','--add-port='+str(port)+'/tcp')
print(json.dumps({'service':run('systemctl','is-active','tnotes.service').strip(),
                  'backup_timer':run('systemctl','is-active','tnotes-backup.timer').strip(),
                  'port':port}))
