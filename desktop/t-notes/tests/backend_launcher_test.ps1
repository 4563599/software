param([int]$Port,[string]$DataDirectory,[string]$ConfigPath)
$ErrorActionPreference='Stop'
$source=Split-Path -Parent $PSScriptRoot
$env:TNOTES_PORT=[string]$Port;$env:TNOTES_DATA=$DataDirectory;$env:TNOTES_CONFIG=$ConfigPath
$children=New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
try{
    $first=& (Join-Path $source 'Launch.ps1') -BackendOnly
    if(-not $first.Ready -or $first.StartedProcessId -le 0){throw 'Headless startup did not create a backend.'}
    $process=Get-Process -Id $first.StartedProcessId -ErrorAction Stop
    $null=$process.Handle;$children.Add($process)
    $second=& (Join-Path $source 'Launch.ps1') -BackendOnly
    if(-not $second.Ready -or $second.StartedProcessId -ne 0){throw 'Headless startup duplicated an existing backend.'}
    $process.Kill();[void]$process.WaitForExit(3000)
    $recovered=& (Join-Path $source 'Launch.ps1') -BackendOnly
    if(-not $recovered.Ready -or $recovered.StartedProcessId -le 0 -or $recovered.StartedProcessId -eq $first.StartedProcessId){throw 'Headless backend recovery failed.'}
    $process=Get-Process -Id $recovered.StartedProcessId -ErrorAction Stop
    $null=$process.Handle;$children.Add($process)
    Write-Output '{"headless_start":"passed","no_duplicate_backend":"passed","headless_recovery":"passed"}'
}finally{
    foreach($process in $children){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(3000)};$process.Dispose()}
}
