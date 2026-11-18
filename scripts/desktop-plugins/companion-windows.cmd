@echo off
rem The click: a companion plugin's node, joined to the window beside this folder.
rem
rem `powershell`, not `pwsh`: Windows PowerShell 5.1 is what a person has, and a
rem launcher that needed 7 would fail on the machine it was made for. The script
rem is written for both — scripts\check-syntax.ps1 parses it in each.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0companion-windows.ps1" %*
exit /b %ERRORLEVEL%
