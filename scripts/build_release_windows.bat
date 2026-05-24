@echo off
setlocal

cd /d "%~dp0\.."

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release_windows.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
  echo Release 打包完成。
) else (
  echo Release 打包失败，请查看上方错误信息。
)
pause
exit /b %EXIT_CODE%
