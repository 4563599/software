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
    }
}

function Read-DevToolsSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $settings = Get-DevToolsDefaultSettings
    try {
        $saved = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($name in 'RemoteLogPath', 'ExportPath', 'Serial', 'SaveFolder') {
            $property = $saved.PSObject.Properties[$name]
            if ($null -ne $property -and $property.Value -is [string] -and ($name -in @('Serial', 'SaveFolder') -or $property.Value.Trim())) {
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
    $prefix = $Root.TrimEnd('/') + '/'
    $files = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^(\d+)\s+(\d+)\s+(/.+?)\s*$') {
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
