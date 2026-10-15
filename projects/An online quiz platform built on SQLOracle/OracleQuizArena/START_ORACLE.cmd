@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0.local\temp" mkdir "%~dp0.local\temp"
set "TEMP=%~dp0.local\temp"
set "TMP=%TEMP%"
"%~dp0python\.venv\Scripts\python.exe" "%~dp0local_oracle.py" start
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
