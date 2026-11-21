' Desktop widget - silent launcher (no console window)
Option Explicit

Dim shell, baseDir, command
Set shell = CreateObject("WScript.Shell")

baseDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
shell.CurrentDirectory = baseDir

command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & baseDir & "Widget.ps1"""

shell.Run command, 0, False
