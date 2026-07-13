Option Explicit

Dim shell, fso, appDir, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

appDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(appDir, "TailMount.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)

shell.Run command, 0, False

