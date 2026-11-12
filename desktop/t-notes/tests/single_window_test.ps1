param([int]$Port,[string]$DataDirectory,[switch]$PlacementOnly)
# Opens real browser windows against a throwaway data directory and port; never touches the real vault.
$ErrorActionPreference='Stop'
$source=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
if(-not $Port){$probe=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$probe.Start();$Port=$probe.LocalEndpoint.Port;$probe.Stop()}
$ownsData=-not $DataDirectory
if($ownsData){$DataDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tnotes-window-test-'+[guid]::NewGuid().ToString('N'))}
$env:TNOTES_PORT=[string]$Port;$env:TNOTES_DATA=$DataDirectory
. (Join-Path $source 'window.ps1')
$browserProfile=Get-TNotesBrowserProfile
$powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launchArguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $source 'Launch.ps1')+'"'
function Get-BrowserIds{
    $browsers=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -Property ProcessId,CommandLine)
    return @(Select-TNotesBrowserProcessIds -Processes $browsers -ProfileDirectory $browserProfile)
}
function Get-Windows{
    $found=@()
    foreach($id in Get-BrowserIds){
        $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$id)
        $found+=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition))
    }
    return $found
}
function Wait-Windows([int]$Seconds=20){
    # Give a wrongly opened second window time to appear before counting.
    $deadline=(Get-Date).AddSeconds($Seconds)
    while((Get-Date) -lt $deadline -and @(Get-Windows).Count -eq 0){Start-Sleep -Milliseconds 250}
    Start-Sleep -Seconds 3
    return @(Get-Windows).Count
}
function Close-Browser{
    foreach($id in Get-BrowserIds){& (Join-Path $env:WINDIR 'System32\taskkill.exe') /F /T /PID $id 2>$null | Out-Null}
    $deadline=(Get-Date).AddSeconds(10)
    while((Get-Date) -lt $deadline -and @(Get-BrowserIds).Count){Start-Sleep -Milliseconds 250}
}
$backendId=0
try{
    $backend=& (Join-Path $source 'Launch.ps1') -BackendOnly
    if(-not $backend.Ready){throw 'Test backend did not start.'}
    $backendId=$backend.StartedProcessId

    # Three launchers at once, as with a double-click or repeated Start-TNotes.cmd runs.
    $launchers=@(1..3|ForEach-Object{Start-Process -FilePath $powershell -ArgumentList $launchArguments -WindowStyle Hidden -PassThru})
    foreach($launcher in $launchers){if(-not $launcher.WaitForExit(60000)){throw 'A launcher did not finish.'}}
    $count=Wait-Windows
    if($count -ne 1){throw "Simultaneous launches opened $count windows instead of 1."}

    # The launcher turns off the browser's password saving before the browser first opens the profile.
    # Checked as text and never printed: the browser keeps account details in this file.
    $preferences=[IO.File]::ReadAllText((Join-Path $browserProfile 'Default\Preferences'))
    if($preferences -notmatch '"credentials_enable_service"\s*:\s*false'){throw 'The browser profile still offers to save passwords.'}

    # Launching again with the window open must reuse it.
    $again=Start-Process -FilePath $powershell -ArgumentList $launchArguments -WindowStyle Hidden -PassThru
    if(-not $again.WaitForExit(60000)){throw 'The repeat launcher did not finish.'}
    Start-Sleep -Seconds 3
    $count=@(Get-Windows).Count
    if($count -ne 1){throw "A repeat launch left $count windows instead of 1."}

    # The T button path: clicks while the window is still starting are ignored,
    # and the window opens directly above the button that was clicked.
    Add-Type -AssemblyName System.Windows.Forms
    $area=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $api=Get-TNotesWindowApi
    # This DWM attribute is write-only; successful HRESULT is the native API contract.
    if(-not (Disable-TNotesWindowTransitions -Handle (Get-TNotesWindowHandle))){throw 'The notes window rejected disabling native transition animations.'}
    function Assert-AboveButton([int[]]$Button,[string]$When){
        $rectangle=New-Object int[] 4
        if(-not $api::GetWindowRect((Get-TNotesWindowHandle),$rectangle)){throw 'The window position could not be read.'}
        $expected=Get-TNotesAnchoredLocation -Anchor $Button -Width ($rectangle[2]-$rectangle[0]) -Height ($rectangle[3]-$rectangle[1]) -WorkingArea $area
        if([Math]::Abs($rectangle[0]-$expected[0]) -gt 1 -or [Math]::Abs($rectangle[1]-$expected[1]) -gt 1){
            $windowProcess=Get-Process -Id (Get-BrowserIds)[0]
            throw "$When rectangle=$($rectangle -join ','), expected=$($expected -join ','), button=$($Button -join ','), title=$($windowProcess.MainWindowTitle), minimized=$($api::IsIconic((Get-TNotesWindowHandle)))."
        }
        if($rectangle[3] -gt $Button[1] -or $rectangle[0] -lt $area.Left -or $rectangle[2] -gt $area.Right){throw "$When the window is not above T or leaves the screen: rectangle=$($rectangle -join ','), button=$($Button -join ','), screen=$($area.Left),$($area.Top),$($area.Right),$($area.Bottom)."}
    }
    $cornerButton=@(($area.Right-60),($area.Bottom-60),52,52)
    $middleButton=@(($area.Left+800),($area.Bottom-60),52,52)
    Close-Browser
    $results=@(1..3|ForEach-Object{Open-TNotes -Anchor ($cornerButton -join ',')})
    if(($results -join ',') -ne 'Started,Starting,Starting'){throw ('Rapid T clicks returned '+($results -join ','))}
    if(-not $script:TNotesPendingLaunch.WaitForExit(60000)){throw 'The T button launcher did not finish.'}
    $count=Wait-Windows
    if($count -ne 1){throw "Rapid T clicks opened $count windows instead of 1."}
    Assert-AboveButton $cornerButton 'After opening,'

    # A later click raises the existing window, restoring it when minimized, and brings it back above the button.
    $pattern=(Get-Windows)[0].GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)
    $pattern.SetWindowVisualState([Windows.Automation.WindowVisualState]::Minimized)
    Start-Sleep -Seconds 1
    $result=Open-TNotes -Anchor ($middleButton -join ',')
    if($result -ne 'Focused'){throw "A click with the window open returned $result."}
    Start-Sleep -Seconds 2
    $windows=@(Get-Windows)
    if($windows.Count -ne 1){throw "Raising the window left $($windows.Count) windows instead of 1."}
    $state=$windows[0].GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if($state -eq [Windows.Automation.WindowVisualState]::Minimized){throw 'The minimized window was not restored.'}
    Assert-AboveButton $middleButton 'After the bar moved,'

    if($PlacementOnly){
        foreach($screen in [System.Windows.Forms.Screen]::AllScreens){
            $area=$screen.WorkingArea
            foreach($x in @(($area.Left+10),($area.Right-60))){
                $button=@($x,($area.Bottom-60),52,52)
                $null=Open-TNotes -Anchor ($button -join ',')
                Start-Sleep -Milliseconds 300
                Assert-AboveButton $button 'After raising on the target monitor,'
                (Get-Windows)[0].GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState([Windows.Automation.WindowVisualState]::Minimized)
                Start-Sleep -Milliseconds 100
                $null=Open-TNotes -Anchor ($button -join ',')
                Start-Sleep -Milliseconds 300
                Assert-AboveButton $button 'After restoring on the target monitor,'
            }
        }
        Write-Output '{"single_window":"passed","opens_above_button":"passed","restores_above_button":"passed","all_monitors_fit":"passed"}'
        return
    }

    # The layout button grows the window to the library and back. Wherever the T button is, the window must
    # stay above it, stay on the screen, and return to exactly where it was.
    $page={param($id) [Windows.Automation.AutomationElement]::FromHandle((Get-TNotesWindowHandle)).FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$id)))}
    $wait={param($id) for($i=0;$i -lt 60;$i++){$e=& $page $id;if($e -and $e.Current.IsEnabled){return $e};Start-Sleep -Milliseconds 250};$problem=& $page 'auth-error';throw "The page never showed $id. Sign-in message: '$(if($problem){$problem.Current.Name})'."}
    $type={param($id,$text) (& $wait $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($text)}
    $press={param($id) (& $wait $id).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
    function Get-WindowRectangle{$rectangle=New-Object int[] 4;[void]$api::GetWindowRect((Get-TNotesWindowHandle),$rectangle);return $rectangle}
    $randomBytes=New-Object byte[] 15
    $generator=[Security.Cryptography.RandomNumberGenerator]::Create();$generator.GetBytes($randomBytes);$generator.Dispose()
    $testPassphrase=[Convert]::ToBase64String($randomBytes)
    & $press 'auth-mode';& $type 'username' 'window-test';& $type 'master' $testPassphrase;& $type 'master-confirm' $testPassphrase;& $press 'auth-submit'
    $null=& $wait 'view'
    $leftButton=@(($area.Left+10),($area.Bottom-60),52,52)
    foreach($case in @(@('right edge',$cornerButton),@('left edge',$leftButton),@('middle',$middleButton))){
        $name=$case[0];$button=$case[1]
        $null=Open-TNotes -Anchor ($button -join ',');Start-Sleep -Milliseconds 800
        $small=Get-WindowRectangle
        Assert-AboveButton $button "Before the layout button ($name),"
        & $press 'view';Start-Sleep -Milliseconds 1500
        $big=Get-WindowRectangle
        if(($big[2]-$big[0]) -le 900){throw "The layout button did not enlarge the window ($name)."}
        if($big[0] -lt $area.Left -or $big[2] -gt $area.Right -or $big[1] -lt $area.Top){throw "The enlarged window left the screen ($name): $($big -join ',')."}
        if($big[3] -gt $button[1] -or $big[0] -gt $button[0] -or $big[2] -lt ($button[0]+$button[2])){throw "The enlarged window is not above the T button ($name): $($big -join ',')."}
        & $press 'view';Start-Sleep -Milliseconds 1500
        $back=Get-WindowRectangle
        for($index=0;$index -lt 4;$index++){if([Math]::Abs($back[$index]-$small[$index]) -gt 1){throw "The window did not return to its place ($name): was $($small -join ',') now $($back -join ',')."}}
    }

    # As a switch, a click tucks the window away only while it is the one in front.
    $handle=Get-TNotesWindowHandle
    $inFront=$api::GetForegroundWindow() -eq $handle
    $result=Open-TNotes -Toggle
    Start-Sleep -Seconds 1
    $minimized=$api::IsIconic($handle)
    if($inFront -and ($result -ne 'Minimized' -or -not $minimized)){throw "A click on the front window returned $result instead of tucking it away."}
    if(-not $inFront -and ($result -ne 'Focused' -or $minimized)){throw "A click on a background window returned $result instead of raising it."}
    $toggle=if($inFront){'front_window_minimized'}else{'background_window_raised'}
    Write-Output ('{"simultaneous_launch_single_window":"passed","browser_password_saving_off":"passed","repeat_launch_reuses_window":"passed","rapid_clicks_single_window":"passed","opens_above_button":"passed","layout_toggle_stays_above_button":"passed","minimized_window_restored":"passed","toggle":"'+$toggle+'"}')
}finally{
    Close-Browser
    if($backendId -gt 0){Stop-Process -Id $backendId -Force -ErrorAction SilentlyContinue}
    if($ownsData){
        $resolved=[IO.Path]::GetFullPath($DataDirectory)
        $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'tnotes-window-test-*'){throw 'Refusing to remove a test directory outside the temporary workspace.'}
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
