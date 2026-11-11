param([switch]$Legacy)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
function Assert-True($condition,[string]$message){if(-not $condition){throw $message};Write-Output ('PASS: '+$message)}
function Fake([int]$id,[int]$parent,[string]$name,[string]$path='',[string]$command='',[string]$package='',[int]$birth=0){
    [pscustomobject]@{ProcessId=$id;ParentProcessId=$parent;Name=$name;ExecutablePath=$path;CommandLine=$command;PackageFullName=$package;AppUserModelId='';CreationDate=([datetime]'2026-01-01T00:00:00Z').AddSeconds($birth)}
}
$fixture=@(
    (Fake 4 0 'System'),
    (Fake 5 4 'services.exe'),
    (Fake 6 5 'svchost.exe'),
    (Fake 10 1 'ChatGPT.exe' 'C:\Program Files\WindowsApps\OpenAI.Codex_1\app\ChatGPT.exe'),
    (Fake 11 10 'conhost.exe' 'C:\Windows\System32\conhost.exe'),
    (Fake 20 6 'RuntimeBroker.exe' 'C:\Windows\System32\RuntimeBroker.exe' '' 'OpenAI.Codex_1_x64__test'),
    (Fake 21 1 'RuntimeBroker.exe' 'C:\Windows\System32\RuntimeBroker.exe' '' 'Microsoft.Windows.Search_1_x64__test'),
    (Fake 30 1 'codex-windows-sandbox-setup.exe' 'D:\tools\codex-data\home\plugins\cache\openai-bundled\sandbox\codex-windows-sandbox-setup.exe'),
    (Fake 31 1 'node.exe' 'D:\tools\codex-data\home\plugins\cache\openai-primary-runtime\node.exe'),
    (Fake 40 1 'java.exe' 'C:\Users\test\AppData\Local\Claude-Data\jre\java.exe'),
    (Fake 41 1 'java.exe' 'D:\tools\android\Android Studio\jbr\bin\java.exe' 'org.gradle.GradleDaemon'),
    (Fake 50 10 'node.exe' 'D:\tools\codex\t-notes\runtime\node.exe'),
    (Fake 51 50 'conhost.exe'),
    (Fake 60 10 'msedge.exe' 'C:\Program Files\Edge\msedge.exe' '--user-data-dir="C:\Users\test\AppData\Local\TNotes\browser-v3"'),
    (Fake 61 60 'msedge.exe'),
    (Fake 80 1 'claude.exe'),
    (Fake 900 10 'powershell.exe' '' '-File "D:\tools\codex\codex-floating-button.ps1"'),
    (Fake 901 10 'powershell.exe' '' '-File "D:\tools\codex\ai-process-cleanup-worker.ps1"')
)
if($Legacy){
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'codex-floating-button.ps1'),[ref]$null,[ref]$null)
    $function=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AiRelatedProcessIds'},$true)
    . ([scriptblock]::Create($function.Extent.Text))
    $selected=@(Get-AiRelatedProcessIds -Processes $fixture)
}else{
    . (Join-Path $root 'ai-process-cleanup.ps1')
    $selected=@(Select-AiCleanupProcesses -Processes $fixture -ProtectedProcessIds @(900,901) | ForEach-Object ProcessId)
}
Assert-True ($selected -contains 20) 'Find an AI-owned RuntimeBroker by package identity'
Assert-True ($selected -contains 30 -and $selected -contains 31) 'Find helpers under the migrated D drive runtime'
Assert-True ($selected -contains 40 -and $selected -contains 80) 'Find Claude Java and roots with unreadable image paths'
Assert-True (-not ($selected | Where-Object {$_ -in @(21,41,50,51,60,61,900,901)})) 'Preserve Windows brokers, unrelated Java, toolbar, and T Notes'
if($Legacy){exit 0}
$parent=Fake 100 1 'ChatGPT.exe' '' '' '' 0
$parent | Add-Member NoteProperty StoppedAt (([datetime]'2026-01-01T00:00:00Z').AddSeconds(100))
$orphan=Fake 101 100 'java.exe' '' '' '' 50
Assert-True (@(Select-AiCleanupProcesses -Processes @($orphan) -KnownTargets @($parent)).Count -eq 1) 'Remember ownership when a parent exits before rescan'
$reused=@((Fake 100 1 'notepad.exe' '' '' '' 200),(Fake 102 100 'java.exe' '' '' '' 201))
Assert-True (@(Select-AiCleanupProcesses -Processes $reused -KnownTargets @($parent)).Count -eq 0) 'Reject a reused parent PID'
$sameId=Fake 100 1 'notepad.exe' '' '' '' 200
Assert-True (@(Select-AiCleanupProcesses -Processes @($sameId) -KnownTargets @($parent)).Count -eq 0) 'Do not treat a reused target PID as the old process'
$state=@{Index=0;Stopped=(New-Object 'System.Collections.Generic.List[int]')}
$snapshots=@(@((Fake 110 1 'ChatGPT.exe')), @((Fake 111 1 'claude.exe')), @(), @(), @(), @())
$reader={ $index=[Math]::Min($state.Index,$snapshots.Count-1);$state.Index++;@($snapshots[$index]) }.GetNewClosure()
$stopper={param($process)[void]$state.Stopped.Add([int]$process.ProcessId)}.GetNewClosure()
$result=Invoke-AiCleanup -ReadSnapshot $reader -Terminate $stopper -Pause {} -MaxPasses 8
Assert-True ($result.Status -eq 'Complete' -and $state.Stopped.Contains(110) -and $state.Stopped.Contains(111)) 'Rescan new processes instead of checking only old PIDs'
$again={@((Fake 120 1 'claude.exe'))}
$failed=Invoke-AiCleanup -ReadSnapshot $again -Terminate {throw 'Denied'} -Pause {} -MaxPasses 3
Assert-True ($failed.Status -eq 'Partial' -and $failed.Remaining.Count -eq 1) 'Report denied or respawned processes instead of false success'
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$start.Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
try{
    $birth=$child.StartTime.ToUniversalTime()
    Stop-AiProcessIdentity ([pscustomobject]@{ProcessId=$child.Id;CreationDate=$birth.AddSeconds(5)})
    Assert-True (-not $child.HasExited) 'Refuse termination when the process start time does not match'
    Stop-AiProcessIdentity ([pscustomobject]@{ProcessId=$child.Id;CreationDate=$birth})
    Assert-True ($child.WaitForExit(3000)) 'Terminate only the verified dedicated test child'
}finally{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
Write-Output 'All AI cleanup tests passed. Running user applications were not terminated.'
