param(
    [Parameter(Mandatory = $true)]
    [string]$Url
)

# Opens a web address from a note in the default browser and brings the browser to the front.
# The notes backend runs in the background, and Windows keeps background programs from changing the
# foreground window, so a browser opened from here would only flash in the taskbar. While this helper
# shares the input state of the window in front (the notes window the user just clicked), Windows lets it
# bring the browser window forward.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The backend checks the address already; checked again so this file is safe on its own.
$target = $null
if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$target) -or $target.Scheme -notin @('http', 'https') -or $target.UserInfo) {
    exit 2
}

$api = 'TNotesForegroundApi' -as [Type]
if ($null -eq $api) {
    $builder = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('TNotes.Foreground')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    ).DefineDynamicModule('TNotes.Foreground').DefineType(
        'TNotesForegroundApi',
        [System.Reflection.TypeAttributes]'Public, Abstract, Sealed'
    )
    foreach ($signature in @(
        @{ Name = 'GetForegroundWindow'; Library = 'user32.dll'; Returns = [IntPtr]; Parameters = [Type[]]@() },
        @{ Name = 'GetWindowThreadProcessId'; Library = 'user32.dll'; Returns = [uint32]; Parameters = [Type[]]@([IntPtr], [IntPtr]) },
        @{ Name = 'GetCurrentThreadId'; Library = 'kernel32.dll'; Returns = [uint32]; Parameters = [Type[]]@() },
        @{ Name = 'AttachThreadInput'; Library = 'user32.dll'; Returns = [bool]; Parameters = [Type[]]@([uint32], [uint32], [bool]) },
        @{ Name = 'AllowSetForegroundWindow'; Library = 'user32.dll'; Returns = [bool]; Parameters = [Type[]]@([int]) },
        @{ Name = 'SetForegroundWindow'; Library = 'user32.dll'; Returns = [bool]; Parameters = [Type[]]@([IntPtr]) },
        @{ Name = 'IsIconic'; Library = 'user32.dll'; Returns = [bool]; Parameters = [Type[]]@([IntPtr]) },
        @{ Name = 'ShowWindowAsync'; Library = 'user32.dll'; Returns = [bool]; Parameters = [Type[]]@([IntPtr], [int]) }
    )) {
        $method = $builder.DefinePInvokeMethod(
            $signature.Name,
            $signature.Library,
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
            [System.Reflection.CallingConventions]::Standard,
            $signature.Returns,
            $signature.Parameters,
            [System.Runtime.InteropServices.CallingConvention]::Winapi,
            [System.Runtime.InteropServices.CharSet]::Auto
        )
        $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig)
    }
    $api = $builder.CreateType()
}

function Get-DefaultBrowserName {
    # The program registered for https links, e.g. "chrome" for ChromeHTML.
    try {
        $progId = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId
        $command = (Get-ItemProperty -LiteralPath ('Registry::HKEY_CLASSES_ROOT\' + $progId + '\shell\open\command') -ErrorAction Stop).'(default)'
        if ($command -match '^\s*"([^"]+)"' -or $command -match '^\s*(\S+)') {
            return [IO.Path]::GetFileNameWithoutExtension($Matches[1])
        }
    }
    catch {
    }
    return $null
}

$browser = Get-DefaultBrowserName
$foregroundThread = $api::GetWindowThreadProcessId($api::GetForegroundWindow(), [IntPtr]::Zero)
$ownThread = $api::GetCurrentThreadId()
$attached = $false
if ($foregroundThread -ne 0 -and $foregroundThread -ne $ownThread) {
    $attached = $api::AttachThreadInput($ownThread, $foregroundThread, $true)
}
try {
    # Lets the browser activate itself where Windows allows it; the explicit raise below covers the rest.
    [void]$api::AllowSetForegroundWindow(-1)
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\rundll32.exe') -ArgumentList @('url.dll,FileProtocolHandler', $target.AbsoluteUri)
    if ($browser) {
        # The browser's front window is where the new tab opens. The notes window itself runs on Edge, so
        # with Edge as the default browser it is skipped.
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 150
            $window = @(Get-Process -Name $browser -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -notlike 'T Notes*'
            }) | Select-Object -First 1
            if ($null -ne $window -and $attempt -ge 4) {
                if ($api::IsIconic($window.MainWindowHandle)) {
                    [void]$api::ShowWindowAsync($window.MainWindowHandle, 9)
                }
                [void]$api::SetForegroundWindow($window.MainWindowHandle)
                break
            }
        }
    }
    else {
        Start-Sleep -Milliseconds 1500
    }
}
finally {
    if ($attached) {
        [void]$api::AttachThreadInput($ownThread, $foregroundThread, $false)
    }
}
