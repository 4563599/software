param([switch]$BackendOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$client = Join-Path $PSScriptRoot 'client'
$installedNode = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
$nodeCandidates = @((Join-Path $PSScriptRoot 'runtime\node.exe'), (Join-Path $env:ProgramFiles 'nodejs\node.exe'), $installedNode) | Where-Object { $_ }
$node = $nodeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $node) {
    if ($BackendOnly) { throw 'T Notes runtime is missing.' }
    [System.Windows.Forms.MessageBox]::Show('Node.js 22 or newer is required. Install Node.js or use the portable package.', 'T Notes') | Out-Null
    exit 1
}
$port = if ($env:TNOTES_PORT) { [int]$env:TNOTES_PORT } else { 47321 }
$endpoint = 'http://127.0.0.1:' + $port
$appUrl = $endpoint + '/?v=4'
$healthy = $false
$started = $null
$gate = New-Object Threading.Mutex($false, ('Local\TNotesBackendStartup-' + $port))
$owned = $false
try {
try { $owned = $gate.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { throw 'T Notes backend startup is busy.' }
try {
    $health = Invoke-RestMethod -Uri "$endpoint/health" -TimeoutSec 2
    if ($health.app -ne 'TNotes') { throw 'Port is occupied by a different application.' }
    $healthy = $true
} catch {}
if (-not $healthy) {
    $backendTask = if ($port -eq 47321 -and -not $env:TNOTES_DATA) { Get-ScheduledTask -TaskName 'TNotesLocalBackend' -ErrorAction SilentlyContinue } else { $null }
    if ($backendTask) {
        Start-ScheduledTask -TaskName 'TNotesLocalBackend'
    } else {
    $dataDir = if ($env:TNOTES_DATA) { $env:TNOTES_DATA } else { Join-Path $env:LOCALAPPDATA 'TNotes' }
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $started = Start-Process -FilePath $node -ArgumentList ('"' + (Join-Path $client 'desktop.cjs') + '"') -WorkingDirectory $client -WindowStyle Hidden -RedirectStandardError (Join-Path $dataDir 'desktop-error.log') -RedirectStandardOutput (Join-Path $dataDir 'desktop-output.log') -PassThru
    }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 150
        try { $health = Invoke-RestMethod -Uri "$endpoint/health" -TimeoutSec 1; if ($health.app -eq 'TNotes') { $healthy = $true; break } } catch {}
    }
}
if (-not $healthy) {
    if ($BackendOnly) { throw 'T Notes local backend did not become healthy.' }
    [System.Windows.Forms.MessageBox]::Show('T Notes could not start. Check port 47321 and the desktop-error.log file.', 'T Notes') | Out-Null
    exit 1
}
} finally {
    if ($owned) { $gate.ReleaseMutex() }
    $gate.Dispose()
}
if ($BackendOnly) { [pscustomobject]@{Ready=$healthy;StartedProcessId=$(if($started){$started.Id}else{0});Endpoint=$endpoint}; return }
$browsers = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
)
$browser = $browsers | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $browser) { Start-Process $appUrl; exit 0 }
$profile = Join-Path $env:LOCALAPPDATA 'TNotes\browser-v3'
Start-Process -FilePath $browser -ArgumentList @('--app=' + $appUrl, '--new-window', '--user-data-dir="' + $profile + '"', '--window-size=470,810', '--no-first-run', '--no-default-browser-check')
