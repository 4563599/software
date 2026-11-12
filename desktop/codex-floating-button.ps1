$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexFloatingButton', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

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
        Add-CodexPInvokeMethod -TypeBuilder $typeBuilder -Name 'GetWindowLong' -ReturnType ([int]) -ParameterTypes @([IntPtr], [int])
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
        try { Open-TNotes -Toggle -Anchor $Anchor | Out-Null }
        catch { [System.Windows.Forms.MessageBox]::Show('T Notes backend could not start. Your unsaved text is still in the current window.', 'T Notes') | Out-Null }
    }

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
        try {
            $worker = Join-Path $projectRoot 'ai-process-cleanup-worker.ps1'
            if (-not (Test-Path -LiteralPath $worker)) { throw 'Cleanup worker is missing.' }
            $resultFile = Join-Path $projectRoot ('ai-cleanup-result-' + [guid]::NewGuid().ToString('N') + '.json')
            $arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' +
                $worker + '" -Mode Clean -ResultPath "' + $resultFile + '" -ProtectedProcessId ' + $PID
            $workerProcess = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
            $workerProcess.Dispose()
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
            $message = (-join ([char[]](0x7BA1, 0x7406, 0x5458, 0x6388, 0x6743, 0x5DF2, 0x53D6, 0x6D88, 0xFF0C, 0x6216, 0x6E05, 0x7406, 0x68C0, 0x67E5, 0x672A, 0x5B8C, 0x6210, 0x3002, 0x672A, 0x786E, 0x8BA4, 0x5168, 0x90E8, 0x8FDB, 0x7A0B, 0x5DF2, 0x5173, 0x95ED, 0x3002)))
            [System.Windows.Forms.MessageBox]::Show($form,$message,$confirmTitle,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        finally {
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
        }

        $remainingIds = @($processIds | Where-Object {
            $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue)
        })
        $elevationCancelled = $false
        if ($remainingIds.Count -gt 0) {
            $taskKillArguments = Get-AndroidStudioTaskKillArguments -ProcessIds $remainingIds
            try {
                Start-Process `
                    -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') `
                    -ArgumentList $taskKillArguments `
                    -Verb RunAs `
                    -WindowStyle Hidden `
                    -Wait | Out-Null
            }
            catch {
                $elevationCancelled = $true
            }
        }

        Start-Sleep -Milliseconds 300
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

    # One shape and size for all three buttons; only the colour and the letter differ.
    # The corner radius matches the C artwork (22% of its size) so all three outlines are identical.
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

    $barButtons = @(
        [pscustomobject]@{
            Image = $codexImage; Text = ''; FontSize = 0
            From = [System.Drawing.Color]::Empty; To = [System.Drawing.Color]::Empty
            ToolTip = $codexToolTipText; Action = { Invoke-AiAppsShutdown }
        },
        [pscustomobject]@{
            Image = $null; Text = 'AS'; FontSize = 22
            From = [System.Drawing.Color]::FromArgb(20, 142, 226); To = [System.Drawing.Color]::FromArgb(0, 108, 188)
            ToolTip = $studioToolTipText; Action = { Invoke-AndroidStudioShutdown }
        },
        [pscustomobject]@{
            Image = $null; Text = 'T'; FontSize = 31
            From = [System.Drawing.Color]::FromArgb(66, 133, 244); To = [System.Drawing.Color]::FromArgb(37, 99, 235)
            ToolTip = $notesToolTipText; Action = { param($anchor) Invoke-TNotes -Anchor $anchor }
        }
    )
    $barState = [pscustomobject]@{ Hover = -1; Pressed = -1; Busy = $false; Painted = $false; Ticks = 0; Failures = 0 }

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
            [single]$Radius
        )

        $diameter = 2 * $Radius
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
        $path.AddArc($X + $Size - $diameter, $Y, $diameter, $diameter, 270, 90)
        $path.AddArc($X + $Size - $diameter, $Y + $Size - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc($X, $Y + $Size - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        return $path
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
                        $font = New-Object System.Drawing.Font('Segoe UI', $button.FontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
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

        $screenDc = [CodexWindowApi]::GetDC([IntPtr]::Zero)
        $memoryDc = [CodexWindowApi]::CreateCompatibleDC($screenDc)
        # A transparent background makes GDI+ hand over the premultiplied pixels the layered window expects.
        $surface = $bitmap.GetHbitmap([System.Drawing.Color]::FromArgb(0))
        $previousObject = [CodexWindowApi]::SelectObject($memoryDc, $surface)
        try {
            [Int64]$surfaceSize = ([Int64]$bitmap.Height -shl 32) -bor [Int64]$bitmap.Width
            [Int64]$sourcePoint = 0
            # AC_SRC_OVER, no flags, constant alpha 255, AC_SRC_ALPHA.
            [int]$blend = 0x01FF0000
            $ULW_ALPHA = 2
            $barState.Painted = [bool][CodexWindowApi]::UpdateLayeredWindow(
                $form.Handle,
                $screenDc,
                [IntPtr]::Zero,
                [ref]$surfaceSize,
                $memoryDc,
                [ref]$sourcePoint,
                0,
                [ref]$blend,
                $ULW_ALPHA
            )
        }
        finally {
            [CodexWindowApi]::SelectObject($memoryDc, $previousObject) | Out-Null
            [CodexWindowApi]::DeleteObject($surface) | Out-Null
            [CodexWindowApi]::DeleteDC($memoryDc) | Out-Null
            [CodexWindowApi]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null
            $bitmap.Dispose()
        }

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
    $keepTopMost = {
        if ($form.IsDisposed -or -not $form.IsHandleCreated) {
            return
        }

        $form.TopMost = $true
        [CodexWindowApi]::SetWindowPos(
            $form.Handle,
            $HWND_TOPMOST,
            0,
            0,
            0,
            0,
            $topMostFlags
        ) | Out-Null
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
        DragThreshold = 4
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
            }
        }
    })

    $form.Add_MouseLeave({
        & $setHover -1
    })

    $form.Add_FormClosed({
        $topMostTimer.Stop()
        $topMostTimer.Dispose()
        $codexImage.Dispose()
        $toolTip.Dispose()
        $contextMenu.Dispose()
    })

    $form.Show()
    Update-ToolbarSurface
    & $keepTopMost
    [CodexWindowApi]::ShowWindowAsync($form.Handle, 4) | Out-Null
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
