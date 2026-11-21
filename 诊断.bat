@echo off
chcp 65001>nul
title Widget diagnostic
echo === Widget self-test ===
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Widget.ps1" -Test
echo.
echo --- last log lines ---
powershell.exe -NoProfile -Command "if (Test-Path '%~dp0logs\widget.log') { Get-Content '%~dp0logs\widget.log' -Tail 15 -Encoding UTF8 }"
echo.
pause
