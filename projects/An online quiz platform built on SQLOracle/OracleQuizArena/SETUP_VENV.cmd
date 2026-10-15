@echo off
setlocal
cd /d "%~dp0"

if not exist "python\.venv\Scripts\python.exe" (
  py -3 -m venv "python\.venv"
  if errorlevel 1 exit /b 1
)

"python\.venv\Scripts\python.exe" -m pip install --disable-pip-version-check -r "python\requirements.txt"
if errorlevel 1 exit /b 1

if not exist "python\.env" copy "python\.env.example" "python\.env" >nul
echo Virtual environment is ready.
echo Start the game with START_GAME.cmd
