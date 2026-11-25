$ErrorActionPreference = 'Stop'
# The T Notes close guard: only the top right close button of the watched window counts, and the mouse watcher starts
# and stops cleanly. A small top-most test window stands in for the notes window for well under a second.
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
if ($null -eq ('Codex.Toolbar.CloseGuard' -as [Type])) {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 't-notes\CloseGuard.cs.txt'))) -Language CSharp
}
if ($null -eq ('CloseGuardTestApi' -as [Type])) {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;using System.Text;public static class CloseGuardTestApi{[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassName(IntPtr h,StringBuilder s,int n);}'
}
$guard = 'Codex.Toolbar.CloseGuard' -as [Type]
$form = New-Object System.Windows.Forms.Form
try {
    $form.Text = 'Close Guard Test'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = New-Object System.Drawing.Rectangle(200, 200, 420, 300)
    $form.Show()
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    $className = New-Object System.Text.StringBuilder 128
    [void][CloseGuardTestApi]::GetClassName($form.Handle, $className, 128)
    $guard::Title = 'Close Guard Test'
    $guard::ClassName = $className.ToString()
    # The visible frame ends about 7 pixels inside the window rectangle (the invisible resize border).
    $right = 200 + 420 - 7
    $cases = @(@(($right - 5), 205, $true), @(($right - 23), 215, $true), @(($right - 80), 215, $false), @(410, 350, $false), @(215, 210, $false))
    foreach ($case in $cases) {
        $found = $guard::CloseButtonAt($case[0], $case[1]) -eq $form.Handle
        if ($found -ne $case[2]) { throw "Close guard misjudged the point $($case[0]),$($case[1])." }
    }
    $guard::Title = 'T Notes v4'
    if ($guard::CloseButtonAt(($right - 5), 205) -ne [IntPtr]::Zero) { throw 'Close guard acted on a window with another title.' }
    $guard::Start()
    if (-not $guard::Running) { throw 'Close guard did not start.' }
    $guard::Stop()
    for ($i = 0; $i -lt 20 -and $guard::Running; $i++) { Start-Sleep -Milliseconds 50 }
    if ($guard::Running) { throw 'Close guard did not stop.' }
}
finally {
    $guard::Title = 'T Notes v4'
    $guard::ClassName = 'Chrome_WidgetWin_1'
    $form.Close()
    $form.Dispose()
}
Write-Output 'PASS: T Notes close button minimizes: only the close button of the watched window counts; the watcher starts and stops.'
