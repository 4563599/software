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
Add-Type -AssemblyName System.Drawing
$hits=@(@(8,8,0),@(59,59,0),@(60,30,-1),@(68,30,1),@(128,30,2),@(179,30,2),@(180,30,-1),@(30,7,-1),@(30,60,-1)) | ForEach-Object {(Get-FloatingButtonIndex -X $_[0] -Y $_[1] -Count 3 -ButtonSize 52 -Gap 8 -Margin 8) -eq $_[2]}
if($hits -contains $false){throw 'Toolbar button hit-testing regressed.'}
$screens=@([pscustomobject]@{Left=0;Top=0;Right=1920;Bottom=1040},[pscustomobject]@{Left=1920;Top=0;Right=3456;Bottom=824})
$barSize=[pscustomobject]@{Width=188;Height=68};$fallback=[System.Drawing.Point]::new(1720,960)
$placements=@(@([pscustomobject]@{X=2000;Y=100},2000,100),@([pscustomobject]@{X=1800;Y=1000},1732,972),@([pscustomobject]@{X=3400;Y=800},1720,960),@([pscustomobject]@{X='left';Y=5},1720,960),@([pscustomobject]@{Y=5},1720,960),@($null,1720,960)) | ForEach-Object {$point=Get-FloatingBarStartLocation -SavedLocation $_[0] -BarSize $barSize -WorkingAreas $screens -DefaultLocation $fallback;$point.X -eq $_[1] -and $point.Y -eq $_[2]}
if($placements -contains $false){throw 'Toolbar start position regressed.'}
. (Join-Path $root 't-notes\window.ps1')
$notesProfile='C:\Users\test\AppData\Local\TNotes\browser-v3'
$browserFixture=@([pscustomobject]@{ProcessId=60;CommandLine='"C:\Edge\msedge.exe" --app=http://127.0.0.1:47321/?v=4 --new-window --user-data-dir="C:\Users\test\AppData\Local\TNotes\browser-v3" --window-size=470,810'},[pscustomobject]@{ProcessId=61;CommandLine='"C:\Edge\msedge.exe" --type=renderer --user-data-dir="C:\Users\test\AppData\Local\TNotes\browser-v3" --lang=zh-CN'},[pscustomobject]@{ProcessId=62;CommandLine='"C:\Edge\msedge.exe" --user-data-dir="C:\Users\test\AppData\Local\TNotes\browser-v3-old"'},[pscustomobject]@{ProcessId=63;CommandLine='"C:\Chrome\chrome.exe" --profile-directory=Default'},[pscustomobject]@{ProcessId=64;CommandLine=$null},[pscustomobject]@{ProcessId=65;CommandLine='"C:\Chrome\chrome.exe" --user-data-dir=c:\users\test\appdata\local\tnotes\browser-v3'})
if((Select-TNotesBrowserProcessIds -Processes $browserFixture -ProfileDirectory $notesProfile) -join ',' -ne '60,65'){throw 'T Notes window process selection regressed.'}
$desk=[pscustomobject]@{Left=0;Top=0;Right=1920;Bottom=1040}
$anchored=@(@(@(1848,968,52,52),810,'1450,156'),@(@(1000,968,52,52),810,'791,156'),@(@(1000,20,52,52),810,'791,74'),@(@(1000,500,52,52),1000,'791,0')) | ForEach-Object {((Get-TNotesAnchoredLocation -Anchor $_[0] -Width 470 -Height $_[1] -WorkingArea $desk) -join ',') -eq $_[2]}
if($anchored -contains $false){throw 'Notes window placement above the T button regressed.'}
$fitCases=@(
 @(@(1848,968,52,52),470,810,$desk,'1450,156,470,810'),
 @(@(3384,752,52,52),470,810,$screens[1],'2986,0,470,750'),
 @(@(-1528,752,52,52),470,810,([pscustomobject]@{Left=-1536;Top=0;Right=0;Bottom=824}),'-1536,0,470,750'),
 @(@(1000,20,52,52),470,810,$desk,'791,74,470,810'),
 @(@(250,410,52,52),470,810,([pscustomobject]@{Left=0;Top=0;Right=320;Bottom=480}),'0,0,320,408')
)
foreach($case in $fitCases){
 if(((Get-TNotesAnchoredBounds -Anchor $case[0] -Width $case[1] -Height $case[2] -WorkingArea $case[3]) -join ',') -ne $case[4]){throw 'Notes bounds do not fit above T on its monitor.'}
}
if((@(ConvertFrom-TNotesAnchor -Anchor 'p-1500,900,52,52') -join ',') -ne '-1500,900,52,52' -or @(ConvertFrom-TNotesAnchor -Anchor 'not a rectangle').Count -ne 0){throw 'Notes window anchor parsing regressed.'}
& (Join-Path $PSScriptRoot 'ai-process-cleanup.tests.ps1')
& (Join-Path $PSScriptRoot 'configure-notes.tests.ps1')
& (Join-Path $PSScriptRoot 'notes-window-state.tests.ps1')
& (Join-Path $root 'Install.ps1') -DryRun | Out-Null
Write-Output 'PASS: Source parsing, C / AS selection, protected notes, and installation dry-run.'
