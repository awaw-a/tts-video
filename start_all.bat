@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "APP_URL=http://127.0.0.1:8000"
set "INDEXTTS_URL=http://127.0.0.1:9000"
set "PYTHON_EXE=%CD%\.venv310\Scripts\python.exe"

if not exist "%PYTHON_EXE%" (
  set "PYTHON_EXE=python"
)

echo ========================================
echo tts-video one-click startup
echo ========================================
echo Project: %CD%
echo Python:  %PYTHON_EXE%
echo.

if not exist "index-tts\checkpoints\config.yaml" (
  echo [WARN] index-tts checkpoints were not found.
  echo        Please check index-tts\checkpoints before using IndexTTS.
  echo.
)

findstr /C:"backend:" "configs\default.yaml" | findstr /C:"indextts_api" >nul 2>nul
if errorlevel 1 (
  echo [WARN] configs\default.yaml does not look like indextts_api mode.
  echo        To use cloned voice generation, set:
  echo        tts.backend: "indextts_api"
  echo.
)

call :CheckIndexTTS
if errorlevel 1 (
  echo [1/4] Starting IndexTTS API server on %INDEXTTS_URL% ...
  start "IndexTTS API Server" cmd /k "call scripts\run_indextts_server.bat"
) else (
  echo [1/4] IndexTTS API server is already ready.
)

echo [2/4] Waiting for IndexTTS model to load ...
set /a INDEX_WAIT=0
:WAIT_INDEXTTS
call :CheckIndexTTS
if not errorlevel 1 goto INDEXTTS_READY

set /a INDEX_WAIT+=1
if !INDEX_WAIT! GEQ 180 (
  echo [ERROR] IndexTTS did not become ready within 6 minutes.
  echo         Visit %INDEXTTS_URL%/health or check the IndexTTS window.
  pause
  exit /b 1
)

timeout /t 2 /nobreak >nul
goto WAIT_INDEXTTS

:INDEXTTS_READY
echo [2/4] IndexTTS is ready.

call :CheckApp
if errorlevel 1 (
  echo [3/4] Starting tts-video web server on %APP_URL% ...
  start "tts-video Web Server" cmd /k ""%PYTHON_EXE%" -m uvicorn app:app --host 127.0.0.1 --port 8000"
) else (
  echo [3/4] tts-video web server is already running.
)

echo [4/4] Waiting for tts-video web server ...
set /a APP_WAIT=0
:WAIT_APP
call :CheckApp
if not errorlevel 1 goto APP_READY

set /a APP_WAIT+=1
if !APP_WAIT! GEQ 60 (
  echo [ERROR] tts-video did not become ready within 2 minutes.
  echo         Check the tts-video window for details.
  pause
  exit /b 1
)

timeout /t 2 /nobreak >nul
goto WAIT_APP

:APP_READY
echo.
echo Ready:
echo   tts-video: %APP_URL%
echo   IndexTTS:  %INDEXTTS_URL%/health
echo.
echo Opening browser ...
start "" "%APP_URL%"
echo.
echo Keep the two server windows open while using the app.
pause
exit /b 0

:CheckIndexTTS
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-RestMethod -Uri '%INDEXTTS_URL%/health' -TimeoutSec 3; if ($r.model_loaded -eq $true) { exit 0 } else { exit 1 } } catch { exit 1 }"
exit /b %ERRORLEVEL%

:CheckApp
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -Uri '%APP_URL%/' -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { exit 0 } else { exit 1 } } catch { exit 1 }"
exit /b %ERRORLEVEL%
