"""First-time Linux deployment with an explicitly verified SSH host key."""
import argparse
import base64
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess

import paramiko

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--user', default='root')
    parser.add_argument('--fingerprint', required=True, help='User-verified SHA256 SSH fingerprint')
    parser.add_argument('--port', type=int, default=18443, help='Notes HTTPS port')
    parser.add_argument('--output-dir', type=Path, default=Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.local/share'))) / 'TNotes')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('Invalid HTTPS port')
    try:
        address = ipaddress.ip_address(args.host)
        if address.version != 4:
            parser.error('This deployment currently requires IPv4 or an IPv4-resolving DNS name')
    except ValueError:
        if len(args.host) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', part) for part in args.host.split('.')):
            parser.error('Invalid DNS hostname')
    if not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', args.fingerprint):
        parser.error('Use a verified SHA256 SSH host-key fingerprint')
    output = args.output_dir.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error('Private deployment files must be written outside the repository')
    if any((output / name).exists() for name in ('server.json', 'server-ca.pem', 'enrollment.once')):
        parser.error('Connection files already exist; refusing to overwrite')
    output.mkdir(parents=True, mode=0o700, exist_ok=True)
    if os.name == 'nt':
        sid = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'], text=True)
        match = re.search(r'S-1-5-[0-9-]+', sid)
        if not match:
            raise RuntimeError('Could not identify the current Windows user')
        subprocess.run(['icacls', str(output), '/inheritance:r', '/grant:r', '*' + match[0] + ':(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'], check=True, capture_output=True)
    else:
        output.chmod(0o700)

    class PinnedHost(paramiko.MissingHostKeyPolicy):
        def missing_host_key(self, client, hostname, key):
            actual = 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
            if hostname != args.host or actual != args.fingerprint:
                raise RuntimeError('SSH host key does not match the user-verified fingerprint')

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(PinnedHost())
    password = getpass.getpass('Server SSH password (hidden): ')
    try:
        client.connect(args.host, username=args.user, password=password, allow_agent=False, look_for_keys=False, timeout=15, auth_timeout=15, banner_timeout=15)
        password = None
        _, stdout, stderr = client.exec_command('test ! -e /opt/tnotes && test ! -e /var/lib/tnotes && mkdir -m 755 /opt/tnotes', timeout=15)
        if stdout.channel.recv_exit_status():
            raise RuntimeError('Existing server installation found or insufficient privileges; no overwrite performed')
        with client.open_sftp() as sftp:
            for name in ('server.py', 'backup.py', 'install_remote.py'):
                sftp.put(str(ROOT / 't-notes/server' / name), '/opt/tnotes/' + name)
            invitation = secrets.token_urlsafe(32)
            stdin, stdout, stderr = client.exec_command('/usr/bin/python3 /opt/tnotes/install_remote.py', timeout=90)
            stdin.write(json.dumps({'hostname': args.host, 'port': args.port, 'enrollment_digest': hashlib.sha256(invitation.encode()).hexdigest()}))
            stdin.channel.shutdown_write()
            result = stdout.read().decode()
            if stdout.channel.recv_exit_status():
                raise RuntimeError('Server setup failed; inspect the remote service logs before retrying')
            sftp.get('/opt/tnotes/cert.pem', str(output / 'server-ca.pem'))
            (output / 'server.json').write_text(json.dumps({'url': f'https://{args.host}:{args.port}/'}), encoding='utf-8')
            (output / 'enrollment.once').write_text(invitation, encoding='utf-8')
            invitation = None
            for name in ('server.json', 'server-ca.pem', 'enrollment.once'):
                (output / name).chmod(0o600)
            print(result.strip())
            print(json.dumps({'private_files_saved_outside_repo': True, 'output_directory': str(output)}))
    finally:
        password = None
        client.close()


if __name__ == '__main__':
    main()
