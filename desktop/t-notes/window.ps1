# Shared by Launch.ps1 and the floating toolbar so T Notes keeps exactly one app window.
# Dot-source this file; it defines functions only and starts nothing.

$script:TNotesPendingLaunch = $null

function Get-TNotesBrowserProfile {
    # The browser profile lives beside the data it shows, so a separate data directory
    # (tests, a second vault) is never mistaken for the window of another one.
    $dataDirectory = if ($env:TNOTES_DATA) { $env:TNOTES_DATA } else { Join-Path $env:LOCALAPPDATA 'TNotes' }
    return (Join-Path $dataDirectory 'browser-v3')
}

function Select-TNotesBrowserProcessIds {
    param(
        [AllowEmptyCollection()]
        [object[]]$Processes = @(),

        [Parameter(Mandatory = $true)]
        [string]$ProfileDirectory
    )

    # The dedicated profile identifies the window. Page titles are not reliable: they
    # differ while the page loads, when the backend is down, and after an upgrade.
    $profilePattern = '(?i)--user-data-dir="?' + [regex]::Escape($ProfileDirectory.TrimEnd('\')) + '\\?"?(?:\s|$)'
    $selected = New-Object System.Collections.Generic.List[int]
    foreach ($process in $Processes) {
        if ($null -eq $process) {
            continue
        }

        $commandLine = [string]$process.CommandLine
        # Renderer, GPU and crash-handler children carry --type=; only the browser process owns windows.
        if ($commandLine -match $profilePattern -and $commandLine -notmatch '(?i)\s--type=') {
            $selected.Add([int]$process.ProcessId)
        }
    }

    return @($selected | Sort-Object)
}

function Get-TNotesBrowserProcessIds {
    param(
        [string]$ProfileDirectory = (Get-TNotesBrowserProfile)
    )

    $browsers = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -Property ProcessId, CommandLine -ErrorAction SilentlyContinue)
    return @(Select-TNotesBrowserProcessIds -Processes $browsers -ProfileDirectory $ProfileDirectory)
}

function Get-TNotesWindowHandle {
    param(
        [string]$ProfileDirectory = (Get-TNotesBrowserProfile)
    )

    foreach ($processId in @(Get-TNotesBrowserProcessIds -ProfileDirectory $ProfileDirectory)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            continue
        }

        try {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                return $process.MainWindowHandle
            }
        }
        finally {
            $process.Dispose()
        }
    }

    return [IntPtr]::Zero
}

function Get-TNotesWindowApi {
    $existing = 'TNotesWindowApi' -as [Type]
    if ($null -ne $existing) {
        return $existing
    }

    $assemblyBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('TNotes.NativeMethods')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    )
    $typeAttributes = [System.Reflection.TypeAttributes]::Public `
        -bor [System.Reflection.TypeAttributes]::Abstract `
        -bor [System.Reflection.TypeAttributes]::Sealed
    $typeBuilder = $assemblyBuilder.DefineDynamicModule('TNotes.NativeMethods').DefineType('TNotesWindowApi', $typeAttributes)
    $methodAttributes = [System.Reflection.MethodAttributes]::Public `
        -bor [System.Reflection.MethodAttributes]::Static `
        -bor [System.Reflection.MethodAttributes]::PinvokeImpl
    $signatures = @(
        @{ Name = 'ShowWindowAsync'; Returns = [bool]; Parameters = [Type[]]@([IntPtr], [int]) },
        @{ Name = 'SetForegroundWindow'; Returns = [bool]; Parameters = [Type[]]@([IntPtr]) },
        @{ Name = 'IsIconic'; Returns = [bool]; Parameters = [Type[]]@([IntPtr]) },
        @{ Name = 'IsZoomed'; Returns = [bool]; Parameters = [Type[]]@([IntPtr]) },
        @{ Name = 'GetForegroundWindow'; Returns = [IntPtr]; Parameters = [Type[]]@() },
        # RECT is four 32-bit integers; an int array of four is filled in place.
        @{ Name = 'GetWindowRect'; Returns = [bool]; Parameters = [Type[]]@([IntPtr], [int[]]) },
        @{ Name = 'SetWindowPos'; Returns = [bool]; Parameters = [Type[]]@([IntPtr], [IntPtr], [int], [int], [int], [int], [int]) }
    )
    foreach ($signature in $signatures) {
        $method = $typeBuilder.DefinePInvokeMethod(
            $signature.Name,
            'user32.dll',
            $methodAttributes,
            [System.Reflection.CallingConventions]::Standard,
            $signature.Returns,
            $signature.Parameters,
            [System.Runtime.InteropServices.CallingConvention]::Winapi,
            [System.Runtime.InteropServices.CharSet]::Auto
        )
        $method.SetImplementationFlags(
            $method.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig
        )
    }

    return $typeBuilder.CreateType()
}

function Show-TNotesWindow {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    $api = Get-TNotesWindowApi
    $SW_MINIMIZE = 6
    $SW_RESTORE = 9
    # Restore only a minimized window; restoring a maximized one would shrink it.
    if ($api::IsIconic($Handle)) {
        [void]$api::ShowWindowAsync($Handle, $SW_RESTORE)
    }
    if (-not $api::SetForegroundWindow($Handle)) {
        # Windows refuses focus changes from background processes; minimize and restore still raises the window.
        [void]$api::ShowWindowAsync($Handle, $SW_MINIMIZE)
        [void]$api::ShowWindowAsync($Handle, $SW_RESTORE)
    }
}

function ConvertFrom-TNotesAnchor {
    param(
        [string]$Anchor
    )

    # "x,y,width,height" of the button the window belongs to, in screen pixels. A leading letter is
    # allowed so a negative x (a screen to the left) is never mistaken for a command-line switch.
    if ($Anchor -notmatch '(-?\d{1,6}),(-?\d{1,6}),(\d{1,5}),(\d{1,5})$') {
        return @()
    }

    return @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
}

function Get-TNotesAnchoredLocation {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Anchor,

        [int]$Width,
        [int]$Height,

        [Parameter(Mandatory = $true)]
        $WorkingArea,

        [int]$Gap = 2
    )

    # Centred over the button and directly above it, but always fully on the button's screen.
    $x = $Anchor[0] + [int]($Anchor[2] / 2) - [int]($Width / 2)
    $x = [Math]::Max($WorkingArea.Left, [Math]::Min($x, $WorkingArea.Right - $Width))
    $above = $Anchor[1] - $Gap - $Height
    $below = $Anchor[1] + $Anchor[3] + $Gap
    if ($above -ge $WorkingArea.Top) {
        $y = $above
    }
    elseif (($below + $Height) -le $WorkingArea.Bottom) {
        # The bar sits near the top of the screen: there is only room underneath it.
        $y = $below
    }
    else {
        $y = $WorkingArea.Top
    }

    return @($x, $y)
}

function Move-TNotesWindowToAnchor {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,

        [string]$Anchor
    )

    $bounds = @(ConvertFrom-TNotesAnchor -Anchor $Anchor)
    if ($bounds.Count -ne 4) {
        return
    }

    $api = Get-TNotesWindowApi
    # A maximized window already fills the screen; moving it would only break that.
    if ($api::IsZoomed($Handle)) {
        return
    }
    # A window that is still being restored reports its minimized placeholder position.
    for ($attempt = 0; $attempt -lt 25 -and $api::IsIconic($Handle); $attempt++) {
        Start-Sleep -Milliseconds 20
    }
    $rectangle = New-Object int[] 4
    if ($api::IsIconic($Handle) -or -not $api::GetWindowRect($Handle, $rectangle)) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $center = New-Object System.Drawing.Point(($bounds[0] + [int]($bounds[2] / 2)), ($bounds[1] + [int]($bounds[3] / 2)))
    $location = Get-TNotesAnchoredLocation `
        -Anchor $bounds `
        -Width ($rectangle[2] - $rectangle[0]) `
        -Height ($rectangle[3] - $rectangle[1]) `
        -WorkingArea ([System.Windows.Forms.Screen]::FromPoint($center).WorkingArea)
    if ($location[0] -ne $rectangle[0] -or $location[1] -ne $rectangle[1]) {
        $SWP_NOSIZE = 0x0001
        $SWP_NOZORDER = 0x0004
        $SWP_NOACTIVATE = 0x0010
        [void]$api::SetWindowPos($Handle, [IntPtr]::Zero, $location[0], $location[1], 0, 0, ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE))
    }
}

function Open-TNotes {
    param(
        # The T button works as a switch: a click while the window is in front tucks it away.
        [switch]$Toggle,

        # Screen rectangle of the button that was clicked; the window is placed directly above it.
        [string]$Anchor = ''
    )

    # Entry point for the T button. Returns 'Focused', 'Minimized', 'Started' or 'Starting';
    # throws when the local backend cannot be started.
    if ($null -ne $script:TNotesPendingLaunch) {
        # The window takes a few seconds to appear. Clicks during that time (a double-click,
        # an impatient second click) must not start another launcher.
        if (-not $script:TNotesPendingLaunch.HasExited) {
            return 'Starting'
        }
        $script:TNotesPendingLaunch.Dispose()
        $script:TNotesPendingLaunch = $null
    }

    $launcher = Join-Path $PSScriptRoot 'Launch.ps1'
    & $launcher -BackendOnly | Out-Null

    $window = Get-TNotesWindowHandle
    if ($window -ne [IntPtr]::Zero) {
        $api = Get-TNotesWindowApi
        if ($Toggle -and $api::GetForegroundWindow() -eq $window -and -not $api::IsIconic($window)) {
            [void]$api::ShowWindowAsync($window, 6)
            return 'Minimized'
        }
        Show-TNotesWindow -Handle $window
        Move-TNotesWindowToAnchor -Handle $window -Anchor $Anchor
        return 'Focused'
    }

    $arguments = '-NoProfile -WindowStyle Hidden -File "' + $launcher + '"'
    $bounds = @(ConvertFrom-TNotesAnchor -Anchor $Anchor)
    if ($bounds.Count -eq 4) {
        $arguments += ' -Anchor "p' + ($bounds -join ',') + '"'
    }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:TNotesPendingLaunch = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    return 'Started'
}
