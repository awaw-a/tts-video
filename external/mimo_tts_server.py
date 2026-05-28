from __future__ import annotations

import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from modules.core.config import load_config
from modules.core.mimo_credentials import (
    get_mimo_api_key,
    has_mimo_api_key,
    save_mimo_api_key,
)
from modules.core.paths import PROJECT_ROOT
from modules.core.tts_tool import (
    get_tts_tool_url,
    read_tts_tool_mode,
    request_tts_tool_switch,
    write_tts_tool_mode,
)
from modules.tts.mimo_api import MimoApiTTS


logger = logging.getLogger("mimo_tts_server")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logger.propagate = False

OUTPUT_ROOT = PROJECT_ROOT / "data" / "mimo_tts_server" / "outputs"


class ApiKeyRequest(BaseModel):
    api_key: str


class ToolSwitchRequest(BaseModel):
    target_mode: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    write_tts_tool_mode("mimo")
    yield


app = FastAPI(title="MiMo TTS Tool Server", version="0.1.0", lifespan=lifespan)
app.mount(
    "/mimo-static",
    StaticFiles(directory=PROJECT_ROOT / "static"),
    name="mimo_static",
)


async def save_upload_file(upload_file: UploadFile, output_path: Path) -> Path:
    """分块保存上传的参考音频。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as file_obj:
        while True:
            chunk = await upload_file.read(1024 * 1024)
            if not chunk:
                break
            file_obj.write(chunk)
    return output_path


def build_mimo_engine() -> MimoApiTTS:
    """根据项目配置创建 MiMo TTS 后端。"""
    settings = load_config()
    return MimoApiTTS(
        api_url=settings.tts.mimo_api_url,
        model=settings.tts.mimo_model,
        timeout=settings.tts.mimo_request_timeout,
    )


@app.get("/")
def index() -> FileResponse:
    """返回 MiMo 独立语音调节页面。"""
    return FileResponse(
        PROJECT_ROOT / "static" / "mimo_tts.html",
        headers={"Cache-Control": "no-store"},
    )


@app.get("/health")
def health() -> dict[str, Any]:
    """返回 MiMo 工具服务状态，不暴露 API Key 内容。"""
    settings = load_config()
    return {
        "status": "ok",
        "mode": "mimo",
        "configured": has_mimo_api_key(),
        "api_key_source": "environment" if get_mimo_api_key() else None,
        "model": settings.tts.mimo_model,
        "api_url": settings.tts.mimo_api_url,
    }


@app.get("/api/mimo/status")
def mimo_status() -> dict[str, Any]:
    """返回 MiMo API Key 是否已配置。"""
    return {
        "configured": has_mimo_api_key(),
        "model": load_config().tts.mimo_model,
    }


@app.post("/api/mimo/key")
def save_api_key(payload: ApiKeyRequest) -> dict[str, Any]:
    """保存 MiMo API Key 到后端和系统用户环境变量。"""
    try:
        save_mimo_api_key(payload.api_key)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"保存 MiMo API Key 失败：{exc}") from exc
    return {"configured": True}


@app.get("/api/tts/mode")
def tts_mode() -> dict[str, Any]:
    """返回当前 TTS 工具模式。"""
    mode = read_tts_tool_mode()
    return {
        "mode": mode,
        "available_modes": ["indextts", "mimo"],
        "url": get_tts_tool_url(mode),
    }


@app.post("/api/tts/switch")
def switch_tts_tool(payload: ToolSwitchRequest) -> dict[str, Any]:
    """请求启动控制脚本切换到另一个 TTS 工具。"""
    try:
        switch_payload = request_tts_tool_switch(payload.target_mode, source_mode="mimo")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"status": "switch_requested", **switch_payload}


@app.post("/synthesize")
async def synthesize(
    text: str = Form(...),
    voice: UploadFile = File(...),
    style_prompt: str = Form(""),
) -> FileResponse:
    """接收文本、参考音频和风格指令，返回 MiMo 生成的 wav 文件。"""
    clean_text = text.strip()
    if not clean_text:
        raise HTTPException(status_code=400, detail="文本不能为空")
    if not has_mimo_api_key():
        raise HTTPException(status_code=400, detail="请先填写 MiMo API Key")

    task_id = uuid4().hex
    task_dir = OUTPUT_ROOT / task_id
    voice_suffix = Path(voice.filename or "").suffix.lower() or ".wav"
    voice_path = task_dir / f"reference_audio{voice_suffix}"
    output_path = task_dir / "output.wav"

    try:
        await save_upload_file(voice, voice_path)
        if not voice_path.exists() or voice_path.stat().st_size == 0:
            raise HTTPException(status_code=400, detail="参考音频为空")

        logger.info(
            "MiMo synthesis task %s received: text_chars=%s, style_chars=%s",
            task_id,
            len(clean_text),
            len(style_prompt),
        )
        engine = build_mimo_engine()
        engine.synthesize(
            clean_text,
            voice_path,
            output_path,
            options={"style_prompt": style_prompt, "format": "wav"},
        )
        return FileResponse(
            output_path,
            media_type="audio/wav",
            filename="mimo-output.wav",
        )
    except HTTPException:
        raise
    except ValueError as exc:
        logger.warning("MiMo synthesis task %s failed with validation error: %s", task_id, exc)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("MiMo synthesis task %s failed", task_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc
