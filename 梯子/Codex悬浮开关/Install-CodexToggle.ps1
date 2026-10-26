[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'CodexToggle'),
    [string]$ExpectedStaticIp = '82.26.250.63',
    [switch]$ValidateOnly,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$expectedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($ExpectedStaticIp, [ref]$expectedAddress)) {
    throw 'ExpectedStaticIp must be an IP address.'
}
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This package requires 64-bit Windows.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler was not found.' }
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$buildDir = Join-Path ([System.IO.Path]::GetTempPath()) ('CodexToggleBuild-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildDir | Out-Null
$runtimeFiles = @('CodexWidget.cs', 'CodexSafety.cs', 'CodexProcesses.ps1', 'CodexToggle.ps1', 'CodexToggle.ico', 'CodexToggle.png')
foreach ($name in $runtimeFiles + @('Test-CodexSafety.cs', 'Test-CodexToggle.ps1', 'network-settings.json')) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Missing package file: ' + $name) }
    Copy-Item -LiteralPath $source -Destination (Join-Path $buildDir $name)
}

function Invoke-Compiler {
    param([string[]]$CompilerArguments)
    & $compiler @CompilerArguments
    if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed.' }
}

$references = @('/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Management.dll', '/reference:System.Web.Extensions.dll')
Invoke-Compiler -CompilerArguments (@('/nologo', '/target:winexe', '/platform:x64', '/optimize+', ('/out:' + (Join-Path $buildDir 'CodexWidget.exe')), ('/win32icon:' + (Join-Path $buildDir 'CodexToggle.ico'))) + $references + @((Join-Path $buildDir 'CodexWidget.cs'), (Join-Path $buildDir 'CodexSafety.cs')))

if ($ValidateOnly) {
    Invoke-Compiler -CompilerArguments (@('/nologo', '/target:exe', '/platform:x64', ('/out:' + (Join-Path $buildDir 'CodexSafety.Tests.exe'))) + $references + @((Join-Path $buildDir 'CodexSafety.cs'), (Join-Path $buildDir 'Test-CodexSafety.cs')))
    & (Join-Path $buildDir 'CodexSafety.Tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Safety confirmation tests failed.' }
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $buildDir 'Test-CodexToggle.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Process selection tests failed.' }
    $selfTest = Start-Process -FilePath (Join-Path $buildDir 'CodexWidget.exe') -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
    if ($selfTest.ExitCode -ne 0) { throw 'Widget main-process detection test failed.' }
    [pscustomobject]@{Mode='ValidationOnly';Result='PASS';BuildDirectory=$buildDir;DesktopAppOpened=$false;DesktopAppClosed=$false} | ConvertTo-Json
    return
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($InstallDir -eq [System.IO.Path]::GetPathRoot($InstallDir).TrimEnd('\') -or $InstallDir -eq $PSScriptRoot.TrimEnd('\')) {
    throw 'Choose a dedicated installation directory, separate from the source package.'
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$backupDir = Join-Path $InstallDir ('backups\install-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$widgetExe = Join-Path $InstallDir 'CodexWidget.exe'
foreach ($name in $runtimeFiles + @('CodexWidget.exe', 'network-settings.json', 'widget-settings.json')) {
    $existing = Join-Path $InstallDir $name
    if (Test-Path -LiteralPath $existing -PathType Leaf) { Copy-Item -LiteralPath $existing -Destination (Join-Path $backupDir $name) }
}
# Replace only the resident widget at this exact installation path.
foreach ($item in @(Get-CimInstance Win32_Process -Filter "Name='CodexWidget.exe'")) {
    if ([string]::Equals([string]$item.ExecutablePath, $widgetExe, [StringComparison]::OrdinalIgnoreCase)) {
        $process = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
        if ($process -and [Math]::Abs(($process.StartTime.ToUniversalTime() - ([datetime]$item.CreationDate).ToUniversalTime()).TotalMilliseconds) -le 3) {
            Stop-Process -InputObject $process -Force
            $process.WaitForExit(5000) | Out-Null
        }
    }
}
foreach ($name in $runtimeFiles + @('CodexWidget.exe')) {
    Copy-Item -LiteralPath (Join-Path $buildDir $name) -Destination (Join-Path $InstallDir $name) -Force
}
$networkFile = Join-Path $InstallDir 'network-settings.json'
if (-not (Test-Path -LiteralPath $networkFile) -or $PSBoundParameters.ContainsKey('ExpectedStaticIp')) {
    @{ExpectedStaticIp=$expectedAddress.ToString()} | ConvertTo-Json | Set-Content -LiteralPath $networkFile -Encoding UTF8
}

$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 开关.lnk'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 悬浮开关.lnk'
$shortcutShell = New-Object -ComObject WScript.Shell
foreach ($linkPath in @($desktopLink, $startupLink)) {
    if (Test-Path -LiteralPath $linkPath) { Copy-Item -LiteralPath $linkPath -Destination (Join-Path $backupDir ([System.IO.Path]::GetFileName($linkPath))) }
    $shortcut = $shortcutShell.CreateShortcut($linkPath)
    $shortcut.TargetPath = $widgetExe
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = (Join-Path $InstallDir 'CodexToggle.ico') + ',0'
    $shortcut.Description = '仅显示悬浮开关；点击后检查静态出口并打开 Codex'
    $shortcut.Save()
}

# Disable the packaged desktop app's own login startup; keep the widget shortcut.
$startupBackups = @()
foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)) {
    $taskIds = @('App')
    try {
        $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
        $manifestTasks = @($manifest.SelectNodes("//*[local-name()='StartupTask']"))
        if ($manifestTasks.Count -gt 0) { $taskIds = @($manifestTasks | ForEach-Object { $_.GetAttribute('TaskId') }) }
    } catch {}
    foreach ($taskId in $taskIds) {
        $key = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\' + $package.PackageFamilyName + '\' + $taskId
        $old = Get-ItemProperty -LiteralPath $key -Name State -ErrorAction SilentlyContinue
        $oldState = $null
        if ($old) { $oldState = $old.State }
        $startupBackups += [pscustomobject]@{RegistryPath=$key;PreviousState=$oldState}
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -LiteralPath $key -Name State -PropertyType DWord -Value 1 -Force | Out-Null
        if ((Get-ItemProperty -LiteralPath $key -Name State).State -ne 1) { throw 'Could not disable Codex desktop login startup.' }
    }
}
$startupBackups | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir 'desktop-startup.before.json') -Encoding UTF8

if (-not $NoLaunch) {
    # An independent interactive task keeps the widget alive after Codex closes.
    $taskName = 'CodexWidget-Install-' + [guid]::NewGuid().ToString('N')
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $action = New-ScheduledTaskAction -Execute $widgetExe -WorkingDirectory $InstallDir
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        $found = @()
        do {
            $found = @(Get-CimInstance Win32_Process -Filter "Name='CodexWidget.exe'" | Where-Object { [string]::Equals([string]$_.ExecutablePath, $widgetExe, [StringComparison]::OrdinalIgnoreCase) })
            if ($found.Count -eq 0) { Start-Sleep -Milliseconds 200 }
        } while ($found.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)
        if ($found.Count -eq 0) { throw 'The floating widget did not start. Run the desktop shortcut to inspect the error.' }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

$result = [pscustomobject]@{Mode='Installed';InstallDirectory=$InstallDir;DesktopShortcut=$desktopLink;WidgetStartupShortcut=$startupLink;NativeDesktopStartup='Disabled where registered';WidgetStarted=(-not $NoLaunch);CodexAutoOpen=$false;BackupDirectory=$backupDir}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir 'installation.json') -Encoding UTF8
$result | ConvertTo-Json
