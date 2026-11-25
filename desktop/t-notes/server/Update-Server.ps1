# Updates server.py on an existing T Notes sync server (installed by install_remote.py) without touching its data.
# The new server.py is tested on the server first (Python runs there, not on this computer); only then is the
# running copy backed up, replaced and the service restarted. SSH asks for the server password if it needs one.
#
#   powershell -ExecutionPolicy Bypass -File t-notes\server\Update-Server.ps1 [-User root] [-Server 1.2.3.4]
param(
    [string]$User = 'root',
    # Defaults to the host in %LOCALAPPDATA%\TNotes\server.json, the server this computer syncs with.
    [string]$Server = ''
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Server) {
    $config = Join-Path $env:LOCALAPPDATA 'TNotes\server.json'
    if (-not (Test-Path -LiteralPath $config)) { throw 'No server given and no TNotes server.json found; pass -Server.' }
    $Server = ([uri]((Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).url)).Host
}
if ($Server -notmatch '^[A-Za-z0-9.:-]+$' -or $User -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'Invalid server or user name.' }
$target = "$User@$Server"

# Same layout as the repository, so the tests find ../server/server.py.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('tnotes-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'server'), (Join-Path $stage 'tests') -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $here 'server.py') -Destination (Join-Path $stage 'server')
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $here) 'tests\test_store.py') -Destination (Join-Path $stage 'tests')
    $remote = '/tmp/tnotes-update'
    Write-Output "Copying server.py and its tests to $target ..."
    & ssh $target "rm -rf $remote && mkdir -p $remote"
    if ($LASTEXITCODE -ne 0) { throw 'Could not connect with SSH.' }
    & scp -q -r (Join-Path $stage 'server') (Join-Path $stage 'tests') "${target}:$remote/"
    if ($LASTEXITCODE -ne 0) { throw 'Copying the files failed.' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $commands = @(
        'set -e',
        "cd $remote",
        'python3 -m unittest discover -s tests -p test_store.py',
        'test -f /opt/tnotes/server.py',
        "cp -p /opt/tnotes/server.py /opt/tnotes/server.py.bak-$stamp",
        'install -m 644 server/server.py /opt/tnotes/server.py',
        'systemctl restart tnotes.service',
        'sleep 2',
        'systemctl is-active tnotes.service',
        "rm -rf $remote",
        "echo 'Updated. Previous version kept as /opt/tnotes/server.py.bak-$stamp'"
    ) -join ' && '
    Write-Output 'Testing on the server, then installing and restarting tnotes.service ...'
    & ssh $target $commands
    if ($LASTEXITCODE -ne 0) { throw 'The update stopped (see above). If the tests failed, the running server was not changed.' }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
