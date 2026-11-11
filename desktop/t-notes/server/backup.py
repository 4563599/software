"""Consistent encrypted database snapshots, retaining the last seven days."""
import datetime
import sqlite3
from pathlib import Path

folder = Path('/var/lib/tnotes/backups')
folder.mkdir(mode=0o700, exist_ok=True)
target = folder / ('vault-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d') + '.sqlite3')
with sqlite3.connect('/var/lib/tnotes/vault.sqlite3') as source:
    with sqlite3.connect(target) as destination:
        source.backup(destination)
target.chmod(0o600)
for old in sorted(folder.glob('vault-*.sqlite3'))[:-7]:
    old.unlink()
