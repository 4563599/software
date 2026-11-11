$ErrorActionPreference = 'Stop'
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexFloatingWatchdog', [ref]$created)
if (-not $created) { $mutex.Dispose(); exit 0 }
try {
    $toolbar = Join-Path $PSScriptRoot 'codex-floating-button.ps1'
    $toolbarPattern = '(?i)-File\s+"?' + [regex]::Escape($toolbar) + '"?\s*$'
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.SessionId -eq $sessionId -and $_.CommandLine -match $toolbarPattern
    })
    # "Exit" in the toolbar menu leaves this marker; the toolbar removes it the next time it is started
    # (sign-in or the desktop shortcut). Without it, an exit would be undone within a minute.
    $paused = Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'TNotes\toolbar-paused')
    if ($running.Count -eq 0 -and -not $paused) {
    if (-not (Test-Path -LiteralPath $toolbar -PathType Leaf)) { throw 'Floating toolbar script is missing.' }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $toolbar + '"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.SessionId -eq $sessionId -and $_.CommandLine -match $toolbarPattern
    })
    if ($running.Count -ne 1) { throw 'Floating toolbar restart did not verify.' }
    $log = Join-Path $PSScriptRoot 'floating-watchdog.log'
    if (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).Length -lt 1MB) {
        Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Restored floating toolbar.') -Encoding UTF8
    }
    }
    $notesLauncher = Join-Path $PSScriptRoot 't-notes\Launch.ps1'
    if (Test-Path -LiteralPath $notesLauncher) { & $notesLauncher -BackendOnly | Out-Null }
} catch {
    $log = Join-Path $PSScriptRoot 'floating-watchdog.log'
    if (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).Length -lt 1MB) {
        Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Floating toolbar / notes backend health check failed.') -Encoding UTF8
    }
    exit 1
} finally {
    if ($created) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
