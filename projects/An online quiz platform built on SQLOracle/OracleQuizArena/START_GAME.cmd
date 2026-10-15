@echo off
setlocal
cd /d "%~dp0"

if not exist "python\.venv\Scripts\pythonw.exe" (
  echo Virtual environment was not found. Run INSTALL_AND_RUN.cmd first.
  pause
  exit /b 1
)

start "" /D "%~dp0python" "%~dp0python\.venv\Scripts\pythonw.exe" "%~dp0python\desktop_app.py"
