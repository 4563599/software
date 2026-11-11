import datetime
import hashlib
import ipaddress
import json
import os
import socket
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
NODE = os.environ.get('TNOTES_NODE') or shutil.which('node')
if os.name != 'nt' or not NODE:
    raise RuntimeError('Windows and Node.js 22+ on PATH are required for the integration tests')
out = ROOT / 'test-output'
out.mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='sync-test-', dir=out))
def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]

ports = [port(),port(),port()]
key = rsa.generate_private_key(public_exponent=65537,key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'TNotes test only')])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1))
        .not_valid_after(now+datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),False)
        .add_extension(x509.BasicConstraints(ca=True,path_length=None),True).sign(key,hashes.SHA256()))
(work/'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
(work/'server-ca.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
(work/'server.json').write_text(json.dumps({'url':f'https://127.0.0.1:{ports[0]}/'}))
(work/'service.json').write_text(json.dumps({'host':'127.0.0.1','port':ports[0],'database':str(work/'vault.sqlite3'),'cert':str(work/'server-ca.pem'),'key':str(work/'key.pem'),'enrollment_digest':hashlib.sha256(b'test-enrollment-only').hexdigest()}))
children=[]
client_envs=[]
log=(work/'process.log').open('w')
try:
    children.append(subprocess.Popen([sys.executable,str(ROOT/'server/server.py'),'--config',str(work/'service.json')],stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW))
    for i in range(2):
        client=work/('client'+str(i));client.mkdir()
        if i==0:(client/'enrollment.once').write_text('test-enrollment-only')
        env={**os.environ,'TNOTES_CONFIG':str(work/'server.json'),'TNOTES_DATA':str(client),'TNOTES_PORT':str(ports[i+1])}
        client_envs.append(env)
        children.append(subprocess.Popen([NODE,str(ROOT/'client/desktop.cjs')],env=env,stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW))
    time.sleep(2)
    result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'tests/backend_launcher_test.ps1'),'-Port',str(port()),'-DataDirectory',str(work/'launcher-fixture'),'-ConfigPath',str(work/'server.json')],timeout=60,creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:raise RuntimeError('Headless backend startup test failed')
    print(json.dumps({'headless_backend_start_recovery_idempotence':'passed'}))
    result=subprocess.run([NODE,str(ROOT/'tests/relay_retry_test.cjs'),str(work)],timeout=60)
    if result.returncode:raise RuntimeError('Network retry test failed')
    result=subprocess.run([NODE,str(ROOT/'tests/browser_test.cjs'),str(ports[1]),str(ports[2]),str(out)],timeout=180)
    if result.returncode:raise RuntimeError('Browser integration test failed: '+str(work))
    children[2].terminate()
    children[2].wait(timeout=10)
    children.append(subprocess.Popen([NODE,str(ROOT/'client/desktop.cjs')],env=client_envs[1],stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW))
    time.sleep(1)
    result=subprocess.run([NODE,str(ROOT/'tests/browser_test.cjs'),str(ports[1]),str(ports[2]),str(out),'restart'],timeout=90)
    if result.returncode:raise RuntimeError('Remembered login restart test failed: '+str(work))
    probe=subprocess.Popen([NODE,str(ROOT/'tests/stale_page_test.cjs'),str(ports[1]),str(work)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    children.append(probe)
    deadline=time.monotonic()+25
    while not (work/'page-ready').exists():
        if time.monotonic()>deadline or probe.poll() is not None:raise RuntimeError('Stale-page probe did not become ready')
        time.sleep(.1)
    children[1].terminate()
    children[1].wait(timeout=10)
    agent_a=subprocess.Popen([NODE,str(ROOT/'client/desktop.cjs')],env=client_envs[0],stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW)
    children.append(agent_a)
    time.sleep(1)
    (work/'agent-restarted').write_text('ready')
    for marker in ('draft-ready','failed-save-confirmed'):
        deadline=time.monotonic()+25
        while not (work/marker).exists():
            if time.monotonic()>deadline or probe.poll() is not None:raise RuntimeError('Draft recovery fixture did not reach '+marker)
            time.sleep(.1)
        if marker=='draft-ready':
            agent_a.terminate();agent_a.wait(timeout=10)
            (work/'backend-down').write_text('ready')
        else:
            agent_a=subprocess.Popen([NODE,str(ROOT/'client/desktop.cjs')],env=client_envs[0],stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW)
            children.append(agent_a);time.sleep(1)
            (work/'backend-recovered').write_text('ready')
    probe.wait(timeout=40)
    print(probe.stdout.read().decode(errors='replace'))
    if probe.returncode:raise RuntimeError('Stale-page login regression failed: '+str(work))
    if (work/'client0/remembered-session.dpapi').exists():raise RuntimeError('Opted-out login was persisted')
    if not (work/'client1/remembered-session.dpapi').exists():raise RuntimeError('Remembered login was not protected on disk')
    for file in (work/'vault.sqlite3',work/'client0/encrypted-cache.json',work/'client1/encrypted-cache.json',work/'client1/remembered-session.dpapi'):
        data=file.read_bytes()
        for secret in (b'Cross-device QA note',b'QA-secret-do-not-store-plaintext',b'QA-passphrase-only-2026'):
            if secret in data:raise RuntimeError('Plaintext found in '+str(file))
    with sqlite3.connect(work/'vault.sqlite3') as db:
        count=db.execute('select count(*) from records').fetchone()[0]
    print(json.dumps({'database_records':count,'plaintext_scan':'passed','test_folder':str(work)}))
finally:
    for process in children:
        process.terminate()
    for process in children:
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.kill();process.wait()
    log.close()
