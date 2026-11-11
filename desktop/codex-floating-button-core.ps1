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

function Get-ControlPointerOffset {
    param(
        [Parameter(Mandatory = $true)]
        $ControlLocation,

        [Parameter(Mandatory = $true)]
        $EventLocation
    )

    $x = [int]$ControlLocation.X + [int]$EventLocation.X
    $y = [int]$ControlLocation.Y + [int]$EventLocation.Y

    return [System.Drawing.Point]::new($x, $y)
}
