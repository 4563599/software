param([switch]$BackendOnly,[string]$Anchor = '')
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
. (Join-Path $PSScriptRoot 'window.ps1')
$browserProfile = Get-TNotesBrowserProfile
# Only one window: launches are serialized, and a launch that finds the window just raises it.
$windowGate = New-Object Threading.Mutex($false, ('Local\TNotesWindowLaunch-' + $port))
$windowOwned = $false
try {
    try { $windowOwned = $windowGate.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $windowOwned = $true }
    # Not owning the gate means another launch is still bringing the window up; opening one here would duplicate it.
    if ($windowOwned) {
        $window = Get-TNotesWindowHandle -ProfileDirectory $browserProfile
        if ($window -ne [IntPtr]::Zero) {
            Show-TNotesWindow -Handle $window
            Move-TNotesWindowToAnchor -Handle $window -Anchor $Anchor
        } else {
            $browsers = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
            )
            $browser = $browsers | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $browser) {
                Start-Process $appUrl
            } else {
                if (@(Get-TNotesBrowserProcessIds -ProfileDirectory $browserProfile).Count -eq 0) {
                    # No browser holds the profile right now, so its preferences can be set: the browser must not
                    # offer to save the master password or the accounts kept in records.
                    try { & $node (Join-Path $client 'browser-prefs.cjs') $browserProfile | Out-Null } catch {}
                }
                # --disable-sync: this profile exists only to show the vault; nothing in it belongs in a browser account.
                $browserArguments = @(('--app=' + $appUrl), '--new-window', ('--user-data-dir="' + $browserProfile + '"'), '--no-first-run', '--no-default-browser-check', '--disable-sync')
                $bounds = @(ConvertFrom-TNotesAnchor -Anchor $Anchor)
                if ($bounds.Count -eq 4) {
                    # Ask the browser to open above the T button straight away, so the window does not jump there afterwards.
                    Add-Type -AssemblyName System.Drawing
                    $screen = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($bounds[0] + [int]($bounds[2] / 2)), ($bounds[1] + [int]($bounds[3] / 2)))))
                    $start = Get-TNotesAnchoredBounds -Anchor $bounds -Width 470 -Height 810 -WorkingArea $screen.WorkingArea
                    $browserArguments += '--window-position=' + $start[0] + ',' + $start[1]
                    $browserArguments += '--window-size=' + $start[2] + ',' + $start[3]
                } else {
                    $browserArguments += '--window-size=470,810'
                }
                Start-Process -FilePath $browser -ArgumentList $browserArguments
                # Hold the gate until the window exists, so a launch queued behind this one finds it.
                $window = [IntPtr]::Zero
                for ($attempt = 0; $attempt -lt 60 -and $window -eq [IntPtr]::Zero; $attempt++) {
                    Start-Sleep -Milliseconds 250
                    $window = Get-TNotesWindowHandle -ProfileDirectory $browserProfile
                }
                # The browser may still prefer where the window was last time; its real size is known only now.
                if ($window -ne [IntPtr]::Zero) {
                    [void](Disable-TNotesWindowTransitions -Handle $window)
                    Move-TNotesWindowToAnchor -Handle $window -Anchor $Anchor
                }
            }
        }
    }
} finally {
    if ($windowOwned) { $windowGate.ReleaseMutex() }
    $windowGate.Dispose()
}
