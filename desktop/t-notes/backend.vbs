Option Explicit
Dim shell, files, root, client, node, environment, result, directory, candidate, configuration
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
root = files.GetParentFolderName(WScript.ScriptFullName)
client = files.BuildPath(root, "client")
node = files.BuildPath(root, "runtime\node.exe")
If Not files.FileExists(node) Then node = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\nodejs\node.exe"
If Not files.FileExists(node) Then
    For Each directory In Split(shell.Environment("Process")("PATH"), ";")
        If Len(directory) > 0 Then
            candidate = files.BuildPath(Replace(directory, Chr(34), ""), "node.exe")
            If files.FileExists(candidate) Then
                node = candidate
                Exit For
            End If
        End If
    Next
End If
If Not files.FileExists(node) Then WScript.Quit 2
Set environment = shell.Environment("Process")
environment("TNOTES_PORT") = "47321"
environment("TNOTES_DATA") = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\TNotes"
configuration = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\TNotes\server.json"
If Not files.FileExists(configuration) Then configuration = files.BuildPath(client, "server.json")
environment("TNOTES_CONFIG") = configuration
shell.CurrentDirectory = client
result = shell.Run(Chr(34) & node & Chr(34) & " " & Chr(34) & files.BuildPath(client, "desktop.cjs") & Chr(34), 0, True)
WScript.Quit result
