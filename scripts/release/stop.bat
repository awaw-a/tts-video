@echo off
setlocal

cd /d "%~dp0"

set "PS1=%~dp0scripts\release\stop_release.ps1"
if not exist "%PS1%" set "PS1=%~dp0stop_release.ps1"

set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo [ERROR] Windows PowerShell was not found.
  pause
  exit /b 1
)

if not exist "%PS1%" (
  echo [ERROR] stop_release.ps1 was not found.
  echo Please unzip the package first. Do not run it inside the zip viewer.
  pause
  exit /b 1
)

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
pause
exit /b %EXIT_CODE%

