$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path (Split-Path -Parent $PSScriptRoot) 't-notes\window.ps1')
Add-Type -TypeDefinition @'
public static class TNotesPlacementTestApi {
    public static int[] Rectangle;
    public static int[] RestoredRectangle;
    public static bool Minimized, MinimizeQueued, RestoreQueued, ForegroundAllowed;
    public static bool TransitionsDisabled, ShownWithTransitions;
    public static int MinimizePolls, AnimationReads;
    public static bool IsIconic(System.IntPtr handle) {
        if (MinimizeQueued) {
            if (MinimizePolls++ == 0) return false;
            MinimizeQueued = false; Minimized = true; return true;
        }
        if (RestoreQueued) {
            RestoreQueued = false; Minimized = false;
            Rectangle = (int[])RestoredRectangle.Clone();
        }
        return Minimized;
    }
    public static bool IsZoomed(System.IntPtr handle) { return false; }
    public static bool SetForegroundWindow(System.IntPtr handle) { return ForegroundAllowed; }
    public static bool ShowWindowAsync(System.IntPtr handle, int command) {
        if (!TransitionsDisabled) ShownWithTransitions = true;
        if (command == 6) { MinimizeQueued = true; MinimizePolls = 0; }
        if (command == 9) RestoreQueued = true;
        return true;
    }
    public static int DwmSetWindowAttribute(System.IntPtr handle, int attribute, ref int value, int size) {
        if (attribute != 3 || value != 1 || size != 4) return -1;
        TransitionsDisabled = true; return 0;
    }
    public static bool GetWindowRect(System.IntPtr handle, int[] rectangle) {
        if (AnimationReads-- > 0) Rectangle = new int[] { 0, 950, 104, 990 };
        Rectangle.CopyTo(rectangle, 0); return true;
    }
    public static bool GetWindowPlacement(System.IntPtr handle, System.IntPtr placement) {
        for (int i = 0; i < 4; i++) System.Runtime.InteropServices.Marshal.WriteInt32(placement, 28 + i * 4, RestoredRectangle[i]);
        return true;
    }
    public static bool SetWindowPos(System.IntPtr handle, System.IntPtr after, int x, int y, int w, int h, int flags) {
        int width = (flags & 1) != 0 ? Rectangle[2] - Rectangle[0] : w;
        int height = (flags & 1) != 0 ? Rectangle[3] - Rectangle[1] : h;
        Rectangle = new int[] { x, y, x + width, y + height }; return true;
    }
}
'@
function Get-TNotesWindowApi { return [TNotesPlacementTestApi] }
$area=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$button=@(($area.Right-100),($area.Bottom-80),52,52)
foreach($case in @('background','minimized','foreground','animating')){
 [TNotesPlacementTestApi]::RestoredRectangle=@(($area.Right-128),($area.Bottom-266),($area.Right+342),($area.Bottom+544))
 [TNotesPlacementTestApi]::Rectangle=[TNotesPlacementTestApi]::RestoredRectangle.Clone()
 [TNotesPlacementTestApi]::Minimized=$case -eq 'minimized'
 [TNotesPlacementTestApi]::MinimizeQueued=$false
 [TNotesPlacementTestApi]::RestoreQueued=$false
 [TNotesPlacementTestApi]::ForegroundAllowed=$case -in @('foreground','animating')
 [TNotesPlacementTestApi]::AnimationReads=if($case -eq 'animating'){2}else{0}
 [TNotesPlacementTestApi]::TransitionsDisabled=$false
 [TNotesPlacementTestApi]::ShownWithTransitions=$false
 Show-TNotesWindow -Handle ([IntPtr]1)
 Move-TNotesWindowToAnchor -Handle ([IntPtr]1) -Anchor ($button -join ',')
 # Process a queued restore just as the browser would after the launcher returns.
 [void][TNotesPlacementTestApi]::IsIconic([IntPtr]1)
 if(-not [TNotesPlacementTestApi]::TransitionsDisabled -or [TNotesPlacementTestApi]::ShownWithTransitions){throw 'T Notes transitions were not disabled before showing or restoring the window.'}
 $rectangle=[TNotesPlacementTestApi]::Rectangle
 $expected=Get-TNotesAnchoredLocation -Anchor $button -Width 470 -Height 810 -WorkingArea $area
 if($rectangle[0] -ne $expected[0] -or $rectangle[1] -ne $expected[1] -or $rectangle[3] -gt $button[1]){
  throw "The $case window was positioned before its asynchronous restore completed."
 }
 Write-Output "PASS: $case notes window settles above T after restoration."
}
