param([switch]$DryRun,[switch]$NoStart,[switch]$ReplaceExisting)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$PSScriptRoot
$required=@('Start-Desktop.vbs','codex-floating-button.ps1','codex-floating-button-core.ps1','codex-network-check.ps1','ai-process-cleanup.ps1','ai-process-cleanup-worker.ps1','codex-floating-watchdog.ps1','codex-floating-watchdog.vbs','icons\codex-c.ico','icons\codex-c-1024.png','t-notes\Launch.ps1','t-notes\backend.vbs','t-notes\client\desktop.cjs','t-notes\client\web\index.html')
foreach($file in $required){if(-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)){throw "Required source file is missing: $file"}}
$node=Join-Path $root 't-notes\runtime\node.exe'
if(-not (Test-Path -LiteralPath $node)){$command=Get-Command node.exe -ErrorAction SilentlyContinue;if(-not $command){throw 'Install Node.js 22 or newer first.'};$node=$command.Source}
$version=[string](& $node --version)
if($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22){throw 'Node.js 22 or newer is required.'}
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$tasks=@('TNotesLocalBackend','TNotesFloatingToolbarWatchdog')
foreach($name in $tasks){
 $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($existing){
  $owned=$existing.Actions.Count -eq 1 -and $existing.Actions[0].Execute -like '*\wscript.exe' -and $existing.Actions[0].Arguments -match '(?i)(?:codex-floating-watchdog|backend)\.vbs"?\s*$'
  if(-not $owned){throw "An unrelated task uses this name: $name"}
  if($existing.Actions[0].Arguments -notlike ('*'+$root+'*') -and -not $ReplaceExisting -and -not $DryRun){throw 'Another installation is active. Save drafts, then use -ReplaceExisting to migrate its tasks.'}
 }
}
$plan=[pscustomobject]@{InstallDirectory=$root;Node=$node;NodeVersion=$version;UserData=(Join-Path $env:LOCALAPPDATA 'TNotes');Tasks=$tasks;RuntimeMigrationRequiresReplaceExisting=$true}
if($DryRun){$plan|ConvertTo-Json;return}
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$backendAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+(Join-Path $root 't-notes\backend.vbs')+'"') -WorkingDirectory (Join-Path $root 't-notes')
$backendSettings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $tasks[0] -Action $backendAction -Principal $principal -Settings $backendSettings -Description 'Encrypted notes backend; independent of AI application processes.' -Force | Out-Null
$guardAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+(Join-Path $root 'codex-floating-watchdog.vbs')+'"') -WorkingDirectory $root
$triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
$guardSettings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 30) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $tasks[1] -Action $guardAction -Trigger $triggers -Principal $principal -Settings $guardSettings -Description 'Check the C / AS / T toolbar and notes backend every minute; no console windows.' -Force | Out-Null
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Desktop Tools.lnk'))
$shortcut.TargetPath=$wscript;$shortcut.Arguments='//B //Nologo "'+(Join-Path $root 'Start-Desktop.vbs')+'"'
$shortcut.WorkingDirectory=$root;$shortcut.IconLocation=(Join-Path $root 'icons\codex-c.ico')+',0';$shortcut.Save()
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $run -Force | Out-Null
New-ItemProperty -LiteralPath $run -Name 'CodexFloatingButton' -PropertyType String -Value ('"'+$wscript+'" //B //Nologo "'+(Join-Path $root 'Start-Desktop.vbs')+'"') -Force | Out-Null
if(-not $NoStart){
 if($ReplaceExisting){
  $old=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -match '(?i)-File\s+"[^"\r\n]+\\codex-floating-button\.ps1"\s*$'})
  foreach($process in $old){Stop-Process -Id $process.ProcessId -ErrorAction Stop}
  Stop-ScheduledTask -TaskName $tasks[0] -ErrorAction SilentlyContinue
 }
 Start-ScheduledTask -TaskName $tasks[1]
}
$plan|ConvertTo-Json
