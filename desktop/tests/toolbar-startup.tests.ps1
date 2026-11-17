$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens=$null;$errors=$null
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-floating-button.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
$main=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$form=[pscustomobject]@{}
# A sign-in display transition must not make timer startup depend on Shown being delivered.
$form|Add-Member -MemberType ScriptMethod -Name Add_Shown -Value {param($handler)}
$form|Add-Member -MemberType ScriptMethod -Name Show -Value {}
$keepTopMost={}
$topMostTimer=New-Object System.Windows.Forms.Timer
try{
 foreach($statement in $main.Body.Statements){
  $text=$statement.Extent.Text
  if($text -match '^\[System\.Windows\.Forms\.Application\]::Run\('){break}
  if($text -match '^\$(?:form\.(?:Add_Shown|Show)|topMostTimer\.Start)\('){
   & ([scriptblock]::Create($text))
  }
 }
 if(-not $topMostTimer.Enabled){throw 'The toolbar recovery timer only starts when Shown fires; a running process can remain invisible without recovery.'}
 Write-Output 'PASS: Toolbar recovery timer starts even when the Shown callback is not delivered.'
}finally{
 $topMostTimer.Stop()
 $topMostTimer.Dispose()
}
