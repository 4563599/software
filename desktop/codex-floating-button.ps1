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
            [Type[]]$ParameterTypes
        )

        $attributes = [System.Reflection.MethodAttributes]::Public `
            -bor [System.Reflection.MethodAttributes]::Static `
            -bor [System.Reflection.MethodAttributes]::PinvokeImpl
        $method = $TypeBuilder.DefinePInvokeMethod(
            $Name,
            'user32.dll',
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

        [void]$typeBuilder.CreateType()
    }

    $projectRoot = $PSScriptRoot
    . (Join-Path $projectRoot 'codex-floating-button-core.ps1')
    . (Join-Path $projectRoot 'codex-network-check.ps1')
    . (Join-Path $projectRoot 'ai-process-cleanup.ps1')

    function Invoke-TNotes {
        $launcher = Join-Path $projectRoot 't-notes\Launch.ps1'
        try { & $launcher -BackendOnly | Out-Null }
        catch { [System.Windows.Forms.MessageBox]::Show('T Notes backend could not start. Your unsaved text is still in the current window.', 'T Notes') | Out-Null; return }
        $window = Get-Process -Name 'msedge', 'chrome' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like 'T Notes v4*' -and $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if ($null -ne $window) {
            [CodexWindowApi]::ShowWindowAsync($window.MainWindowHandle, 9) | Out-Null
            [CodexWindowApi]::SetForegroundWindow($window.MainWindowHandle) | Out-Null
            return
        }
        $launcher = Join-Path $projectRoot 't-notes\Launch.ps1'
        if (-not (Test-Path -LiteralPath $launcher)) {
            [System.Windows.Forms.MessageBox]::Show('T Notes is not installed.', 'T Notes') | Out-Null
            return
        }
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -WindowStyle Hidden -File "' + $launcher + '"') -WindowStyle Hidden
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
        $codexButton.Enabled = $false
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
            if (-not $form.IsDisposed) { $codexButton.Enabled = $true }
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

    $codexImage = [System.Drawing.Image]::FromFile($imagePath)
    $studioImage = New-Object System.Drawing.Bitmap(48, 48)
    $studioGraphics = [System.Drawing.Graphics]::FromImage($studioImage)
    $studioBackgroundBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 122, 204))
    $studioTextBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $studioFont = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $studioTextFormat = New-Object System.Drawing.StringFormat
    try {
        $studioGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $studioTextFormat.Alignment = [System.Drawing.StringAlignment]::Center
        $studioTextFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
        $studioGraphics.FillEllipse($studioBackgroundBrush, 0, 0, 47, 47)
        $studioGraphics.DrawString('AS', $studioFont, $studioTextBrush, [System.Drawing.RectangleF]::new(0, 0, 48, 48), $studioTextFormat)
    }
    finally {
        $studioTextFormat.Dispose()
        $studioFont.Dispose()
        $studioTextBrush.Dispose()
        $studioBackgroundBrush.Dispose()
        $studioGraphics.Dispose()
    }

    $notesImage = New-Object System.Drawing.Bitmap(48, 48)
    $notesGraphics = [System.Drawing.Graphics]::FromImage($notesImage)
    $notesBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(37, 99, 235))
    $notesTextBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $notesFont = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $notesFormat = New-Object System.Drawing.StringFormat
    try {
        $notesFormat.Alignment = [System.Drawing.StringAlignment]::Center
        $notesFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
        $notesGraphics.FillRectangle($notesBrush, 0, 0, 48, 48)
        $notesGraphics.DrawString('T', $notesFont, $notesTextBrush, [System.Drawing.RectangleF]::new(0, 0, 48, 48), $notesFormat)
    }
    finally {
        $notesFormat.Dispose()
        $notesFont.Dispose()
        $notesTextBrush.Dispose()
        $notesBrush.Dispose()
        $notesGraphics.Dispose()
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CodexFloatingButton'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ClientSize = New-Object System.Drawing.Size(200, 60)
    $form.BackColor = [System.Drawing.Color]::Magenta
    $form.TransparencyKey = [System.Drawing.Color]::Magenta

    $codexButton = New-Object System.Windows.Forms.PictureBox
    $codexButton.Name = 'CodexButton'
    $codexButton.Tag = 'Codex'
    $codexButton.Location = New-Object System.Drawing.Point(6, 0)
    $codexButton.Size = New-Object System.Drawing.Size(60, 60)
    $codexButton.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $codexButton.BackColor = [System.Drawing.Color]::Transparent
    $codexButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $codexButton.Image = $codexImage

    $studioButton = New-Object System.Windows.Forms.PictureBox
    $studioButton.Name = 'AndroidStudioButton'
    $studioButton.Tag = 'AndroidStudio'
    $studioButton.Location = New-Object System.Drawing.Point(70, 0)
    $studioButton.Size = New-Object System.Drawing.Size(60, 60)
    $studioButton.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::CenterImage
    $studioButton.BackColor = [System.Drawing.Color]::Transparent
    $studioButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $studioButton.Image = $studioImage

    $form.Controls.Add($codexButton)
    $form.Controls.Add($studioButton)

    $notesButton = New-Object System.Windows.Forms.PictureBox
    $notesButton.Name = 'TNotesButton'
    $notesButton.Location = New-Object System.Drawing.Point(134, 0)
    $notesButton.Size = New-Object System.Drawing.Size(60, 60)
    $notesButton.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::CenterImage
    $notesButton.BackColor = [System.Drawing.Color]::Transparent
    $notesButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $notesButton.Image = $notesImage
    $form.Controls.Add($notesButton)

    $GWL_EXSTYLE = -20
    $WS_EX_TOOLWINDOW = 0x00000080
    $WS_EX_NOACTIVATE = 0x08000000
    $formHandle = $form.Handle
    $extendedStyle = [CodexWindowApi]::GetWindowLong($formHandle, $GWL_EXSTYLE)
    [CodexWindowApi]::SetWindowLong(
        $formHandle,
        $GWL_EXSTYLE,
        $extendedStyle -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE
    ) | Out-Null

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
    $topMostTimer.Add_Tick($keepTopMost)
    $form.Add_Shown({
        & $keepTopMost
        $topMostTimer.Start()
    })
    $form.Add_Deactivate({
        & $keepTopMost
    })

    $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(
        [Math]::Max($workingArea.Left, $workingArea.Right - $form.Width - 18),
        [Math]::Max($workingArea.Top, $workingArea.Bottom - $form.Height - 18)
    )

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $exitText = -join ([char[]](0x9000, 0x51FA, 0x60AC, 0x6D6E, 0x6309, 0x94AE))
    $exitItem = $contextMenu.Items.Add($exitText)
    $exitItem.Add_Click({ $form.Close() })
    $form.ContextMenuStrip = $contextMenu
    $codexButton.ContextMenuStrip = $contextMenu
    $studioButton.ContextMenuStrip = $contextMenu
    $notesButton.ContextMenuStrip = $contextMenu

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $codexToolTipText = (-join ([char[]](0x5F7B, 0x5E95, 0x5173, 0x95ED))) + ' Codex / ChatGPT / Claude'
    $studioToolTipText = (-join ([char[]](0x5F3A, 0x5236, 0x5173, 0x95ED))) + ' Android Studio'
    $toolTip.SetToolTip($codexButton, $codexToolTipText)
    $toolTip.SetToolTip($studioButton, $studioToolTipText)
    $toolTip.SetToolTip($notesButton, 'T Notes')

    $dragState = [pscustomobject]@{
        IsDown = $false
        IsDragging = $false
        Offset = [System.Drawing.Point]::Empty
        Start = [System.Drawing.Point]::Empty
        DragThreshold = 4
    }

    $mouseDownHandler = {
        param($sender, $eventArgs)

        if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }

        $dragState.IsDown = $true
        $dragState.IsDragging = $false
        $senderOffset = if ($sender -eq $form) {
            [System.Drawing.Point]::Empty
        }
        else {
            $sender.Location
        }
        $dragState.Offset = Get-ControlPointerOffset `
            -ControlLocation $senderOffset `
            -EventLocation $eventArgs.Location
        $dragState.Start = [System.Windows.Forms.Cursor]::Position
    }

    $mouseMoveHandler = {
        param($sender, $eventArgs)

        if (-not $dragState.IsDown) {
            return
        }

        $cursor = [System.Windows.Forms.Cursor]::Position
        $deltaX = [Math]::Abs($cursor.X - $dragState.Start.X)
        $deltaY = [Math]::Abs($cursor.Y - $dragState.Start.Y)
        if ($deltaX -ge $dragState.DragThreshold -or $deltaY -ge $dragState.DragThreshold) {
            $dragState.IsDragging = $true
        }

        if ($dragState.IsDragging) {
            $form.Location = Get-FloatingButtonLocation `
                -CursorPosition $cursor `
                -PointerOffset $dragState.Offset
        }
    }

    $mouseUpHandler = {
        param($sender, $eventArgs)

        if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }

        $wasDragging = $dragState.IsDragging
        $dragState.IsDown = $false
        $dragState.IsDragging = $false
        if (-not $wasDragging) {
            if ($sender -eq $codexButton) {
                Invoke-AiAppsShutdown
            }
            elseif ($sender -eq $studioButton) {
                Invoke-AndroidStudioShutdown
            }
            elseif ($sender -eq $notesButton) {
                Invoke-TNotes
            }
        }
    }

    foreach ($control in @($form, $codexButton, $studioButton, $notesButton)) {
        $control.Add_MouseDown($mouseDownHandler)
        $control.Add_MouseMove($mouseMoveHandler)
        $control.Add_MouseUp($mouseUpHandler)
    }

    $form.Add_FormClosed({
        $topMostTimer.Stop()
        $topMostTimer.Dispose()
        $codexButton.Image = $null
        $studioButton.Image = $null
        $notesButton.Image = $null
        $codexImage.Dispose()
        $studioImage.Dispose()
        $notesImage.Dispose()
        $toolTip.Dispose()
        $contextMenu.Dispose()
    })

    $form.Show()
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
