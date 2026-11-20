Set-StrictMode -Version Latest

# Functions behind the tool button: they parse adb output, pick Gradle processes and keep the settings.
# Dot-source this file; it defines functions only and starts nothing.

function Get-DevToolsDefaultSettings {
    $exportPath = 'E:\BLELogs'
    if (-not (Test-Path -LiteralPath 'E:\' -PathType Container)) {
        $exportPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BLELogs'
    }

    return [pscustomobject]@{
        RemoteLogPath = '/sdcard/Android/data/com.enplus.caro_sdk/files/BLEBluetoothLog'
        ExportPath = $exportPath
        Serial = ''
        # Where "save to computer" in the log viewer last saved; empty until the first save.
        SaveFolder = ''
        # The app whose downloaded AP logs (cache/charger_logs) the log viewer exports.
        ApLogPackage = 'energy.octopus.installer'
        # APK installs: the options chosen last ("r", "t", "d" for adb install, "c" for clearing the app's data by
        # uninstalling it first, in any mix) and the folder last picked from.
        InstallFlags = 'r'
        ApkFolder = ''
        # Installer account tool: the server ("dev" or "pre") and the account it signs in with. The password is
        # kept encrypted for the current Windows user (DPAPI), never as plain text.
        InstallerEnv = 'dev'
        InstallerEmail = ''
        InstallerPassword = ''
    }
}

function Find-AaptPath {
    param(
        [AllowEmptyString()]
        [string]$AdbPath = ''
    )

    # aapt reads an APK's package name and version. It ships with the SDK build-tools; the newest one wins.
    $roots = @()
    if ($AdbPath) { $roots += Split-Path -Parent (Split-Path -Parent $AdbPath) }
    $roots += @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $tools = Join-Path $root 'build-tools'
        if (-not (Test-Path -LiteralPath $tools -PathType Container)) { continue }
        $found = Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property @{ Expression = { $version = $null; if ([version]::TryParse(($_.Name -replace '-.*$', ''), [ref]$version)) { $version } else { [version]'0.0' } }; Descending = $true } |
            ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}

function ConvertFrom-ApkBadging {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # From "aapt dump badging app.apk".
    $info = [pscustomobject]@{ Package = ''; VersionCode = ''; VersionName = ''; Label = ''; MinSdk = ''; Debuggable = $false; TestOnly = $false }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "^package: name='([^']*)'") {
            $info.Package = $Matches[1]
            if ($line -match "versionCode='([^']*)'") { $info.VersionCode = $Matches[1] }
            if ($line -match "versionName='([^']*)'") { $info.VersionName = $Matches[1] }
        }
        elseif ($line -match "^application-label:'(.*)'\s*$" -and -not $info.Label) { $info.Label = $Matches[1] }
        elseif ($line -match "^sdkVersion:'(\d+)'") { $info.MinSdk = $Matches[1] }
        elseif ($line -match '^application-debuggable') { $info.Debuggable = $true }
        elseif ($line -match "^testOnly='?-?1'?|testOnly='-1'") { $info.TestOnly = $true }
    }
    return $info
}

function Test-ApkTestOnly {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # From "aapt dump xmltree app.apk AndroidManifest.xml": Android Studio's run builds set android:testOnly to
    # true, which "dump badging" does not show; such an APK installs only with -t.
    return ($Text -match 'android:testOnly\(0x[0-9a-fA-F]+\)=\(type 0x12\)0xffffffff')
}

function Get-InstallWarnings {
    param(
        [AllowNull()]
        $Apk,

        [AllowNull()]
        $Installed,

        [AllowEmptyString()]
        [string]$Flags = ''
    )

    # Options this APK needs on this phone but that are not ticked: "t", "r" or "d".
    # Clearing the data uninstalls the old version first, so -r and -d are not needed then.
    $needed = @()
    if ($null -ne $Apk -and $Apk.TestOnly -and -not $Flags.Contains('t')) { $needed += 't' }
    if ($Flags.Contains('c')) { return $needed }
    if ($null -ne $Installed -and -not $Flags.Contains('r')) { $needed += 'r' }
    $apkCode = 0L
    $phoneCode = 0L
    if ($null -ne $Apk -and $null -ne $Installed -and [long]::TryParse([string]$Apk.VersionCode, [ref]$apkCode) -and
        [long]::TryParse([string]$Installed.VersionCode, [ref]$phoneCode) -and $apkCode -lt $phoneCode -and -not $Flags.Contains('d')) {
        $needed += 'd'
    }
    return $needed
}

function ConvertFrom-InstalledPackage {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # From "dumpsys package <name> | grep -E 'versionCode=|versionName='"; empty when the app is not installed.
    $code = ''
    $name = ''
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $code -and $line -match 'versionCode=(\d+)') { $code = $Matches[1] }
        if (-not $name -and $line -match 'versionName=(\S+)') { $name = $Matches[1] }
    }
    if (-not $code) { return $null }
    return [pscustomobject]@{ VersionCode = $code; VersionName = $name }
}

function Get-InstallArguments {
    param(
        [AllowEmptyString()]
        [string]$Flags = '',

        [Parameter(Mandatory = $true)]
        [string]$ApkPath
    )

    # "adb install" with the chosen options, always in the order -r -t -d. With "c" the old version is uninstalled first,
    # so keeping its data (-r) does not apply.
    $arguments = @('install')
    foreach ($flag in 'r', 't', 'd') {
        if ($Flags.Contains($flag) -and -not ($flag -eq 'r' -and $Flags.Contains('c'))) { $arguments += '-' + $flag }
    }
    return @($arguments + $ApkPath)
}

function ConvertFrom-UninstallOutput {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [int]$ExitCode = 0
    )

    # "adb uninstall <package>" prints "Success", or "Failure [DELETE_FAILED_INTERNAL_ERROR]", or
    # "Failure [not installed for 0]" when the phone does not have the app (nothing to remove, which is fine).
    $lines = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('*') })
    if ($ExitCode -eq 0 -and ($lines -contains 'Success')) {
        return [pscustomobject]@{ Result = 'Removed'; Code = ''; Message = 'Success' }
    }
    $message = @($lines | Where-Object { $_ -match '(?i)failure|failed|error|exception' }) | Select-Object -First 1
    if (-not $message) { $message = if ($lines.Count) { $lines[-1] } else { 'exit code ' + $ExitCode } }
    if ($message -match '(?i)not installed|unknown package') {
        return [pscustomobject]@{ Result = 'NotInstalled'; Code = ''; Message = $message }
    }
    $code = 'UNKNOWN'
    if ($message -match '\[(DELETE_[A-Z_]+)') { $code = $Matches[1] }
    elseif ($message -match "(?i)device '.*' not found|device offline|no devices|unauthorized") { $code = 'DEVICE' }
    return [pscustomobject]@{ Result = 'Failed'; Code = $code; Message = $message }
}

function ConvertFrom-InstallOutput {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [int]$ExitCode = 0
    )

    # adb prints "Success", or a line such as
    # "adb: failed to install app.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: ...]".
    # Code is the Android error name (or DEVICE / NO_FILE / UNKNOWN); Message is the English line to show as is.
    $lines = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('*') -and $_ -notmatch '^Performing (Streamed|Push) Install' })
    $failure = @($lines | Where-Object { $_ -match '(?i)failure|failed|error|exception' }) | Select-Object -First 1
    if ($ExitCode -eq 0 -and -not $failure -and ($lines -contains 'Success')) {
        return [pscustomobject]@{ Success = $true; Code = ''; Message = 'Success' }
    }
    $message = if ($failure) { $failure } elseif ($lines.Count) { $lines[-1] } else { 'exit code ' + $ExitCode }
    $code = 'UNKNOWN'
    if ($message -match '\[(INSTALL_[A-Z_]+)') { $code = $Matches[1] }
    elseif ($message -match '\b(INSTALL_[A-Z_]+)\b') { $code = $Matches[1] }
    elseif ($message -match "(?i)device '.*' not found|device offline|no devices|device unauthorized|unauthorized") { $code = 'DEVICE' }
    elseif ($message -match '(?i)no such file|cannot stat|failed to stat|does not exist') { $code = 'NO_FILE' }
    return [pscustomobject]@{ Success = $false; Code = $code; Message = $message }
}

function Test-AndroidPackageName {
    param(
        [AllowEmptyString()]
        [string]$Name = ''
    )

    # It goes into a phone shell command, so only a real package name (letters, digits, _ and dots) passes.
    return ($Name -match '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
}

function ConvertTo-LocalRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # "SN123/log 1.zip" from the phone -> "SN123\log 1.zip", with characters Windows refuses in names replaced.
    $parts = foreach ($part in ($Name -split '/')) {
        $clean = ($part -replace '[\\:*?"<>|\x00-\x1f]', '_').Trim().TrimEnd('.')
        if ($clean -and $clean -ne '..') { $clean }
    }
    return (@($parts) -join '\')
}

function Read-DevToolsSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $settings = Get-DevToolsDefaultSettings
    try {
        $saved = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($name in 'RemoteLogPath', 'ExportPath', 'Serial', 'SaveFolder', 'ApLogPackage', 'InstallFlags', 'ApkFolder', 'InstallerEnv', 'InstallerEmail', 'InstallerPassword') {
            $property = $saved.PSObject.Properties[$name]
            if ($name -eq 'InstallFlags' -and $null -ne $property -and $property.Value -is [string] -and $property.Value -notmatch '^[rtdc]*$') {
                continue
            }
            if ($name -eq 'InstallerEnv' -and $null -ne $property -and $property.Value -notin @('dev', 'pre')) {
                continue
            }
            if ($null -ne $property -and $property.Value -is [string] -and ($name -in @('Serial', 'SaveFolder', 'InstallFlags', 'ApkFolder', 'InstallerEmail', 'InstallerPassword') -or $property.Value.Trim())) {
                $settings.$name = $property.Value.Trim()
            }
        }
    }
    catch {
    }

    return $settings
}

function Save-DevToolsSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Settings
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $json = [pscustomobject]@{
        RemoteLogPath = [string]$Settings.RemoteLogPath
        ExportPath = [string]$Settings.ExportPath
        Serial = [string]$Settings.Serial
        SaveFolder = $(if ($null -ne $Settings.PSObject.Properties['SaveFolder']) { [string]$Settings.SaveFolder } else { '' })
        ApLogPackage = $(if ($null -ne $Settings.PSObject.Properties['ApLogPackage']) { [string]$Settings.ApLogPackage } else { 'energy.octopus.installer' })
        InstallFlags = $(if ($null -ne $Settings.PSObject.Properties['InstallFlags']) { [string]$Settings.InstallFlags } else { 'r' })
        ApkFolder = $(if ($null -ne $Settings.PSObject.Properties['ApkFolder']) { [string]$Settings.ApkFolder } else { '' })
        InstallerEnv = $(if ($null -ne $Settings.PSObject.Properties['InstallerEnv'] -and $Settings.InstallerEnv -in @('dev', 'pre')) { [string]$Settings.InstallerEnv } else { 'dev' })
        InstallerEmail = $(if ($null -ne $Settings.PSObject.Properties['InstallerEmail']) { [string]$Settings.InstallerEmail } else { '' })
        InstallerPassword = $(if ($null -ne $Settings.PSObject.Properties['InstallerPassword']) { [string]$Settings.InstallerPassword } else { '' })
    } | ConvertTo-Json
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Find-AdbPath {
    $command = Get-Command -Name 'adb.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if (-not $sdk) {
            continue
        }
        $candidate = Join-Path $sdk 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function ConvertTo-ProcessArgumentString {
    param(
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    # Windows splits a command line by its own quoting rules; quote each argument so paths with spaces stay whole.
    $quoted = foreach ($argument in $Arguments) {
        $text = [string]$argument
        if ($text -ne '' -and $text -notmatch '[\s"]') {
            $text
        }
        else {
            $escaped = [regex]::Replace($text, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }

    return (@($quoted) -join ' ')
}

function ConvertFrom-AdbDeviceList {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $devices = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('List of devices') -or $trimmed.StartsWith('*') -or $trimmed.StartsWith('adb ')) {
            continue
        }

        $parts = @($trimmed -split '\s+')
        if ($parts.Count -lt 2) {
            continue
        }

        $model = ''
        foreach ($part in @($parts | Select-Object -Skip 2)) {
            if ($part -match '^model:(.+)$') {
                $model = $Matches[1] -replace '_', ' '
            }
        }

        $devices += [pscustomobject]@{
            Serial = $parts[0]
            State = $parts[1]
            Model = $model
        }
    }

    return $devices
}

function Get-AndroidComponentFromRecord {
    param(
        [AllowEmptyString()]
        [string]$Line = ''
    )

    # ActivityRecord{7a812aa u0 com.example/.MainActivity t4452} and Window{3f2 u0 com.example/com.example.Main}
    if ($Line -match '\{\S+\s+u\d+\s+([^\s/{}]+)/([^\s{}]+)') {
        $package = $Matches[1]
        $class = $Matches[2]
        if ($class.StartsWith('.')) {
            $class = $package + $class
        }

        return [pscustomobject]@{
            Component = $Matches[1] + '/' + $Matches[2]
            Package = $package
            ClassName = $class
        }
    }

    return $null
}

function ConvertFrom-ActivityDump {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $lines = @($Text -split "`r?`n" | Where-Object { $_ -match '(?i)topResumedActivity|mResumedActivity|ResumedActivity' } | ForEach-Object { $_.Trim() })
    # The activity the user sees is the top resumed one; older Android versions only report mResumedActivity.
    foreach ($key in 'topResumedActivity', 'mResumedActivity', 'ResumedActivity') {
        foreach ($line in $lines) {
            if ($line -cmatch ('(?:^|[^A-Za-z])' + $key + '\b')) {
                $component = Get-AndroidComponentFromRecord -Line $line
                if ($null -ne $component) {
                    return [pscustomobject]@{ Lines = $lines; Activity = $component }
                }
            }
        }
    }

    return [pscustomobject]@{ Lines = $lines; Activity = $null }
}

function ConvertFrom-WindowFocusDump {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $lines = @($Text -split "`r?`n" | Where-Object { $_ -match '(?i)mCurrentFocus|mFocusedApp' } | ForEach-Object { $_.Trim() })
    foreach ($line in $lines) {
        $component = Get-AndroidComponentFromRecord -Line $line
        if ($null -ne $component) {
            return [pscustomobject]@{ Lines = $lines; Activity = $component }
        }
    }

    return [pscustomobject]@{ Lines = $lines; Activity = $null }
}

function ConvertFrom-TaskDump {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # Task stacks from "dumpsys activity activities": each "Task{... #id ...}" (TaskRecord before Android 10)
    # is followed by its "Hist #n: ActivityRecord{...}" lines, top of the stack first. Tasks are listed most
    # recent first. Samsung prints the hierarchy a second time; a task seen before is not added again, and
    # tasks without activities (empty split-screen and freeform containers) are left out.
    $tasks = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    $current = $null
    $resumed = ''
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $resumed -and $line -match '(?:topResumedActivity|mResumedActivity|ResumedActivity)[=:]\s*ActivityRecord\{(\S+)') {
            $resumed = $Matches[1]
        }
        if ($line -match '^\s*(?:\*\s+)?(?:Task|TaskRecord)\{\S+ #(\d+)\s*([^}]*)\}') {
            $id = [int]$Matches[1]
            $attributes = ' ' + $Matches[2]
            if ($byId.ContainsKey($id)) {
                $current = $byId[$id]
                continue
            }
            $affinity = ''
            if ($attributes -match '\sA=(?:\d+:)?([^\s}]+)') { $affinity = $Matches[1] }
            elseif ($attributes -match '\sI=([^/\s}]+)') { $affinity = $Matches[1] }
            $current = [pscustomobject]@{
                Id = $id
                Type = $(if ($attributes -match '\stype=(\S+)') { $Matches[1] } else { '' })
                Affinity = $affinity
                Visible = ($attributes -match '\svisible=true')
                Activities = (New-Object System.Collections.Generic.List[object])
            }
            $byId[$id] = $current
            $tasks.Add($current)
            continue
        }
        if ($null -ne $current -and $line -match '^\s*(?:\*\s+)?Hist\s+#\d+:\s+ActivityRecord\{(\S+)\s+u\d+\s+([^\s/{}]+)/([^\s{}]+)') {
            $package = $Matches[2]
            $class = $Matches[3]
            if ($class.StartsWith('.')) {
                $class = $package + $class
            }
            $current.Activities.Add([pscustomobject]@{
                Record = $Matches[1]
                Package = $package
                ClassName = $class
                ShortName = $class.Substring($class.LastIndexOf('.') + 1)
                Resumed = $false
            })
        }
    }

    foreach ($task in $tasks) {
        foreach ($activity in $task.Activities) {
            $activity.Resumed = ($resumed -ne '' -and $activity.Record -eq $resumed)
        }
    }
    return @($tasks | Where-Object { $_.Activities.Count -gt 0 })
}

function Find-SecureWindows {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # Windows on screen that forbid screen capture (flag SECURE), from
    # "dumpsys window windows | grep -E '^  Window #|fl=|isOnScreen='". While one is shown, Xiaomi phones
    # refuse every screenshot; "InputMethod" is the keyboard, e.g. MIUI's security keyboard on a password box.
    $found = New-Object System.Collections.Generic.List[string]
    $name = $null
    $secure = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*Window #\d+ Window\{\S+ u\d+ ([^}]+)\}') {
            $name = $Matches[1].Trim()
            $secure = $false
            continue
        }
        if ($null -eq $name) {
            continue
        }
        if ($line -match '^\s*fl=') {
            $secure = $line -match '(?:^|\s)SECURE(?:\s|$)'
        }
        elseif ($line -match 'isOnScreen=true' -and $secure -and -not $found.Contains($name)) {
            $found.Add($name)
        }
    }
    return $found.ToArray()
}

function Select-GradleProcesses {
    param(
        [AllowEmptyCollection()]
        [object[]]$Processes = @(),

        [AllowEmptyCollection()]
        [int[]]$ExcludeIds = @()
    )

    # Only build processes: Gradle daemons, wrappers and workers, and the Kotlin compile daemon they start.
    # Android Studio itself and unrelated Java programs are left running.
    $selected = @()
    foreach ($process in $Processes) {
        if ($null -eq $process -or $ExcludeIds -contains [int]$process.ProcessId) {
            continue
        }

        $name = ([string]$process.Name).ToLowerInvariant()
        $commandLine = [string]$process.CommandLine
        $kind = $null
        if ($name -in @('java.exe', 'javaw.exe')) {
            if ($commandLine -match '(?i)KotlinCompileDaemon|org\.jetbrains\.kotlin\.daemon') {
                $kind = 'Kotlin'
            }
            elseif ($commandLine -match '(?i)GradleDaemon|org\.gradle\.launcher\.daemon') {
                $kind = 'Daemon'
            }
            elseif ($commandLine -match '(?i)GradleWrapperMain|org\.gradle\.wrapper') {
                $kind = 'Wrapper'
            }
            elseif ($commandLine -match '(?i)GradleWorkerMain|org\.gradle\.process\.internal\.worker') {
                $kind = 'Worker'
            }
            elseif ($commandLine -match '(?i)org\.gradle\.|gradle-launcher') {
                $kind = 'Gradle'
            }
        }
        elseif ($name -in @('gradle.exe', 'gradlew.exe')) {
            $kind = 'Gradle'
        }

        if ($null -eq $kind) {
            continue
        }

        $version = ''
        if ($commandLine -match '(?i)GradleDaemon\s+(\d+(?:\.\d+)+)' -or
            $commandLine -match '(?i)gradle-launcher-(\d+(?:\.\d+)+)' -or
            $commandLine -match '(?i)kotlin-(?:compiler|daemon)[\w-]*?-(\d+(?:\.\d+)+)' -or
            $commandLine -match '(?i)gradle-(\d+(?:\.\d+)+)-(?:bin|all)') {
            $version = $Matches[1]
        }

        $selected += [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            Kind = $kind
            Version = $version
        }
    }

    return $selected
}

function Test-RemoteLogPath {
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    # The path goes into a phone shell command inside single quotes, so characters that could end the
    # quoting or start another command are refused.
    return ($Path -match '^/.' -and $Path -notmatch '[''"`$;&|<>\\\r\n*?]')
}

function Test-LocalExportPath {
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    if ($Path -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') {
        return $false
    }
    return ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -lt 0 -and $Path.IndexOf('*') -lt 0 -and $Path.IndexOf('?') -lt 0)
}

function Get-DeviceFolderName {
    param(
        [AllowEmptyString()]
        [string]$Model = '',

        [Parameter(Mandatory = $true)]
        [string]$Serial
    )

    # One folder per phone, so logs from two phones exported to the same place never mix.
    $name = if ($Model) { $Model + '_' + $Serial } else { $Serial }
    $name = ($name -replace '[\\/:*?"<>|\s.]+', '_').Trim('_')
    if (-not $name) {
        $name = 'phone'
    }
    return $name
}

function ConvertFrom-RemoteFileStat {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    # Lines from: find <root> -type f -exec stat -c '%s %Y %n' {} +
    # The root may be relative, as in an app's own folder read through run-as ("cache/charger_logs").
    $prefix = $Root.TrimEnd('/') + '/'
    $files = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^(\d+)\s+(\d+)\s+(\S.*?)\s*$') {
            continue
        }

        $path = $Matches[3]
        $relative = if ($path.StartsWith($prefix)) { $path.Substring($prefix.Length) } else { $path }
        $files += [pscustomobject]@{
            Path = $path
            Name = $relative
            Leaf = $path.Substring($path.LastIndexOf('/') + 1)
            Size = [int64]$Matches[1]
            Modified = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches[2]).LocalDateTime
        }
    }

    return @($files | Sort-Object -Property @{ Expression = 'Modified'; Descending = $true }, @{ Expression = 'Name'; Descending = $true })
}

function Test-RemoteBrowsePath {
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    # Browsing also allows the phone's root folder.
    return ($Path -eq '/' -or (Test-RemoteLogPath -Path $Path))
}

function ConvertTo-RemotePath {
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    # "/sdcard//Download/" -> "/sdcard/Download"; the root stays "/".
    $clean = ($Path.Trim() -replace '/{2,}', '/')
    if ($clean.Length -gt 1) {
        $clean = $clean.TrimEnd('/')
    }
    return $clean
}

function Get-RemoteParentPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $clean = ConvertTo-RemotePath -Path $Path
    $cut = $clean.LastIndexOf('/')
    if ($clean -eq '/' -or $cut -lt 0) {
        return $null
    }
    if ($cut -eq 0) {
        return '/'
    }
    return $clean.Substring(0, $cut)
}

function Join-RemotePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Directory -eq '/') {
        return '/' + $Name
    }
    return $Directory.TrimEnd('/') + '/' + $Name
}

function ConvertFrom-RemoteDirListing {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    # Lines from: cd <dir> && find . -mindepth 1 -maxdepth 1 -exec stat -L -c '%F|%s|%Y|%n' {} +
    # Folders come first, then files; both newest first, as logs are usually read from the latest.
    $entries = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $parts = $line.Split([char[]]@('|'), 4)
        if ($parts.Count -ne 4 -or $parts[1] -notmatch '^\d+$' -or $parts[2] -notmatch '^\d+$' -or -not $parts[3].StartsWith('./')) {
            continue
        }
        $name = $parts[3].Substring(2).TrimEnd()
        if (-not $name) {
            continue
        }
        $entries += [pscustomobject]@{
            Name = $name
            Path = Join-RemotePath -Directory $Directory -Name $name
            IsDirectory = ($parts[0] -eq 'directory')
            Size = [int64]$parts[1]
            Modified = [DateTimeOffset]::FromUnixTimeSeconds([int64]$parts[2]).LocalDateTime
        }
    }

    return @($entries | Sort-Object -Property @{ Expression = 'IsDirectory'; Descending = $true }, @{ Expression = 'Modified'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
}

function Test-TextContent {
    param(
        [byte[]]$Bytes = @()
    )

    # A NUL byte early in the file means it is not a text log (an image, a database, ...).
    $limit = [Math]::Min($Bytes.Length, 8192)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Bytes[$i] -eq 0) {
            return $false
        }
    }
    return $true
}

function Get-ImageRowHashes {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap]$Bitmap
    )

    # One 64-bit fingerprint per pixel row. The right 7% is left out so a scroll bar fading at the edge does
    # not make otherwise identical rows look different; the left edge counts, so rounded corners drawn at the
    # edge of a list are noticed.
    $width = $Bitmap.Width
    $height = $Bitmap.Height
    $data = $Bitmap.LockBits([System.Drawing.Rectangle]::new(0, 0, $width, $height), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $bytes = New-Object byte[] ($stride * $height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    }
    finally {
        $Bitmap.UnlockBits($data)
    }

    $left = 0
    $count = [Math]::Max(4, ([int]($width * 0.93)) * 4)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashes = New-Object long[] $height
        for ($y = 0; $y -lt $height; $y++) {
            $hashes[$y] = [BitConverter]::ToInt64($md5.ComputeHash($bytes, $y * $stride + $left, $count), 0)
        }
    }
    finally {
        $md5.Dispose()
    }
    return , $hashes
}

function Get-StaticBottomRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$RowHashes
    )

    # Rows at the bottom that never change between screens: the navigation bar, a bottom tab bar.
    $height = $RowHashes[0].Length
    $static = [int]($height / 3)
    for ($i = 1; $i -lt $RowHashes.Count; $i++) {
        $previous = $RowHashes[$i - 1]
        $next = $RowHashes[$i]
        $same = 0
        while ($same -lt $static -and $previous[$height - 1 - $same] -eq $next[$height - 1 - $same]) {
            $same++
        }
        $static = [Math]::Min($static, $same)
    }
    return $static
}

function Find-ScrollOffset {
    param(
        [Parameter(Mandatory = $true)]
        [long[]]$Previous,

        [Parameter(Mandatory = $true)]
        [long[]]$Next,

        # Rows from this one down are fixed (navigation bar) and take no part.
        [Parameter(Mandatory = $true)]
        [int]$ContentBottom,

        [int]$MinimumVotes = 8
    )

    # A row that occurs exactly once on the previous screen and again on the next screen tells how far the
    # page moved. Blank rows occur many times and are ignored. The distance most rows agree on wins.
    $positions = @{}
    for ($y = 0; $y -lt $ContentBottom; $y++) {
        $key = $Previous[$y]
        if ($positions.ContainsKey($key)) { $positions[$key] = -1 } else { $positions[$key] = $y }
    }
    $votes = @{}
    $total = 0
    for ($y = 0; $y -lt $ContentBottom; $y++) {
        $key = $Next[$y]
        if ($positions.ContainsKey($key) -and $positions[$key] -gt $y) {
            $distance = $positions[$key] - $y
            if ($votes.ContainsKey($distance)) { $votes[$distance]++ } else { $votes[$distance] = 1 }
            $total++
        }
    }
    if ($total -eq 0) {
        return 0
    }
    $best = $votes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
    if ($best.Value -lt $MinimumVotes -or $best.Value -lt ($total * 0.3)) {
        return 0
    }
    return [int]$best.Key
}

function Get-JoinRow {
    param(
        [Parameter(Mandatory = $true)]
        [long[]]$Previous,

        [Parameter(Mandatory = $true)]
        [long[]]$Next,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        # Rows from this one down are the fixed bottom bar.
        [Parameter(Mandatory = $true)]
        [int]$ContentBottom,

        [int]$Run = 6
    )

    # The row of the previous screen where the next screen takes over: just below the lowest stretch where
    # both screens show the same page rows. Rows under it can carry effects drawn at the edge of a list
    # (Samsung rounds the list's corners there), which are not part of the page.
    for ($row = $ContentBottom - 1; $row - $Offset - $Run -ge 0; $row--) {
        $same = $true
        for ($k = 0; $k -lt $Run; $k++) {
            if ($Previous[$row - $k] -ne $Next[$row - $k - $Offset]) {
                $same = $false
                break
            }
        }
        if ($same) {
            return $row + 1
        }
    }
    return $ContentBottom
}

function Join-ScrollFrames {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Bitmap[]]$Frames,

        # Offsets[i] is how far frame i moved compared with frame i-1; Offsets[0] is unused.
        [Parameter(Mandatory = $true)]
        [int[]]$Offsets,

        # JoinRows[i] is the row of frame i-1 where frame i takes over; JoinRows[0] is unused.
        [Parameter(Mandatory = $true)]
        [int[]]$JoinRows
    )

    # The first screen down to the first join, then from each later screen the rows between its two joins,
    # and the last screen down to its bottom edge (which includes the fixed bottom bar once).
    $width = $Frames[0].Width
    $height = $Frames[0].Height
    $total = $height
    for ($i = 1; $i -lt $Frames.Count; $i++) {
        $total += $Offsets[$i]
    }
    $result = New-Object System.Drawing.Bitmap($width, $total, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($result)
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $pixel = [System.Drawing.GraphicsUnit]::Pixel
        $top = 0
        for ($i = 0; $i -lt $Frames.Count; $i++) {
            $from = if ($i -eq 0) { 0 } else { $JoinRows[$i] - $Offsets[$i] }
            $to = if ($i -eq $Frames.Count - 1) { $height } else { $JoinRows[$i + 1] }
            $rows = $to - $from
            if ($rows -gt 0) {
                $graphics.DrawImage($Frames[$i], [System.Drawing.Rectangle]::new(0, $top, $width, $rows), [System.Drawing.Rectangle]::new(0, $from, $width, $rows), $pixel)
                $top += $rows
            }
        }
    }
    finally {
        $graphics.Dispose()
    }
    return $result
}

function Format-ByteSize {
    param(
        [int64]$Bytes
    )

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N0} KB' -f [Math]::Ceiling($Bytes / 1KB))
    }
    return ([string]$Bytes + ' B')
}

function Format-LogLines {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @()
    )

    # "[time] [CONNECT] ..." and "[time] [DISCONNECT] ..." start their text at different columns, so the
    # boxes drawn after the tag do not line up. Padding every tag to the widest one in the file aligns them.
    $pattern = New-Object System.Text.RegularExpressions.Regex('^(\[[^\]]*\]) (\[[A-Za-z][A-Za-z0-9_]{0,15}\]) ?(.*)$')
    $width = 0
    foreach ($line in $Lines) {
        $match = $pattern.Match($line)
        if ($match.Success -and $match.Groups[2].Length -gt $width) {
            $width = $match.Groups[2].Length
        }
    }
    if ($width -eq 0) {
        return $Lines
    }

    $formatted = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $match = $pattern.Match($line)
        if ($match.Success) {
            $formatted.Add($match.Groups[1].Value + ' ' + $match.Groups[2].Value.PadRight($width) + ' ' + $match.Groups[3].Value)
        }
        else {
            $formatted.Add($line)
        }
    }
    return $formatted.ToArray()
}

function Select-LogLines {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @(),

        [AllowEmptyString()]
        [string]$Filter = ''
    )

    if (-not $Filter) {
        return $Lines
    }
    # A plain loop: logs reach tens of thousands of lines and the pipeline is several times slower.
    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched.Add($line)
        }
    }
    return $matched.ToArray()
}

# ---------------- Installer account ----------------

function Get-InstallerApiHosts {
    # The installer app's servers; the account tool signs in and deregisters against one of them.
    return [ordered]@{
        dev = 'https://oversea.dev.en-plus.cn/EuChargeApp/'
        pre = 'https://oversea.pre.en-plus.cn/EuChargeApp/'
    }
}

function Get-InstallerApiHeaders {
    # The headers the installer app sends with every request.
    return [ordered]@{
        fromApp = 'Installer'
        clientType = 'ANDROID'
        'Accept-Language' = 'en'
        timeZoneId = 'Asia/Shanghai'
        appVersion = '1.1.0'
    }
}

function Get-InstallerServerPoint {
    # The server's public key (an uncompressed P-256 point, 65 bytes) from its certificate for sensitive data,
    # the same certificate the app uses to encrypt the email and password.
    $certificate = @(
        'MIIC5TCCAougAwIBAgIUEHHTgZYI5h2GuNX8XEutOWJlR50wCgYIKoZIzj0EAwIw'
        'gcYxCzAJBgNVBAYTAkNOMRIwEAYDVQQIDAlHYXVuZ2RvbmcxETAPBgNVBAcMCFNo'
        'ZW56aGVuMSUwIwYDVQQKDBxTaGVuemhlbiBFTiBQbHVzIFRlY2ggQ28gTHRkMQsw'
        'CQYDVQQLDAJJVDEzMDEGA1UEAwwqRW5wbHVzIGluc3RhbGxlciBzZW5zaXRpdmUg'
        'ZGF0YSBlbmNyeXB0aW9uMScwJQYJKoZIhvcNAQkBFhhjaGFvLmRlbmdAZW4tcGx1'
        'cy5jb20uY24wIBcNMjYwNjE1MDYyNTUwWhgPMjA2NjA2MTUwNjI1NTBaMIHGMQsw'
        'CQYDVQQGEwJDTjESMBAGA1UECAwJR2F1bmdkb25nMREwDwYDVQQHDAhTaGVuemhl'
        'bjElMCMGA1UECgwcU2hlbnpoZW4gRU4gUGx1cyBUZWNoIENvIEx0ZDELMAkGA1UE'
        'CwwCSVQxMzAxBgNVBAMMKkVucGx1cyBpbnN0YWxsZXIgc2Vuc2l0aXZlIGRhdGEg'
        'ZW5jcnlwdGlvbjEnMCUGCSqGSIb3DQEJARYYY2hhby5kZW5nQGVuLXBsdXMuY29t'
        'LmNuMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsptSiTz9COauaEwfXm3yBv2w'
        'M99iax7uqLM9ADEMLEUSGB9KFGn16KAOS9vKBEuWj6QVZu6OHt2M8BuPqVhd0qNT'
        'MFEwHQYDVR0OBBYEFByMHKshRDRjbaxhf6MYZVc6R1YaMB8GA1UdIwQYMBaAFByM'
        'HKshRDRjbaxhf6MYZVc6R1YaMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID'
        'SAAwRQIhAKnm5x4zNWb2wdSYBLDQEGnpC1n1NQasnZVkX++TPshFAiB54QAQmOtA'
        'PMZb9vUAIZQJKZHX/cGj4e7m7VNbZwFP6g=='
    ) -join ''
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, [Convert]::FromBase64String($certificate))
    try {
        return , $cert.PublicKey.EncodedKeyValue.RawData
    }
    finally {
        $cert.Dispose()
    }
}

function Initialize-InstallerEcc {
    if ('InstallerEcc' -as [type]) { return }
    # The app's encryption: an ephemeral ECDH P-256 key, HKDF-SHA256, then AES-256-GCM.
    # Output: base64(ephemeral public point 65 + IV 12 + ciphertext + tag 16). .NET Framework has no AesGcm,
    # so GCM is built from AES-ECB blocks.
    Add-Type -TypeDefinition @"
using System;
using System.Security.Cryptography;
using System.Text;

public static class InstallerEcc
{
    public static string Encrypt(string data, byte[] serverPoint)
    {
        byte[] plain = Encoding.UTF8.GetBytes(data);
        using (ECDiffieHellmanCng eph = new ECDiffieHellmanCng(256))
        {
            // CNG's HMAC KDF computes HMAC(zero salt, shared secret), which is exactly HKDF-Extract.
            eph.KeyDerivationFunction = ECDiffieHellmanKeyDerivationFunction.Hmac;
            eph.HashAlgorithm = CngAlgorithm.Sha256;
            eph.HmacKey = new byte[32];

            byte[] blob = eph.PublicKey.ToByteArray();
            byte[] ephPoint = new byte[65];
            ephPoint[0] = 4;
            Buffer.BlockCopy(blob, 8, ephPoint, 1, 64);

            byte[] serverBlob = new byte[72];
            BitConverter.GetBytes(0x314B4345).CopyTo(serverBlob, 0);
            BitConverter.GetBytes(32).CopyTo(serverBlob, 4);
            Buffer.BlockCopy(serverPoint, 1, serverBlob, 8, 64);

            byte[] prk;
            using (ECDiffieHellmanPublicKey serverKey = ECDiffieHellmanCngPublicKey.FromByteArray(serverBlob, CngKeyBlobFormat.EccPublicBlob))
            {
                prk = eph.DeriveKeyMaterial(serverKey);
            }

            // HKDF-Expand for one block: info is the ephemeral point.
            byte[] key;
            using (HMACSHA256 hmac = new HMACSHA256(prk))
            {
                byte[] info = new byte[66];
                Buffer.BlockCopy(ephPoint, 0, info, 0, 65);
                info[65] = 1;
                key = hmac.ComputeHash(info);
            }

            byte[] iv = new byte[12];
            using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(iv);
            }
            byte[] sealedData = GcmEncrypt(key, iv, plain, ephPoint);

            byte[] output = new byte[65 + 12 + sealedData.Length];
            Buffer.BlockCopy(ephPoint, 0, output, 0, 65);
            Buffer.BlockCopy(iv, 0, output, 65, 12);
            Buffer.BlockCopy(sealedData, 0, output, 77, sealedData.Length);
            return Convert.ToBase64String(output);
        }
    }

    // Returns ciphertext followed by the 16-byte tag.
    public static byte[] GcmEncrypt(byte[] key, byte[] iv, byte[] plain, byte[] aad)
    {
        using (AesManaged aes = new AesManaged())
        {
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = key;
            using (ICryptoTransform enc = aes.CreateEncryptor())
            {
                byte[] h = Block(enc, new byte[16]);
                byte[] j0 = new byte[16];
                Buffer.BlockCopy(iv, 0, j0, 0, 12);
                j0[15] = 1;

                byte[] counter = (byte[])j0.Clone();
                byte[] cipher = new byte[plain.Length];
                for (int i = 0; i < plain.Length; i += 16)
                {
                    Inc32(counter);
                    byte[] stream = Block(enc, counter);
                    for (int j = 0; j < 16 && i + j < plain.Length; j++)
                    {
                        cipher[i + j] = (byte)(plain[i + j] ^ stream[j]);
                    }
                }

                byte[] s = new byte[16];
                Absorb(s, h, aad);
                Absorb(s, h, cipher);
                byte[] lengths = new byte[16];
                WriteBits(lengths, 0, aad.Length);
                WriteBits(lengths, 8, cipher.Length);
                Absorb(s, h, lengths);

                byte[] tagMask = Block(enc, j0);
                byte[] result = new byte[cipher.Length + 16];
                Buffer.BlockCopy(cipher, 0, result, 0, cipher.Length);
                for (int j = 0; j < 16; j++)
                {
                    result[cipher.Length + j] = (byte)(s[j] ^ tagMask[j]);
                }
                return result;
            }
        }
    }

    static byte[] Block(ICryptoTransform enc, byte[] input)
    {
        byte[] output = new byte[16];
        enc.TransformBlock(input, 0, 16, output, 0);
        return output;
    }

    static void Inc32(byte[] counter)
    {
        for (int i = 15; i >= 12; i--)
        {
            if (++counter[i] != 0) break;
        }
    }

    static void WriteBits(byte[] buffer, int offset, int byteLength)
    {
        ulong bits = (ulong)byteLength * 8;
        for (int i = 7; i >= 0; i--)
        {
            buffer[offset + i] = (byte)bits;
            bits >>= 8;
        }
    }

    // GHASH: 16-byte blocks, the last one padded with zeros; each block is XORed in, then multiplied by H.
    static void Absorb(byte[] s, byte[] h, byte[] data)
    {
        for (int i = 0; i < data.Length; i += 16)
        {
            for (int j = 0; j < 16 && i + j < data.Length; j++)
            {
                s[j] ^= data[i + j];
            }
            byte[] product = Multiply(s, h);
            Buffer.BlockCopy(product, 0, s, 0, 16);
        }
    }

    static byte[] Multiply(byte[] x, byte[] y)
    {
        byte[] z = new byte[16];
        byte[] v = (byte[])y.Clone();
        for (int i = 0; i < 128; i++)
        {
            if ((x[i >> 3] & (0x80 >> (i & 7))) != 0)
            {
                for (int j = 0; j < 16; j++) z[j] ^= v[j];
            }
            bool lsb = (v[15] & 1) != 0;
            for (int j = 15; j > 0; j--)
            {
                v[j] = (byte)((v[j] >> 1) | (v[j - 1] << 7));
            }
            v[0] = (byte)(v[0] >> 1);
            if (lsb) v[0] ^= 0xE1;
        }
        return z;
    }
}
"@
}

function ConvertTo-InstallerCipherText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        # The server's public point; the installer server's own key by default.
        [byte[]]$ServerPoint = $null
    )

    Initialize-InstallerEcc
    if ($null -eq $ServerPoint) { $ServerPoint = Get-InstallerServerPoint }
    return [InstallerEcc]::Encrypt($Text, $ServerPoint)
}

function ConvertFrom-InstallerResponse {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [int]$StatusCode = 200
    )

    # The server answers {"code":2000,"message":"...","data":{...}}; 2000 means success.
    $result = [pscustomobject]@{ Ok = $false; Status = $StatusCode; Code = ''; Message = ''; Token = ''; UserId = ''; Raw = $Text.Trim() }
    $json = $null
    try { $json = $Text | ConvertFrom-Json } catch { }
    if ($json -isnot [pscustomobject]) {
        if ($StatusCode -ne 200) { $result.Code = 'HTTP ' + $StatusCode }
        return $result
    }
    $code = $json.PSObject.Properties['code']
    if ($null -ne $code -and $null -ne $code.Value) { $result.Code = [string]$code.Value }
    elseif ($StatusCode -ne 200) { $result.Code = 'HTTP ' + $StatusCode }
    foreach ($name in 'message', 'msg') {
        $message = $json.PSObject.Properties[$name]
        if ($null -ne $message -and $message.Value) { $result.Message = [string]$message.Value; break }
    }
    $data = $json.PSObject.Properties['data']
    if ($null -ne $data -and $data.Value -is [pscustomobject]) {
        $token = $data.Value.PSObject.Properties['token']
        if ($null -ne $token -and $null -ne $token.Value) { $result.Token = [string]$token.Value }
        $userId = $data.Value.PSObject.Properties['userId']
        if ($null -ne $userId -and $null -ne $userId.Value) { $result.UserId = [string]$userId.Value }
    }
    $result.Ok = ($StatusCode -ge 200 -and $StatusCode -lt 300 -and $result.Code -eq '2000')
    return $result
}

function ConvertFrom-InstallerLogcat {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # The app logs each HTTP response through HttpLog; every line of one response carries the same
    # "HttpLog-Response-<id>". The newest response with a token wins; its userId and email come from the same id.
    $lines = @(($Text -split "`r?`n") -match 'HttpLog-Response-')
    $hit = @($lines -match '"token":\s*"[^"]+"') | Select-Object -Last 1
    if (-not $hit -or $hit -notmatch 'HttpLog-Response-([0-9a-fA-F]+).*"token":\s*"([^"]+)"') {
        return $null
    }
    $id = $Matches[1]
    $found = [pscustomobject]@{ Token = $Matches[2]; UserId = ''; Email = '' }
    $same = @($lines -match ('HttpLog-Response-' + $id + '(?![0-9a-fA-F])'))
    $line = @($same -match '"userId":\s*\d+') | Select-Object -Last 1
    if ($line -and $line -match '"userId":\s*(\d+)') { $found.UserId = $Matches[1] }
    $line = @($same -match '"email":\s*"[^"]+"') | Select-Object -Last 1
    if ($line -and $line -match '"email":\s*"([^"]+)"') { $found.Email = $Matches[1] }
    return $found
}

function Format-TokenPreview {
    param(
        [AllowEmptyString()]
        [string]$Token = ''
    )

    # Results show only the ends of a token; the whole token stays in the token box.
    if ($Token.Length -le 14) { return $Token }
    return $Token.Substring(0, 6) + [char]0x2026 + $Token.Substring($Token.Length - 4)
}

function Protect-DevToolsSecret {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # Encrypted for the current Windows user (DPAPI); other users and other computers cannot read it.
    if (-not $Text) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($bytes)
}

function Unprotect-DevToolsSecret {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )

    # Empty when there is nothing saved or it was saved by another user or on another computer.
    if (-not $Text) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        return ''
    }
}
