@echo off
setlocal
cd /d "%~dp0"
"%~dp0python\.venv\Scripts\python.exe" "%~dp0local_oracle.py" stop
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
