@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0LanLink.ps1" (
    echo LanLink.ps1 not found.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LanLink.ps1" %*
if errorlevel 1 pause
