from __future__ import annotations

import os
import random
import sys
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from uuid import uuid4

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from modules.render.ffmpeg_utils import run_ffmpeg

logger = logging.getLogger("indextts_server")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logger.propagate = False


PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = PROJECT_ROOT / "data" / "indextts_server" / "outputs"
DEFAULT_MAX_TEXT_LENGTH = 1000

SUPPORTED_TTS_OPTIONS = {
    "speed": True,
    "volume_gain_db": True,
    "seed": True,
    "emotion": False,
    "temperature": True,
    "top_p": True,
    "top_k": True,
    "repetition_penalty": True,
}


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


@dataclass
class SynthesisOptions:
    """前端可调整且当前包装服务已真实接通的推理/音频参数。"""

    speed: float = 1.0
    volume_gain_db: float = 0.0
    seed: int | None = None
    temperature: float = 0.8
    top_p: float = 0.8
    top_k: int = 30
    repetition_penalty: float = 10.0


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


def parse_optional_seed(value: str | None) -> int | None:
    """把表单里的 seed 字符串转为整数；空值代表使用随机结果。"""
    if value is None or value.strip() == "":
        return None
    try:
        seed = int(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="seed 必须是整数") from exc
    if seed < 0 or seed > 2**32 - 1:
        raise HTTPException(status_code=400, detail="seed 必须在 0 到 4294967295 之间")
    return seed


def validate_range(name: str, value: float, minimum: float, maximum: float) -> float:
    """限制前端传入参数范围，避免把异常值直接送进模型。"""
    if value < minimum or value > maximum:
        raise HTTPException(status_code=400, detail=f"{name} 必须在 {minimum} 到 {maximum} 之间")
    return value


def build_synthesis_options(
    speed: float,
    volume_gain_db: float,
    seed: str | None,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
) -> SynthesisOptions:
    """构造并校验可真实生效的 TTS 参数。"""
    return SynthesisOptions(
        speed=validate_range("speed", float(speed), 0.75, 1.5),
        volume_gain_db=validate_range("volume_gain_db", float(volume_gain_db), -12.0, 12.0),
        seed=parse_optional_seed(seed),
        temperature=validate_range("temperature", float(temperature), 0.1, 2.0),
        top_p=validate_range("top_p", float(top_p), 0.1, 1.0),
        top_k=int(validate_range("top_k", int(top_k), 1, 100)),
        repetition_penalty=validate_range("repetition_penalty", float(repetition_penalty), 1.0, 20.0),
    )


def set_inference_seed(seed: int | None) -> None:
    """设置 Python / NumPy / Torch 随机种子，让同参数下结果尽量可复现。"""
    if seed is None:
        return

    random.seed(seed)
    try:
        import numpy as np

        np.random.seed(seed)
    except Exception:
        pass

    try:
        import torch

        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
    except Exception:
        pass


def generation_kwargs(options: SynthesisOptions) -> dict:
    """转换为 IndexTTS v1/v2 infer 支持的采样参数。"""
    return {
        "temperature": options.temperature,
        "top_p": options.top_p,
        "top_k": options.top_k,
        "repetition_penalty": options.repetition_penalty,
    }


def infer_v2(tts_model: object, voice_path: Path, text: str, output_path: Path, options: SynthesisOptions) -> None:
    """调用 IndexTTS v2 推理接口。"""
    tts_model.infer(
        spk_audio_prompt=str(voice_path),
        text=text,
        output_path=str(output_path),
        verbose=True,
        **generation_kwargs(options),
    )


def infer_v1(tts_model: object, voice_path: Path, text: str, output_path: Path, options: SynthesisOptions) -> None:
    """调用旧版 IndexTTS 推理接口。"""
    tts_model.infer(
        str(voice_path),
        text,
        str(output_path),
        verbose=True,
        **generation_kwargs(options),
    )


def postprocess_audio(output_path: Path, options: SynthesisOptions) -> None:
    """用 ffmpeg 对生成结果做语速和音量增益后处理。"""
    filters: list[str] = []
    if abs(options.speed - 1.0) > 0.001:
        filters.append(f"atempo={options.speed:.4f}")
    if abs(options.volume_gain_db) > 0.001:
        filters.append(f"volume={options.volume_gain_db:.2f}dB")
    if not filters:
        return

    temp_path = output_path.with_name("output_postprocessed.wav")
    run_ffmpeg(
        [
            "-i",
            output_path,
            "-vn",
            "-filter:a",
            ",".join(filters),
            "-acodec",
            "pcm_s16le",
            "-ar",
            "44100",
            "-ac",
            "2",
            temp_path,
        ]
    )
    output_path.unlink(missing_ok=True)
    temp_path.replace(output_path)


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
    logger.info(
        "Loading IndexTTS model: version=%s, repo=%s, model_dir=%s",
        config.version,
        config.repo,
        config.model_dir,
    )

    try:
        model, version = load_model_from_config(config)
        model_state.model = model
        model_state.version = version
        model_state.model_loaded = True
        model_state.error = None
        logger.info("IndexTTS model loaded successfully: version=%s", version)
    except Exception as exc:
        model_state.model = None
        model_state.version = "unknown"
        model_state.model_loaded = False
        model_state.error = str(exc)
        logger.exception("IndexTTS model failed to load")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI 生命周期：启动时加载模型，退出时交给 Python 回收资源。"""
    load_model_once()
    yield


app = FastAPI(title="IndexTTS API Server", version="0.2.0", lifespan=lifespan)


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
    """返回模型加载状态和当前包装服务支持的参数。"""
    payload = {
        "status": "ok",
        "model_loaded": model_state.model_loaded,
        "version": model_state.version,
        "supported_tts_options": SUPPORTED_TTS_OPTIONS,
    }
    if model_state.error:
        payload["error"] = model_state.error
    return payload


@app.post("/synthesize")
async def synthesize(
    text: str = Form(...),
    voice: UploadFile = File(...),
    speed: float = Form(1.0),
    volume_gain_db: float = Form(0.0),
    seed: str | None = Form(None),
    temperature: float = Form(0.8),
    top_p: float = Form(0.8),
    top_k: int = Form(30),
    repetition_penalty: float = Form(10.0),
) -> FileResponse:
    """接收文案、参考音频和推理参数，返回 IndexTTS 生成的 wav 文件。"""
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

    options = build_synthesis_options(
        speed=speed,
        volume_gain_db=volume_gain_db,
        seed=seed,
        temperature=temperature,
        top_p=top_p,
        top_k=top_k,
        repetition_penalty=repetition_penalty,
    )

    task_id = uuid4().hex
    task_dir = OUTPUT_ROOT / task_id
    voice_suffix = Path(voice.filename or "").suffix.lower() or ".wav"
    voice_path = task_dir / f"reference_audio{voice_suffix}"
    output_path = task_dir / "output.wav"
    logger.info(
        "Synthesis task %s received: text_chars=%s, version=%s, speed=%.2f, seed=%s",
        task_id,
        len(clean_text),
        model_state.version,
        options.speed,
        options.seed,
    )

    try:
        await save_upload_file(voice, voice_path)
        logger.info("Synthesis task %s reference audio saved: %s bytes", task_id, voice_path.stat().st_size)
        if voice_path.stat().st_size == 0:
            raise HTTPException(status_code=400, detail="参考音频为空")

        # 多数 TTS 模型不是为并发推理设计的，这里先串行化，避免显存互相踩踏。
        with inference_lock:
            logger.info("Synthesis task %s starting IndexTTS inference", task_id)
            set_inference_seed(options.seed)
            if model_state.version == "v2":
                infer_v2(model_state.model, voice_path, clean_text, output_path, options)
            elif model_state.version == "v1":
                infer_v1(model_state.model, voice_path, clean_text, output_path, options)
            else:
                raise RuntimeError("未知 IndexTTS 版本，无法推理")
            postprocess_audio(output_path, options)
            logger.info("Synthesis task %s inference and audio postprocess finished", task_id)

        if not output_path.exists() or output_path.stat().st_size == 0:
            raise RuntimeError("IndexTTS 未生成有效 wav 文件")

        logger.info("Synthesis task %s completed: output_bytes=%s", task_id, output_path.stat().st_size)
        return FileResponse(
            output_path,
            media_type="audio/wav",
            filename="output.wav",
        )
    except HTTPException:
        logger.warning("Synthesis task %s failed with HTTP error", task_id)
        raise
    except Exception as exc:
        logger.exception("Synthesis task %s failed", task_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc
