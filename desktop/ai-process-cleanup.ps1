Set-StrictMode -Version Latest

function Get-AiField($Process,[string]$Name) {
    $property=$Process.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $null
}

function Get-AiBirth($Process) {
    $value=Get-AiField $Process 'CreationDate'
    if($null -eq $value){return [datetime]::MinValue}
    return ([datetime]$value).ToUniversalTime()
}

function Get-AiIdentityKey($Process) {
    return ([string]$Process.ProcessId)+':'+(Get-AiBirth $Process).Ticks
}

function Initialize-AiNativeApi {
    if('AiProcessWin32' -as [type]){return}
    $name=New-Object Reflection.AssemblyName('AiProcessWin32')
    if($PSVersionTable.PSEdition -eq 'Core'){$assembly=[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name,[Reflection.Emit.AssemblyBuilderAccess]::Run)}
    else{$assembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly($name,[Reflection.Emit.AssemblyBuilderAccess]::Run)}
    $module=$assembly.DefineDynamicModule('AiProcessWin32')
    $type=$module.DefineType('AiProcessWin32',[Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $methods=@(
        @{Name='OpenProcess';Return=[IntPtr];Parameters=@([uint32],[bool],[int])},
        @{Name='CloseHandle';Return=[bool];Parameters=@([IntPtr])},
        @{Name='QueryFullProcessImageName';Return=[bool];Parameters=@([IntPtr],[uint32],[Text.StringBuilder],[uint32].MakeByRefType())},
        @{Name='GetApplicationUserModelId';Return=[int];Parameters=@([IntPtr],[uint32].MakeByRefType(),[Text.StringBuilder])},
        @{Name='GetPackageFullName';Return=[int];Parameters=@([IntPtr],[uint32].MakeByRefType(),[Text.StringBuilder])}
    )
    foreach($entry in $methods){
        $method=$type.DefinePInvokeMethod($entry.Name,'kernel32.dll',[Reflection.MethodAttributes]'Public, Static, PinvokeImpl',[Reflection.CallingConventions]::Standard,$entry.Return,[type[]]$entry.Parameters,[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
        $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
    }
    [void]$type.CreateType()
}

function Read-AiNativeIdentity([int]$ProcessId) {
    $identity=[pscustomobject]@{ImagePath='';AppUserModelId='';PackageFullName='';QueryError=0}
    $handle=[AiProcessWin32]::OpenProcess(0x1000,$false,$ProcessId)
    if($handle -eq [IntPtr]::Zero){$identity.QueryError=-1;return $identity}
    try{
        $text=New-Object Text.StringBuilder(32768);[uint32]$size=$text.Capacity
        if([AiProcessWin32]::QueryFullProcessImageName($handle,0,$text,[ref]$size)){$identity.ImagePath=$text.ToString()}
        $text=New-Object Text.StringBuilder(1024);[uint32]$size=$text.Capacity
        if([AiProcessWin32]::GetApplicationUserModelId($handle,[ref]$size,$text) -eq 0){$identity.AppUserModelId=$text.ToString()}
        $text=New-Object Text.StringBuilder(1024);[uint32]$size=$text.Capacity
        if([AiProcessWin32]::GetPackageFullName($handle,[ref]$size,$text) -eq 0){$identity.PackageFullName=$text.ToString()}
        return $identity
    }finally{[void][AiProcessWin32]::CloseHandle($handle)}
}

function Get-AiProcessSnapshot {
    $ErrorActionPreference='Stop'
    Initialize-AiNativeApi
    $rows=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach($row in $rows){
        $native=Read-AiNativeIdentity -ProcessId ([int]$row.ProcessId)
        $path=[string]$row.ExecutablePath
        if(-not $path){$path=$native.ImagePath}
        [pscustomobject]@{
            ProcessId=[int]$row.ProcessId;ParentProcessId=[int]$row.ParentProcessId
            Name=[string]$row.Name;CreationDate=$row.CreationDate
            ExecutablePath=$path;CommandLine=[string]$row.CommandLine
            AppUserModelId=$native.AppUserModelId;PackageFullName=$native.PackageFullName
            IdentityQueryError=$native.QueryError
        }
    }
}

function Select-AiCleanupProcesses {
    param(
        [AllowEmptyCollection()][object[]]$Processes=@(),
        [AllowEmptyCollection()][object[]]$KnownTargets=@(),
        [AllowEmptyCollection()][int[]]$ProtectedProcessIds=@()
    )
    $byId=@{};$protected=@{};$preservedTrees=@{};$selected=@{};$reason=@{}
    foreach($process in $Processes){$byId[[int]$process.ProcessId]=$process}
    foreach($id in $ProtectedProcessIds){$protected[[int]$id]=$true;$preservedTrees[[int]$id]=$true}
    foreach($process in $Processes){
        $id=[int]$process.ProcessId
        $name=[string]$process.Name;$path=[string](Get-AiField $process 'ExecutablePath');$command=[string](Get-AiField $process 'CommandLine')
        $notes=$path -match '(?i)\\t-notes\\(?:runtime|client)\\' -or $command -match '(?i)\\t-notes\\(?:client\\desktop\.cjs|Launch\.ps1|backend\.vbs)'
        $notesBrowser=$name -match '^(?i:chrome|msedge)\.exe$' -and $command -match '(?i)--user-data-dir[= ]"?[^\r\n"]*\\TNotes\\browser'
        $toolbar=$name -match '^(?i:powershell|pwsh|wscript)\.exe$' -and $command -match '(?i)\\codex-floating-(?:button|watchdog)\.(?:ps1|vbs)(?:"|\s|$)'
        if($id -le 4){$protected[$id]=$true}
        if($notes -or $notesBrowser -or $toolbar){$protected[$id]=$true;$preservedTrees[$id]=$true}
    }
    do{
        $changed=$false
        foreach($process in $Processes){
            $id=[int]$process.ProcessId;$parent=[int]$process.ParentProcessId
            if(-not $protected.ContainsKey($id) -and $preservedTrees.ContainsKey($parent)){
                if(-not $byId.ContainsKey($parent) -or (Get-AiBirth $process) -ge (Get-AiBirth $byId[$parent])){$protected[$id]=$true;$preservedTrees[$id]=$true;$changed=$true}
            }
        }
    }while($changed)

    $history=@{}
    foreach($known in $KnownTargets){
        $id=[int]$known.ProcessId
        if(-not $history.ContainsKey($id) -or (Get-AiBirth $known) -gt (Get-AiBirth $history[$id])){$history[$id]=$known}
    }
    $trusted='(?i)\\(?:WindowsApps\\(?:OpenAI\.(?:Codex|ChatGPT)|Claude|Anthropic\.Claude)_[^\\]+|AppData\\Local\\OpenAI\\(?:Codex|ChatGPT)|AppData\\Roaming\\(?:Codex|Claude)|AppData\\Local\\(?:Claude-Data|Claude)|\.cache\\codex-runtimes|\.codex\\plugins\\cache\\openai-[^\\]+|codex-data\\home\\plugins\\cache\\openai-[^\\]+|\.claude)\\'
    $identity='(?i)^(?:OpenAI\.(?:Codex|ChatGPT)[_!.-]|Claude[_!.-]|Anthropic\.Claude[_!.-])'
    foreach($process in $Processes){
        $id=[int]$process.ProcessId
        if($protected.ContainsKey($id)){continue}
        $name=[string]$process.Name;$path=[string](Get-AiField $process 'ExecutablePath');$command=[string](Get-AiField $process 'CommandLine')
        $package=[string](Get-AiField $process 'PackageFullName');$appId=[string](Get-AiField $process 'AppUserModelId')
        $root=$name -match '^(?i:ChatGPT|codex(?:-[A-Za-z0-9_-]+)?|claude(?:-[A-Za-z0-9_-]+)?|cowork-svc)\.exe$'
        $helper=$name -match '^(?i:node|node_repl|pwsh|powershell|cmd|conhost|OpenConsole|extension-host|git|ssh|bash|sh|wsl|python|python3|java|javaw|RuntimeBroker|msedgewebview2)\.exe$'
        if($root){$selected[$id]=$true;$reason[$id]='Application'}
        elseif($package -match $identity -or $appId -match $identity){$selected[$id]=$true;$reason[$id]='ApplicationIdentity'}
        elseif($path -match $trusted -or ($helper -and ($command -match $trusted -or $command -match 'CLAUDE_DESKTOP_'))){$selected[$id]=$true;$reason[$id]='OwnedRuntime'}
        elseif($history.ContainsKey($id) -and (Get-AiBirth $process) -ne [datetime]::MinValue -and (Get-AiIdentityKey $process) -eq (Get-AiIdentityKey $history[$id])){$selected[$id]=$true;$reason[$id]='PreviouslyObserved'}
    }
    do{
        $changed=$false
        foreach($process in $Processes){
            $id=[int]$process.ProcessId;$parent=[int]$process.ParentProcessId
            if($selected.ContainsKey($id) -or $protected.ContainsKey($id)){continue}
            if($selected.ContainsKey($parent) -and $byId.ContainsKey($parent) -and (Get-AiBirth $process) -ge (Get-AiBirth $byId[$parent])){
                $selected[$id]=$true;$reason[$id]='Descendant';$changed=$true
            }elseif(-not $byId.ContainsKey($parent) -and $history.ContainsKey($parent)){
                $known=$history[$parent];$stopped=Get-AiField $known 'StoppedAt';$birth=Get-AiBirth $process
                if($null -ne $stopped -and $birth -ne [datetime]::MinValue -and $birth -ge (Get-AiBirth $known) -and $birth -le ([datetime]$stopped).ToUniversalTime()){
                    $selected[$id]=$true;$reason[$id]='ObservedParent';$changed=$true
                }
            }
        }
    }while($changed)
    foreach($id in @($selected.Keys | Sort-Object)){
        $process=$byId[$id]
        [pscustomobject]@{ProcessId=$id;ParentProcessId=[int]$process.ParentProcessId;Name=[string]$process.Name;CreationDate=(Get-AiBirth $process);Reason=$reason[$id];StoppedAt=$null}
    }
}

function Stop-AiProcessIdentity($Process) {
    $live=Get-Process -Id $Process.ProcessId -ErrorAction SilentlyContinue
    if($null -eq $live){return}
    try{
        # Hold the process handle and verify its start time; a reused PID must never be killed.
        $null=$live.Handle
        $expected=Get-AiBirth $Process
        if($expected -eq [datetime]::MinValue){throw 'Process identity could not be verified'}
        if([Math]::Abs(($live.StartTime.ToUniversalTime()-$expected).TotalMilliseconds) -gt 1){return}
        $live.Kill()
        [void]$live.WaitForExit(1000)
    }finally{$live.Dispose()}
}

function Invoke-AiCleanup {
    param(
        [scriptblock]$ReadSnapshot={Get-AiProcessSnapshot},
        [scriptblock]$Terminate={param($process)Stop-AiProcessIdentity $process},
        [scriptblock]$Pause={Start-Sleep -Milliseconds 400},
        [AllowEmptyCollection()][int[]]$ProtectedProcessIds=@(),
        [AllowEmptyCollection()][object[]]$KnownTargets=@(),
        [ValidateRange(1,50)][int]$MaxPasses=12
    )
    $tracked=@{};$failures=@{};$quiet=0
    foreach($target in $KnownTargets){$tracked[(Get-AiIdentityKey $target)]=$target}
    for($pass=0;$pass -lt $MaxPasses;$pass++){
        $snapshot=@(& $ReadSnapshot)
        $targets=@(Select-AiCleanupProcesses -Processes $snapshot -KnownTargets @($tracked.Values) -ProtectedProcessIds $ProtectedProcessIds)
        if($targets.Count -eq 0){$quiet++;if($quiet -ge 3){break}}
        else{
            $quiet=0
            foreach($target in $targets){
                $key=Get-AiIdentityKey $target
                if(-not $tracked.ContainsKey($key)){$tracked[$key]=$target}
            }
            foreach($target in $targets){
                $key=Get-AiIdentityKey $target
                try{& $Terminate $target | Out-Null}
                catch{$failures[$key]=[pscustomobject]@{ProcessId=$target.ProcessId;Name=$target.Name;Error='TerminationFailed'}}
                $tracked[$key].StoppedAt=[datetime]::UtcNow
            }
        }
        & $Pause
    }
    $final=@(& $ReadSnapshot)
    $remaining=@(Select-AiCleanupProcesses -Processes $final -KnownTargets @($tracked.Values) -ProtectedProcessIds $ProtectedProcessIds)
    $alive=@{};foreach($process in $final){$alive[(Get-AiIdentityKey $process)]=$true}
    $closed=@($tracked.Keys | Where-Object {-not $alive.ContainsKey($_)}).Count
    [pscustomobject]@{
        Status=$(if($remaining.Count -eq 0){'Complete'}else{'Partial'})
        ClosedCount=$closed;ObservedCount=$tracked.Count;Remaining=@($remaining | Select-Object ProcessId,Name,Reason)
        Failures=@($failures.Values);Passes=[Math]::Min($pass+1,$MaxPasses)
    }
}
