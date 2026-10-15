@echo off
setlocal
cd /d "%~dp0"
title Oracle Quiz Arena - university server setup
echo Oracle Quiz Arena: setup for an existing university Oracle server
echo Docker and a local Oracle database will not be installed.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_and_run.ps1" -UseExistingDatabase %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
