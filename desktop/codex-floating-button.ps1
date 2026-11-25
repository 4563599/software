$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexFloatingButton', [ref]$createdNew)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    function Add-CodexPInvokeMethod {
        param(
            [Parameter(Mandatory = $true)]
            [System.Reflection.Emit.TypeBuilder]$TypeBuilder,

            [Parameter(Mandatory = $true)]
            [string]$Name,

            [Parameter(Mandatory = $true)]
            [Type]$ReturnType,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [Type[]]$ParameterTypes,

            [string]$Library = 'user32.dll'
        )

        $attributes = [System.Reflection.MethodAttributes]::Public `
            -bor [System.Reflection.MethodAttributes]::Static `
            -bor [System.Reflection.MethodAttributes]::PinvokeImpl
        $method = $TypeBuilder.DefinePInvokeMethod(
            $Name,
            $Library,
            $attributes,
            [System.Reflection.CallingConventions]::Standard,
            $ReturnType,
            $ParameterTypes,
            [System.Runtime.InteropServices.CallingConvention]::Winapi,
            [System.Runtime.InteropServices.CharSet]::Auto
        )
        $method.SetImplementationFlags(
            $method.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig
        )
    }

    if ($null -eq ('CodexWindowApi' -as [Type])) {
        $assemblyName = New-Object System.Reflection.AssemblyName('CodexFloatingButton.NativeMethods')
        $assemblyBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            $assemblyName,
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $moduleBuilder = $assemblyBuilder.DefineDynamicModule('CodexFloatingButton.NativeMethods')
        $typeAttributes = [System.Reflection.TypeAttributes]::Public `
            -bor [System.Reflection.TypeAttributes]::Abstract `
            -bor [System.Reflection.TypeAttributes]::Sealed
        $typeBuilder = $moduleBuilder.DefineType('CodexWindowApi', $typeAttributes)

        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'ShowWindowAsync' -ReturnType ([bool]) -ParameterTypes @([IntPtr], [int])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'SetForegroundWindow' -ReturnType ([bool]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'IsIconic' -ReturnType ([bool]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'IsWindowVisible' -ReturnType ([bool]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'FindWindow' -ReturnType ([IntPtr]) -ParameterTypes @([string], [string])
        # When the message being handled was posted, in the same milliseconds as [Environment]::TickCount.
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetMessageTime' -ReturnType ([int]) -ParameterTypes @()
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'PostMessage' -ReturnType ([bool]) -ParameterTypes @([IntPtr], [uint32], [IntPtr], [IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetWindowThreadProcessId' -ReturnType ([int]) -ParameterTypes @([IntPtr], [int].MakeByRefType())
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetWindowRect' -ReturnType ([bool]) -ParameterTypes @([IntPtr], [int[]])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetWindowLong' -ReturnType ([int]) -ParameterTypes @([IntPtr], [int])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetWindow' -ReturnType ([IntPtr]) -ParameterTypes @([IntPtr], [uint32])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'SetWindowLong' -ReturnType ([int]) -ParameterTypes @([IntPtr], [int], [int])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'SetWindowPos' -ReturnType ([bool]) -ParameterTypes @(
            [IntPtr],
            [IntPtr],
            [int],
            [int],
            [int],
            [int],
            [uint32]
        )
        # Per-pixel transparency for the bar. POINT and SIZE are two 32-bit integers, passed here as one
        # 64-bit value by reference; BLENDFUNCTION is four bytes, passed as one 32-bit value by reference.
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetDC' -ReturnType ([IntPtr]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'ReleaseDC' -ReturnType ([int]) -ParameterTypes @([IntPtr], [IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'UpdateLayeredWindow' -ReturnType ([bool]) -ParameterTypes @(
            [IntPtr],
            [IntPtr],
            [IntPtr],
            [Int64].MakeByRefType(),
            [IntPtr],
            [Int64].MakeByRefType(),
            [int],
            [int].MakeByRefType(),
            [int]
        )
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Library 'gdi32.dll' -Name 'CreateCompatibleDC' -ReturnType ([IntPtr]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Library 'gdi32.dll' -Name 'SelectObject' -ReturnType ([IntPtr]) -ParameterTypes @([IntPtr], [IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Library 'gdi32.dll' -Name 'DeleteObject' -ReturnType ([bool]) -ParameterTypes @([IntPtr])
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Library 'gdi32.dll' -Name 'DeleteDC' -ReturnType ([bool]) -ParameterTypes @([IntPtr])

        [void]$typeBuilder.CreateType()
    }

    $projectRoot = $PSScriptRoot
    . (Join-Path $projectRoot 'codex-floating-button-core.ps1')
    if (-not $createdNew) {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -Property ProcessId, SessionId, CommandLine)
        $revealed = Restore-FloatingToolbarWindow -NativeApi ([CodexWindowApi]) -ScriptPath $PSCommandPath -Processes $processes `
            -WorkingAreas @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea }) `
            -PrimaryWorkingArea ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea)
        if ($revealed) { exit 0 }
        Write-Warning 'The toolbar is already running but its window could not be revealed.'
        exit 1
    }
    . (Join-Path $projectRoot 'codex-network-check.ps1')
    . (Join-Path $projectRoot 'ai-process-cleanup.ps1')

    $notesWindowScript = Join-Path $projectRoot 't-notes\window.ps1'
    if (Test-Path -LiteralPath $notesWindowScript) {
        . $notesWindowScript
    }

    function Invoke-TNotes {
        param(
            # Screen rectangle of the T button, "x,y,width,height"; the notes window opens directly above it.
            [string]$Anchor = ''
        )

        if (-not (Get-Command -Name 'Open-TNotes' -CommandType Function -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show('T Notes is not installed.', 'T Notes') | Out-Null
            return
        }
        # Open-TNotes raises the existing window or starts exactly one; repeated clicks never add a window.
        # With the window already in front, the click tucks it away instead.
        $result = ''
        try { $result = [string]@(Open-TNotes -Toggle -Anchor $Anchor -InProcess)[-1] }
        catch {
            [System.Windows.Forms.MessageBox]::Show('T Notes backend could not start. Your unsaved text is still in the current window.', 'T Notes') | Out-Null
            return
        }
        # A window that is still starting takes a few seconds; the card says so until it shows.
        if ($result -eq 'Started' -or $result -eq 'Starting') {
            # The launcher ends once the window is there and placed above the button; the window is then looked up
            # for this vault's browser profile, which also lets the next click find it at once.
            Show-ToolbarProgress -Text $progressText.Notes -ButtonIndex 2 -Done {
                if (Test-TNotesLaunchPending) { return 'wait' }
                if ((Get-TNotesWindowHandle) -ne [IntPtr]::Zero) { return 'done' }
                return 'gone'
            }
        }
    }

    # The tool window keeps its text in a UTF-8 file; its title is how an open window is found again.
    $devToolsScript = Join-Path $projectRoot 'dev-tools\DevTools.ps1'
    $devToolsText = $null
    try {
        $devToolsText = [IO.File]::ReadAllText((Join-Path $projectRoot 'dev-tools\text.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
    }

    function Invoke-DevTools {
        param(
            # Screen rectangle of the tool button, "x,y,width,height"; the tool window opens directly above it.
            [string]$Anchor = ''
        )

        if ($null -eq $devToolsText -or -not (Test-Path -LiteralPath $devToolsScript)) {
            [System.Windows.Forms.MessageBox]::Show('Dev tools are not installed.', 'Dev Tools') | Out-Null
            return
        }

        # Like T: one window. A click raises it above the button, or tucks it away when it is already in front.
        # A window that is still being built (not showing yet) belongs to a start in progress.
        $handle = Find-ToolbarWindow -Title ([string]$devToolsText.Title)
        if ($handle -ne [IntPtr]::Zero -and (Get-Command -Name 'Get-TNotesWindowApi' -CommandType Function -ErrorAction SilentlyContinue)) {
            $ownerId = 0
            [void][CodexWindowApi]::GetWindowThreadProcessId($handle, [ref]$ownerId)
            $owner = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
            if ($null -ne $owner -and $owner.ProcessName -eq 'powershell') {
                $api = Get-TNotesWindowApi
                if (-not $api::IsIconic($handle) -and $api::GetForegroundWindow() -eq $handle) {
                    [void]$api::ShowWindowAsync($handle, 6)
                    return
                }
                # Same raising as the notes window, including the fallback when Windows refuses the focus change.
                Show-TNotesWindow -Handle $handle
                $parts = @(ConvertFrom-TNotesAnchor -Anchor $Anchor)
                $rectangle = New-Object int[] 4
                if ($parts.Count -eq 4 -and $api::GetWindowRect($handle, $rectangle)) {
                    $area = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($parts[0], $parts[1])).WorkingArea
                    $location = Get-TNotesAnchoredLocation -Anchor $parts -Width ($rectangle[2] - $rectangle[0]) -Height ($rectangle[3] - $rectangle[1]) -WorkingArea $area
                    # SWP_NOSIZE | SWP_NOZORDER
                    [void]$api::SetWindowPos($handle, [IntPtr]::Zero, $location[0], $location[1], 0, 0, 0x0005)
                }
                return
            }
        }

        # Starting the tool window takes one to a few seconds. The card says so until it shows, and clicks meanwhile
        # do not start a second copy.
        $launch = $devToolsLaunch.Process
        if ($null -eq $launch -or $launch.HasExited) {
            if ($null -ne $launch) { $launch.Dispose() }
            $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $devToolsScript + '" -Anchor "' + $Anchor + '"'
            $devToolsLaunch.Process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
        }
        Show-ToolbarProgress -Text $progressText.DevTools -ButtonIndex 3 -Done {
            if ((Find-ToolbarWindow -Title ([string]$devToolsText.Title)) -ne [IntPtr]::Zero) { return 'done' }
            if (-not $devToolsLaunch.Process.HasExited) { return 'wait' }
            return 'gone'
        }
    }
    $devToolsLaunch = [pscustomobject]@{ Process = $null }

    function Get-AiRelatedProcessIds {
        param([object[]]$Processes)
        return @(Select-AiCleanupProcesses -Processes $Processes -ProtectedProcessIds @($PID) | ForEach-Object ProcessId)
    }

    function Invoke-AiAppsShutdown {
        $confirmTitle = (-join ([char[]](0x5F7B, 0x5E95, 0x5173, 0x95ED, 0x0020, 0x0043, 0x006F, 0x0064, 0x0065, 0x0078, 0x0020, 0x002F, 0x0020, 0x0043, 0x0068, 0x0061, 0x0074, 0x0047, 0x0050, 0x0054, 0x0020, 0x002F, 0x0020, 0x0043, 0x006C, 0x0061, 0x0075, 0x0064, 0x0065)))
        $confirmMessage = (-join ([char[]](0x5C06, 0x5173, 0x95ED, 0x0020, 0x0043, 0x006F, 0x0064, 0x0065, 0x0078, 0x3001, 0x0043, 0x0068, 0x0061, 0x0074, 0x0047, 0x0050, 0x0054, 0x3001, 0x0043, 0x006C, 0x0061, 0x0075, 0x0064, 0x0065, 0x0020, 0x53CA, 0x786E, 0x8BA4, 0x5F52, 0x5C5E, 0x5B83, 0x4EEC, 0x7684, 0x540E, 0x53F0, 0x8FDB, 0x7A0B, 0x3002))) +
            [Environment]::NewLine + (-join ([char[]](0x672A, 0x4FDD, 0x5B58, 0x7684, 0x5BF9, 0x8BDD, 0x548C, 0x4EFB, 0x52A1, 0x72B6, 0x6001, 0x53EF, 0x80FD, 0x4E22, 0x5931, 0x3002))) +
            [Environment]::NewLine + (-join ([char[]](0x9700, 0x8981, 0x7BA1, 0x7406, 0x5458, 0x6388, 0x6743, 0xFF1B, 0x60AC, 0x6D6E, 0x680F, 0x548C, 0x0020, 0x0054, 0x0020, 0x8BB0, 0x5F55, 0x5DE5, 0x5177, 0x4F1A, 0x4FDD, 0x7559, 0x3002)))
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $form, $confirmMessage, $confirmTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $form.UseWaitCursor = $true
        Show-ToolbarProgress -Text $progressText.CloseAi -ButtonIndex 0
        try {
            $worker = Join-Path $projectRoot 'ai-process-cleanup-worker.ps1'
            if (-not (Test-Path -LiteralPath $worker)) { throw 'Cleanup worker is missing.' }
            $resultFile = Join-Path $projectRoot ('ai-cleanup-result-' + [guid]::NewGuid().ToString('N') + '.json')
            $arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' +
                $worker + '" -Mode Clean -ResultPath "' + $resultFile + '" -ProtectedProcessId ' + $PID
            $workerProcess = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
            Wait-ToolbarProcess -Process $workerProcess
            $workerProcess.Dispose()
            Hide-ToolbarProgress
            if (-not (Test-Path -LiteralPath $resultFile)) { throw 'Cleanup did not return a verified result.' }
            $result = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json
            if ($result.Status -eq 'Complete') {
                $message = (-join ([char[]](0x5DF2, 0x5173, 0x95ED, 0x0020))) + $result.ClosedCount + (-join ([char[]](0x0020, 0x4E2A, 0x76F8, 0x5173, 0x8FDB, 0x7A0B, 0xFF0C, 0x5E76, 0x5B8C, 0x6210, 0x591A, 0x8F6E, 0x590D, 0x67E5, 0x3002))) +
                    [Environment]::NewLine + (-join ([char[]](0x60AC, 0x6D6E, 0x680F, 0x548C, 0x0020, 0x0054, 0x0020, 0x8BB0, 0x5F55, 0x5DE5, 0x5177, 0x4FDD, 0x6301, 0x8FD0, 0x884C, 0x3002)))
                $icon = [System.Windows.Forms.MessageBoxIcon]::Information
            }
            elseif ($result.Status -eq 'Partial') {
                $message = (-join ([char[]](0x5DF2, 0x5173, 0x95ED, 0x0020))) + $result.ClosedCount + (-join ([char[]](0x0020, 0x4E2A, 0x8FDB, 0x7A0B, 0xFF0C, 0x4F46, 0x4ECD, 0x6709, 0x8FDB, 0x7A0B, 0x6216, 0x670D, 0x52A1, 0x672A, 0x80FD, 0x5173, 0x95ED, 0x3002)))
                foreach ($remaining in @($result.Remaining | Select-Object -First 12)) {
                    $message += [Environment]::NewLine + $remaining.Name + ' (PID ' + $remaining.ProcessId + ')'
                }
                $message += [Environment]::NewLine + (-join ([char[]](0x672C, 0x6B21, 0x672A, 0x786E, 0x8BA4, 0x5168, 0x90E8, 0x6E05, 0x7406, 0x5B8C, 0x6210, 0xFF0C, 0x7ED3, 0x679C, 0x6587, 0x4EF6, 0xFF1A))) + $resultFile
                $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
            }
            else { throw 'Cleanup verification failed.' }
            [System.Windows.Forms.MessageBox]::Show($form,$message,$confirmTitle,[System.Windows.Forms.MessageBoxButtons]::OK,$icon) | Out-Null
        }
        catch {
            Hide-ToolbarProgress
            $message = (-join ([char[]](0x7BA1, 0x7406, 0x5458, 0x6388, 0x6743, 0x5DF2, 0x53D6, 0x6D88, 0xFF0C, 0x6216, 0x6E05, 0x7406, 0x68C0, 0x67E5, 0x672A, 0x5B8C, 0x6210, 0x3002, 0x672A, 0x786E, 0x8BA4, 0x5168, 0x90E8, 0x8FDB, 0x7A0B, 0x5DF2, 0x5173, 0x95ED, 0x3002)))
            [System.Windows.Forms.MessageBox]::Show($form,$message,$confirmTitle,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        finally {
            Hide-ToolbarProgress
            $form.UseWaitCursor = $false
        }
    }

    function Invoke-AndroidStudioShutdown {
        $closeText = -join ([char[]](0x5173, 0x95ED))
        $confirmTitle = $closeText + ' Android Studio'
        $confirmMessage = (-join ([char[]](0x5C06, 0x5F3A, 0x5236, 0x5173, 0x95ED))) +
            ' Android Studio' + [char]0x3001 + 'Gradle' + [char]0x3001 +
            (-join ([char[]](0x6A21, 0x62DF, 0x5668, 0x548C))) + ' ADB' + [char]0x3002 +
            [Environment]::NewLine +
            (-join ([char[]](0x672A, 0x4FDD, 0x5B58, 0x7684, 0x4FEE, 0x6539, 0x53EF, 0x80FD, 0x4E22, 0x5931))) + [char]0x3002

        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $form,
            $confirmMessage,
            $confirmTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        Show-ToolbarProgress -Text $progressText.CloseStudio -ButtonIndex 1
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $processIds = @(Select-AndroidStudioRelatedProcessIds -Processes $processes |
            Where-Object { $_ -ne $PID })
        $closedCount = 0

        foreach ($processId in $processIds) {
            try {
                Stop-Process -Id $processId -Force -ErrorAction Stop
            }
            catch {
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        $remainingIds = @($processIds | Where-Object {
            $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
        })
        $elevationCancelled = $false
        if ($remainingIds.Count -gt 0) {
            $taskKillArguments = Get-AndroidStudioTaskKillArguments -ProcessIds $remainingIds
            try {
                $killer = Start-Process `
                    -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') `
                    -ArgumentList $taskKillArguments `
                    -Verb RunAs `
                    -WindowStyle Hidden `
                    -PassThru
                Wait-ToolbarProcess -Process $killer
                $killer.Dispose()
            }
            catch {
                $elevationCancelled = $true
            }
        }

        Start-Sleep -Milliseconds 300
        Hide-ToolbarProgress
        $remainingIds = @($processIds | Where-Object {
            $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
        })
        $closedCount = $processIds.Count - $remainingIds.Count
        $resultIcon = [System.Windows.Forms.MessageBoxIcon]::Information

        if ($processIds.Count -eq 0) {
            $resultMessage = (-join ([char[]](0x6CA1, 0x6709, 0x53D1, 0x73B0, 0x6B63, 0x5728, 0x8FD0, 0x884C, 0x7684))) +
                ' Android Studio ' + (-join ([char[]](0x76F8, 0x5173, 0x8FDB, 0x7A0B))) + [char]0x3002
        }
        elseif ($remainingIds.Count -gt 0) {
            $resultIcon = [System.Windows.Forms.MessageBoxIcon]::Warning
            if ($elevationCancelled) {
                $resultMessage = (-join ([char[]](0x672A, 0x83B7, 0x5F97, 0x7BA1, 0x7406, 0x5458, 0x6743, 0x9650))) + [char]0x3002
            }
            else {
                $resultMessage = ''
            }
            $resultMessage += (-join ([char[]](0x4ECD, 0x6709))) + ' ' + $remainingIds.Count + ' ' +
                (-join ([char[]](0x4E2A, 0x8FDB, 0x7A0B, 0x672A, 0x5173, 0x95ED))) + [char]0x3002
        }
        else {
            $resultMessage = (-join ([char[]](0x5DF2, 0x5173, 0x95ED))) + ' ' + $closedCount + ' ' +
                (-join ([char[]](0x4E2A, 0x76F8, 0x5173, 0x8FDB, 0x7A0B))) + [char]0x3002
        }

        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $resultMessage,
            $confirmTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $resultIcon
        ) | Out-Null
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $imagePath = Join-Path $projectRoot 'icons\codex-c-1024.png'
    if (-not (Test-Path -LiteralPath $imagePath)) {
        throw "Icon image not found: $imagePath"
    }

    # One shape and size for all buttons; only the colour and the letter differ.
    # The corner radius matches the C artwork (22% of its size) so all outlines are identical.
    $barLayout = [pscustomobject]@{ ButtonSize = 52; Gap = 8; Margin = 8; Radius = 11 }

    # Scale the C artwork once; every repaint then copies it unscaled.
    $codexSource = [System.Drawing.Image]::FromFile($imagePath)
    $codexImage = New-Object System.Drawing.Bitmap($barLayout.ButtonSize, $barLayout.ButtonSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $codexGraphics = [System.Drawing.Graphics]::FromImage($codexImage)
    $codexAttributes = New-Object System.Drawing.Imaging.ImageAttributes
    try {
        $codexGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $codexGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        # Without this wrap mode the scaler blends the edge rows with transparent black and leaves a dark rim.
        $codexAttributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $codexGraphics.DrawImage(
            $codexSource,
            [System.Drawing.Rectangle]::new(0, 0, $barLayout.ButtonSize, $barLayout.ButtonSize),
            0, 0, $codexSource.Width, $codexSource.Height,
            [System.Drawing.GraphicsUnit]::Pixel,
            $codexAttributes
        )
    }
    finally {
        $codexAttributes.Dispose()
        $codexGraphics.Dispose()
        $codexSource.Dispose()
    }

    $codexToolTipText = (-join ([char[]](0x5F7B, 0x5E95, 0x5173, 0x95ED))) + ' Codex / ChatGPT / Claude'
    $studioToolTipText = (-join ([char[]](0x5F3A, 0x5236, 0x5173, 0x95ED))) + ' Android Studio'
    $notesToolTipText = (-join ([char[]](0x6253, 0x5F00))) + ' / ' + (-join ([char[]](0x6536, 0x8D77))) + ' T ' + (-join ([char[]](0x7B14, 0x8BB0)))

    $devToolsToolTipText = if ($null -ne $devToolsText) { [string]$devToolsText.ToolbarTip } else { 'Dev tools' }
    # A wrench from the Windows icon font; plain letters stand in where that font is missing.
    $hasIconFont = @([System.Drawing.FontFamily]::Families | Where-Object { $_.Name -eq 'Segoe MDL2 Assets' }).Count -gt 0
    $devToolsLabel = if ($hasIconFont) { @([string][char]0xE90F, 'Segoe MDL2 Assets', 24) } else { @('Dev', 'Segoe UI', 17) }

    $barButtons = @(
        [pscustomobject]@{
            Image = $codexImage; Text = ''; FontName = 'Segoe UI'; FontSize = 0
            From = [System.Drawing.Color]::Empty; To = [System.Drawing.Color]::Empty
            ToolTip = $codexToolTipText; Action = { Invoke-AiAppsShutdown }
        },
        [pscustomobject]@{
            Image = $null; Text = 'AS'; FontName = 'Segoe UI'; FontSize = 22
            From = [System.Drawing.Color]::FromArgb(20, 142, 226); To = [System.Drawing.Color]::FromArgb(0, 108, 188)
            ToolTip = $studioToolTipText; Action = { Invoke-AndroidStudioShutdown }
        },
        [pscustomobject]@{
            Image = $null; Text = 'T'; FontName = 'Segoe UI'; FontSize = 31
            From = [System.Drawing.Color]::FromArgb(66, 133, 244); To = [System.Drawing.Color]::FromArgb(37, 99, 235)
            ToolTip = $notesToolTipText; Action = { param($anchor) Invoke-TNotes -Anchor $anchor }
        },
        [pscustomobject]@{
            Image = $null; Text = $devToolsLabel[0]; FontName = $devToolsLabel[1]; FontSize = $devToolsLabel[2]
            From = [System.Drawing.Color]::FromArgb(59, 130, 246); To = [System.Drawing.Color]::FromArgb(29, 78, 216)
            ToolTip = $devToolsToolTipText; Action = { param($anchor) Invoke-DevTools -Anchor $anchor }
        }
    )
    $barState = [pscustomobject]@{ Hover = -1; Pressed = -1; Busy = $false; BusyEnded = $null; Painted = $false; Ticks = 0; Failures = 0; LastTopMost = $true }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CodexFloatingButton'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ClientSize = New-Object System.Drawing.Size(
        (2 * $barLayout.Margin + $barButtons.Count * $barLayout.ButtonSize + ($barButtons.Count - 1) * $barLayout.Gap),
        (2 * $barLayout.Margin + $barLayout.ButtonSize)
    )

    # A layered window takes its pixels, including their transparency, from Update-ToolbarSurface.
    # A colour key cannot do this: smoothed edges blend with the key colour and show as a fringe.
    $GWL_EXSTYLE = -20
    $WS_EX_TOOLWINDOW = 0x00000080
    $WS_EX_LAYERED = 0x00080000
    $WS_EX_NOACTIVATE = 0x08000000
    $formHandle = $form.Handle
    $extendedStyle = [CodexWindowApi]::GetWindowLong($formHandle, $GWL_EXSTYLE)
    [CodexWindowApi]::SetWindowLong(
        $formHandle,
        $GWL_EXSTYLE,
        $extendedStyle -bor $WS_EX_TOOLWINDOW -bor $WS_EX_LAYERED -bor $WS_EX_NOACTIVATE
    ) | Out-Null

    function New-ToolbarRoundedPath {
        param(
            [single]$X,
            [single]$Y,
            [single]$Size,
            [single]$Radius,
            # A height of its own makes a rounded rectangle instead of a square.
            [single]$Height = 0
        )

        $tall = if ($Height -gt 0) { $Height } else { $Size }
        $diameter = 2 * $Radius
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
        $path.AddArc($X + $Size - $diameter, $Y, $diameter, $diameter, 270, 90)
        $path.AddArc($X + $Size - $diameter, $Y + $tall - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc($X, $Y + $tall - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        return $path
    }

    # Hands a picture with transparency to a layered window (the bar, the progress card) and disposes the picture.
    function Set-ToolbarLayeredBitmap {
        param(
            [IntPtr]$Handle,
            [System.Drawing.Bitmap]$Bitmap
        )

        $screenDc = [CodexWindowApi]::GetDC([IntPtr]::Zero)
        $memoryDc = [CodexWindowApi]::CreateCompatibleDC($screenDc)
        # A transparent background makes GDI+ hand over the premultiplied pixels the layered window expects.
        $surface = $Bitmap.GetHbitmap([System.Drawing.Color]::FromArgb(0))
        $previousObject = [CodexWindowApi]::SelectObject($memoryDc, $surface)
        try {
            [Int64]$surfaceSize = ([Int64]$Bitmap.Height -shl 32) -bor [Int64]$Bitmap.Width
            [Int64]$sourcePoint = 0
            # AC_SRC_OVER, no flags, constant alpha 255, AC_SRC_ALPHA.
            [int]$blend = 0x01FF0000
            $ULW_ALPHA = 2
            return [bool][CodexWindowApi]::UpdateLayeredWindow($Handle, $screenDc, [IntPtr]::Zero, [ref]$surfaceSize, $memoryDc, [ref]$sourcePoint, 0, [ref]$blend, $ULW_ALPHA)
        }
        finally {
            [CodexWindowApi]::SelectObject($memoryDc, $previousObject) | Out-Null
            [CodexWindowApi]::DeleteObject($surface) | Out-Null
            [CodexWindowApi]::DeleteDC($memoryDc) | Out-Null
            [CodexWindowApi]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null
            $Bitmap.Dispose()
        }
    }

    function Write-ToolbarDiagnostic {
        param(
            [string]$Text
        )

        # A small private log in the user's data folder, capped in size; it never holds notes or other user data.
        try {
            $directory = Join-Path $env:LOCALAPPDATA 'TNotes'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $file = Join-Path $directory 'toolbar-diagnostic.log'
            if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -lt 65536) {
                Add-Content -LiteralPath $file -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Text) -Encoding ASCII
            }
        }
        catch {
        }
    }

    function Update-ToolbarSurface {
        if ($form.IsDisposed -or -not $form.IsHandleCreated) {
            return
        }

        $size = $barLayout.ButtonSize
        $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

            for ($index = 0; $index -lt $barButtons.Count; $index++) {
                $button = $barButtons[$index]
                $left = $barLayout.Margin + $index * ($size + $barLayout.Gap)
                $top = $barLayout.Margin

                # A soft shadow keeps the buttons readable on light and dark backgrounds alike.
                foreach ($layer in @(@(3, 9), @(2, 16), @(1, 26))) {
                    $grow = $layer[0]
                    $shadowPath = New-ToolbarRoundedPath -X ($left - $grow) -Y ($top - $grow + 2) -Size ($size + 2 * $grow) -Radius ($barLayout.Radius + $grow)
                    $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($layer[1], 0, 0, 0))
                    try {
                        $graphics.FillPath($shadowBrush, $shadowPath)
                    }
                    finally {
                        $shadowBrush.Dispose()
                        $shadowPath.Dispose()
                    }
                }

                $bodyPath = New-ToolbarRoundedPath -X $left -Y $top -Size $size -Radius $barLayout.Radius
                try {
                    if ($null -ne $button.Image) {
                        $graphics.DrawImageUnscaled($button.Image, $left, $top)
                    }
                    else {
                        $bounds = [System.Drawing.RectangleF]::new($left, $top, $size, $size)
                        $bodyBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bounds, $button.From, $button.To, [single]45)
                        # The icon font has no bold face; letters are drawn bold.
                        $fontStyle = if ($button.FontName -eq 'Segoe UI') { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
                        $font = New-Object System.Drawing.Font($button.FontName, $button.FontSize, $fontStyle, [System.Drawing.GraphicsUnit]::Pixel)
                        $textShadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
                        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
                        $textFormat = New-Object System.Drawing.StringFormat
                        try {
                            $textFormat.Alignment = [System.Drawing.StringAlignment]::Center
                            $textFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
                            $graphics.FillPath($bodyBrush, $bodyPath)
                            $graphics.DrawString($button.Text, $font, $textShadowBrush, [System.Drawing.RectangleF]::new($left + 1, $top + 2, $size, $size), $textFormat)
                            $graphics.DrawString($button.Text, $font, $textBrush, [System.Drawing.RectangleF]::new($left, $top + 1, $size, $size), $textFormat)
                        }
                        finally {
                            $textFormat.Dispose()
                            $textBrush.Dispose()
                            $textShadowBrush.Dispose()
                            $font.Dispose()
                            $bodyBrush.Dispose()
                        }
                    }

                    $feedback = $null
                    if ($barState.Pressed -eq $index) {
                        $feedback = [System.Drawing.Color]::FromArgb(46, 0, 0, 0)
                    }
                    elseif ($barState.Hover -eq $index) {
                        $feedback = [System.Drawing.Color]::FromArgb(38, 255, 255, 255)
                    }
                    if ($null -ne $feedback) {
                        $feedbackBrush = New-Object System.Drawing.SolidBrush($feedback)
                        try {
                            $graphics.FillPath($feedbackBrush, $bodyPath)
                        }
                        finally {
                            $feedbackBrush.Dispose()
                        }
                    }
                }
                finally {
                    $bodyPath.Dispose()
                }
            }
        }
        finally {
            $graphics.Dispose()
        }

        $barState.Painted = Set-ToolbarLayeredBitmap -Handle $form.Handle -Bitmap $bitmap

        if (-not $barState.Painted) {
            # The timer below keeps retrying; the first few failures are written down so they can be traced.
            $barState.Failures++
            if ($barState.Failures -le 3) {
                Write-ToolbarDiagnostic 'The bar could not be drawn; retrying.'
            }
        }
        elseif ($barState.Failures -gt 0) {
            Write-ToolbarDiagnostic ('The bar is drawn again after ' + $barState.Failures + ' failed attempts.')
            $barState.Failures = 0
        }
    }

    $HWND_TOPMOST = [IntPtr](-1)
    $SWP_NOSIZE = 0x0001
    $SWP_NOMOVE = 0x0002
    $SWP_NOACTIVATE = 0x0010
    $SWP_SHOWWINDOW = 0x0040
    $topMostFlags = [uint32](
        $SWP_NOSIZE -bor
        $SWP_NOMOVE -bor
        $SWP_NOACTIVATE -bor
        $SWP_SHOWWINDOW
    )
    $GW_OWNER = 4
    $keepTopMost = {
        if ($form.IsDisposed -or -not $form.IsHandleCreated) {
            return
        }

        $wasTopMost = ([CodexWindowApi]::GetWindowLong($form.Handle, $GWL_EXSTYLE) -band 0x00000008) -ne 0
        $form.TopMost = $true
        # A bar kept out of the taskbar has a hidden owner window. Once the bar has dropped out of the
        # always-on-top group (seen 2026-11-17, behind a maximised Android Studio), Windows accepts but
        # ignores HWND_TOPMOST for the bar alone; raising the owner first makes it take effect again.
        $owner = [CodexWindowApi]::GetWindow($form.Handle, $GW_OWNER)
        if ($owner -ne [IntPtr]::Zero) {
            [CodexWindowApi]::SetWindowPos($owner, $HWND_TOPMOST, 0, 0, 0, 0, [uint32]($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE)) | Out-Null
        }
        [CodexWindowApi]::SetWindowPos(
            $form.Handle,
            $HWND_TOPMOST,
            0,
            0,
            0,
            0,
            $topMostFlags
        ) | Out-Null
        if (-not $wasTopMost -and $form.Visible) {
            $isTopMost = ([CodexWindowApi]::GetWindowLong($form.Handle, $GWL_EXSTYLE) -band 0x00000008) -ne 0
            # One line when it happens, and one when it works again; not one every 0.75 seconds while it fails.
            if ($barState.LastTopMost -or $isTopMost) {
                Write-ToolbarDiagnostic ('The bar was not on top; restoring it ' + $(if ($isTopMost) { 'worked.' } else { 'failed.' }))
            }
            $barState.LastTopMost = $isTopMost
        }
        else {
            $barState.LastTopMost = $true
        }
    }

    $topMostTimer = New-Object System.Windows.Forms.Timer
    $topMostTimer.Interval = 750
    $topMostTimer.Add_Tick({
        & $keepTopMost
        # A layered window shows only what was last handed to it. If that never worked, or was lost (for
        # example while the desktop was still starting at sign-in), the bar would stay invisible for good.
        # So hand the picture over again at once while it is missing, and every few seconds otherwise.
        $barState.Ticks++
        if (-not $barState.Painted -or ($barState.Ticks % 4) -eq 0) {
            Update-ToolbarSurface
        }
    })
    $form.Add_Shown({
        & $keepTopMost
        $topMostTimer.Start()
    })
    $form.Add_Deactivate({
        & $keepTopMost
    })

    # A small card above a button while its work takes a moment: a window that is still starting, or programs being
    # closed. A blue ring turns beside the text. The card never takes the focus and lets clicks through; it goes away
    # when the work is done. A window that has not appeared within the time limit turns it into a short red message.
    $progressText = [pscustomobject]@{
        Notes = (-join ([char[]](0x6B63, 0x5728, 0x6253, 0x5F00))) + ' T ' + (-join ([char[]](0x7B14, 0x8BB0, 0x2026)))
        DevTools = (-join ([char[]](0x6B63, 0x5728, 0x6253, 0x5F00))) + $(if ($null -ne $devToolsText) { [string]$devToolsText.Title } else { 'Dev tools' }) + [char]0x2026
        CloseAi = (-join ([char[]](0x6B63, 0x5728, 0x5173, 0x95ED))) + ' Codex / ChatGPT / Claude' + [char]0x2026
        CloseStudio = (-join ([char[]](0x6B63, 0x5728, 0x5173, 0x95ED))) + ' Android Studio' + [char]0x2026
        Failed = -join ([char[]](0x6CA1, 0x6709, 0x6253, 0x5F00, 0xFF0C, 0x8BF7, 0x518D, 0x70B9, 0x4E00, 0x6B21))
    }
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = 'CodexToolbarProgress'
    $progressForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $progressForm.ShowInTaskbar = $false
    $progressForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $progressHandle = $progressForm.Handle
    $WS_EX_TRANSPARENT = 0x00000020
    [CodexWindowApi]::SetWindowLong($progressHandle, $GWL_EXSTYLE,
        [CodexWindowApi]::GetWindowLong($progressHandle, $GWL_EXSTYLE) -bor $WS_EX_TOOLWINDOW -bor $WS_EX_LAYERED -bor $WS_EX_NOACTIVATE -bor $WS_EX_TRANSPARENT) | Out-Null
    $progressFont = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $progressBox = [pscustomobject]@{ Shown = $false; Text = ''; Failed = $false; Angle = 0; Ticks = 0; Width = 0; Height = 0; Check = $null; Started = 0; GoneSince = 0; FailedAt = 0 }
    $progressShadow = 10

    function Update-ToolbarProgress {
        $box = $progressBox
        $bitmap = New-Object System.Drawing.Bitmap($box.Width, $box.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $pens = @()
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $cardWidth = $box.Width - 2 * $progressShadow
            $cardHeight = $box.Height - 2 * $progressShadow
            foreach ($layer in @(@(4, 7), @(2, 12), @(1, 20))) {
                $grow = $layer[0]
                $shadowPath = New-ToolbarRoundedPath -X ($progressShadow - $grow) -Y ($progressShadow - $grow + 2) -Size ($cardWidth + 2 * $grow) -Height ($cardHeight + 2 * $grow) -Radius (10 + $grow)
                $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($layer[1], 0, 0, 0))
                try { $graphics.FillPath($shadowBrush, $shadowPath) } finally { $shadowBrush.Dispose(); $shadowPath.Dispose() }
            }
            $cardPath = New-ToolbarRoundedPath -X $progressShadow -Y $progressShadow -Size $cardWidth -Height $cardHeight -Radius 10
            $cardBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $pens += ($borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(226, 232, 236), 1))
            try { $graphics.FillPath($cardBrush, $cardPath); $graphics.DrawPath($borderPen, $cardPath) } finally { $cardBrush.Dispose(); $cardPath.Dispose() }

            $centerY = $progressShadow + $cardHeight / 2
            $ring = [System.Drawing.RectangleF]::new($progressShadow + 14, $centerY - 8, 16, 16)
            if ($box.Failed) {
                $markBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 76, 76))
                $markFont = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
                $markFormat = New-Object System.Drawing.StringFormat
                try {
                    $markFormat.Alignment = [System.Drawing.StringAlignment]::Center
                    $markFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
                    $graphics.FillEllipse($markBrush, $ring)
                    $graphics.DrawString('!', $markFont, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new($ring.X, $ring.Y + 0.5, 16, 16), $markFormat)
                }
                finally { $markFormat.Dispose(); $markFont.Dispose(); $markBrush.Dispose() }
            }
            else {
                $pens += ($trackPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(219, 231, 253), 2.4))
                $pens += ($arcPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(37, 99, 235), 2.4))
                $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $arcPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $graphics.DrawEllipse($trackPen, $ring)
                $graphics.DrawArc($arcPen, $ring, [single]$box.Angle, [single]100)
            }
            $textColor = if ($box.Failed) { [System.Drawing.Color]::FromArgb(181, 59, 59) } else { [System.Drawing.Color]::FromArgb(31, 42, 48) }
            $textBrush = New-Object System.Drawing.SolidBrush($textColor)
            $textFormat = New-Object System.Drawing.StringFormat
            try {
                $textFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
                $textFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
                $graphics.DrawString($box.Text, $progressFont, $textBrush, [System.Drawing.RectangleF]::new($progressShadow + 40, $progressShadow, $cardWidth - 48, $cardHeight), $textFormat)
            }
            finally { $textFormat.Dispose(); $textBrush.Dispose() }
        }
        finally {
            foreach ($pen in $pens) { $pen.Dispose() }
            $graphics.Dispose()
        }
        [void](Set-ToolbarLayeredBitmap -Handle $progressHandle -Bitmap $bitmap)
    }

    # Shows the card above button $ButtonIndex. $Done, when given, is asked a few times a second and answers 'done'
    # (the window is there: the card goes), 'wait', or 'gone' (the starter ended without a window: after a few more
    # seconds the card says it did not open). Without $Done the card stays until Hide-ToolbarProgress.
    function Show-ToolbarProgress {
        param(
            [string]$Text,
            [int]$ButtonIndex,
            [scriptblock]$Done = $null
        )

        $box = $progressBox
        $box.Text = $Text; $box.Failed = $false; $box.Check = $Done; $box.Started = [Environment]::TickCount; $box.GoneSince = 0
        $box.Width = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $progressFont).Width + 56 + 2 * $progressShadow
        $box.Height = 40 + 2 * $progressShadow
        $buttonLeft = $form.Left + $barLayout.Margin + $ButtonIndex * ($barLayout.ButtonSize + $barLayout.Gap)
        $buttonTop = $form.Top + $barLayout.Margin
        $area = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($buttonLeft, $buttonTop)).WorkingArea
        $x = [int]($buttonLeft + $barLayout.ButtonSize / 2 - $box.Width / 2)
        $x = [Math]::Max($area.Left, [Math]::Min($x, $area.Right - $box.Width))
        # Above the button, or under the bar when it sits at the top of the screen.
        $y = $buttonTop - 6 - $box.Height + $progressShadow
        if ($y -lt $area.Top) { $y = $buttonTop + $barLayout.ButtonSize + 6 - $progressShadow }
        [CodexWindowApi]::SetWindowPos($progressHandle, $HWND_TOPMOST, $x, $y, $box.Width, $box.Height, [uint32]$SWP_NOACTIVATE) | Out-Null
        Update-ToolbarProgress
        [CodexWindowApi]::SetWindowPos($progressHandle, $HWND_TOPMOST, 0, 0, 0, 0, $topMostFlags) | Out-Null
        $box.Shown = $true
        $progressTimer.Start()
    }

    function Hide-ToolbarProgress {
        $progressTimer.Stop()
        $progressBox.Check = $null
        if ($progressBox.Shown) {
            $SWP_HIDEWINDOW = 0x0080
            [CodexWindowApi]::SetWindowPos($progressHandle, [IntPtr]::Zero, 0, 0, 0, 0, [uint32]($SWP_NOSIZE -bor $SWP_NOMOVE -bor $SWP_NOACTIVATE -bor 0x0004 -bor $SWP_HIDEWINDOW)) | Out-Null
            $progressBox.Shown = $false
        }
    }

    $progressTimer = New-Object System.Windows.Forms.Timer
    $progressTimer.Interval = 40
    $progressTimer.Add_Tick({
        $box = $progressBox
        $now = [Environment]::TickCount
        if ($box.Failed) {
            if ($now - $box.FailedAt -ge 3000) { Hide-ToolbarProgress }
            return
        }
        $box.Angle = ($box.Angle + 16) % 360
        $box.Ticks++
        if ($null -ne $box.Check -and ($box.Ticks % 5) -eq 0) {
            $answer = 'wait'
            try { $answer = [string](& $box.Check) } catch { $answer = 'gone' }
            if ($answer -eq 'done') { Hide-ToolbarProgress; return }
            if ($answer -eq 'gone' -and $box.GoneSince -eq 0) { $box.GoneSince = $now }
            if (($box.GoneSince -ne 0 -and $now - $box.GoneSince -ge 4000) -or $now - $box.Started -ge 30000) {
                $box.Failed = $true; $box.FailedAt = $now; $box.Text = $progressText.Failed
            }
        }
        Update-ToolbarProgress
    })

    # A top-level window with exactly this title that is showing, or zero.
    function Find-ToolbarWindow {
        param([string]$Title)

        $handle = [CodexWindowApi].GetMethod('FindWindow').Invoke($null, [object[]]@($null, $Title))
        if ($handle -ne [IntPtr]::Zero -and [CodexWindowApi]::IsWindowVisible($handle)) {
            return $handle
        }
        return [IntPtr]::Zero
    }

    # Waits for a helper process while the bar and the progress card keep drawing; clicks on the bar meanwhile are
    # ignored, since the bar is busy.
    function Wait-ToolbarProcess {
        param([System.Diagnostics.Process]$Process)

        while (-not $Process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
    }

    # The bar returns to where it was last dragged, as long as that screen is still connected.
    $dataDirectory = Join-Path $env:LOCALAPPDATA 'TNotes'
    $positionFile = Join-Path $dataDirectory 'toolbar.json'
    $pauseFile = Join-Path $dataDirectory 'toolbar-paused'
    $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $defaultLocation = New-Object System.Drawing.Point(
        [Math]::Max($workingArea.Left, $workingArea.Right - $form.Width - 12),
        [Math]::Max($workingArea.Top, $workingArea.Bottom - $form.Height - 12)
    )
    $savedLocation = $null
    try {
        $savedLocation = Get-Content -LiteralPath $positionFile -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
    }
    $form.Location = Get-FloatingBarStartLocation `
        -SavedLocation $savedLocation `
        -BarSize $form.Size `
        -WorkingAreas @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea }) `
        -DefaultLocation $defaultLocation

    function Save-ToolbarLocation {
        try {
            New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
            Set-Content -LiteralPath $positionFile -Value ('{"X":' + $form.Left + ',"Y":' + $form.Top + '}') -Encoding ASCII
        }
        catch {
        }
    }

    # Starting the bar (sign-in, desktop shortcut) ends a pause left by the Exit menu item.
    Remove-Item -LiteralPath $pauseFile -Force -ErrorAction SilentlyContinue

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    # The close buttons of T Notes and the tool window only tuck them away; these items close them for good.
    $quitText = -join ([char[]](0x9000, 0x51FA))
    $quitNotesItem = $contextMenu.Items.Add($quitText + ' T ' + (-join ([char[]](0x7B14, 0x8BB0))))
    $quitDevToolsItem = $contextMenu.Items.Add($quitText + $(if ($null -ne $devToolsText) { [string]$devToolsText.Title } else { ' Dev tools' }))
    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $contextMenu.Add_Opening({
        $quitNotesItem.Enabled = [bool](Get-Command -Name 'Get-TNotesWindowHandle' -CommandType Function -ErrorAction SilentlyContinue) -and (Get-TNotesWindowHandle) -ne [IntPtr]::Zero
        $quitDevToolsItem.Enabled = $null -ne $devToolsText -and (Find-ToolbarWindow -Title ([string]$devToolsText.Title)) -ne [IntPtr]::Zero
    })
    $quitNotesItem.Add_Click({
        # A close message, as Alt+F4 sends: the page still asks first when an edit is not saved.
        $window = Get-TNotesWindowHandle
        if ($window -ne [IntPtr]::Zero) {
            [void][CodexWindowApi]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    })
    $quitDevToolsItem.Add_Click({
        # The tool window waits for this signal and then closes for good.
        try {
            $signal = [System.Threading.EventWaitHandle]::OpenExisting('Local\CodexDevToolsQuit')
            [void]$signal.Set()
            $signal.Dispose()
        }
        catch {
        }
    })
    $exitText = -join ([char[]](0x9000, 0x51FA, 0x60AC, 0x6D6E, 0x6309, 0x94AE))
    $exitItem = $contextMenu.Items.Add($exitText)
    $exitItem.Add_Click({
        # Tell the watchdog this exit is intended, so it does not bring the bar back a minute later.
        try {
            New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
            Set-Content -LiteralPath $pauseFile -Value (Get-Date -Format 'o') -Encoding ASCII
        }
        catch {
        }
        $form.Close()
    })
    $form.ContextMenuStrip = $contextMenu

    $toolTip = New-Object System.Windows.Forms.ToolTip
    # The bar never becomes the active window, so the tip must not wait for that.
    $toolTip.ShowAlways = $true

    $dragState = [pscustomobject]@{
        IsDown = $false
        IsDragging = $false
        Offset = [System.Drawing.Point]::Empty
        Start = [System.Drawing.Point]::Empty
        # A click whose pointer slips a little is still a click: Windows' own drag distance, and at least 6 pixels.
        DragThreshold = [Math]::Max(6, [System.Windows.Forms.SystemInformation]::DragSize.Width)
    }

    $hitTest = {
        param($location)

        return Get-FloatingButtonIndex `
            -X $location.X -Y $location.Y `
            -Count $barButtons.Count `
            -ButtonSize $barLayout.ButtonSize -Gap $barLayout.Gap -Margin $barLayout.Margin
    }

    $setHover = {
        param([int]$index)

        if ($barState.Hover -eq $index) {
            return
        }

        $barState.Hover = $index
        if ($index -ge 0) {
            $form.Cursor = [System.Windows.Forms.Cursors]::Hand
            $toolTip.SetToolTip($form, $barButtons[$index].ToolTip)
        }
        else {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $toolTip.SetToolTip($form, '')
        }
        Update-ToolbarSurface
    }

    $form.Add_MouseDown({
        param($sender, $eventArgs)

        if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }
        # A press made while the bar was still busy with the last click waited in the queue; acting on it now would
        # repeat that click (and tuck away the window it just opened).
        if ($null -ne $barState.BusyEnded) {
            $sinceBusy = [int64][CodexWindowApi]::GetMessageTime() - [int64]$barState.BusyEnded
            if ($sinceBusy -lt -2147483648) { $sinceBusy += 4294967296 } elseif ($sinceBusy -gt 2147483647) { $sinceBusy -= 4294967296 }
            if ($sinceBusy -lt 0) {
                return
            }
        }

        $dragState.IsDown = $true
        $dragState.IsDragging = $false
        $dragState.Offset = $eventArgs.Location
        $dragState.Start = [System.Windows.Forms.Cursor]::Position
        $barState.Pressed = & $hitTest $eventArgs.Location
        Update-ToolbarSurface
    })

    $form.Add_MouseMove({
        param($sender, $eventArgs)

        if (-not $dragState.IsDown) {
            & $setHover (& $hitTest $eventArgs.Location)
            return
        }

        $cursor = [System.Windows.Forms.Cursor]::Position
        $deltaX = [Math]::Abs($cursor.X - $dragState.Start.X)
        $deltaY = [Math]::Abs($cursor.Y - $dragState.Start.Y)
        if (-not $dragState.IsDragging -and ($deltaX -ge $dragState.DragThreshold -or $deltaY -ge $dragState.DragThreshold)) {
            # From here on the gesture moves the bar; it no longer counts as a press on a button.
            $dragState.IsDragging = $true
            $barState.Pressed = -1
            Update-ToolbarSurface
        }

        if ($dragState.IsDragging) {
            $form.Location = Get-FloatingButtonLocation `
                -CursorPosition $cursor `
                -PointerOffset $dragState.Offset
        }
    })

    $form.Add_MouseUp({
        param($sender, $eventArgs)

        if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }

        $wasDragging = $dragState.IsDragging
        $pressed = $barState.Pressed
        $dragState.IsDown = $false
        $dragState.IsDragging = $false
        $barState.Pressed = -1
        Update-ToolbarSurface

        if ($wasDragging) {
            Save-ToolbarLocation
            return
        }

        # A click counts only when it is released on the button it started on.
        if ($pressed -ge 0 -and $pressed -eq (& $hitTest $eventArgs.Location) -and -not $barState.Busy) {
            $barState.Busy = $true
            try {
                # Each action is told where its button is on the screen; the notes window opens above it.
                $buttonLeft = $form.Left + $barLayout.Margin + $pressed * ($barLayout.ButtonSize + $barLayout.Gap)
                $anchor = '{0},{1},{2},{3}' -f $buttonLeft, ($form.Top + $barLayout.Margin), $barLayout.ButtonSize, $barLayout.ButtonSize
                & $barButtons[$pressed].Action $anchor
            }
            finally {
                $barState.Busy = $false
                $barState.BusyEnded = [Environment]::TickCount
            }
        }
    })

    $form.Add_MouseLeave({
        & $setHover -1
    })

    $form.Add_FormClosed({
        $topMostTimer.Stop()
        $topMostTimer.Dispose()
        $progressTimer.Stop()
        $progressTimer.Dispose()
        $guard = 'Codex.Toolbar.CloseGuard' -as [Type]
        if ($null -ne $guard) { $guard::Stop() }
        $progressForm.Dispose()
        $progressFont.Dispose()
        $codexImage.Dispose()
        $toolTip.Dispose()
        $contextMenu.Dispose()
    })

    $form.Show()
    Update-ToolbarSurface
    & $keepTopMost
    [CodexWindowApi]::ShowWindowAsync($form.Handle, 4) | Out-Null
    # Recovery must also start when Shown is missed during desktop initialization.
    $topMostTimer.Start()
    Write-ToolbarDiagnostic ('Toolbar initialized; recovery timer enabled=' + $topMostTimer.Enabled + '.')
    # T Notes' close button minimizes the window instead of closing it (t-notes\CloseGuard.cs.txt). It is compiled
    # once, a moment after the bar is up, so the bar never waits for it; without it, the button closes as before.
    $closeGuardTimer = New-Object System.Windows.Forms.Timer
    $closeGuardTimer.Interval = 1500
    $closeGuardTimer.Add_Tick({
        $closeGuardTimer.Stop()
        try {
            if ($null -eq ('Codex.Toolbar.CloseGuard' -as [Type])) {
                Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $projectRoot 't-notes\CloseGuard.cs.txt'))) -Language CSharp
            }
            $guard = 'Codex.Toolbar.CloseGuard' -as [Type]
            $guard::Start()
            Write-ToolbarDiagnostic ('Close guard for T Notes running=' + $guard::Running + '.')
        }
        catch {
            Write-ToolbarDiagnostic ('Close guard for T Notes could not start: ' + $_.Exception.Message)
        }
    })
    $closeGuardTimer.Start()
    [System.Windows.Forms.Application]::Run($form)
}
catch {
    $errorText = $_ | Out-String
    try {
        Set-Content -LiteralPath (Join-Path $PSScriptRoot 'floating-button-error.log') -Value $errorText -Encoding UTF8
    }
    catch {
    }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $errorText,
            'Codex Floating Button',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
    }
}
finally {
    if ($createdNew) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }
    $mutex.Dispose()
}
