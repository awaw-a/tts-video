@echo off
setlocal

cd /d "%~dp0\.."

set "PYTHON_EXE=%CD%\.venv310\Scripts\python.exe"
if not exist "%PYTHON_EXE%" (
  set "PYTHON_EXE=python"
)

set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8

"%PYTHON_EXE%" -u -m uvicorn app:app --host 127.0.0.1 --port 8000
