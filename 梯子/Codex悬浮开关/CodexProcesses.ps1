Set-StrictMode -Version 2.0

function Get-CodexSnapshot {
    @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CommandLine,CreationDate)
}

function Get-CodexRole {
    param([Parameter(Mandatory)]$Process)
    $file = [string]$Process.ExecutablePath
    $localRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    $pluginRoot = Join-Path $env:USERPROFILE '.codex\plugins'
    $mcpRoot = Join-Path $env:USERPROFILE '.codex\mcp'
    $appPattern = '^' + [regex]::Escape((Join-Path $env:ProgramFiles 'WindowsApps') + '\') + 'OpenAI\.Codex_[^\\]+\\'
    if ($file -match $appPattern) { return 'Desktop' }
    if ($file.StartsWith($localRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        if ([string]$Process.Name -like 'codex*.exe') { return 'Engine' }
        return 'Helper'
    }
    if ($file.StartsWith($pluginRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'Helper' }
    if ([string]$Process.Name -match '^(node|python|pythonw|uv|uvx|bun|chrome|chromium|msedge|extension-host)\.exe$') {
        $command = [string]$Process.CommandLine
        foreach ($prefix in @($pluginRoot, $mcpRoot, $localRoot)) {
            if ($command.IndexOf($prefix + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'Helper' }
        }
    }
    return $null
}

function Get-CodexMainDesktop {
    param([object[]]$Snapshot = @(Get-CodexSnapshot))
    foreach ($item in $Snapshot) {
        if ((Get-CodexRole -Process $item) -ne 'Desktop') { continue }
        if ([string]$item.Name -notmatch '^(ChatGPT|Codex)\.exe$') { continue }
        if ([string]$item.CommandLine -match '(?:^|\s)--type(?:=|\s)') { continue }
        $item
    }
}

function Resolve-CodexToggleAction {
    param([object[]]$Snapshot = @(Get-CodexSnapshot))
    if (@(Get-CodexMainDesktop -Snapshot $Snapshot).Count -gt 0) { return 'Close' }
    return 'Open'
}

function Get-CodexTargets {
    param([object[]]$Snapshot = @(Get-CodexSnapshot), [int]$SelfProcessId = $PID)
    $byId = @{}
    foreach ($item in $Snapshot) { $byId[[int]$item.ProcessId] = $item }
    $selected = @{}
    $protected = @{}
    if ($byId.ContainsKey($SelfProcessId)) { $protected[$SelfProcessId] = $true }
    # The resident button must outlive the Codex process tree it controls.
    $utilityPrefix = $PSScriptRoot.TrimEnd('\') + '\'
    foreach ($item in $Snapshot) {
        if ([string]$item.Name -like 'CodexWidget*.exe' -and ([string]$item.ExecutablePath).StartsWith($utilityPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $protected[[int]$item.ProcessId] = $true
        }
    }
    foreach ($item in $Snapshot) {
        $role = Get-CodexRole -Process $item
        if ($role) { $selected[[int]$item.ProcessId] = $role }
    }
    do {
        $changed = $false
        foreach ($item in $Snapshot) {
            $childId = [int]$item.ProcessId
            $parentId = [int]$item.ParentProcessId
            if (-not $byId.ContainsKey($parentId)) { continue }
            $parent = $byId[$parentId]
            if (-not $item.CreationDate -or -not $parent.CreationDate -or $item.CreationDate -lt $parent.CreationDate) { continue }
            if ($selected.ContainsKey($parentId) -and -not $selected.ContainsKey($childId)) {
                $selected[$childId] = 'Child'; $changed = $true
            }
            if ($protected.ContainsKey($parentId) -and -not $protected.ContainsKey($childId)) {
                $protected[$childId] = $true; $changed = $true
            }
        }
    } while ($changed)
    foreach ($item in $Snapshot) {
        $childId = [int]$item.ProcessId
        if (-not $selected.ContainsKey($childId) -or $protected.ContainsKey($childId) -or $childId -le 4) { continue }
        [pscustomobject]@{
            Id = $childId
            ParentId = [int]$item.ParentProcessId
            Name = [string]$item.Name
            Path = [string]$item.ExecutablePath
            CreatedAt = $item.CreationDate
            Role = $selected[$childId]
        }
    }
}

function Stop-CodexTargetBatch {
    param([object[]]$Targets, [int]$SelfProcessId = $PID)
    $stopped = @()
    $issues = @()
    $ordered = @($Targets | Sort-Object @{Expression={ if ($_.Role -eq 'Desktop') { 0 } elseif ($_.Role -eq 'Engine') { 1 } else { 2 } }}, Id)
    foreach ($target in $ordered) {
        if ([int]$target.Id -eq $SelfProcessId -or [int]$target.Id -le 4) { continue }
        $live = Get-Process -Id ([int]$target.Id) -ErrorAction SilentlyContinue
        if (-not $live) { continue }
        try {
            # Recheck creation time to avoid terminating a reused PID.
            if (-not $target.CreatedAt -or [Math]::Abs(($live.StartTime.ToUniversalTime() - ([datetime]$target.CreatedAt).ToUniversalTime()).TotalMilliseconds) -gt 3) { continue }
            Stop-Process -InputObject $live -Force -ErrorAction Stop
            $stopped += [int]$target.Id
        } catch {
            if (Get-Process -Id ([int]$target.Id) -ErrorAction SilentlyContinue) {
                $issues += [pscustomobject]@{Id=[int]$target.Id; Name=$target.Name; Error=$_.Exception.Message}
            }
        }
    }
    [pscustomobject]@{Stopped=$stopped; Issues=$issues}
}

function Open-CodexDesktop {
    $appId = $null
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $entry = Get-StartApps | Where-Object { $_.AppID -like 'OpenAI.Codex_*!*' } | Select-Object -First 1
        if ($entry) { $appId = $entry.AppID }
    }
    if (-not $appId) { $appId = 'OpenAI.Codex_2p2nqsd0c76g0!App' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $appId) -ErrorAction Stop | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $desktop = @(Get-CodexMainDesktop)
        foreach ($item in $desktop) {
            $visible = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
            if ($visible -and $visible.MainWindowHandle -ne 0) { return [pscustomobject]@{AppId=$appId; DesktopProcessCount=$desktop.Count} }
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Codex did not appear after activation.'
}
