$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexProcesses.ps1')
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Fixture { param($Id,$Parent,$Name,$File,$Created,$Command='') [pscustomobject]@{ProcessId=$Id;ParentProcessId=$Parent;Name=$Name;ExecutablePath=$File;CreationDate=$Created;CommandLine=$Command} }
$t = Get-Date
$app = Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$engine = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\version\codex.exe'
$helper = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\node\node.exe'
$plugin = Join-Path $env:USERPROFILE '.codex\plugins\mcp\server.js'
$sample = @(
    (Fixture 100 50 'ChatGPT.exe' $app $t),
    (Fixture 200 100 'codex.exe' $engine $t.AddSeconds(1)),
    (Fixture 300 200 'cmd.exe' 'C:\Windows\System32\cmd.exe' $t.AddSeconds(2)),
    (Fixture 400 300 'node.exe' 'C:\Program Files\nodejs\node.exe' $t.AddSeconds(3)),
    (Fixture 500 400 'chrome.exe' 'C:\Browser\chrome.exe' $t.AddSeconds(4)),
    (Fixture 600 50 'Cursor.exe' 'C:\Cursor\Cursor.exe' $t.AddSeconds(1)),
    (Fixture 610 600 'node.exe' 'C:\Program Files\nodejs\node.exe' $t.AddSeconds(2)),
    (Fixture 700 50 'ChatGPT.exe' 'C:\AnotherApp\ChatGPT.exe' $t.AddSeconds(1)),
    (Fixture 800 999 'node.exe' $helper $t.AddSeconds(1)),
    (Fixture 810 999 'node.exe' 'C:\Program Files\nodejs\node.exe' $t.AddSeconds(1) ('node "' + $plugin + '"')),
    (Fixture 900 200 'powershell.exe' 'C:\Windows\powershell.exe' $t.AddSeconds(2)),
    (Fixture 910 900 'conhost.exe' 'C:\Windows\conhost.exe' $t.AddSeconds(3)),
    (Fixture 1000 50 'ChatGPT.exe' $app $t.AddSeconds(20)),
    (Fixture 1010 1000 'node.exe' 'C:\Program Files\nodejs\node.exe' $t.AddSeconds(-20))
)
$found = @(Get-CodexTargets -Snapshot $sample -SelfProcessId 900)
$ids = @($found | ForEach-Object { $_.Id })
foreach ($expected in @(100,200,300,400,500,800,810,1000)) { Assert-True ($ids -contains $expected) ('Missing Codex target ' + $expected) }
foreach ($excluded in @(600,610,700,900,910,1010)) { Assert-True ($ids -notcontains $excluded) ('Unsafe process selection ' + $excluded) }
Assert-True (@(Get-CodexTargets -Snapshot @() -SelfProcessId 900).Count -eq 0) 'Empty process snapshot should select nothing'
Write-Output 'PASS selection: process tree, orphan helpers, unrelated apps, own helper, PID reuse'

Assert-True ((Resolve-CodexToggleAction -Snapshot @()) -eq 'Open') 'Empty app state should open'
$orphan = @(Fixture 3010 999 'node.exe' $helper $t)
Assert-True ((Resolve-CodexToggleAction -Snapshot $orphan) -eq 'Open') 'An orphan plugin must not be mistaken for an open app'
Assert-True ((Resolve-CodexToggleAction -Snapshot @(Fixture 3011 999 'codex.exe' $engine $t)) -eq 'Open') 'A headless engine must not prevent opening the desktop'
Assert-True ((Resolve-CodexToggleAction -Snapshot @(Fixture 3012 999 'ChatGPT.exe' $app $t '--type=renderer')) -eq 'Open') 'An orphan renderer must not prevent opening the desktop'
Assert-True ((Resolve-CodexToggleAction -Snapshot @(Fixture 3013 50 'ChatGPT.exe' $app $t)) -eq 'Close') 'An actual desktop main process should close'
$widget = Join-Path $PSScriptRoot 'CodexWidget.exe'
$widgetSample = @($sample) + @((Fixture 3020 200 'CodexWidget.exe' $widget $t.AddSeconds(3)),(Fixture 3021 3020 'powershell.exe' 'C:\Windows\powershell.exe' $t.AddSeconds(4)))
$widgetTargets = @(Get-CodexTargets -Snapshot $widgetSample -SelfProcessId 900 | ForEach-Object { $_.Id })
Assert-True ($widgetTargets -notcontains 3020 -and $widgetTargets -notcontains 3021) 'Closing Codex must preserve the resident button and its worker'
Write-Output 'PASS regression: orphan plugin, engine, renderer, running desktop, resident button protection'

$testDir = Join-Path $PSScriptRoot 'test-state'
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
$pidFile = Join-Path $testDir 'worker-pids.json'
$parentFile = Join-Path $testDir 'parent.ps1'
$parentSource = @(
    'param([string]$PidFile)',
    '$ps = Join-Path $env:WINDIR ''System32\WindowsPowerShell\v1.0\powershell.exe''',
    '$a = Start-Process -FilePath $ps -ArgumentList ''-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 90"'' -WindowStyle Hidden -PassThru',
    '$b = Start-Process -FilePath $ps -ArgumentList ''-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 90"'' -WindowStyle Hidden -PassThru',
    '@($PID,$a.Id,$b.Id) | ConvertTo-Json | Set-Content -LiteralPath $PidFile -Encoding UTF8',
    'Start-Sleep -Seconds 90'
)
$parentSource | Set-Content -LiteralPath $parentFile -Encoding UTF8
if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile }
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$parent = Start-Process -FilePath $ps -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $parentFile + '" -PidFile "' + $pidFile + '"') -WindowStyle Hidden -PassThru
$workerIds = @($parent.Id)
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert-True (Test-Path -LiteralPath $pidFile) 'Fixture workers did not start'
    $workerIds = @((Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json))
    $snapshot = @(Get-CodexSnapshot)
    $targets = @($snapshot | Where-Object { $workerIds -contains [int]$_.ProcessId } | ForEach-Object { [pscustomobject]@{Id=[int]$_.ProcessId;ParentId=[int]$_.ParentProcessId;Name=$_.Name;Path=$_.ExecutablePath;CreatedAt=$_.CreationDate;Role='Child'} })
    Assert-True ($targets.Count -eq 3) 'Expected three isolated fixture workers'
    $stale = [pscustomobject]@{Id=$targets[0].Id;ParentId=0;Name=$targets[0].Name;Path=$targets[0].Path;CreatedAt=$targets[0].CreatedAt.AddMinutes(-1);Role='Child'}
    $ignored = Stop-CodexTargetBatch -Targets @($stale)
    Assert-True ($ignored.Stopped.Count -eq 0) 'Stale PID identity was not ignored'
    Assert-True ([bool](Get-Process -Id $targets[0].Id -ErrorAction SilentlyContinue)) 'Stale PID check terminated a live process'
    $stopped = Stop-CodexTargetBatch -Targets $targets
    Start-Sleep -Milliseconds 250
    $survivors = @(Get-Process -Id $workerIds -ErrorAction SilentlyContinue)
    Assert-True ($survivors.Count -eq 0) 'Fixture shutdown left running child processes'
    Assert-True ($stopped.Issues.Count -eq 0) 'Fixture shutdown reported errors'
    Write-Output 'PASS shutdown: three real isolated workers stopped; stale PID guarded'
} finally {
    foreach ($workerId in $workerIds) { Get-Process -Id $workerId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
}
Write-Output 'ALL TESTS PASSED'
