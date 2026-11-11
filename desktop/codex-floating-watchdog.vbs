Option Explicit
Dim shell, files, powershell, script, command, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
script = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "codex-floating-watchdog.ps1")
command = Chr(34) & powershell & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File " & Chr(34) & script & Chr(34)
result = shell.Run(command, 0, True)
WScript.Quit result
