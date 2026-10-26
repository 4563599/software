param(
    [ValidateSet('Toggle','Open','Close','Inspect')][string]$Action = 'Toggle',
    [switch]$DryRun,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexProcesses.ps1')
$mutex = $null
$locked = $false
function Save-CodexResult {
    param($Value)
    $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-action.json') -Encoding UTF8
    ('{0} action={1} targets={2} remaining={3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Value.Action,$Value.TargetCount,$Value.RemainingCount) | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'activity.log') -Encoding UTF8
}
try {
    $snapshot = @(Get-CodexSnapshot)
    $targets = @(Get-CodexTargets -Snapshot $snapshot)
    $planned = $Action
    if ($Action -eq 'Toggle') { $planned = Resolve-CodexToggleAction -Snapshot $snapshot }
    if ($Action -eq 'Inspect' -or $DryRun) {
        $result = [pscustomobject]@{Action=$planned; DryRun=$true; TargetCount=$targets.Count; RemainingCount=$targets.Count; Targets=$targets}
        Save-CodexResult $result
        $result | ConvertTo-Json -Depth 6
        exit 0
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false, ('Local\CodexDesktopToggle-' + $sid))
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }
    # Re-evaluate under the lock so rapid repeated clicks cannot race.
    $snapshot = @(Get-CodexSnapshot)
    $targets = @(Get-CodexTargets -Snapshot $snapshot)
    if ($Action -eq 'Toggle') { $planned = Resolve-CodexToggleAction -Snapshot $snapshot }
    if ($planned -eq 'Open') {
        # Stale MCP/renderer processes must not turn the first click into Close.
        if (@(Get-CodexMainDesktop -Snapshot $snapshot).Count -eq 0 -and $targets.Count -gt 0) {
            $cleanup = Stop-CodexTargetBatch -Targets $targets
        }
        $opened = Open-CodexDesktop
        $result = [pscustomobject]@{Action='Open'; TargetCount=$targets.Count; RemainingCount=$opened.DesktopProcessCount; AppId=$opened.AppId}
    } else {
        $tracked = @{}
        foreach ($target in $targets) { $tracked[[string]$target.Id + '|' + [string]$target.CreatedAt.Ticks] = $target }
        foreach ($target in @($targets | Where-Object { $_.Role -eq 'Desktop' })) {
            $window = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
            if ($window -and $window.MainWindowHandle -ne 0) { try { $window.CloseMainWindow() | Out-Null } catch {} }
        }
        Start-Sleep -Milliseconds 800
        $issues = @()
        for ($round = 0; $round -lt 5; $round++) {
            foreach ($target in @(Get-CodexTargets)) { $tracked[[string]$target.Id + '|' + [string]$target.CreatedAt.Ticks] = $target }
            $batch = Stop-CodexTargetBatch -Targets @($tracked.Values)
            $issues = @($batch.Issues)
            Start-Sleep -Milliseconds 250
            $remaining = @(Get-CodexTargets)
            $trackedAlive = @($tracked.Values | Where-Object {
                $live = Get-Process -Id $_.Id -ErrorAction SilentlyContinue
                if (-not $live -or -not $_.CreatedAt) { return $false }
                try { return [Math]::Abs(($live.StartTime.ToUniversalTime() - ([datetime]$_.CreatedAt).ToUniversalTime()).TotalMilliseconds) -le 3 } catch { return $true }
            })
            if ($remaining.Count -eq 0 -and $trackedAlive.Count -eq 0) { break }
        }
        $result = [pscustomobject]@{Action='Close'; TargetCount=$targets.Count; RemainingCount=@((@($remaining) + @($trackedAlive)) | Select-Object -ExpandProperty Id -Unique).Count; Issues=$issues}
        if ($result.RemainingCount -gt 0) { throw ('Some Codex processes could not be stopped. Remaining: ' + $result.RemainingCount) }
    }
    Save-CodexResult $result
    $result | ConvertTo-Json -Depth 6
} catch {
    $detail = $_.Exception.Message
    [pscustomobject]@{Action='Error'; TargetCount=0; RemainingCount=0; Error=$detail} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'last-error.json') -Encoding UTF8
    if (-not $Quiet) {
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup(('Codex 开关执行失败：' + [Environment]::NewLine + $detail), 0, 'Codex 开关', 16) | Out-Null
    }
    Write-Error $detail
    exit 1
} finally {
    if ($locked -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
