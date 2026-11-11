Option Explicit
Dim shell, files, root, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
root = files.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = root
command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe" & Chr(34) & " -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File " & Chr(34) & files.BuildPath(root, "codex-floating-button.ps1") & Chr(34)
shell.Run command, 0, False
