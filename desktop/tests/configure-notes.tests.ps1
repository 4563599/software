$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$temporaryRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
$fixture=Join-Path $temporaryRoot ('tnotes-configure-'+[guid]::NewGuid().ToString('N'))
$originalLocalAppData=$env:LOCALAPPDATA
try {
 New-Item -ItemType Directory -Path $fixture | Out-Null
 $env:LOCALAPPDATA=$fixture
 $certificate=Join-Path $fixture 'test-public.pem'
 [IO.File]::WriteAllText($certificate,"-----BEGIN CERTIFICATE-----`nPUBLIC TEST FIXTURE`n-----END CERTIFICATE-----`n")
 $result=(& (Join-Path $root 'Configure-Notes.ps1') -ServerUrl 'https://notes.example.com:18443/' -ServerCertificate $certificate) | ConvertFrom-Json
 if(-not $result.Configured){throw 'Configuration did not complete.'}
 $data=Join-Path $fixture 'TNotes'
 $configuration=Get-Content -Raw -LiteralPath (Join-Path $data 'server.json') | ConvertFrom-Json
 if($configuration.url -ne 'https://notes.example.com:18443/'){throw 'Server configuration changed.'}
 if((Get-FileHash -LiteralPath $certificate).Hash -ne (Get-FileHash -LiteralPath (Join-Path $data 'server-ca.pem')).Hash){throw 'Public certificate was not preserved.'}
 $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')
 $originalOwner=(Get-Acl -LiteralPath $data).Owner
 $repeated=(& (Join-Path $root 'Configure-Notes.ps1') -ServerUrl 'https://notes.example.com:18443/' -ServerCertificate $certificate -ReplaceServer) | ConvertFrom-Json
 if(-not $repeated.Configured -or (Get-Acl -LiteralPath $data).Owner -ne $originalOwner){throw 'Repeated configuration changed directory ownership.'}
 foreach($path in @($data,(Join-Path $data 'server.json'),(Join-Path $data 'server-ca.pem'))){
  $acl=Get-Acl -LiteralPath $path
  if($path -eq $data -and -not $acl.AreAccessRulesProtected){throw 'Private data directory still inherits permissions.'}
  if($acl.Access.Count -ne 2){throw 'Unexpected private data permissions.'}
  foreach($entry in $acl.Access){
   if($entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed -or $entry.AccessControlType -ne 'Allow' -or $entry.FileSystemRights -ne 'FullControl'){throw 'Private data permissions are not restricted to this user and SYSTEM.'}
  }
 }
 Write-Output 'PASS: Notes configuration and reconfiguration preserve directory ownership and private permissions.'
} finally {
 $env:LOCALAPPDATA=$originalLocalAppData
 $resolved=[IO.Path]::GetFullPath($fixture)
 if($resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'tnotes-configure-*' -and (Test-Path -LiteralPath $resolved)){
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
