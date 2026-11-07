@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Antigravity Launcher v3

set "CORE=%~dp0launcher-core.ps1"

if not exist "%CORE%" goto :missing

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CORE%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo  [Exit code %RC%]  Press any key to close this window ...
    pause >nul
)
exit /b %RC%

:missing
echo.
echo  [ERROR] launcher-core.ps1 was not found in this folder.
echo  Please keep "Antigravity-Launcher.bat" and "launcher-core.ps1" together.
echo.
pause
exit /b 1
