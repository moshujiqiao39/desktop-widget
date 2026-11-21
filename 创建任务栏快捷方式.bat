@echo off
chcp 65001>nul
title Desktop Widget - create shortcut
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Widget.ps1" -MakeShortcut
echo.
pause
