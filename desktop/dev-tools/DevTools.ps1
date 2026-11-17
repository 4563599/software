param(
    # Screen rectangle of the tool button, "x,y,width,height"; the window opens directly above it.
    [string]$Anchor = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexDevTools', [ref]$createdNew)
if (-not $createdNew) {
    # The window is already open or opening; the toolbar brings that one forward.
    $mutex.Dispose()
    exit 0
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    . (Join-Path $PSScriptRoot 'dev-tools-core.ps1')
    $windowScript = Join-Path (Split-Path -Parent $PSScriptRoot) 't-notes\window.ps1'
    if (Test-Path -LiteralPath $windowScript) {
        . $windowScript
    }

    # All visible text lives in text.json (UTF-8), so this file stays plain ASCII.
    $T = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'text.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $settingsPath = Join-Path $env:LOCALAPPDATA 'TNotes\dev-tools.json'
    $settings = Read-DevToolsSettings -Path $settingsPath
    $state = [pscustomobject]@{
        Busy = $false
        Closing = $false
        Populating = $false
        AdbPath = (Find-AdbPath)
        Devices = @()
        Viewer = $null
        Preview = $null
        Tasks = $null
        Cancel = $false
    }

    # Blue accents on light grey; red only for failures. No green anywhere.
    $theme = [pscustomobject]@{
        Page = [System.Drawing.Color]::FromArgb(244, 246, 250)
        Card = [System.Drawing.Color]::White
        Border = [System.Drawing.Color]::FromArgb(222, 227, 235)
        Accent = [System.Drawing.Color]::FromArgb(37, 99, 235)
        AccentDark = [System.Drawing.Color]::FromArgb(29, 78, 216)
        AccentSoft = [System.Drawing.Color]::FromArgb(234, 241, 254)
        AccentPress = [System.Drawing.Color]::FromArgb(219, 234, 254)
        AccentBorder = [System.Drawing.Color]::FromArgb(147, 180, 247)
        Text = [System.Drawing.Color]::FromArgb(31, 41, 55)
        Muted = [System.Drawing.Color]::FromArgb(107, 114, 128)
        Disabled = [System.Drawing.Color]::FromArgb(165, 172, 182)
        Error = [System.Drawing.Color]::FromArgb(220, 38, 38)
        Output = [System.Drawing.Color]::FromArgb(249, 250, 252)
    }
    $uiFont = 'Microsoft YaHei UI'
    $fonts = [pscustomobject]@{
        Body = New-Object System.Drawing.Font($uiFont, 9)
        Caption = New-Object System.Drawing.Font($uiFont, 9, [System.Drawing.FontStyle]::Bold)
        TileTitle = New-Object System.Drawing.Font($uiFont, 10.5, [System.Drawing.FontStyle]::Bold)
        TileHint = New-Object System.Drawing.Font($uiFont, 8.5)
        Icon = New-Object System.Drawing.Font('Segoe MDL2 Assets', 15)
        Status = New-Object System.Drawing.Font($uiFont, 9, [System.Drawing.FontStyle]::Bold)
        Log = New-Object System.Drawing.Font('Consolas', 9)
        ResultSmall = New-Object System.Drawing.Font($uiFont, 8.5)
        ResultTitle = New-Object System.Drawing.Font($uiFont, 9, [System.Drawing.FontStyle]::Bold)
        ResultStrong = New-Object System.Drawing.Font($uiFont, 10.5, [System.Drawing.FontStyle]::Bold)
        ResultCode = New-Object System.Drawing.Font('Consolas', 9.5)
        StackName = New-Object System.Drawing.Font($uiFont, 9.5, [System.Drawing.FontStyle]::Bold)
        StackClass = New-Object System.Drawing.Font('Consolas', 8.5)
        Badge = New-Object System.Drawing.Font($uiFont, 8)
    }
    $glyphs = [pscustomobject]@{
        Phone = [string][char]0xE8EA
        Stop = [string][char]0xE71A
        Download = [string][char]0xE896
        List = [string][char]0xE8FD
        Camera = [string][char]0xE722
        Scroll = [string][char]0xE8CB
        Layers = [string][char]0xE81E
        Wrench = [string][char]0xE90F
    }
    $doubleBuffered = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic, Instance')
    $newline = [Environment]::NewLine

    function New-RoundedPath {
        param([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius)

        $diameter = 2 * $Radius
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
        $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
        $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        return $path
    }

    function New-ToolsIcon {
        # The same blue square and wrench as the toolbar button, so the taskbar entry is easy to recognise.
        $bitmap = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $path = New-RoundedPath -X 0 -Y 0 -Width 31 -Height 31 -Radius 7
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush([System.Drawing.Rectangle]::new(0, 0, 32, 32), [System.Drawing.Color]::FromArgb(59, 130, 246), $theme.AccentDark, [single]45)
        $font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 17, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $graphics.FillPath($brush, $path)
            $graphics.DrawString($glyphs.Wrench, $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 1, 32, 32), $format)
            return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        }
        finally {
            $format.Dispose()
            $font.Dispose()
            $brush.Dispose()
            $path.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    function New-Caption {
        param([string]$Text)

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Font = $fonts.Caption
        $label.ForeColor = $theme.Muted
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.AutoEllipsis = $true
        return $label
    }

    function New-SmallButton {
        param([string]$Text)

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Font = $fonts.Body
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.UseVisualStyleBackColor = $false
        $button.BackColor = $theme.Card
        $button.ForeColor = $theme.Accent
        $button.FlatAppearance.BorderColor = $theme.Border
        $button.FlatAppearance.MouseOverBackColor = $theme.AccentSoft
        $button.FlatAppearance.MouseDownBackColor = $theme.AccentPress
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $button
    }

    function New-InputField {
        # A borderless text box inside a 1-pixel frame; the frame turns blue while the box has focus.
        $frame = New-Object System.Windows.Forms.Panel
        $frame.BackColor = $theme.Border
        $frame.Padding = New-Object System.Windows.Forms.Padding(1)
        $inner = New-Object System.Windows.Forms.Panel
        $inner.BackColor = $theme.Card
        $inner.Padding = New-Object System.Windows.Forms.Padding(8, 6, 6, 2)
        $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
        $box = New-Object System.Windows.Forms.TextBox
        $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $box.BackColor = $theme.Card
        $box.ForeColor = $theme.Text
        $box.Font = $fonts.Body
        $box.Dock = [System.Windows.Forms.DockStyle]::Fill
        $inner.Controls.Add($box)
        $frame.Controls.Add($inner)
        $box.Add_Enter({ param($sender, $eventArgs) $sender.Parent.Parent.BackColor = $theme.Accent })
        $box.Add_Leave({ param($sender, $eventArgs) $sender.Parent.Parent.BackColor = $theme.Border })
        return [pscustomobject]@{ Frame = $frame; Box = $box }
    }

    function New-FramedTextArea {
        param([System.Drawing.Color]$Background, [System.Drawing.Font]$Font, [bool]$WordWrap)

        $frame = New-Object System.Windows.Forms.Panel
        $frame.BackColor = $theme.Border
        $frame.Padding = New-Object System.Windows.Forms.Padding(1)
        $inner = New-Object System.Windows.Forms.Panel
        $inner.BackColor = $Background
        $inner.Padding = New-Object System.Windows.Forms.Padding(10, 8, 2, 2)
        $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true
        $box.ReadOnly = $true
        $box.WordWrap = $WordWrap
        $box.ScrollBars = if ($WordWrap) { [System.Windows.Forms.ScrollBars]::Vertical } else { [System.Windows.Forms.ScrollBars]::Both }
        $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $box.BackColor = $Background
        $box.ForeColor = $theme.Text
        $box.Font = $Font
        $box.MaxLength = 0
        $box.HideSelection = $false
        $box.Dock = [System.Windows.Forms.DockStyle]::Fill
        $inner.Controls.Add($box)
        $frame.Controls.Add($inner)
        return [pscustomobject]@{ Frame = $frame; Box = $box }
    }

    function New-FramedRichText {
        # Results use rich text so the key value can be bold and names can be monospaced.
        $frame = New-Object System.Windows.Forms.Panel
        $frame.BackColor = $theme.Border
        $frame.Padding = New-Object System.Windows.Forms.Padding(1)
        $inner = New-Object System.Windows.Forms.Panel
        $inner.BackColor = $theme.Output
        $inner.Padding = New-Object System.Windows.Forms.Padding(12, 10, 2, 2)
        $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
        $box = New-Object System.Windows.Forms.RichTextBox
        $box.ReadOnly = $true
        $box.DetectUrls = $false
        $box.WordWrap = $true
        $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
        $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $box.BackColor = $theme.Output
        $box.ForeColor = $theme.Text
        $box.Font = $fonts.Body
        $box.HideSelection = $false
        $box.Dock = [System.Windows.Forms.DockStyle]::Fill
        $inner.Controls.Add($box)
        $frame.Controls.Add($inner)
        return [pscustomobject]@{ Frame = $frame; Box = $box }
    }

    $tilePaint = {
        param($sender, $eventArgs)

        $tile = $sender.Tag
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear($theme.Page)
        $enabled = $sender.Enabled
        $hover = $tile.Hover -and $enabled
        $path = New-RoundedPath -X 0.5 -Y 0.5 -Width ($sender.Width - 1.5) -Height ($sender.Height - 1.5) -Radius 10
        $fill = New-Object System.Drawing.SolidBrush($(if ($hover) { $theme.AccentSoft } else { $theme.Card }))
        $pen = New-Object System.Drawing.Pen($(if ($hover) { $theme.AccentBorder } else { $theme.Border }))
        $circle = New-Object System.Drawing.SolidBrush($(if ($hover) { $theme.Card } else { $theme.AccentSoft }))
        try {
            $graphics.FillPath($fill, $path)
            $graphics.DrawPath($pen, $path)
            $size = 40
            $top = [int](($sender.Height - $size) / 2)
            $graphics.FillEllipse($circle, 16, $top, $size, $size)
            $centered = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, NoPadding'
            $line = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPadding, NoPrefix'
            [System.Windows.Forms.TextRenderer]::DrawText($graphics, $tile.Glyph, $fonts.Icon, [System.Drawing.Rectangle]::new(16, $top, $size, $size), $(if ($enabled) { $theme.Accent } else { $theme.Disabled }), $centered)
            $left = 16 + $size + 14
            $width = $sender.Width - $left - 12
            $middle = [int]($sender.Height / 2)
            [System.Windows.Forms.TextRenderer]::DrawText($graphics, $tile.Title, $fonts.TileTitle, [System.Drawing.Rectangle]::new($left, $middle - 22, $width, 22), $(if ($enabled) { $theme.Text } else { $theme.Disabled }), $line)
            [System.Windows.Forms.TextRenderer]::DrawText($graphics, $tile.Hint, $fonts.TileHint, [System.Drawing.Rectangle]::new($left, $middle + 1, $width, 20), $(if ($enabled) { $theme.Muted } else { $theme.Disabled }), $line)
        }
        finally {
            $circle.Dispose()
            $pen.Dispose()
            $fill.Dispose()
            $path.Dispose()
        }
    }

    function New-ActionTile {
        param([string]$Glyph, [string]$Title, [string]$Hint, [scriptblock]$Action)

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $panel.Tag = [pscustomobject]@{ Glyph = $Glyph; Title = $Title; Hint = $Hint; Hover = $false; Action = $Action }
        $doubleBuffered.SetValue($panel, $true, $null)
        $panel.Add_Paint($tilePaint)
        $panel.Add_MouseEnter({ param($sender, $eventArgs) $sender.Tag.Hover = $true; $sender.Invalidate() })
        $panel.Add_MouseLeave({ param($sender, $eventArgs) $sender.Tag.Hover = $false; $sender.Invalidate() })
        $panel.Add_EnabledChanged({ param($sender, $eventArgs) $sender.Invalidate() })
        $panel.Add_Click({
            param($sender, $eventArgs)
            if ($sender.Enabled -and -not $state.Busy) {
                & $sender.Tag.Action
            }
        })
        return $panel
    }

    function Invoke-Adb {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Arguments,

            [int]$TimeoutSeconds = 30
        )

        # adb runs as a child process while the window keeps responding; it is stopped after the time limit.
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $state.AdbPath
        $info.Arguments = ConvertTo-ProcessArgumentString -Arguments $Arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = [System.Diagnostics.Process]::Start($info)
        $buffer = New-Object System.IO.MemoryStream
        try {
            $copy = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
            $errorRead = $process.StandardError.ReadToEndAsync()
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $timedOut = $false
            $exitedAt = -1
            while ($true) {
                if ($process.HasExited) {
                    if ($exitedAt -lt 0) {
                        $exitedAt = $watch.Elapsed.TotalSeconds
                    }
                    # A freshly started adb server can hold the output pipe open, so do not wait on it for long.
                    if (($copy.IsCompleted -and $errorRead.IsCompleted) -or ($watch.Elapsed.TotalSeconds - $exitedAt) -gt 2) {
                        break
                    }
                }
                elseif ($state.Closing -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                    $timedOut = $true
                    try { $process.Kill() } catch { }
                    [void]$process.WaitForExit(2000)
                    break
                }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 20
            }

            try { [void]$copy.Wait(500) } catch { }
            $bytes = $buffer.ToArray()
            $errorText = ''
            if ($errorRead.IsCompleted -and -not $errorRead.IsFaulted) {
                $errorText = [string]$errorRead.Result
            }
            return [pscustomobject]@{
                ExitCode = $(if ($process.HasExited) { $process.ExitCode } else { -1 })
                TimedOut = $timedOut
                TimeoutSeconds = $TimeoutSeconds
                Bytes = $bytes
                Output = [Text.Encoding]::UTF8.GetString($bytes)
                Error = $errorText
            }
        }
        finally {
            $process.Dispose()
        }
    }

    function Get-AdbErrorDetail {
        param($Result)

        return (@(($Result.Error -split "`r?`n") | Where-Object { $_.Trim() -and -not $_.StartsWith('*') }) -join ' ').Trim()
    }

    function Test-AdbFailed {
        param($Result)

        return ($Result.TimedOut -or ($Result.ExitCode -ne 0 -and [bool](Get-AdbErrorDetail -Result $Result)))
    }

    function Get-AdbFailureText {
        param($Result)

        if ($Result.TimedOut) {
            return ($T.TimedOut -f $Result.TimeoutSeconds)
        }
        $detail = Get-AdbErrorDetail -Result $Result
        if (-not $detail) {
            $detail = (@(($Result.Output -split "`r?`n") | Where-Object { $_.Trim() }) | Select-Object -Last 1)
        }
        if (-not $detail) {
            $detail = 'exit code ' + $Result.ExitCode
        }
        return ($T.AdbFailed -f $detail)
    }

    function Get-DeviceLabel {
        param($Device)

        $separator = '  ' + [char]0x00B7 + '  '
        if ($Device.State -eq 'device') {
            if ($Device.Model) { return ($Device.Model + $separator + $Device.Serial) }
            return $Device.Serial
        }
        $reason = if ($Device.State -eq 'unauthorized') { $T.StateUnauthorized } elseif ($Device.State -eq 'offline') { $T.StateOffline } else { $Device.State }
        return ($Device.Serial + $separator + $reason)
    }

    # ---------------- Main window ----------------

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $T.Title
    $form.Font = $fonts.Body
    $form.BackColor = $theme.Page
    $form.ForeColor = $theme.Text
    $form.ClientSize = New-Object System.Drawing.Size(640, 822)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 782)
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Icon = New-ToolsIcon

    $phoneCaption = New-Caption -Text $T.Phone
    $phoneBox = New-Object System.Windows.Forms.ComboBox
    $phoneBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $phoneBox.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $phoneBox.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $phoneBox.ItemHeight = 24
    $phoneBox.BackColor = $theme.Card
    $phoneBox.Font = $fonts.Body
    $phoneBox.Add_DrawItem({
        param($sender, $eventArgs)

        $eventArgs.DrawBackground()
        if ($eventArgs.Index -ge 0) {
            $selected = ($eventArgs.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
            $color = if ($selected) { [System.Drawing.SystemColors]::HighlightText } else { $theme.Text }
            $bounds = $eventArgs.Bounds
            [System.Windows.Forms.TextRenderer]::DrawText(
                $eventArgs.Graphics,
                [string]$sender.Items[$eventArgs.Index],
                $sender.Font,
                [System.Drawing.Rectangle]::new($bounds.X + 6, $bounds.Y, $bounds.Width - 8, $bounds.Height),
                $color,
                [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix'
            )
        }
    })
    $refreshButton = New-SmallButton -Text $T.Refresh

    # Pairs: the app on screen, screenshots, Bluetooth logs; then the computer-side Gradle stop across the full width.
    $tiles = @(
        (New-ActionTile -Glyph $glyphs.Phone -Title $T.Activity -Hint $T.ActivityHint -Action { Invoke-DevAction -Title $T.Activity -Body { Invoke-ActivityCheck } }),
        (New-ActionTile -Glyph $glyphs.Layers -Title $T.TaskStacks -Hint $T.TaskStacksHint -Action { Invoke-DevAction -Title $T.TaskStacks -Body { Open-TaskWindow } }),
        (New-ActionTile -Glyph $glyphs.Camera -Title $T.Screenshot -Hint $T.ScreenshotHint -Action { Invoke-DevAction -Title $T.Screenshot -Body { Invoke-PhoneScreenshot } }),
        (New-ActionTile -Glyph $glyphs.Scroll -Title $T.LongScreenshot -Hint $T.LongScreenshotHint -Action { Invoke-DevAction -Title $T.LongScreenshot -Body { Invoke-LongScreenshot } }),
        (New-ActionTile -Glyph $glyphs.Download -Title $T.ExportBle -Hint $T.ExportBleHint -Action { Invoke-DevAction -Title $T.ExportBle -Body { Invoke-BleExport } }),
        (New-ActionTile -Glyph $glyphs.List -Title $T.ShowBle -Hint $T.ShowBleHint -Action { Invoke-DevAction -Title $T.ShowBle -Body { Open-LogViewer } }),
        (New-ActionTile -Glyph $glyphs.Stop -Title $T.StopGradle -Hint $T.StopGradleHint -Action { Invoke-DevAction -Title $T.StopGradle -Body { Invoke-GradleStop } })
    )

    $pathCaption = New-Caption -Text $T.PathGroup
    $remoteLabel = New-Object System.Windows.Forms.Label
    $remoteLabel.Text = $T.RemotePath
    $remoteLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $remoteField = New-InputField
    $remoteField.Box.Text = $settings.RemoteLogPath
    $defaultButton = New-SmallButton -Text $T.Default
    $exportLabel = New-Object System.Windows.Forms.Label
    $exportLabel.Text = $T.ExportPath
    $exportLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $exportField = New-InputField
    $exportField.Box.Text = $settings.ExportPath
    $browseButton = New-SmallButton -Text $T.Browse

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Font = $fonts.Status
    $statusLabel.ForeColor = $theme.Muted
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.AutoEllipsis = $true
    $statusLabel.Text = $T.Ready
    $clearButton = New-SmallButton -Text $T.Clear
    # Shown in place of "clear" while a long screenshot is being taken.
    $stopButton = New-SmallButton -Text $T.StopLong
    $stopButton.ForeColor = $theme.Error
    $stopButton.Visible = $false
    $stopButton.Add_Click({ $state.Cancel = $true; $stopButton.Enabled = $false })
    $stopButton.Add_VisibleChanged({ $stopButton.Enabled = $true })
    $output = New-FramedRichText

    $form.Controls.AddRange([System.Windows.Forms.Control[]]@(
        $phoneCaption, $phoneBox, $refreshButton,
        $pathCaption, $remoteLabel, $remoteField.Frame, $defaultButton, $exportLabel, $exportField.Frame, $browseButton,
        $statusLabel, $clearButton, $stopButton, $output.Frame
    ))
    $form.Controls.AddRange([System.Windows.Forms.Control[]]$tiles)
    $busyControls = @($tiles) + @($phoneBox, $refreshButton, $defaultButton, $browseButton)

    function Update-MainLayout {
        $width = $form.ClientSize.Width
        $height = $form.ClientSize.Height
        $pad = 20
        $inner = $width - 2 * $pad
        $buttonWidth = 76

        $phoneCaption.SetBounds($pad, 14, $inner, 20)
        $phoneBox.SetBounds($pad, 38, $inner - $buttonWidth - 10, 30)
        $refreshButton.SetBounds($width - $pad - $buttonWidth, 37, $buttonWidth, 32)

        # Two tiles per row; a last tile without a partner spans the whole row.
        $tileWidth = [int](($inner - 12) / 2)
        for ($index = 0; $index -lt $tiles.Count; $index++) {
            $top = 86 + [Math]::Floor($index / 2) * 82
            if ($index -eq $tiles.Count - 1 -and $index % 2 -eq 0) {
                $tiles[$index].SetBounds($pad, $top, $inner, 72)
            }
            else {
                $left = if ($index % 2 -eq 0) { $pad } else { $width - $pad - $tileWidth }
                $tiles[$index].SetBounds($left, $top, $tileWidth, 72)
            }
        }
        $y = 86 + [Math]::Ceiling($tiles.Count / 2) * 82 + 8

        $labelWidth = 86
        $fieldLeft = $pad + $labelWidth
        $fieldWidth = $inner - $labelWidth - $buttonWidth - 10
        $pathCaption.SetBounds($pad, $y, $inner, 20)
        $remoteLabel.SetBounds($pad, $y + 26, $labelWidth, 32)
        $remoteField.Frame.SetBounds($fieldLeft, $y + 26, $fieldWidth, 32)
        $defaultButton.SetBounds($width - $pad - $buttonWidth, $y + 26, $buttonWidth, 32)
        $exportLabel.SetBounds($pad, $y + 66, $labelWidth, 32)
        $exportField.Frame.SetBounds($fieldLeft, $y + 66, $fieldWidth, 32)
        $browseButton.SetBounds($width - $pad - $buttonWidth, $y + 66, $buttonWidth, 32)

        $statusLabel.SetBounds($pad, $y + 116, $inner - 112, 28)
        $clearButton.SetBounds($width - $pad - 86, $y + 114, 86, 32)
        $stopButton.SetBounds($width - $pad - 102, $y + 114, 102, 32)
        $output.Frame.SetBounds($pad, $y + 154, $inner, [Math]::Max(80, $height - $y - 154 - $pad))
    }

    function Set-Status {
        param([string]$Text, [string]$Kind = 'Muted')

        $statusLabel.ForeColor = switch ($Kind) {
            'Success' { $theme.Accent }
            'Failure' { $theme.Error }
            default { $theme.Muted }
        }
        $statusLabel.Text = $Text
        $statusLabel.Refresh()
    }

    function New-ResultLine {
        param(
            [string]$Label = '',
            [string]$Value = '',
            # Strong: the key result, bold and blue. Code: names and paths, monospaced. Muted: raw detail.
            [ValidateSet('Plain', 'Strong', 'Code', 'Muted', 'Error')]
            [string]$Style = 'Plain'
        )

        return [pscustomobject]@{ Label = $Label; Value = $Value; Style = $Style }
    }

    function Add-OutputText {
        param([string]$Text, [System.Drawing.Font]$Font, [System.Drawing.Color]$Color)

        $box = $output.Box
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionFont = $Font
        $box.SelectionColor = $Color
        $box.SelectedText = $Text
    }

    function Set-OutputParagraph {
        param([int]$Indent, [int]$Hanging)

        $box = $output.Box
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionIndent = $Indent
        $box.SelectionHangingIndent = $Hanging
        $box.SelectionTabs = [int[]]@($Indent + $Hanging)
    }

    function Write-Result {
        param(
            [string]$Title,
            [AllowEmptyCollection()]
            [object[]]$Lines = @(),
            [bool]$Success,
            [string]$Summary
        )

        # Each result: a header line, then "label  value" rows. A wrapped value continues under its own column.
        $word = if ($Success) { $T.Success } else { $T.Failure }
        $box = $output.Box
        $box.ReadOnly = $false
        try {
            Set-OutputParagraph -Indent 0 -Hanging 0
            if ($box.TextLength -gt 0) {
                Add-OutputText -Text "`n" -Font $fonts.ResultSmall -Color $theme.Muted
            }
            Add-OutputText -Text ((Get-Date -Format 'HH:mm:ss') + '   ') -Font $fonts.ResultSmall -Color $theme.Muted
            Add-OutputText -Text $Title -Font $fonts.ResultTitle -Color $theme.Text
            Add-OutputText -Text ('   ' + $word + "`n") -Font $fonts.ResultTitle -Color $(if ($Success) { $theme.Accent } else { $theme.Error })
            foreach ($item in $Lines) {
                $line = if ($item -isnot [string]) { $item } elseif ($Success) { New-ResultLine -Value $item } else { New-ResultLine -Value $item -Style Error }
                Set-OutputParagraph -Indent 14 -Hanging $(if ($line.Label) { 78 } else { 0 })
                if ($line.Label) {
                    Add-OutputText -Text ($line.Label + "`t") -Font $fonts.ResultSmall -Color $theme.Muted
                }
                switch ($line.Style) {
                    'Strong' { $font = $fonts.ResultStrong; $color = $theme.Accent }
                    'Code' { $font = $fonts.ResultCode; $color = $theme.Text }
                    'Muted' { $font = $fonts.ResultSmall; $color = $theme.Muted }
                    'Error' { $font = $fonts.Body; $color = $theme.Error }
                    default { $font = $fonts.Body; $color = $theme.Text }
                }
                Add-OutputText -Text ($line.Value + "`n") -Font $font -Color $color
            }
        }
        finally {
            $box.ReadOnly = $true
        }
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
        $summaryText = if ($Summary) { $Summary.Replace("`r", ' ').Replace("`n", ' ') } else { $word }
        Set-Status -Text ([string][char]0x25CF + '  ' + $word + '  ' + $summaryText) -Kind $(if ($Success) { 'Success' } else { 'Failure' })
    }

    function Set-Busy {
        param([bool]$Busy, [string]$Title = '')

        $state.Busy = $Busy
        foreach ($control in $busyControls) {
            $control.Enabled = -not $Busy
        }
        $form.UseWaitCursor = $Busy
        if ($Busy) {
            Set-Status -Text ($T.Running -f $Title)
        }
        else {
            # A disabled tile misses the mouse leaving it, so its highlight is worked out again here.
            foreach ($tile in $tiles) {
                $tile.Tag.Hover = $tile.ClientRectangle.Contains($tile.PointToClient([System.Windows.Forms.Cursor]::Position))
                $tile.Invalidate()
            }
        }
    }

    function Invoke-DevAction {
        param([string]$Title, [scriptblock]$Body)

        if ($state.Busy) {
            return
        }
        Set-Busy -Busy $true -Title $Title
        try {
            & $Body
        }
        catch {
            $message = $_.Exception.Message
            Write-Result -Title $Title -Lines @($message) -Success $false -Summary $message
        }
        finally {
            if (-not $form.IsDisposed) {
                Set-Busy -Busy $false
            }
        }
    }

    function Update-DeviceList {
        if (-not $state.AdbPath) {
            $state.AdbPath = Find-AdbPath
        }
        $devices = @()
        if ($state.AdbPath) {
            $result = Invoke-Adb -Arguments @('devices', '-l') -TimeoutSeconds 20
            if (-not $result.TimedOut) {
                $devices = @(ConvertFrom-AdbDeviceList -Text $result.Output)
            }
        }

        $state.Devices = $devices
        $state.Populating = $true
        try {
            $phoneBox.BeginUpdate()
            $phoneBox.Items.Clear()
            foreach ($device in $devices) {
                [void]$phoneBox.Items.Add((Get-DeviceLabel -Device $device))
            }
            if ($devices.Count -eq 0) {
                [void]$phoneBox.Items.Add($(if ($state.AdbPath) { $T.NoPhone } else { $T.NoAdb }))
                $phoneBox.SelectedIndex = 0
            }
            else {
                # Prefer the phone chosen last time, then the first one that is ready to use.
                $index = -1
                for ($i = 0; $i -lt $devices.Count; $i++) {
                    if ($devices[$i].Serial -eq $settings.Serial) { $index = $i; break }
                }
                if ($index -lt 0) {
                    for ($i = 0; $i -lt $devices.Count; $i++) {
                        if ($devices[$i].State -eq 'device') { $index = $i; break }
                    }
                }
                $phoneBox.SelectedIndex = [Math]::Max(0, $index)
            }
        }
        finally {
            $phoneBox.EndUpdate()
            $state.Populating = $false
        }
    }

    function Get-UsableDevice {
        param([string]$Title)

        if (-not $state.AdbPath) {
            $state.AdbPath = Find-AdbPath
        }
        if (-not $state.AdbPath) {
            Write-Result -Title $Title -Lines @($T.NoAdb) -Success $false -Summary $T.NoAdb
            return $null
        }
        $index = $phoneBox.SelectedIndex
        if ($index -lt 0 -or $index -ge @($state.Devices).Count) {
            Write-Result -Title $Title -Lines @($T.NeedPhone) -Success $false -Summary $T.NeedPhone
            return $null
        }
        $device = @($state.Devices)[$index]
        if ($device.State -ne 'device') {
            $message = $T.PhoneUnusable -f (Get-DeviceLabel -Device $device)
            Write-Result -Title $Title -Lines @($message) -Success $false -Summary $message
            return $null
        }
        return $device
    }

    function Save-PathInputs {
        param([string]$Title, [switch]$Quiet)

        $remote = $remoteField.Box.Text.Trim()
        if ($remote.Length -gt 1) {
            $remote = $remote.TrimEnd('/')
        }
        $export = $exportField.Box.Text.Trim()
        if ($export -notmatch '^[A-Za-z]:\\$') {
            $export = $export.TrimEnd('\')
        }
        if (-not (Test-RemoteLogPath -Path $remote)) {
            if (-not $Quiet) { Write-Result -Title $Title -Lines @($T.BadRemotePath) -Success $false -Summary $T.BadRemotePath }
            return $false
        }
        if (-not (Test-LocalExportPath -Path $export)) {
            if (-not $Quiet) { Write-Result -Title $Title -Lines @($T.BadExportPath) -Success $false -Summary $T.BadExportPath }
            return $false
        }
        $settings.RemoteLogPath = $remote
        $settings.ExportPath = $export
        try { Save-DevToolsSettings -Path $settingsPath -Settings $settings } catch { }
        return $true
    }

    function Invoke-ActivityCheck {
        $device = Get-UsableDevice -Title $T.Activity
        if ($null -eq $device) {
            return
        }
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-ResultLine -Label $T.LabelPhone -Value (Get-DeviceLabel -Device $device)))

        $result = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'dumpsys activity activities | grep -E ResumedActivity') -TimeoutSeconds 20
        if (Test-AdbFailed -Result $result) {
            $message = Get-AdbFailureText -Result $result
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
            Write-Result -Title $T.Activity -Lines $lines.ToArray() -Success $false -Summary $message
            return
        }
        $parsed = ConvertFrom-ActivityDump -Text $result.Output
        if ($null -eq $parsed.Activity) {
            # Some screens (lock screen, system dialogs) have no resumed activity; the focused window still tells what is shown.
            $focusResult = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'") -TimeoutSeconds 20
            $focus = ConvertFrom-WindowFocusDump -Text $focusResult.Output
            if ($null -eq $focus.Activity) {
                $lines.Add((New-ResultLine -Label $T.LabelResult -Value $T.ActivityMissing -Style Error))
                foreach ($line in @($parsed.Lines) + @($focus.Lines)) { $lines.Add((New-ResultLine -Label $T.LabelRaw -Value $line -Style Muted)) }
                Write-Result -Title $T.Activity -Lines $lines.ToArray() -Success $false -Summary $T.ActivityMissing
                return
            }
            $lines.Add((New-ResultLine -Label $T.LabelNote -Value $T.FocusFallback -Style Muted))
            $parsed = $focus
        }

        # The activity itself stands out; package and full class name follow on their own lines.
        $activity = $parsed.Activity
        $shortName = $activity.ClassName.Substring($activity.ClassName.LastIndexOf('.') + 1)
        $lines.Add((New-ResultLine -Label $T.LabelActivity -Value $shortName -Style Strong))
        $lines.Add((New-ResultLine -Label $T.LabelClass -Value $activity.ClassName -Style Code))
        $lines.Add((New-ResultLine -Label $T.LabelPackage -Value $activity.Package -Style Code))
        Write-Result -Title $T.Activity -Lines $lines.ToArray() -Success $true -Summary ($T.ActivitySummary -f $shortName)
    }

    function Wait-Ui {
        param([int]$Milliseconds)

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $Milliseconds -and -not $state.Closing) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
    }

    function Get-PhoneScreen {
        param($Device)

        # exec-out passes the PNG bytes through unchanged; "shell" would alter line endings in them.
        $result = Invoke-Adb -Arguments @('-s', $Device.Serial, 'exec-out', 'screencap -p') -TimeoutSeconds 30
        $bytes = [byte[]]$result.Bytes
        $isPng = $bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47
        if ($result.TimedOut -or -not $isPng) {
            $message = if ($result.TimedOut) { $T.TimedOut -f $result.TimeoutSeconds } else { $T.ScreenshotFailed }
            return [pscustomobject]@{ Bitmap = $null; Bytes = $bytes; Error = $message; Detail = (Get-AdbErrorDetail -Result $result) }
        }
        $stream = New-Object System.IO.MemoryStream(, $bytes)
        try {
            $decoded = [System.Drawing.Image]::FromStream($stream)
            try {
                # A copy that no longer depends on the stream.
                $bitmap = New-Object System.Drawing.Bitmap($decoded)
            }
            finally {
                $decoded.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
        return [pscustomobject]@{ Bitmap = $bitmap; Bytes = $bytes; Error = $null; Detail = '' }
    }

    function Copy-ImageToClipboard {
        param([System.Drawing.Image]$Image)

        try {
            [System.Windows.Forms.Clipboard]::SetImage($Image)
            return $null
        }
        catch {
            # Fails, for example, while the computer is locked or another program holds the clipboard.
            return $_.Exception.GetBaseException().Message
        }
    }

    function Save-Screenshot {
        param([string]$Prefix, [byte[]]$Bytes)

        $file = Join-Path ([Environment]::GetFolderPath('Desktop')) ($Prefix + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png')
        [IO.File]::WriteAllBytes($file, $Bytes)
        return $file
    }

    function Invoke-PhoneScreenshot {
        $device = Get-UsableDevice -Title $T.Screenshot
        if ($null -eq $device) {
            return
        }
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-ResultLine -Label $T.LabelPhone -Value (Get-DeviceLabel -Device $device)))
        $screen = Get-PhoneScreen -Device $device
        if ($null -eq $screen.Bitmap) {
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $screen.Error -Style Error))
            if ($screen.Detail) { $lines.Add((New-ResultLine -Label $T.LabelRaw -Value $screen.Detail -Style Muted)) }
            Write-Result -Title $T.Screenshot -Lines $lines.ToArray() -Success $false -Summary $screen.Error
            return
        }
        try {
            $file = Save-Screenshot -Prefix 'phone_screenshot_' -Bytes $screen.Bytes
            $lines.Add((New-ResultLine -Label $T.LabelFile -Value $file -Style Code))
            $lines.Add((New-ResultLine -Label $T.LabelSize -Value ('{0} x {1}' -f $screen.Bitmap.Width, $screen.Bitmap.Height)))
            $copyError = Copy-ImageToClipboard -Image $screen.Bitmap
        }
        finally {
            $screen.Bitmap.Dispose()
        }
        if ($copyError) {
            $message = $T.ClipboardFailed -f $copyError
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
        }
        else {
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $T.ScreenshotCopied -Style Strong))
        }
        Write-Result -Title $T.Screenshot -Lines $lines.ToArray() -Success (-not $copyError) -Summary $(if ($copyError) { $message } else { $T.ScreenshotDone })
        Show-ScreenshotPreview -Path $file -Bytes $screen.Bytes
    }

    function Invoke-LongScreenshot {
        $device = Get-UsableDevice -Title $T.LongScreenshot
        if ($null -eq $device) {
            return
        }
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-ResultLine -Label $T.LabelPhone -Value (Get-DeviceLabel -Device $device)))
        $frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
        $hashes = New-Object System.Collections.Generic.List[object]
        $offsets = New-Object System.Collections.Generic.List[int]
        $joins = New-Object System.Collections.Generic.List[int]
        $maxScreens = 12
        $state.Cancel = $false
        $stopButton.Visible = $true
        $clearButton.Visible = $false
        $stopNote = $T.LongReachedEnd
        try {
            $screen = Get-PhoneScreen -Device $device
            if ($null -eq $screen.Bitmap) {
                $lines.Add((New-ResultLine -Label $T.LabelResult -Value $screen.Error -Style Error))
                Write-Result -Title $T.LongScreenshot -Lines $lines.ToArray() -Success $false -Summary $screen.Error
                return
            }
            $frames.Add($screen.Bitmap)
            $hashes.Add((Get-ImageRowHashes -Bitmap $screen.Bitmap))
            $offsets.Add(0)
            $joins.Add(0)
            $width = $screen.Bitmap.Width
            $height = $screen.Bitmap.Height
            # A slow swipe over 40% of the screen: little fling, and always enough overlap to line screens up.
            $x = [int]($width / 2)
            $from = [int]($height * 0.72)
            $to = [int]($height * 0.32)

            while ($true) {
                if ($frames.Count -ge $maxScreens) { $stopNote = $T.LongReachedLimit -f $maxScreens; break }
                if ($state.Cancel -or $state.Closing) { $stopNote = $T.LongCancelled; break }
                Set-Status -Text ($T.LongProgress -f ($frames.Count + 1))
                $swipe = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', "input swipe $x $from $x $to 700") -TimeoutSeconds 20
                if (Test-AdbFailed -Result $swipe) { $stopNote = Get-AdbFailureText -Result $swipe; break }
                # Let the page settle and the scroll bar fade before taking the next screen. Samsung keeps the
                # scroll bar for about 2.2 seconds after a swipe; taken earlier, it would show up in the long image.
                Wait-Ui -Milliseconds 2500
                $next = Get-PhoneScreen -Device $device
                if ($null -eq $next.Bitmap) { $stopNote = $next.Error; break }
                $nextHashes = Get-ImageRowHashes -Bitmap $next.Bitmap
                $previousHashes = $hashes[$hashes.Count - 1]
                $bottom = $height - (Get-StaticBottomRows -RowHashes @($previousHashes, $nextHashes))
                $offset = Find-ScrollOffset -Previous $previousHashes -Next $nextHashes -ContentBottom $bottom
                if ($offset -le 0) {
                    # The page did not move any more: its end is reached.
                    $next.Bitmap.Dispose()
                    break
                }
                $frames.Add($next.Bitmap)
                $hashes.Add($nextHashes)
                $offsets.Add($offset)
                $joins.Add((Get-JoinRow -Previous $previousHashes -Next $nextHashes -Offset $offset -ContentBottom $bottom))
            }

            Set-Status -Text $T.LongJoining
            $image = Join-ScrollFrames -Frames $frames.ToArray() -Offsets $offsets.ToArray() -JoinRows $joins.ToArray()
            try {
                $stream = New-Object System.IO.MemoryStream
                $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $stream.ToArray()
                $stream.Dispose()
                $file = Save-Screenshot -Prefix 'phone_long_screenshot_' -Bytes $bytes
                $copyError = Copy-ImageToClipboard -Image $image
                $lines.Add((New-ResultLine -Label $T.LabelFile -Value $file -Style Code))
                $lines.Add((New-ResultLine -Label $T.LabelSize -Value ($T.LongSize -f $image.Width, $image.Height, $frames.Count)))
                $lines.Add((New-ResultLine -Label $T.LabelNote -Value $(if ($frames.Count -eq 1) { $T.LongNoScroll } else { $stopNote }) -Style Muted))
            }
            finally {
                $image.Dispose()
            }
            if ($copyError) {
                $message = $T.ClipboardFailed -f $copyError
                $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
            }
            else {
                $lines.Add((New-ResultLine -Label $T.LabelResult -Value $T.ScreenshotCopied -Style Strong))
            }
            Write-Result -Title $T.LongScreenshot -Lines $lines.ToArray() -Success (-not $copyError) -Summary $(if ($copyError) { $message } else { $T.LongDone -f $frames.Count })
            Show-ScreenshotPreview -Path $file -Bytes $bytes
        }
        finally {
            foreach ($frame in $frames) { $frame.Dispose() }
            if (-not $form.IsDisposed) {
                $stopButton.Visible = $false
                $clearButton.Visible = $true
            }
        }
    }

    # ---------------- Screenshot preview ----------------

    function New-PrimaryButton {
        param([string]$Text)

        $button = New-SmallButton -Text $Text
        $button.BackColor = $theme.Accent
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderSize = 0
        $button.FlatAppearance.MouseOverBackColor = $theme.AccentDark
        $button.FlatAppearance.MouseDownBackColor = $theme.AccentDark
        # Disabled, the button turns pale instead of showing grey text on the full blue.
        $button.Add_EnabledChanged({
            param($sender, $eventArgs)
            $sender.BackColor = if ($sender.Enabled) { $theme.Accent } else { $theme.AccentBorder }
        })
        return $button
    }

    function New-ScreenshotPreview {
        $previewForm = New-Object System.Windows.Forms.Form
        $previewForm.Font = $fonts.Body
        $previewForm.BackColor = $theme.Page
        $previewForm.ForeColor = $theme.Text
        $previewForm.MinimumSize = New-Object System.Drawing.Size(420, 360)
        $previewForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $previewForm.Icon = $form.Icon

        $copyButton = New-PrimaryButton -Text $T.CopyImage
        $openButton = New-SmallButton -Text $T.OpenImage
        $folderButton = New-SmallButton -Text $T.OpenFolder
        $info = New-Object System.Windows.Forms.Label
        $info.ForeColor = $theme.Muted
        $info.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $info.AutoEllipsis = $true

        $frame = New-Object System.Windows.Forms.Panel
        $frame.BackColor = $theme.Border
        $frame.Padding = New-Object System.Windows.Forms.Padding(1)
        $scroller = New-Object System.Windows.Forms.Panel
        $scroller.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 242)
        $scroller.AutoScroll = $true
        $scroller.Dock = [System.Windows.Forms.DockStyle]::Fill
        $picture = New-Object System.Windows.Forms.PictureBox
        $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $picture.BackColor = [System.Drawing.Color]::White
        $scroller.Controls.Add($picture)
        $frame.Controls.Add($scroller)

        $previewStatus = New-Object System.Windows.Forms.Label
        $previewStatus.ForeColor = $theme.Muted
        $previewStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $previewStatus.AutoEllipsis = $true

        $previewForm.Controls.AddRange([System.Windows.Forms.Control[]]@($copyButton, $openButton, $folderButton, $info, $frame, $previewStatus))
        $preview = [pscustomobject]@{
            Form = $previewForm
            Copy = $copyButton
            Open = $openButton
            Folder = $folderButton
            Info = $info
            Frame = $frame
            Scroller = $scroller
            Picture = $picture
            Status = $previewStatus
            Image = $null
            Path = ''
        }

        # The copy button copies the picture again at any time, for example after something else was copied.
        $copyButton.Add_Click({
            $preview = $state.Preview
            if ($null -eq $preview -or $null -eq $preview.Image) { return }
            $copyError = Copy-ImageToClipboard -Image $preview.Image
            if ($copyError) {
                $preview.Status.ForeColor = $theme.Error
                $preview.Status.Text = $T.ClipboardFailed -f $copyError
            }
            else {
                $preview.Status.ForeColor = $theme.Accent
                $preview.Status.Text = $T.ScreenshotCopied
            }
        })
        $openButton.Add_Click({
            if ($null -ne $state.Preview -and (Test-Path -LiteralPath $state.Preview.Path)) {
                Start-Process -FilePath $state.Preview.Path
            }
        })
        $folderButton.Add_Click({
            if ($null -ne $state.Preview -and (Test-Path -LiteralPath $state.Preview.Path)) {
                Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('/select,"' + $state.Preview.Path + '"')
            }
        })
        $scroller.Add_MouseEnter({ $state.Preview.Scroller.Focus() })
        $picture.Add_MouseEnter({ $state.Preview.Scroller.Focus() })
        $previewForm.Add_Resize({ Update-PreviewLayout })
        $previewForm.Add_FormClosed({
            if ($null -ne $state.Preview.Image) {
                $state.Preview.Picture.Image = $null
                $state.Preview.Image.Dispose()
            }
            $state.Preview = $null
        })
        return $preview
    }

    function Update-PreviewLayout {
        $preview = $state.Preview
        if ($null -eq $preview) { return }
        $width = $preview.Form.ClientSize.Width
        $height = $preview.Form.ClientSize.Height
        $pad = 14
        $preview.Copy.SetBounds($pad, 12, 118, 32)
        $preview.Open.SetBounds($pad + 126, 12, 86, 32)
        $preview.Folder.SetBounds($pad + 218, 12, 104, 32)
        $preview.Frame.SetBounds($pad, 54, $width - 2 * $pad, [Math]::Max(60, $height - 54 - 38))
        # Bottom line: what just happened on the left, picture size and file size on the right.
        $infoWidth = 170
        $preview.Status.SetBounds($pad, $height - 32, [Math]::Max(10, $width - 2 * $pad - $infoWidth), 26)
        $preview.Info.SetBounds($width - $pad - $infoWidth, $height - 32, $infoWidth, 26)
        if ($null -ne $preview.Image) {
            # Fit the width; a long screenshot then scrolls vertically.
            $room = $preview.Scroller.ClientSize.Width - 20
            if ($preview.Image.Height * $room / $preview.Image.Width -gt $preview.Scroller.ClientSize.Height) {
                $room = $preview.Scroller.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 22
            }
            $pictureWidth = [Math]::Max(40, $room)
            $pictureHeight = [int]($preview.Image.Height * $pictureWidth / $preview.Image.Width)
            $preview.Picture.SetBounds(10 + $preview.Scroller.AutoScrollPosition.X, 10 + $preview.Scroller.AutoScrollPosition.Y, $pictureWidth, $pictureHeight)
        }
    }

    function Show-ScreenshotPreview {
        param([string]$Path, [byte[]]$Bytes)

        if ($null -eq $state.Preview) {
            $state.Preview = New-ScreenshotPreview
        }
        $preview = $state.Preview
        if ($null -ne $preview.Image) {
            $preview.Picture.Image = $null
            $preview.Image.Dispose()
            $preview.Image = $null
        }
        $stream = New-Object System.IO.MemoryStream(, $Bytes)
        try {
            $decoded = [System.Drawing.Image]::FromStream($stream)
            try { $preview.Image = New-Object System.Drawing.Bitmap($decoded) } finally { $decoded.Dispose() }
        }
        finally {
            $stream.Dispose()
        }
        $preview.Path = $Path
        $preview.Picture.Image = $preview.Image
        $preview.Form.Text = $T.PreviewTitle -f (Split-Path -Leaf $Path)
        $preview.Info.Text = '{0} x {1}  {2}  {3}' -f $preview.Image.Width, $preview.Image.Height, [char]0x00B7, (Format-ByteSize -Bytes $Bytes.Length)
        $preview.Status.ForeColor = $theme.Accent
        $preview.Status.Text = $T.ScreenshotCopied
        if (-not $preview.Form.Visible) {
            # Beside the tool window, about as tall as the screen allows.
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $preview.Form.Size = New-Object System.Drawing.Size(480, [Math]::Min(900, $area.Height - 40))
            $left = if ($form.Left - 492 -ge $area.Left) { $form.Left - 492 } else { [Math]::Min($form.Right + 12, $area.Right - 480) }
            $top = [Math]::Max($area.Top, [Math]::Min($form.Top, $area.Bottom - $preview.Form.Height))
            $preview.Form.Location = New-Object System.Drawing.Point($left, $top)
            $preview.Form.Show()
        }
        $preview.Scroller.AutoScrollPosition = [System.Drawing.Point]::Empty
        Update-PreviewLayout
        if ($preview.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $preview.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $preview.Form.Activate()
    }

    function Invoke-GradleStop {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name='gradle.exe' OR Name='gradlew.exe'" -Property ProcessId, Name, CommandLine -ErrorAction SilentlyContinue)
        $targets = @(Select-GradleProcesses -Processes $processes -ExcludeIds @($PID))
        if ($targets.Count -eq 0) {
            Write-Result -Title $T.StopGradle -Lines @($T.GradleNone) -Success $true -Summary $T.GradleNone
            return
        }

        foreach ($target in $targets) {
            try { Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop } catch { }
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
            $remaining = @($targets | Where-Object { $null -ne (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) })
        } while ($remaining.Count -gt 0 -and $watch.Elapsed.TotalSeconds -lt 4)

        $kindNames = @{ Daemon = $T.GradleDaemon; Wrapper = $T.GradleWrapper; Worker = $T.GradleWorker; Gradle = $T.GradleOther; Kotlin = $T.GradleKotlin }
        $remainingIds = @($remaining | ForEach-Object { $_.ProcessId })
        $stopped = $targets.Count - $remaining.Count
        $lines = New-Object System.Collections.Generic.List[object]
        if ($remaining.Count -eq 0) {
            $summary = $T.GradleStopped -f $stopped
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $summary -Style Strong))
        }
        else {
            $summary = ($T.GradleRemain -f $remaining.Count).TrimEnd(([char]0xFF1A), ':')
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $summary -Style Error))
        }
        foreach ($target in $targets) {
            $name = $kindNames[$target.Kind]
            if ($target.Version) { $name += ' ' + $target.Version }
            $kept = $remainingIds -contains $target.ProcessId
            $outcome = if ($kept) { $T.NotStopped } else { $T.Stopped }
            $lines.Add((New-ResultLine -Label ('PID ' + $target.ProcessId) -Value ($name + '   ' + $outcome) -Style $(if ($kept) { 'Error' } else { 'Plain' })))
        }
        Write-Result -Title $T.StopGradle -Lines $lines.ToArray() -Success ($remaining.Count -eq 0) -Summary $summary
    }

    function Invoke-BleExport {
        $device = Get-UsableDevice -Title $T.ExportBle
        if ($null -eq $device -or -not (Save-PathInputs -Title $T.ExportBle)) {
            return
        }
        $remote = $settings.RemoteLogPath
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-ResultLine -Label $T.LabelPhone -Value (Get-DeviceLabel -Device $device)))

        $check = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', "if [ -d '$remote' ]; then echo FOUND; fi") -TimeoutSeconds 20
        if (Test-AdbFailed -Result $check) {
            $message = Get-AdbFailureText -Result $check
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
            Write-Result -Title $T.ExportBle -Lines $lines.ToArray() -Success $false -Summary $message
            return
        }
        if ($check.Output -notmatch 'FOUND') {
            $message = $T.RemoteMissing -f $remote
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value ($message -replace "`r?`n", ' ') -Style Error))
            Write-Result -Title $T.ExportBle -Lines $lines.ToArray() -Success $false -Summary $message
            return
        }

        $target = Join-Path $settings.ExportPath (Get-DeviceFolderName -Model $device.Model -Serial $device.Serial)
        try {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        catch {
            $message = $T.CannotCreate -f $target
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
            Write-Result -Title $T.ExportBle -Lines $lines.ToArray() -Success $false -Summary $message
            return
        }

        $leaf = $remote.Substring($remote.LastIndexOf('/') + 1)
        $destination = Join-Path $target $leaf
        $lines.Add((New-ResultLine -Label $T.LabelFrom -Value $remote -Style Code))
        $lines.Add((New-ResultLine -Label $T.LabelTo -Value $destination -Style Code))
        $result = Invoke-Adb -Arguments @('-s', $device.Serial, 'pull', $remote, $target) -TimeoutSeconds 900
        # adb's own summary line, e.g. "120 files pulled, 0 skipped. 32.5 MB/s (264470723 bytes in 7.769s)".
        foreach ($line in @((($result.Output + "`n" + $result.Error) -split "`r?`n") | Where-Object { $_.Trim() -and -not $_.StartsWith('*') } | Select-Object -Last 3)) {
            $text = $line.Trim()
            $colon = $text.IndexOf(': ')
            if ($colon -gt 0 -and $text.StartsWith('/')) { $text = $text.Substring($colon + 2) }
            $lines.Add((New-ResultLine -Label 'adb' -Value $text -Style Muted))
        }
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            $message = if ($result.TimedOut) { $T.TimedOut -f $result.TimeoutSeconds } else { $T.ExportFailed }
            $lines.Add((New-ResultLine -Label $T.LabelResult -Value $message -Style Error))
            Write-Result -Title $T.ExportBle -Lines $lines.ToArray() -Success $false -Summary $message
            return
        }

        $summary = $T.ExportDone -f $destination
        $lines.Add((New-ResultLine -Label $T.LabelResult -Value $T.ExportOpened -Style Strong))
        Write-Result -Title $T.ExportBle -Lines $lines.ToArray() -Success $true -Summary $summary
        $folder = if (Test-Path -LiteralPath $destination) { $destination } else { $target }
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"' + $folder + '"')
    }

    # ---------------- Phone file browser and log viewer ----------------

    function New-EntryIcons {
        # Folder and file pictures for the list, drawn here so they look the same on every Windows version.
        $icons = New-Object System.Windows.Forms.ImageList
        $icons.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
        $icons.ImageSize = New-Object System.Drawing.Size(24, 26)
        foreach ($kind in 'Folder', 'File') {
            $bitmap = New-Object System.Drawing.Bitmap(24, 26, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $pen = New-Object System.Drawing.Pen($(if ($kind -eq 'Folder') { $theme.Accent } else { $theme.Muted }))
            try {
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                if ($kind -eq 'Folder') {
                    $tab = New-RoundedPath -X 4 -Y 6 -Width 8 -Height 6 -Radius 1.5
                    $body = New-RoundedPath -X 4 -Y 8.5 -Width 17 -Height 11.5 -Radius 2
                    $fill = New-Object System.Drawing.SolidBrush($theme.AccentBorder)
                    try {
                        $graphics.FillPath($fill, $tab)
                        $graphics.FillPath($fill, $body)
                        $graphics.DrawPath($pen, $body)
                    }
                    finally {
                        $fill.Dispose()
                        $tab.Dispose()
                        $body.Dispose()
                    }
                }
                else {
                    $page = New-Object System.Drawing.Drawing2D.GraphicsPath
                    $page.AddPolygon([System.Drawing.PointF[]]@(
                        [System.Drawing.PointF]::new(6.5, 4.5), [System.Drawing.PointF]::new(14, 4.5), [System.Drawing.PointF]::new(18.5, 9),
                        [System.Drawing.PointF]::new(18.5, 21.5), [System.Drawing.PointF]::new(6.5, 21.5)))
                    try {
                        $graphics.FillPath([System.Drawing.Brushes]::White, $page)
                        $graphics.DrawPath($pen, $page)
                        $graphics.DrawLines($pen, [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(14, 4.5), [System.Drawing.PointF]::new(14, 9), [System.Drawing.PointF]::new(18.5, 9)))
                        foreach ($lineY in 12.5, 15.5, 18.5) { $graphics.DrawLine($pen, 9, $lineY, 16, $lineY) }
                    }
                    finally {
                        $page.Dispose()
                    }
                }
            }
            finally {
                $pen.Dispose()
                $graphics.Dispose()
            }
            $icons.Images.Add($kind, $bitmap)
        }
        return $icons
    }

    function New-GlyphButton {
        param([string]$Glyph, [string]$Tip, [System.Windows.Forms.ToolTip]$Tips)

        $button = New-SmallButton -Text $Glyph
        $button.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)
        $button.ForeColor = $theme.Text
        $Tips.SetToolTip($button, $Tip)
        return $button
    }

    function New-LogViewer {
        $viewerForm = New-Object System.Windows.Forms.Form
        $viewerForm.Font = $fonts.Body
        $viewerForm.BackColor = $theme.Page
        $viewerForm.ForeColor = $theme.Text
        $viewerForm.ClientSize = New-Object System.Drawing.Size(1100, 700)
        $viewerForm.MinimumSize = New-Object System.Drawing.Size(760, 460)
        $viewerForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $viewerForm.Icon = $form.Icon
        $viewerForm.KeyPreview = $true

        $tips = New-Object System.Windows.Forms.ToolTip
        $backButton = New-GlyphButton -Glyph ([string][char]0xE72B) -Tip $T.BackTip -Tips $tips
        $forwardButton = New-GlyphButton -Glyph ([string][char]0xE72A) -Tip $T.ForwardTip -Tips $tips
        $upButton = New-GlyphButton -Glyph ([string][char]0xE74A) -Tip $T.UpTip -Tips $tips
        $refreshListButton = New-GlyphButton -Glyph ([string][char]0xE72C) -Tip $T.RefreshTip -Tips $tips
        $saveButton = New-PrimaryButton -Text $T.SaveToPc
        $tips.SetToolTip($saveButton, $T.SaveTip)
        # The address box works like Explorer's: type a phone path and press Enter.
        $addressField = New-InputField
        $addressField.Box.Font = $fonts.ResultCode
        $tips.SetToolTip($addressField.Box, $T.AddressTip)
        $filterLabel = New-Object System.Windows.Forms.Label
        $filterLabel.Text = $T.Filter
        $filterLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $filterField = New-InputField

        $split = New-Object System.Windows.Forms.SplitContainer
        $split.BackColor = $theme.Page
        $split.SplitterWidth = 10
        $split.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1

        $listFrame = New-Object System.Windows.Forms.Panel
        $listFrame.BackColor = $theme.Border
        $listFrame.Padding = New-Object System.Windows.Forms.Padding(1)
        $listFrame.Dock = [System.Windows.Forms.DockStyle]::Fill
        $list = New-Object System.Windows.Forms.ListView
        $list.View = [System.Windows.Forms.View]::Details
        $list.FullRowSelect = $true
        $list.MultiSelect = $false
        $list.HideSelection = $false
        $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
        $list.Dock = [System.Windows.Forms.DockStyle]::Fill
        $list.Font = $fonts.Body
        $list.ShowItemToolTips = $true
        $list.SmallImageList = New-EntryIcons
        [void]$list.Columns.Add($T.Name, 190)
        [void]$list.Columns.Add($T.Size, 78, [System.Windows.Forms.HorizontalAlignment]::Right)
        [void]$list.Columns.Add($T.Modified, 90)
        $listFrame.Controls.Add($list)
        $split.Panel1.Controls.Add($listFrame)

        $content = New-FramedTextArea -Background $theme.Card -Font $fonts.Log -WordWrap $false
        $content.Frame.Dock = [System.Windows.Forms.DockStyle]::Fill
        $split.Panel2.Controls.Add($content.Frame)

        $viewerStatus = New-Object System.Windows.Forms.Label
        $viewerStatus.ForeColor = $theme.Muted
        $viewerStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $viewerStatus.AutoEllipsis = $true

        $filterTimer = New-Object System.Windows.Forms.Timer
        $filterTimer.Interval = 300

        # Right-click on a file or folder offers the same save as the button.
        $listMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $listMenu.Font = $fonts.Body
        $saveMenuItem = $listMenu.Items.Add($T.SaveToPc + '...')
        $saveMenuItem.ShortcutKeyDisplayString = 'Ctrl+S'
        $list.ContextMenuStrip = $listMenu

        $viewerForm.Controls.AddRange([System.Windows.Forms.Control[]]@($backButton, $forwardButton, $upButton, $refreshListButton, $addressField.Frame, $saveButton, $filterLabel, $filterField.Frame, $split, $viewerStatus))
        $viewer = [pscustomobject]@{
            Form = $viewerForm
            Tips = $tips
            Back = $backButton
            Forward = $forwardButton
            Up = $upButton
            Refresh = $refreshListButton
            Save = $saveButton
            Menu = $listMenu
            Address = $addressField
            FilterLabel = $filterLabel
            Filter = $filterField
            Split = $split
            List = $list
            Content = $content.Box
            Status = $viewerStatus
            FilterTimer = $filterTimer
            Device = $null
            Directory = ''
            History = (New-Object System.Collections.Generic.List[string])
            HistoryIndex = -1
            Text = ''
            Lines = [string[]]@()
            FileName = ''
            FilePath = ''
            LoadingPath = ''
            Pending = $null
            Busy = $false
        }

        $viewerForm.Add_Resize({ Update-ViewerLayout })
        $split.Add_SplitterMoved({ Update-ViewerColumns })
        $backButton.Add_Click({ Move-ViewerHistory -Step -1 })
        $forwardButton.Add_Click({ Move-ViewerHistory -Step 1 })
        $upButton.Add_Click({ Open-ViewerParent })
        $refreshListButton.Add_Click({ Update-ViewerFolder })
        $saveButton.Add_Click({ Save-ViewerItem })
        $saveMenuItem.Add_Click({ Save-ViewerItem })
        $listMenu.Add_Opening({
            param($sender, $eventArgs)
            # Nothing to save under the mouse, or a save already running: no menu.
            if ($state.Viewer.List.SelectedItems.Count -eq 0 -or $state.Viewer.Busy) { $eventArgs.Cancel = $true }
        })
        $addressField.Box.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $eventArgs.SuppressKeyPress = $true
                Set-ViewerDirectory -Path $sender.Text
            }
            elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
                $eventArgs.SuppressKeyPress = $true
                $sender.Text = $state.Viewer.Directory
            }
        })
        # A single click on a file shows it; a double click (or Enter) on a folder opens it, as in Explorer.
        $list.Add_SelectedIndexChanged({
            $viewer = $state.Viewer
            Update-ViewerButtons
            if ($viewer.List.SelectedItems.Count -gt 0 -and -not $viewer.List.SelectedItems[0].Tag.IsDirectory) {
                Request-ViewerFile -File $viewer.List.SelectedItems[0].Tag
            }
        })
        $list.Add_ItemActivate({
            $viewer = $state.Viewer
            if ($viewer.List.SelectedItems.Count -gt 0 -and $viewer.List.SelectedItems[0].Tag.IsDirectory) {
                Set-ViewerDirectory -Path $viewer.List.SelectedItems[0].Tag.Path
            }
        })
        $viewerForm.Add_KeyDown({
            param($sender, $eventArgs)
            $viewer = $state.Viewer
            $typing = $viewer.Address.Box.Focused -or $viewer.Filter.Box.Focused
            if ($eventArgs.Alt -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Left) { $eventArgs.Handled = $true; Move-ViewerHistory -Step -1 }
            elseif ($eventArgs.Alt -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Right) { $eventArgs.Handled = $true; Move-ViewerHistory -Step 1 }
            elseif ($eventArgs.Alt -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Up) { $eventArgs.Handled = $true; Open-ViewerParent }
            elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Back -and -not $typing) { $eventArgs.Handled = $true; Open-ViewerParent }
            elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) { $eventArgs.Handled = $true; Update-ViewerFolder }
            elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::S) { $eventArgs.SuppressKeyPress = $true; Save-ViewerItem }
        })
        $filterField.Box.Add_TextChanged({ $state.Viewer.FilterTimer.Stop(); $state.Viewer.FilterTimer.Start() })
        $filterTimer.Add_Tick({ $state.Viewer.FilterTimer.Stop(); Update-ViewerContent })
        $viewerForm.Add_FormClosed({
            $state.Viewer.FilterTimer.Dispose()
            $state.Viewer.Tips.Dispose()
            $state.Viewer = $null
        })
        return $viewer
    }

    function Update-ViewerLayout {
        $viewer = $state.Viewer
        if ($null -eq $viewer) { return }
        $width = $viewer.Form.ClientSize.Width
        $height = $viewer.Form.ClientSize.Height
        $pad = 16
        $viewer.Back.SetBounds($pad, 14, 36, 32)
        $viewer.Forward.SetBounds($pad + 40, 14, 36, 32)
        $viewer.Up.SetBounds($pad + 80, 14, 36, 32)
        $viewer.Refresh.SetBounds($pad + 120, 14, 36, 32)
        $filterWidth = 260
        $viewer.Filter.Frame.SetBounds($width - $pad - $filterWidth, 14, $filterWidth, 32)
        $viewer.FilterLabel.SetBounds($width - $pad - $filterWidth - 50, 14, 44, 32)
        $addressLeft = $pad + 166
        $saveWidth = 104
        $addressWidth = [Math]::Max(120, $width - $pad - $filterWidth - 60 - $saveWidth - 10 - $addressLeft)
        $viewer.Address.Frame.SetBounds($addressLeft, 14, $addressWidth, 32)
        $viewer.Save.SetBounds($addressLeft + $addressWidth + 10, 14, $saveWidth, 32)
        $viewer.Split.SetBounds($pad, 58, $width - 2 * $pad, [Math]::Max(100, $height - 58 - 40))
        $viewer.Status.SetBounds($pad, $height - 36, $width - 2 * $pad, 28)
        Update-ViewerColumns
    }

    function Update-ViewerColumns {
        $viewer = $state.Viewer
        if ($null -eq $viewer) { return }
        # Room for the vertical scroll bar is always kept, so a long list never adds a horizontal one.
        $nameWidth = $viewer.List.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - $viewer.List.Columns[1].Width - $viewer.List.Columns[2].Width - 4
        $viewer.List.Columns[0].Width = [Math]::Max(120, $nameWidth)
    }

    function Update-ViewerButtons {
        $viewer = $state.Viewer
        if ($null -eq $viewer) { return }
        $idle = -not $viewer.Busy
        $viewer.Back.Enabled = $idle -and $viewer.HistoryIndex -gt 0
        $viewer.Forward.Enabled = $idle -and $viewer.HistoryIndex -lt ($viewer.History.Count - 1)
        $viewer.Up.Enabled = $idle -and $viewer.Directory -and $viewer.Directory -ne '/'
        $viewer.Refresh.Enabled = $idle
        $viewer.Save.Enabled = $idle -and ($viewer.List.SelectedItems.Count -gt 0 -or [bool]$viewer.FilePath)
    }

    function Set-ViewerStatus {
        param([string]$Text, [switch]$Failure, [switch]$Success)

        $viewer = $state.Viewer
        if ($null -eq $viewer) { return }
        $viewer.Status.ForeColor = if ($Failure) { $theme.Error } elseif ($Success) { $theme.Accent } else { $theme.Muted }
        $viewer.Status.Text = $Text
        $viewer.Status.Refresh()
    }

    function Set-ViewerDirectory {
        param(
            [string]$Path,
            # Moving with Back / Forward keeps the history as it is.
            [switch]$FromHistory,
            # On opening: go into the newest folder and show the newest file, so the latest log is on screen at once.
            [int]$OpenNewestDepth = 0
        )

        $viewer = $state.Viewer
        if ($null -eq $viewer -or $viewer.Busy) { return }
        $target = ConvertTo-RemotePath -Path $Path
        if (-not (Test-RemoteBrowsePath -Path $target)) {
            Set-ViewerStatus -Text $T.BadBrowsePath -Failure
            $viewer.Address.Box.Text = $viewer.Directory
            return
        }

        $newestFile = $null
        $newestFolder = $null
        $viewer.Busy = $true
        Update-ViewerButtons
        $viewer.Form.UseWaitCursor = $true
        try {
            Set-ViewerStatus -Text ($T.Loading -f $target)
            $command = "if cd '$target' 2>/dev/null; then find . -mindepth 1 -maxdepth 1 -exec stat -L -c '%F|%s|%Y|%n' {} + 2>/dev/null; else echo MISSING; fi"
            $result = Invoke-Adb -Arguments @('-s', $viewer.Device.Serial, 'shell', $command) -TimeoutSeconds 60
            if ($null -eq $state.Viewer) { return }
            if (Test-AdbFailed -Result $result) {
                Set-ViewerStatus -Text ($T.ListFailed -f (Get-AdbFailureText -Result $result)) -Failure
                $viewer.Address.Box.Text = $viewer.Directory
                return
            }
            if ($result.Output.Trim() -eq 'MISSING') {
                Set-ViewerStatus -Text ($T.FolderMissing -f $target) -Failure
                $viewer.Address.Box.Text = $viewer.Directory
                return
            }

            $entries = @(ConvertFrom-RemoteDirListing -Text $result.Output -Directory $target)
            $viewer.Directory = $target
            $viewer.Address.Box.Text = $target
            if (-not $FromHistory) {
                # Going somewhere new drops the forward history, as in Explorer.
                while ($viewer.History.Count -gt $viewer.HistoryIndex + 1) {
                    $viewer.History.RemoveAt($viewer.History.Count - 1)
                }
                if ($viewer.History.Count -eq 0 -or $viewer.History[$viewer.History.Count - 1] -ne $target) {
                    $viewer.History.Add($target)
                }
                $viewer.HistoryIndex = $viewer.History.Count - 1
            }

            $viewer.List.BeginUpdate()
            $viewer.List.Items.Clear()
            $folders = 0
            foreach ($entry in $entries) {
                $item = New-Object System.Windows.Forms.ListViewItem($entry.Name)
                $item.ImageKey = if ($entry.IsDirectory) { 'Folder' } else { 'File' }
                [void]$item.SubItems.Add($(if ($entry.IsDirectory) { '' } else { Format-ByteSize -Bytes $entry.Size }))
                [void]$item.SubItems.Add($entry.Modified.ToString('MM-dd HH:mm'))
                $item.ToolTipText = $entry.Path
                $item.Tag = $entry
                [void]$viewer.List.Items.Add($item)
                if ($entry.IsDirectory) {
                    $folders++
                    if ($null -eq $newestFolder) { $newestFolder = $entry }
                }
                elseif ($null -eq $newestFile) {
                    $newestFile = $entry
                }
            }
            $viewer.List.EndUpdate()
            Set-ViewerStatus -Text ($T.FolderCount -f $folders, ($entries.Count - $folders))
        }
        finally {
            if ($null -ne $state.Viewer) {
                $viewer.Busy = $false
                $viewer.Form.UseWaitCursor = $false
                Update-ViewerButtons
            }
        }

        if ($null -eq $state.Viewer) { return }
        # Keep the file on screen selected when its folder is shown again.
        foreach ($item in $viewer.List.Items) {
            if ($item.Tag.Path -eq $viewer.FilePath) {
                $item.Selected = $true
                $item.EnsureVisible()
                break
            }
        }
        if ($OpenNewestDepth -gt 0) {
            if ($null -ne $newestFile) {
                $viewer.List.Items[$entries.IndexOf($newestFile)].Selected = $true
                Request-ViewerFile -File $newestFile
            }
            elseif ($null -ne $newestFolder) {
                Set-ViewerDirectory -Path $newestFolder.Path -OpenNewestDepth ($OpenNewestDepth - 1)
            }
        }
    }

    function Move-ViewerHistory {
        param([int]$Step)

        $viewer = $state.Viewer
        if ($null -eq $viewer -or $viewer.Busy) { return }
        $index = $viewer.HistoryIndex + $Step
        if ($index -lt 0 -or $index -ge $viewer.History.Count) { return }
        $viewer.HistoryIndex = $index
        Set-ViewerDirectory -Path $viewer.History[$index] -FromHistory
    }

    function Open-ViewerParent {
        $viewer = $state.Viewer
        if ($null -eq $viewer -or -not $viewer.Directory) { return }
        $parent = Get-RemoteParentPath -Path $viewer.Directory
        if ($null -ne $parent) {
            Set-ViewerDirectory -Path $parent
        }
    }

    function Update-ViewerFolder {
        # Refresh: list the folder again and reload the file on screen, since logs keep growing.
        $viewer = $state.Viewer
        if ($null -eq $viewer -or $viewer.Busy -or -not $viewer.Directory) { return }
        Set-ViewerDirectory -Path $viewer.Directory -FromHistory
        if ($null -eq $state.Viewer) { return }
        foreach ($item in $viewer.List.Items) {
            if ($item.Tag.Path -eq $viewer.FilePath) {
                Request-ViewerFile -File $item.Tag -Force
                break
            }
        }
    }

    function Save-ViewerItem {
        # Copies the selected phone file or folder to this computer, as the phone stores it (not the filtered view).
        $viewer = $state.Viewer
        if ($null -eq $viewer -or $viewer.Busy) { return }
        $entry = $null
        if ($viewer.List.SelectedItems.Count -gt 0) {
            $entry = $viewer.List.SelectedItems[0].Tag
        }
        elseif ($viewer.FilePath) {
            $entry = [pscustomobject]@{ Name = $viewer.FileName; Path = $viewer.FilePath; IsDirectory = $false }
        }
        if ($null -eq $entry) {
            Set-ViewerStatus -Text $T.SaveNothing -Failure
            return
        }

        # Start where the last save went, else the export folder, else the desktop.
        $startFolder = [Environment]::GetFolderPath('Desktop')
        foreach ($candidate in @($settings.SaveFolder, $settings.ExportPath)) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { $startFolder = $candidate; break }
        }
        if ($entry.IsDirectory) {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            try {
                $dialog.Description = $T.SaveFolderDialog -f $entry.Name
                $dialog.SelectedPath = $startFolder
                if ($dialog.ShowDialog($viewer.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
                $folder = $dialog.SelectedPath
            }
            finally {
                $dialog.Dispose()
            }
            # adb puts the folder itself inside the chosen one.
            $pullTarget = $folder
            $destination = Join-Path $folder $entry.Name
        }
        else {
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            try {
                $dialog.Title = $T.SaveToPc
                $dialog.FileName = $entry.Name
                $dialog.InitialDirectory = $startFolder
                $dialog.Filter = $T.AllFiles + '|*.*'
                $dialog.OverwritePrompt = $true
                if ($dialog.ShowDialog($viewer.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
                $destination = $dialog.FileName
            }
            finally {
                $dialog.Dispose()
            }
            $pullTarget = $destination
            $folder = Split-Path -Parent $destination
        }
        $settings.SaveFolder = $folder
        try { Save-DevToolsSettings -Path $settingsPath -Settings $settings } catch { }

        $viewer.Busy = $true
        Update-ViewerButtons
        $viewer.Form.UseWaitCursor = $true
        try {
            Set-ViewerStatus -Text ($T.Saving -f $entry.Name)
            $result = Invoke-Adb -Arguments @('-s', $viewer.Device.Serial, 'pull', $entry.Path, $pullTarget) -TimeoutSeconds 900
        }
        finally {
            if ($null -ne $state.Viewer) {
                $viewer.Busy = $false
                $viewer.Form.UseWaitCursor = $false
                Update-ViewerButtons
            }
        }
        if ($null -eq $state.Viewer) { return }
        if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $destination)) {
            $detail = if ($result.TimedOut) { $T.TimedOut -f $result.TimeoutSeconds } else { Get-AdbErrorDetail -Result $result }
            if (-not $detail) { $detail = 'exit code ' + $result.ExitCode }
            Set-ViewerStatus -Text ($T.SaveFailed -f $detail) -Failure
            return
        }
        Set-ViewerStatus -Text ($T.Saved -f $destination) -Success
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('/select,"' + $destination + '"')
    }

    function Request-ViewerFile {
        param($File, [switch]$Force)

        $viewer = $state.Viewer
        if ($null -eq $viewer -or $null -eq $File) { return }
        if (-not $Force -and ($File.Path -eq $viewer.LoadingPath -or ($File.Path -eq $viewer.FilePath -and -not $viewer.Busy))) { return }
        # Clicking through files quickly only loads the last one clicked.
        $viewer.Pending = $File
        if ($viewer.Busy) { return }
        $viewer.Busy = $true
        Update-ViewerButtons
        try {
            while ($null -ne $state.Viewer -and $null -ne $viewer.Pending) {
                $next = $viewer.Pending
                $viewer.Pending = $null
                $viewer.LoadingPath = $next.Path
                Show-ViewerFile -File $next
                $viewer.LoadingPath = ''
            }
        }
        finally {
            if ($null -ne $state.Viewer) {
                $viewer.Busy = $false
                Update-ViewerButtons
            }
        }
    }

    function Show-ViewerFile {
        param($File)

        $viewer = $state.Viewer
        if (-not (Test-RemoteLogPath -Path $File.Path)) {
            Set-ViewerStatus -Text ($T.ReadFailed -f $File.Name) -Failure
            return
        }
        if ($File.Size -gt 64MB) {
            Set-ViewerStatus -Text ($T.FileTooLarge -f $File.Name, (Format-ByteSize -Bytes $File.Size)) -Failure
            return
        }
        Set-ViewerStatus -Text ($T.Loading -f $File.Name)
        $result = Invoke-Adb -Arguments @('-s', $viewer.Device.Serial, 'exec-out', "cat '$($File.Path)'") -TimeoutSeconds 120
        if ($null -eq $state.Viewer) { return }
        if (Test-AdbFailed -Result $result) {
            Set-ViewerStatus -Text ($T.ReadFailed -f (Get-AdbFailureText -Result $result)) -Failure
            return
        }
        if (-not (Test-TextContent -Bytes $result.Bytes)) {
            Set-ViewerStatus -Text ($T.NotText -f $File.Name) -Failure
            return
        }
        $text = $result.Output.TrimEnd("`r", "`n")
        $viewer.Lines = [string[]](Format-LogLines -Lines ([string[]]($text -split "`r?`n")))
        $viewer.Text = [string]::Join("`r`n", $viewer.Lines)
        $viewer.FileName = $File.Name
        $viewer.FilePath = $File.Path
        Update-ViewerContent
    }

    function Update-ViewerContent {
        $viewer = $state.Viewer
        if ($null -eq $viewer -or -not $viewer.FileName) { return }
        $filter = $viewer.Filter.Box.Text.Trim()
        $total = $viewer.Lines.Count
        if ($filter) {
            $matched = [string[]]@(Select-LogLines -Lines $viewer.Lines -Filter $filter)
            $viewer.Content.Text = [string]::Join("`r`n", $matched)
            $summary = $T.ShowingFiltered -f $viewer.FileName, $total, $matched.Count, $filter
        }
        else {
            $viewer.Content.Text = $viewer.Text
            $summary = $T.Showing -f $viewer.FileName, $total
        }
        # Logs grow at the end, so show the latest lines first; the caret goes to the start of the last line
        # so the view does not also scroll sideways to the end of a long line.
        $shown = $viewer.Content.Text
        $viewer.Content.SelectionStart = $shown.LastIndexOf("`n") + 1
        $viewer.Content.SelectionLength = 0
        $viewer.Content.ScrollToCaret()
        Set-ViewerStatus -Text $summary
    }

    function Open-LogViewer {
        $device = Get-UsableDevice -Title $T.ShowBle
        if ($null -eq $device -or -not (Save-PathInputs -Title $T.ShowBle)) {
            return
        }
        if ($null -eq $state.Viewer) {
            $state.Viewer = New-LogViewer
        }
        $viewer = $state.Viewer
        $label = Get-DeviceLabel -Device $device
        $viewer.Device = $device
        $viewer.History.Clear()
        $viewer.HistoryIndex = -1
        $viewer.Directory = ''
        $viewer.FilePath = ''
        $viewer.FileName = ''
        $viewer.Content.Clear()
        $viewer.List.Items.Clear()
        $viewer.Form.Text = $T.ViewerTitle -f $label
        if (-not $viewer.Form.Visible) {
            # Wide enough for whole log lines: most of the screen the tool window is on, centred on it.
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $viewer.Form.Size = New-Object System.Drawing.Size([Math]::Min(1720, $area.Width - 40), [Math]::Min(920, $area.Height - 40))
            $viewer.Form.Location = New-Object System.Drawing.Point(($area.Left + [int](($area.Width - $viewer.Form.Width) / 2)), ($area.Top + [int](($area.Height - $viewer.Form.Height) / 2)))
            $viewer.Form.Show()
            Update-ViewerLayout
            $viewer.Split.SplitterDistance = 380
            Update-ViewerColumns
        }
        if ($viewer.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $viewer.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $viewer.Form.Activate()
        $openedLines = @(
            (New-ResultLine -Label $T.LabelPhone -Value $label),
            (New-ResultLine -Label $T.LabelFrom -Value $settings.RemoteLogPath -Style Code)
        )
        Write-Result -Title $T.ShowBle -Lines $openedLines -Success $true -Summary ($T.ViewerOpened -f $label)
        Set-ViewerDirectory -Path $settings.RemoteLogPath -OpenNewestDepth 3
    }

    # ---------------- Task stacks ----------------

    $stackLayout = [pscustomobject]@{ CardWidth = 420; Header = 72; Block = 48; Gap = 6; ContainerLeft = 66 }

    function Get-TaskCardHeight {
        param([int]$Count)

        return $stackLayout.Header + 10 + $Count * ($stackLayout.Block + $stackLayout.Gap) - $stackLayout.Gap + 10 + 18
    }

    function Add-Pill {
        param($Graphics, [string]$Text, [int]$X, [int]$Y, [System.Drawing.Color]$Fill, [System.Drawing.Color]$Color, [switch]$AlignRight)

        $size = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $fonts.Badge)
        $width = $size.Width + 8
        $left = if ($AlignRight) { $X - $width } else { $X }
        $path = New-RoundedPath -X $left -Y $Y -Width $width -Height 20 -Radius 10
        $brush = New-Object System.Drawing.SolidBrush($Fill)
        try {
            $Graphics.FillPath($brush, $path)
            [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Text, $fonts.Badge, [System.Drawing.Rectangle]::new($left, $Y, $width, 20), $Color, [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, NoPadding')
        }
        finally {
            $brush.Dispose()
            $path.Dispose()
        }
        return $width
    }

    $taskCardPaint = {
        param($sender, $eventArgs)

        $task = $sender.Tag
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear($theme.Page)
        $width = $sender.Width
        $height = $sender.Height
        $line = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPadding, NoPrefix'

        # The card; the task on screen gets a blue edge.
        $card = New-RoundedPath -X 0.5 -Y 0.5 -Width ($width - 1.5) -Height ($height - 1.5) -Radius 12
        $cardPen = New-Object System.Drawing.Pen($(if ($task.Visible) { $theme.Accent } else { $theme.Border }), $(if ($task.Visible) { 2 } else { 1 }))
        try {
            $graphics.FillPath([System.Drawing.Brushes]::White, $card)
            $graphics.DrawPath($cardPen, $card)
        }
        finally {
            $cardPen.Dispose()
            $card.Dispose()
        }

        # Heading: task id and size, then the app with a badge for foreground, home or recents.
        [System.Windows.Forms.TextRenderer]::DrawText($graphics, ('#' + $task.Id + '   ' + ($T.TaskCount -f $task.Activities.Count)), $fonts.ResultSmall, [System.Drawing.Rectangle]::new(16, 10, $width - 32, 20), $theme.Muted, $line)
        $badgeWidth = 0
        if ($task.Visible) { $badgeWidth = Add-Pill -Graphics $graphics -Text $T.TaskVisible -X ($width - 16) -Y 34 -Fill $theme.Accent -Color ([System.Drawing.Color]::White) -AlignRight }
        elseif ($task.Type -eq 'home') { $badgeWidth = Add-Pill -Graphics $graphics -Text $T.TaskHome -X ($width - 16) -Y 34 -Fill $theme.Page -Color $theme.Muted -AlignRight }
        elseif ($task.Type -eq 'recents') { $badgeWidth = Add-Pill -Graphics $graphics -Text $T.TaskRecents -X ($width - 16) -Y 34 -Fill $theme.Page -Color $theme.Muted -AlignRight }
        [System.Windows.Forms.TextRenderer]::DrawText($graphics, $task.Affinity, $fonts.TileTitle, [System.Drawing.Rectangle]::new(16, 32, $width - 32 - $badgeWidth - 8, 24), $theme.Text, $line)

        # The stack: an open-top container with the activities stacked inside, the top of the stack first.
        $left = $stackLayout.ContainerLeft
        $right = $width - 18
        $top = $stackLayout.Header
        $count = $task.Activities.Count
        $bottom = $top + 10 + $count * ($stackLayout.Block + $stackLayout.Gap) - $stackLayout.Gap + 10
        $container = New-Object System.Drawing.Drawing2D.GraphicsPath
        $container.AddLine($left, $top, $left, $bottom - 10)
        $container.AddArc($left, $bottom - 20, 20, 20, 180, -90)
        $container.AddLine($left + 10, $bottom, $right - 10, $bottom)
        $container.AddArc($right - 20, $bottom - 20, 20, 20, 90, -90)
        $container.AddLine($right, $bottom - 10, $right, $top)
        $containerPen = New-Object System.Drawing.Pen($theme.AccentBorder, 2)
        try {
            $graphics.DrawPath($containerPen, $container)
        }
        finally {
            $containerPen.Dispose()
            $container.Dispose()
        }

        $blockLeft = $left + 9
        $blockWidth = $right - $left - 18
        for ($i = 0; $i -lt $count; $i++) {
            $entry = $task.Activities[$i]
            $y = $top + 10 + $i * ($stackLayout.Block + $stackLayout.Gap)
            $block = New-RoundedPath -X $blockLeft -Y $y -Width $blockWidth -Height $stackLayout.Block -Radius 8
            $fill = New-Object System.Drawing.SolidBrush($(if ($entry.Resumed) { $theme.Accent } else { [System.Drawing.Color]::FromArgb(246, 248, 252) }))
            $edge = New-Object System.Drawing.Pen($(if ($entry.Resumed) { $theme.AccentDark } else { $theme.Border }))
            try {
                $graphics.FillPath($fill, $block)
                $graphics.DrawPath($edge, $block)
            }
            finally {
                $edge.Dispose()
                $fill.Dispose()
                $block.Dispose()
            }
            $nameColor = if ($entry.Resumed) { [System.Drawing.Color]::White } else { $theme.Text }
            $classColor = if ($entry.Resumed) { [System.Drawing.Color]::FromArgb(219, 234, 254) } else { $theme.Muted }
            [System.Windows.Forms.TextRenderer]::DrawText($graphics, $entry.ShortName, $fonts.StackName, [System.Drawing.Rectangle]::new($blockLeft + 12, $y + 5, $blockWidth - 24, 20), $nameColor, $line)
            [System.Windows.Forms.TextRenderer]::DrawText($graphics, $entry.ClassName, $fonts.StackClass, [System.Drawing.Rectangle]::new($blockLeft + 12, $y + 26, $blockWidth - 24, 17), $classColor, $line)
        }

        # "Top" beside the first block and "bottom" beside the last, joined by a line along the stack.
        $firstY = $top + 10
        $lastY = $top + 10 + ($count - 1) * ($stackLayout.Block + $stackLayout.Gap)
        $topLabelY = if ($count -eq 1) { $firstY + 2 } else { $firstY + 14 }
        $bottomLabelY = if ($count -eq 1) { $lastY + $stackLayout.Block - 22 } else { $lastY + 14 }
        if ($bottomLabelY - $topLabelY -gt 24) {
            $guide = New-Object System.Drawing.Pen($theme.Border, 2)
            $guide.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
            try { $graphics.DrawLine($guide, 36, $topLabelY + 22, 36, $bottomLabelY - 2) } finally { $guide.Dispose() }
        }
        [void](Add-Pill -Graphics $graphics -Text $T.TaskTop -X 14 -Y $topLabelY -Fill $theme.AccentSoft -Color $theme.Accent)
        [void](Add-Pill -Graphics $graphics -Text $T.TaskBottom -X 14 -Y $bottomLabelY -Fill $theme.Page -Color $theme.Muted)
    }

    function New-TaskWindow {
        $taskForm = New-Object System.Windows.Forms.Form
        $taskForm.Font = $fonts.Body
        $taskForm.BackColor = $theme.Page
        $taskForm.ForeColor = $theme.Text
        $taskForm.MinimumSize = New-Object System.Drawing.Size(520, 420)
        $taskForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $taskForm.Icon = $form.Icon

        $summary = New-Object System.Windows.Forms.Label
        $summary.ForeColor = $theme.Muted
        $summary.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $summary.AutoEllipsis = $true
        $refresh = New-SmallButton -Text $T.Refresh
        $board = New-Object System.Windows.Forms.FlowLayoutPanel
        $board.AutoScroll = $true
        $board.WrapContents = $true
        $board.BackColor = $theme.Page
        $doubleBuffered.SetValue($board, $true, $null)
        $taskStatus = New-Object System.Windows.Forms.Label
        $taskStatus.ForeColor = $theme.Muted
        $taskStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $taskStatus.AutoEllipsis = $true
        $tips = New-Object System.Windows.Forms.ToolTip

        $taskForm.Controls.AddRange([System.Windows.Forms.Control[]]@($summary, $refresh, $board, $taskStatus))
        $window = [pscustomobject]@{ Form = $taskForm; Summary = $summary; Refresh = $refresh; Board = $board; Status = $taskStatus; Tips = $tips; Device = $null; Busy = $false }
        $taskForm.Add_Resize({ Update-TaskWindowLayout })
        $refresh.Add_Click({ [void](Update-TaskWindow) })
        $board.Add_MouseEnter({ $state.Tasks.Board.Focus() })
        $taskForm.Add_KeyDown({ param($sender, $eventArgs) if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) { [void](Update-TaskWindow) } })
        $taskForm.KeyPreview = $true
        $taskForm.Add_FormClosed({
            $state.Tasks.Tips.Dispose()
            $state.Tasks = $null
        })
        return $window
    }

    function Update-TaskWindowLayout {
        $window = $state.Tasks
        if ($null -eq $window) { return }
        $width = $window.Form.ClientSize.Width
        $height = $window.Form.ClientSize.Height
        $pad = 16
        $window.Refresh.SetBounds($width - $pad - 86, 14, 86, 32)
        $window.Summary.SetBounds($pad, 14, [Math]::Max(60, $width - 2 * $pad - 96), 32)
        $window.Board.SetBounds($pad, 58, $width - $pad, [Math]::Max(60, $height - 58 - 40))
        $window.Status.SetBounds($pad, $height - 34, $width - 2 * $pad, 26)
    }

    function Update-TaskWindow {
        # Reads the task stacks of the window's phone again and redraws them. Returns how many there are.
        $window = $state.Tasks
        if ($null -eq $window -or $window.Busy) { return [pscustomobject]@{ Count = 0; Error = '' } }
        $window.Busy = $true
        $window.Refresh.Enabled = $false
        $window.Form.UseWaitCursor = $true
        try {
            $window.Status.ForeColor = $theme.Muted
            $window.Status.Text = $T.TaskLoading
            $window.Status.Refresh()
            $result = Invoke-Adb -Arguments @('-s', $window.Device.Serial, 'shell', "dumpsys activity activities | grep -E 'ResumedActivity|Task\{|TaskRecord\{|Hist +#'") -TimeoutSeconds 20
            if ($null -eq $state.Tasks) { return [pscustomobject]@{ Count = 0; Error = '' } }
            if (Test-AdbFailed -Result $result) {
                $message = Get-AdbFailureText -Result $result
                $window.Status.ForeColor = $theme.Error
                $window.Status.Text = $message
                return [pscustomobject]@{ Count = 0; Error = $message }
            }
            $tasks = @(ConvertFrom-TaskDump -Text $result.Output)

            $window.Board.SuspendLayout()
            foreach ($old in @($window.Board.Controls)) { $old.Dispose() }
            $window.Board.Controls.Clear()
            foreach ($task in $tasks) {
                $card = New-Object System.Windows.Forms.Panel
                $card.Size = New-Object System.Drawing.Size($stackLayout.CardWidth, (Get-TaskCardHeight -Count $task.Activities.Count))
                $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 16)
                $card.Tag = $task
                $doubleBuffered.SetValue($card, $true, $null)
                $card.Add_Paint($taskCardPaint)
                # Long class names are cut on the card; hovering shows them in full.
                $names = New-Object System.Collections.Generic.List[string]
                foreach ($entry in $task.Activities) { $names.Add([string]$entry.ClassName) }
                [string]$tip = [string]::Join([Environment]::NewLine, $names.ToArray())
                $window.Tips.SetToolTip([System.Windows.Forms.Control]$card, $tip)
                $window.Board.Controls.Add($card)
            }
            $window.Board.ResumeLayout()

            $window.Summary.Text = $T.TaskSummary -f $tasks.Count
            if ($tasks.Count -eq 0) {
                $window.Status.ForeColor = $theme.Error
                $window.Status.Text = $T.TaskNone
                return [pscustomobject]@{ Count = 0; Error = $T.TaskNone }
            }
            $window.Status.Text = $T.TaskUpdated -f (Get-Date -Format 'HH:mm:ss')
            return [pscustomobject]@{ Count = $tasks.Count; Error = '' }
        }
        finally {
            if ($null -ne $state.Tasks) {
                $window.Busy = $false
                $window.Refresh.Enabled = $true
                $window.Form.UseWaitCursor = $false
            }
        }
    }

    function Open-TaskWindow {
        $device = Get-UsableDevice -Title $T.TaskStacks
        if ($null -eq $device) {
            return
        }
        if ($null -eq $state.Tasks) {
            $state.Tasks = New-TaskWindow
        }
        $window = $state.Tasks
        $label = Get-DeviceLabel -Device $device
        $window.Device = $device
        $window.Form.Text = $T.TaskWindowTitle -f $label
        if (-not $window.Form.Visible) {
            # Room for three stacks side by side where the screen allows, centred on the tool window's screen.
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $window.Form.Size = New-Object System.Drawing.Size([Math]::Min(1400, $area.Width - 40), [Math]::Min(900, $area.Height - 40))
            $window.Form.Location = New-Object System.Drawing.Point(($area.Left + [int](($area.Width - $window.Form.Width) / 2)), ($area.Top + [int](($area.Height - $window.Form.Height) / 2)))
            $window.Form.Show()
            Update-TaskWindowLayout
        }
        if ($window.Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $window.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $window.Form.Activate()
        $outcome = Update-TaskWindow
        $lines = @((New-ResultLine -Label $T.LabelPhone -Value $label))
        if ($outcome.Error) {
            $lines += New-ResultLine -Label $T.LabelResult -Value $outcome.Error -Style Error
            Write-Result -Title $T.TaskStacks -Lines $lines -Success $false -Summary $outcome.Error
            return
        }
        $message = $T.TaskOpened -f $outcome.Count
        $lines += New-ResultLine -Label $T.LabelResult -Value $message
        Write-Result -Title $T.TaskStacks -Lines $lines -Success $true -Summary $message
    }

    # ---------------- Events ----------------

    $refreshButton.Add_Click({
        Invoke-DevAction -Title $T.Refresh -Body {
            Update-DeviceList
            Set-Status -Text $T.Ready
        }
    })
    $phoneBox.Add_SelectedIndexChanged({
        if ($state.Populating) { return }
        $index = $phoneBox.SelectedIndex
        if ($index -ge 0 -and $index -lt @($state.Devices).Count) {
            $settings.Serial = @($state.Devices)[$index].Serial
            try { Save-DevToolsSettings -Path $settingsPath -Settings $settings } catch { }
        }
    })
    $defaultButton.Add_Click({
        $remoteField.Box.Text = (Get-DevToolsDefaultSettings).RemoteLogPath
        [void](Save-PathInputs -Title $T.PathGroup -Quiet)
    })
    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description = $T.SelectFolder
            if (Test-Path -LiteralPath $exportField.Box.Text -PathType Container) {
                $dialog.SelectedPath = $exportField.Box.Text
            }
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $exportField.Box.Text = $dialog.SelectedPath
                [void](Save-PathInputs -Title $T.PathGroup -Quiet)
            }
        }
        finally {
            $dialog.Dispose()
        }
    })
    $remoteField.Box.Add_Leave({ [void](Save-PathInputs -Title $T.PathGroup -Quiet) })
    $exportField.Box.Add_Leave({ [void](Save-PathInputs -Title $T.PathGroup -Quiet) })
    $clearButton.Add_Click({
        $output.Box.Clear()
        Set-Status -Text $T.Ready
    })
    $form.Add_Resize({ Update-MainLayout })
    $form.Add_Shown({
        # Started from a toolbar click: come to the front once, then behave like a normal window.
        $form.TopMost = $true
        $form.Activate()
        $form.TopMost = $false
        # Nothing is focused at first, so the path box does not open with all of its text selected.
        $form.ActiveControl = $null
        $remoteField.Box.Select(0, 0)
        Invoke-DevAction -Title $T.Refresh -Body {
            Update-DeviceList
            Set-Status -Text $T.Ready
        }
    })
    $form.Add_FormClosing({
        $state.Closing = $true
        if ($null -ne $state.Viewer) {
            $state.Viewer.Form.Close()
        }
        if ($null -ne $state.Preview) {
            $state.Preview.Form.Close()
        }
        if ($null -ne $state.Tasks) {
            $state.Tasks.Form.Close()
        }
    })

    Update-MainLayout
    $anchorParts = @()
    if ($Anchor -and (Get-Command -Name 'ConvertFrom-TNotesAnchor' -CommandType Function -ErrorAction SilentlyContinue)) {
        $anchorParts = @(ConvertFrom-TNotesAnchor -Anchor $Anchor)
    }
    if ($anchorParts.Count -eq 4) {
        $area = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($anchorParts[0], $anchorParts[1])).WorkingArea
        $location = Get-TNotesAnchoredLocation -Anchor $anchorParts -Width $form.Width -Height $form.Height -WorkingArea $area
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = [System.Drawing.Point]::new($location[0], $location[1])
    }

    [System.Windows.Forms.Application]::Run($form)
}
catch {
    $errorText = $_ | Out-String
    try {
        $directory = Join-Path $env:LOCALAPPDATA 'TNotes'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $directory 'dev-tools-error.log') -Value $errorText -Encoding UTF8
    }
    catch {
    }
    try {
        [System.Windows.Forms.MessageBox]::Show($errorText, 'Dev Tools', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    catch {
    }
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
