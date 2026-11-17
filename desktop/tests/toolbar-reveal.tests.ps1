$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-floating-button-core.ps1')
Add-Type -TypeDefinition @'
public static class ToolbarRevealTestApi {
    public static int Owner = 44, ShowCommand;
    public static int[] Rectangle = new int[] {1643,743,1831,811};
    public static bool Minimized, Raised, OwnerRaised;
    public static System.IntPtr GetWindow(System.IntPtr handle,uint command) {
        return command == 4 && handle.ToInt64() == 11 ? new System.IntPtr(12) : System.IntPtr.Zero;
    }
    public static System.IntPtr FindWindow(string className,string title) {
        return className == null && title == "CodexFloatingButton" ? new System.IntPtr(11) : System.IntPtr.Zero;
    }
    public static int GetWindowThreadProcessId(System.IntPtr handle,out int owner) { owner = Owner; return 1; }
    public static bool GetWindowRect(System.IntPtr handle,int[] rectangle) { Rectangle.CopyTo(rectangle,0); return true; }
    public static bool IsIconic(System.IntPtr handle) { return Minimized; }
    public static bool IsWindowVisible(System.IntPtr handle) { return ShowCommand != 0; }
    public static int GetWindowLong(System.IntPtr handle,int index) { return Raised ? 8 : 0; }
    public static bool ShowWindowAsync(System.IntPtr handle,int command) { ShowCommand = command; Minimized = false; return true; }
    public static bool SetWindowPos(System.IntPtr handle,System.IntPtr after,int x,int y,int w,int h,uint flags) {
        if (handle.ToInt64() == 12) { OwnerRaised = after.ToInt64() == -1; return true; }
        // As Windows did on 2026-11-17: the call succeeds, but the bar only becomes topmost once its
        // hidden owner window has been raised.
        Raised = after.ToInt64() == -1 && (flags & 64) != 0 && OwnerRaised;
        Rectangle = new int[] {x,y,x+188,y+68}; return true;
    }
}
'@
$source='X:\desktop\codex-floating-button.ps1'
$processes=@([pscustomobject]@{ProcessId=44;SessionId=9;CommandLine='powershell.exe -NoProfile -File "X:\desktop\codex-floating-button.ps1"'})
$area=[pscustomobject]@{Left=0;Top=0;Right=1920;Bottom=1040}
$arguments=@{NativeApi=[ToolbarRevealTestApi];ScriptPath=$source;Processes=$processes;SessionId=9;WorkingAreas=@($area);PrimaryWorkingArea=$area}
if(-not (Restore-FloatingToolbarWindow @arguments) -or -not [ToolbarRevealTestApi]::Raised){throw 'An existing toolbar was not shown and made topmost (its hidden owner must be raised first).'}
[ToolbarRevealTestApi]::OwnerRaised=$false
[ToolbarRevealTestApi]::Rectangle=@(5000,2000,5188,2068)
if(-not (Restore-FloatingToolbarWindow @arguments) -or ([ToolbarRevealTestApi]::Rectangle -join ',') -ne '1720,960,1908,1028'){throw 'An off-screen toolbar was not returned to the visible desktop.'}
[ToolbarRevealTestApi]::Minimized=$true;[ToolbarRevealTestApi]::OwnerRaised=$false
if(-not (Restore-FloatingToolbarWindow @arguments) -or [ToolbarRevealTestApi]::ShowCommand -ne 9){throw 'A minimized toolbar was not restored.'}
foreach($mismatch in @([pscustomobject]@{ProcessId=44;SessionId=9;CommandLine='powershell.exe -File "X:\unrelated.ps1"'},[pscustomobject]@{ProcessId=44;SessionId=10;CommandLine=$processes[0].CommandLine})){
 [ToolbarRevealTestApi]::Raised=$false;[ToolbarRevealTestApi]::OwnerRaised=$false
 $arguments.Processes=@($mismatch)
 if((Restore-FloatingToolbarWindow @arguments) -or [ToolbarRevealTestApi]::Raised){throw 'The reveal command acted on an unrelated process or session.'}
}
Write-Output 'PASS: Reveal reuses the owned toolbar, restores its visibility, and never terminates a process.'
