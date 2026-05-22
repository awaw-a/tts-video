#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

export INDEXTTS_REPO="index-tts"
export INDEXTTS_MODEL_DIR="index-tts/checkpoints"
export INDEXTTS_CFG_PATH="index-tts/checkpoints/config.yaml"
export INDEXTTS_VERSION="auto"
export INDEXTTS_USE_FP16="true"
export INDEXTTS_USE_CUDA_KERNEL="false"
export INDEXTTS_USE_DEEPSPEED="false"

if [ -x ".venv310/bin/python" ]; then
  ".venv310/bin/python" -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
elif [ -x ".venv/bin/python" ]; then
  ".venv/bin/python" -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
else
  python -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
fi
