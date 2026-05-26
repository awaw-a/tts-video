@echo off
setlocal

cd /d "%~dp0"

if not exist "%~dp0logs" mkdir "%~dp0logs" >nul 2>nul
set "BOOT_LOG=%~dp0logs\start_tts_bat.log"
echo ======================================== > "%BOOT_LOG%"
echo tts-video Release start_tts.bat >> "%BOOT_LOG%"
echo Time: %DATE% %TIME% >> "%BOOT_LOG%"
echo Root: %~dp0 >> "%BOOT_LOG%"

set "PS1=%~dp0scripts\release\start_tts_release.ps1"
if not exist "%PS1%" set "PS1=%~dp0start_tts_release.ps1"

echo PowerShell script: %PS1% >> "%BOOT_LOG%"

set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo [ERROR] Windows PowerShell was not found.
  echo [ERROR] PowerShell not found: %POWERSHELL% >> "%BOOT_LOG%"
  pause
  exit /b 1
)

if not exist "%PS1%" (
  echo [ERROR] start_tts_release.ps1 was not found.
  echo [ERROR] Missing script: %PS1% >> "%BOOT_LOG%"
  echo Please unzip the package first. Do not run it inside the zip viewer.
  pause
  exit /b 1
)

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "EXIT_CODE=%ERRORLEVEL%"
echo ExitCode: %EXIT_CODE% >> "%BOOT_LOG%"

echo.
if "%EXIT_CODE%"=="0" (
  echo IndexTTS exited.
) else (
  echo Startup failed. Check the console message or logs\start_tts_bat.log and logs\start_tts_release.log.
)
echo.
pause

exit /b %EXIT_CODE%
