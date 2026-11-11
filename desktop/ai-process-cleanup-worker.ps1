param(
    [ValidateSet('Audit','Clean')][string]$Mode='Audit',
    [string]$ResultPath='',
    [int]$ProtectedProcessId=0
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ai-process-cleanup.ps1')
function Publish-Result($value){
    $json=$value | ConvertTo-Json -Depth 6
    if($ResultPath){
        $full=[IO.Path]::GetFullPath($ResultPath)
        if([IO.Path]::GetDirectoryName($full) -ne $PSScriptRoot -or [IO.Path]::GetFileName($full) -notmatch '^ai-cleanup-result-[a-f0-9]{32}\.json$'){throw 'Invalid cleanup result path'}
        [IO.File]::WriteAllText($full,$json,(New-Object Text.UTF8Encoding($false)))
    }else{Write-Output $json}
}
try{
    if($ResultPath){
        $full=[IO.Path]::GetFullPath($ResultPath)
        if([IO.Path]::GetDirectoryName($full) -ne $PSScriptRoot -or [IO.Path]::GetFileName($full) -notmatch '^ai-cleanup-result-[a-f0-9]{32}\.json$'){throw 'Invalid cleanup result path'}
        if(Test-Path -LiteralPath $full){throw 'Cleanup result already exists'}
        [IO.File]::WriteAllText($full,'{"Status":"Pending"}',(New-Object Text.UTF8Encoding($false)))
    }
    $protected=@($PID)
    if($ProtectedProcessId -gt 0){$protected+=$ProtectedProcessId}
    $snapshot=@(Get-AiProcessSnapshot)
    $initial=@(Select-AiCleanupProcesses -Processes $snapshot -ProtectedProcessIds $protected)
    if($Mode -eq 'Audit'){
        Publish-Result ([pscustomobject]@{Status='Audit';ReadOnly=$true;TargetCount=$initial.Count;Summary=@($initial | Group-Object Name | Select-Object Name,Count)})
        exit 0
    }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        Publish-Result ([pscustomobject]@{Status='PermissionRequired';ClosedCount=0;Remaining=@();Error='AdministratorRequired'})
        exit 2
    }
    $serviceFailures=@()
    $coworkIds=@($initial | Where-Object { $_.Name -ieq 'cowork-svc.exe' } | ForEach-Object ProcessId)
    if($coworkIds.Count -gt 0){
        foreach($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { [int]$_.ProcessId -in $coworkIds })){
            try{Stop-Service -Name $service.Name -ErrorAction Stop}
            catch{$serviceFailures += [pscustomobject]@{Name=$service.Name;Error='ServiceStopFailed'}}
        }
    }
    foreach($target in $initial){$target.StoppedAt=[datetime]::UtcNow}
    $result=Invoke-AiCleanup -ProtectedProcessIds $protected -KnownTargets $initial
    $result | Add-Member NoteProperty ServiceFailures $serviceFailures
    if($serviceFailures.Count -gt 0){$result.Status='Partial'}
    Publish-Result $result
    if($result.Status -ne 'Complete'){exit 2}
}catch{
    try{Publish-Result ([pscustomobject]@{Status='Error';ClosedCount=0;Remaining=@();Error='CleanupCheckFailed'})}catch{}
    exit 1
}
