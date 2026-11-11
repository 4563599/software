$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | Where-Object {$_.FullName -notmatch '\\(?:node_modules|test-output)\\'} | ForEach-Object {
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('PowerShell syntax errors: '+$_.FullName)}
}
. (Join-Path $root 'codex-floating-button-core.ps1')
$fixture=@([pscustomobject]@{ProcessId=10;ParentProcessId=1;Name='studio64.exe';ExecutablePath='X:\Android\studio64.exe';CommandLine='studio64.exe'},[pscustomobject]@{ProcessId=11;ParentProcessId=10;Name='java.exe';ExecutablePath='X:\Java\java.exe';CommandLine='GradleDaemon'},[pscustomobject]@{ProcessId=12;ParentProcessId=1;Name='java.exe';ExecutablePath='X:\Java\java.exe';CommandLine='example.Server'})
if((Select-AndroidStudioRelatedProcessIds -Processes $fixture)-join ',' -ne '10,11'){throw 'Android process selection regressed.'}
if((Get-AndroidStudioTaskKillArguments -ProcessIds @(10,11,10)) -ne '/F /T /PID 10 /PID 11'){throw 'Android elevated arguments regressed.'}
& (Join-Path $PSScriptRoot 'ai-process-cleanup.tests.ps1')
& (Join-Path $PSScriptRoot 'configure-notes.tests.ps1')
& (Join-Path $root 'Install.ps1') -DryRun | Out-Null
Write-Output 'PASS: Source parsing, C / AS selection, protected notes, and installation dry-run.'
