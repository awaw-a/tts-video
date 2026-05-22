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

uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
