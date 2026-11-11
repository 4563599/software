param(
 [Parameter(Mandatory=$true)][string]$ServerUrl,
 [Parameter(Mandatory=$true)][string]$ServerCertificate,
 [switch]$Enrollment,
 [switch]$ReplaceServer
)
$ErrorActionPreference='Stop'
$url=[uri]$ServerUrl
if($url.Scheme -ne 'https' -or $url.UserInfo -or $url.AbsolutePath -ne '/' -or $url.Query -or $url.Fragment){throw 'Use an HTTPS server origin without credentials or a path.'}
if(-not (Test-Path -LiteralPath $ServerCertificate -PathType Leaf)){throw 'The trusted server certificate is missing.'}
$certificateText=Get-Content -Raw -LiteralPath $ServerCertificate
if($certificateText -notmatch '-----BEGIN CERTIFICATE-----' -or $certificateText -match 'PRIVATE KEY'){throw 'Use only the public PEM certificate, never a private key.'}
$data=Join-Path $env:LOCALAPPDATA 'TNotes'
$config=Join-Path $data 'server.json'
if((Test-Path -LiteralPath $config) -and -not $ReplaceServer){throw 'A server is already configured. Use -ReplaceServer only after verifying the new server.'}
New-Item -ItemType Directory -Path $data -Force | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
foreach($identity in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))){
 $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl',[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))
}
Set-Acl -LiteralPath $data -AclObject $acl
if(Test-Path -LiteralPath $config){Copy-Item -LiteralPath $config -Destination ($config+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')}
$certificateTarget=Join-Path $data 'server-ca.pem'
if([IO.Path]::GetFullPath($ServerCertificate) -ne [IO.Path]::GetFullPath($certificateTarget)){Copy-Item -LiteralPath $ServerCertificate -Destination $certificateTarget -Force}
$json=@{url=$url.AbsoluteUri}|ConvertTo-Json
[IO.File]::WriteAllText($config,$json,(New-Object Text.UTF8Encoding($false)))
if($Enrollment){
 $secret=Read-Host 'First-owner enrollment token (hidden input)' -AsSecureString
 $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
 try{
  $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  if($value -notmatch '^[A-Za-z0-9_-]{32,128}$'){throw 'Invalid enrollment token.'}
  [IO.File]::WriteAllText((Join-Path $data 'enrollment.once'),$value,(New-Object Text.UTF8Encoding($false)))
 }finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$value=$null;$secret.Dispose()}
}
[pscustomobject]@{Configured=$true;UserData=$data;EnrollmentInstalled=$Enrollment.IsPresent;RestartBackendRequired=$true}|ConvertTo-Json
