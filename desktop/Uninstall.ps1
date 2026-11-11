param([switch]$ConfirmUninstall)
$ErrorActionPreference='Stop'
if(-not $ConfirmUninstall){Write-Output 'Use -ConfirmUninstall to remove this installation startup entries. Notes and encrypted data are never deleted.';return}
foreach($name in @('TNotesFloatingToolbarWatchdog','TNotesLocalBackend')){
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($task -and @($task.Actions|Where-Object {$_.Arguments -like ('*'+$PSScriptRoot+'*')}).Count -gt 0){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false}
}
$pattern='(?i)-File\s+"?'+[regex]::Escape((Join-Path $PSScriptRoot 'codex-floating-button.ps1'))+'"?\s*$'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -match $pattern} | ForEach-Object {Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$value=Get-ItemProperty -LiteralPath $run -Name 'CodexFloatingButton' -ErrorAction SilentlyContinue
if($value -and $value.CodexFloatingButton -like ('*'+$PSScriptRoot+'*')){Remove-ItemProperty -LiteralPath $run -Name 'CodexFloatingButton'}
$shortcut=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Desktop Tools.lnk'
if(Test-Path -LiteralPath $shortcut){$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcut);if($link.Arguments -like ('*'+$PSScriptRoot+'*')){Remove-Item -LiteralPath $shortcut}}
Write-Output 'Removed only startup entries owned by this folder. Encrypted notes and connection settings were kept.'
