@echo off
setlocal

cd /d "%~dp0\.."

set INDEXTTS_REPO=index-tts
set INDEXTTS_MODEL_DIR=index-tts\checkpoints
set INDEXTTS_CFG_PATH=index-tts\checkpoints\config.yaml
set INDEXTTS_VERSION=auto
set INDEXTTS_USE_FP16=true
set INDEXTTS_USE_CUDA_KERNEL=false
set INDEXTTS_USE_DEEPSPEED=false

if exist ".venv310\Scripts\python.exe" (
  ".venv310\Scripts\python.exe" -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
) else if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
) else (
  python -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
)
