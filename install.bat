@echo off
setlocal

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\install_windows.ps1" %*
if errorlevel 1 (
  echo.
  echo Install failed. Please check the messages above.
  pause
  exit /b 1
)

echo.
echo Install finished.
pause
