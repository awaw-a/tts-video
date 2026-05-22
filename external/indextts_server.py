from __future__ import annotations

import os
import sys
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from uuid import uuid4

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse


PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = PROJECT_ROOT / "data" / "indextts_server" / "outputs"
DEFAULT_MAX_TEXT_LENGTH = 1000


@dataclass
class IndexTTSRuntimeConfig:
    """IndexTTS 服务运行配置，全部可以通过环境变量覆盖。"""

    repo: Path
    model_dir: Path
    cfg_path: Path
    version: str
    use_fp16: bool
    use_cuda_kernel: bool
    use_deepspeed: bool
    max_text_length: int = DEFAULT_MAX_TEXT_LENGTH


@dataclass
class ModelState:
    """保存模型加载状态，供 /health 和 /synthesize 共享。"""

    model: object | None = None
    version: str = "unknown"
    model_loaded: bool = False
    error: str | None = None


model_state = ModelState()
inference_lock = Lock()


def parse_bool(value: str | None, default: bool = False) -> bool:
    """解析常见布尔环境变量写法。"""
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def resolve_path(value: str) -> Path:
    """把环境变量中的路径解析为绝对路径；相对路径按 tts-video 根目录计算。"""
    path = Path(value).expanduser()
    if path.is_absolute():
        return path.resolve()
    return (PROJECT_ROOT / path).resolve()


def load_runtime_config() -> IndexTTSRuntimeConfig:
    """从环境变量读取 IndexTTS 服务配置。"""
    return IndexTTSRuntimeConfig(
        repo=resolve_path(os.getenv("INDEXTTS_REPO", "index-tts")),
        model_dir=resolve_path(os.getenv("INDEXTTS_MODEL_DIR", "index-tts/checkpoints")),
        cfg_path=resolve_path(os.getenv("INDEXTTS_CFG_PATH", "index-tts/checkpoints/config.yaml")),
        version=os.getenv("INDEXTTS_VERSION", "auto").strip().lower(),
        use_fp16=parse_bool(os.getenv("INDEXTTS_USE_FP16"), default=False),
        use_cuda_kernel=parse_bool(os.getenv("INDEXTTS_USE_CUDA_KERNEL"), default=False),
        use_deepspeed=parse_bool(os.getenv("INDEXTTS_USE_DEEPSPEED"), default=False),
        max_text_length=int(os.getenv("INDEXTTS_MAX_TEXT_LENGTH", str(DEFAULT_MAX_TEXT_LENGTH))),
    )


def add_repo_to_python_path(repo: Path) -> None:
    """把 IndexTTS 仓库加入 sys.path，避免主项目直接依赖 IndexTTS 包。"""
    repo_text = str(repo)
    if repo_text not in sys.path:
        sys.path.insert(0, repo_text)


def load_indextts_v2(config: IndexTTSRuntimeConfig) -> object:
    """加载 IndexTTS v2 模型。"""
    add_repo_to_python_path(config.repo)
    from indextts.infer_v2 import IndexTTS2

    return IndexTTS2(
        cfg_path=str(config.cfg_path),
        model_dir=str(config.model_dir),
        use_fp16=config.use_fp16,
        use_cuda_kernel=config.use_cuda_kernel,
        use_deepspeed=config.use_deepspeed,
    )


def load_indextts_v1(config: IndexTTSRuntimeConfig) -> object:
    """加载旧版 IndexTTS 模型。"""
    add_repo_to_python_path(config.repo)
    from indextts.infer import IndexTTS

    return IndexTTS(
        model_dir=str(config.model_dir),
        cfg_path=str(config.cfg_path),
    )


def infer_v2(tts_model: object, voice_path: Path, text: str, output_path: Path) -> None:
    """调用 IndexTTS v2 推理接口。"""
    tts_model.infer(
        spk_audio_prompt=str(voice_path),
        text=text,
        output_path=str(output_path),
        verbose=True,
    )


def infer_v1(tts_model: object, voice_path: Path, text: str, output_path: Path) -> None:
    """调用旧版 IndexTTS 推理接口。"""
    tts_model.infer(
        str(voice_path),
        text,
        str(output_path),
    )


def load_model_from_config(config: IndexTTSRuntimeConfig) -> tuple[object, str]:
    """按配置加载 v1/v2；auto 模式下优先尝试 v2，再回退 v1。"""
    if config.version == "v2":
        return load_indextts_v2(config), "v2"
    if config.version == "v1":
        return load_indextts_v1(config), "v1"
    if config.version != "auto":
        raise ValueError("INDEXTTS_VERSION 仅支持 auto、v1、v2")

    errors: list[str] = []
    try:
        return load_indextts_v2(config), "v2"
    except Exception as exc:
        errors.append(f"v2 加载失败：{exc}")

    try:
        return load_indextts_v1(config), "v1"
    except Exception as exc:
        errors.append(f"v1 加载失败：{exc}")

    raise RuntimeError("；".join(errors))


def load_model_once() -> None:
    """服务启动时加载一次模型；失败时保留错误信息，方便 /health 排查。"""
    config = load_runtime_config()
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    try:
        model, version = load_model_from_config(config)
        model_state.model = model
        model_state.version = version
        model_state.model_loaded = True
        model_state.error = None
    except Exception as exc:
        model_state.model = None
        model_state.version = "unknown"
        model_state.model_loaded = False
        model_state.error = str(exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI 生命周期：启动时加载模型，进程退出时交给 Python 回收资源。"""
    load_model_once()
    yield


app = FastAPI(title="IndexTTS API Server", version="0.1.0", lifespan=lifespan)


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


@app.get("/health")
def health() -> dict:
    """返回模型加载状态。"""
    payload = {
        "status": "ok",
        "model_loaded": model_state.model_loaded,
        "version": model_state.version,
    }
    if model_state.error:
        payload["error"] = model_state.error
    return payload


@app.post("/synthesize")
async def synthesize(text: str = Form(...), voice: UploadFile = File(...)) -> FileResponse:
    """接收文案和参考音频，返回 IndexTTS 生成的 wav 文件。"""
    config = load_runtime_config()
    clean_text = text.strip()
    if not clean_text:
        raise HTTPException(status_code=400, detail="text 不能为空")
    if len(clean_text) > config.max_text_length:
        raise HTTPException(
            status_code=400,
            detail=f"text 过长，当前限制为 {config.max_text_length} 字符",
        )
    if not model_state.model_loaded or model_state.model is None:
        detail = "IndexTTS 模型未加载"
        if model_state.error:
            detail = f"{detail}：{model_state.error}"
        raise HTTPException(status_code=503, detail=detail)

    task_id = uuid4().hex
    task_dir = OUTPUT_ROOT / task_id
    voice_suffix = Path(voice.filename or "").suffix.lower() or ".wav"
    voice_path = task_dir / f"reference_audio{voice_suffix}"
    output_path = task_dir / "output.wav"

    try:
        await save_upload_file(voice, voice_path)
        if voice_path.stat().st_size == 0:
            raise HTTPException(status_code=400, detail="参考音频为空")

        # 多数 TTS 模型不是为并发推理设计的，这里先串行化，避免显存互相踩踏。
        with inference_lock:
            if model_state.version == "v2":
                infer_v2(model_state.model, voice_path, clean_text, output_path)
            elif model_state.version == "v1":
                infer_v1(model_state.model, voice_path, clean_text, output_path)
            else:
                raise RuntimeError("未知 IndexTTS 版本，无法推理")

        if not output_path.exists() or output_path.stat().st_size == 0:
            raise RuntimeError("IndexTTS 未生成有效 wav 文件")

        return FileResponse(
            output_path,
            media_type="audio/wav",
            filename="output.wav",
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
