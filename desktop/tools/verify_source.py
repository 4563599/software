"""Audit staged desktop files without printing file contents or credentials."""
import ast
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def main():
    repo = Path(git('rev-parse', '--show-toplevel').decode().strip())
    prefix = ROOT.relative_to(repo).as_posix() + '/'
    names = git('ls-files', '--cached', '-z', '--', '.').decode().split('\0')
    checked = 0
    for relative in filter(None, names):
        name = PurePosixPath(relative)
        if any(part in {'node_modules', 'runtime', 'test-output', '__pycache__', 'private', 'dist'} for part in name.parts):
            raise RuntimeError('Generated or private directory staged: ' + relative)
        if name.name in {'server.json', 'server-ca.pem', 'enrollment.once', 'network-settings.json'} or re.search(r'\.(?:pem|key|pfx|p12|dpapi|once|sqlite3|db|log|bak|lnk)(?:\.|$)', name.name):
            raise RuntimeError('Private or generated file staged: ' + relative)
        if name.name.startswith('encrypted-cache.json') or name.name.startswith('ai-cleanup-result-') or name.name.startswith('.env'):
            raise RuntimeError('Local user data staged: ' + relative)
        blob = git('show', ':' + prefix + relative)
        if blob.startswith(b'%TSD-Header'):
            raise RuntimeError('Source appears to be enterprise-encrypted; use an approved export process: ' + relative)
        if name.suffix == '.png':
            if not blob.startswith(b'\x89PNG\r\n\x1a\n'):
                raise RuntimeError('Invalid PNG asset: ' + relative)
        elif name.suffix == '.ico':
            if not blob.startswith(b'\0\0\x01\0'):
                raise RuntimeError('Invalid ICO asset: ' + relative)
        else:
            text = blob.decode('utf-8-sig')
            if '\x00' in text or re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
                raise RuntimeError('Binary source or private key staged: ' + relative)
            if name.suffix == '.py':
                ast.parse(text, filename=relative)
            elif name.suffix == '.json':
                json.loads(text)
        checked += 1
    if not checked:
        raise RuntimeError('No desktop source files are staged')
    print(json.dumps({'staged_desktop_files_checked': checked, 'source_and_asset_validation': 'passed'}))


if __name__ == '__main__':
    main()
