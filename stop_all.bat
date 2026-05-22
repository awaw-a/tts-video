@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

echo ========================================
echo tts-video stop services
echo ========================================

call :StopPort 8000 "tts-video Web Server"
call :StopPort 9000 "IndexTTS API Server"

echo.
echo Done.
pause
exit /b 0

:StopPort
set "PORT=%~1"
set "NAME=%~2"
set "FOUND=0"

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
  set "FOUND=1"
  echo Stopping %NAME% on port %PORT%, pid %%P ...
  taskkill /PID %%P /F >nul 2>nul
  if errorlevel 1 (
    echo [WARN] Failed to stop pid %%P. You may need to close its window manually.
  ) else (
    echo [OK] Stopped pid %%P.
  )
)

if "!FOUND!"=="0" (
  echo [OK] %NAME% is not running on port %PORT%.
)

exit /b 0
