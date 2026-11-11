Set-StrictMode -Version Latest

function Select-CodexWindowProcess {
    param(
        [AllowEmptyCollection()]
        [object[]]$Processes = @()
    )

    foreach ($process in $Processes) {
        if ($null -eq $process) {
            continue
        }

        $windowHandle = [Int64]0
        if ($null -ne $process.MainWindowHandle) {
            $windowHandle = [Int64]$process.MainWindowHandle
        }

        $path = [string]$process.Path
        if ($windowHandle -eq 0 -or $path -notmatch '(?i)[\\/]OpenAI\.Codex_') {
            continue
        }

        return $process
    }

    return $null
}

function Get-CodexToggleAction {
    param(
        [AllowNull()]
        $Process,

        [bool]$IsMinimized,

        [bool]$IsVisible
    )

    if ($null -eq $Process) {
        return 'Start'
    }

    if ($IsMinimized -or -not $IsVisible) {
        return 'Restore'
    }

    return 'Minimize'
}

function Select-AndroidStudioRelatedProcessIds {
    param(
        [AllowEmptyCollection()]
        [object[]]$Processes = @()
    )

    $directProcessNames = @(
        'studio64.exe',
        'studio.exe',
        'adb.exe',
        'emulator.exe',
        'emulator-check.exe',
        'gradle.exe',
        'gradlew.exe'
    )
    $selectedIds = @{}

    foreach ($process in $Processes) {
        if ($null -eq $process) {
            continue
        }

        $name = ([string]$process.Name).ToLowerInvariant()
        $commandLine = [string]$process.CommandLine
        $executablePath = [string]$process.ExecutablePath
        $isDirectProcess = $directProcessNames -contains $name
        $isAndroidJavaProcess = $name -in @('java.exe', 'javaw.exe') -and
            $commandLine -match '(?i)GradleDaemon|org\.gradle\.|KotlinCompileDaemon|kotlin\.daemon|com\.android\.tools'
        $isAndroidQemuProcess = $name -like 'qemu-system-*.exe' -and
            ($executablePath -match '(?i)[\\/]Android[\\/].*Sdk[\\/]' -or
                $commandLine -match '(?i)[\\/]Android[\\/].*Sdk[\\/]')

        if ($isDirectProcess -or $isAndroidJavaProcess -or $isAndroidQemuProcess) {
            $selectedIds[[int]$process.ProcessId] = $true
        }
    }

    do {
        $addedDescendant = $false
        foreach ($process in $Processes) {
            if ($null -eq $process) {
                continue
            }

            $processId = [int]$process.ProcessId
            $parentProcessId = [int]$process.ParentProcessId
            if (-not $selectedIds.ContainsKey($processId) -and $selectedIds.ContainsKey($parentProcessId)) {
                $selectedIds[$processId] = $true
                $addedDescendant = $true
            }
        }
    } while ($addedDescendant)

    return @($selectedIds.Keys | Sort-Object)
}

function Get-AndroidStudioTaskKillArguments {
    param(
        [AllowEmptyCollection()]
        [int[]]$ProcessIds = @()
    )

    $validProcessIds = @($ProcessIds | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('/F')
    $arguments.Add('/T')

    foreach ($processId in $validProcessIds) {
        $arguments.Add('/PID')
        $arguments.Add([string]$processId)
    }

    return $arguments -join ' '
}

function Get-FloatingButtonLocation {
    param(
        [Parameter(Mandatory = $true)]
        $CursorPosition,

        [Parameter(Mandatory = $true)]
        $PointerOffset
    )

    $x = [int]$CursorPosition.X - [int]$PointerOffset.X
    $y = [int]$CursorPosition.Y - [int]$PointerOffset.Y

    return [System.Drawing.Point]::new($x, $y)
}

function Get-FloatingButtonIndex {
    param(
        [int]$X,
        [int]$Y,
        [int]$Count,
        [int]$ButtonSize,
        [int]$Gap,
        [int]$Margin
    )

    # Buttons sit in one row; the gaps and the shadow margin around them belong to no button.
    if ($Y -lt $Margin -or $Y -ge ($Margin + $ButtonSize)) {
        return -1
    }

    for ($index = 0; $index -lt $Count; $index++) {
        $left = $Margin + $index * ($ButtonSize + $Gap)
        if ($X -ge $left -and $X -lt ($left + $ButtonSize)) {
            return $index
        }
    }

    return -1
}

function Get-FloatingBarStartLocation {
    param(
        [AllowNull()]
        $SavedLocation,

        [Parameter(Mandatory = $true)]
        $BarSize,

        [AllowEmptyCollection()]
        [object[]]$WorkingAreas = @(),

        [Parameter(Mandatory = $true)]
        $DefaultLocation
    )

    # A remembered position is only trusted while its screen is still connected;
    # otherwise the bar would start somewhere it cannot be seen or reached.
    if ($null -ne $SavedLocation -and
        $null -ne $SavedLocation.PSObject.Properties['X'] -and
        $null -ne $SavedLocation.PSObject.Properties['Y']) {
        $savedX = 0
        $savedY = 0
        if ([int]::TryParse([string]$SavedLocation.X, [ref]$savedX) -and [int]::TryParse([string]$SavedLocation.Y, [ref]$savedY)) {
            $centerX = $savedX + [int]($BarSize.Width / 2)
            $centerY = $savedY + [int]($BarSize.Height / 2)
            foreach ($area in $WorkingAreas) {
                if ($centerX -ge $area.Left -and $centerX -lt $area.Right -and
                    $centerY -ge $area.Top -and $centerY -lt $area.Bottom) {
                    $x = [Math]::Max($area.Left, [Math]::Min($savedX, $area.Right - $BarSize.Width))
                    $y = [Math]::Max($area.Top, [Math]::Min($savedY, $area.Bottom - $BarSize.Height))
                    return [System.Drawing.Point]::new($x, $y)
                }
            }
        }
    }

    return $DefaultLocation
}
