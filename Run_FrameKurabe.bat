@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0FrameKurabe.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
pause
exit /b %exitCode%
