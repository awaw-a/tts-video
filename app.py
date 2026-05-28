from __future__ import annotations

import shutil
import logging
import sys
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from modules.core.config import load_config
from modules.core.mimo_credentials import has_mimo_api_key, save_mimo_api_key
from modules.core.paths import PROJECT_ROOT, ensure_runtime_dirs, resolve_project_path
from modules.core.task import create_task, get_task, mark_task_failed, mark_task_success
from modules.media.audio_utils import ensure_wav_or_supported_audio, get_audio_duration
from modules.media.image_utils import SUPPORTED_BACKGROUND_STYLES, prepare_canvas_image, validate_image_file
from modules.render.image_video import burn_subtitles, create_static_video
from modules.subtitle.ass_generator import generate_ass
from modules.subtitle.splitter import split_script_to_sentences
from modules.subtitle.srt_generator import generate_srt
from modules.tts.factory import get_tts_engine


settings = load_config()
ensure_runtime_dirs(settings.paths)
logger = logging.getLogger("tts_video")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(handler)
logger.setLevel(logging.INFO)
logger.propagate = False

app = FastAPI(title="tts-video", version="0.3.0")
app.mount("/static", StaticFiles(directory=PROJECT_ROOT / "static"), name="static")


ASPECT_RATIO_SIZES = {
    "16:9": (1920, 1080),
    "4:3": (1440, 1080),
    "9:16": (1080, 1920),
    "3:4": (1080, 1440),
    "1:1": (1080, 1080),
}

SUBTITLE_STYLES = {
    "white_black": "白字黑边",
    "yellow_black": "黄字黑边",
    "bilibili_large": "B站大字风格",
}

BACKGROUND_STYLES = {
    "blur": "图片模糊填充",
    "white": "纯白",
    "red": "纯红",
    "blue": "纯蓝",
    "gradient_blue": "渐变蓝",
    "gradient_red": "渐变红",
}

# 这些参数已经在 external/indextts_server.py 中真实接通。
INDEXTTS_SUPPORTED_OPTIONS = {
    "speed": True,
    "volume_gain_db": True,
    "seed": True,
    "emotion": False,
    "temperature": True,
    "top_p": True,
    "top_k": True,
    "repetition_penalty": True,
}

MOCK_SUPPORTED_OPTIONS = {
    "speed": False,
    "volume_gain_db": False,
    "seed": False,
    "emotion": False,
    "temperature": False,
    "top_p": False,
    "top_k": False,
    "repetition_penalty": False,
}

MIMO_SUPPORTED_OPTIONS = {
    **MOCK_SUPPORTED_OPTIONS,
    "style_prompt": True,
}

AVAILABLE_TTS_BACKENDS = ("indextts_api", "mimo_api", "mock")

TTS_BACKEND_LABELS = {
    "indextts_api": "IndexTTS",
    "mimo_api": "MiMoTTS",
    "mock": "Mock",
}


class SubtitlePreviewRequest(BaseModel):
    script: str
    max_cjk_chars: int | None = None


class MimoApiKeyRequest(BaseModel):
    api_key: str


@app.get("/")
def index() -> FileResponse:
    """返回前端页面。"""
    return FileResponse(
        PROJECT_ROOT / "static" / "index.html",
        headers={"Cache-Control": "no-store"},
    )


async def save_upload_file(upload_file: UploadFile, output_path: Path) -> Path:
    """分块保存上传文件，避免一次性读取大文件。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as file_obj:
        while True:
            chunk = await upload_file.read(1024 * 1024)
            if not chunk:
                break
            file_obj.write(chunk)
    return output_path


def get_upload_suffix(upload_file: UploadFile) -> str:
    """从上传文件名中提取扩展名。"""
    return Path(upload_file.filename or "").suffix.lower()


def get_tts_backend() -> str:
    """读取当前主程序使用的 TTS 后端。"""
    return normalize_tts_backend(settings.tts.backend)


def normalize_tts_backend(value: str | None) -> str:
    """规范化并校验前端传入的 TTS 后端名称。"""
    backend = (value or settings.tts.backend or "mock").strip().lower()
    if backend not in AVAILABLE_TTS_BACKENDS:
        raise ValueError(f"不支持的 TTS 后端：{backend}")
    return backend


def get_tts_engine_for_backend(backend: str):
    """按本次请求选择的后端创建 TTS 引擎。"""
    tts_config = vars(settings.tts).copy()
    tts_config["backend"] = backend
    return get_tts_engine({"tts": tts_config})


def get_indextts_health(timeout: float = 2.0) -> dict[str, Any]:
    """探测外部 IndexTTS API 服务状态。"""
    api_url = settings.tts.indextts_api_url.rstrip("/")
    try:
        response = requests.get(f"{api_url}/health", timeout=timeout)
        response.raise_for_status()
        payload = response.json()
        return {
            "url": api_url,
            "available": bool(payload.get("model_loaded")),
            "model_loaded": bool(payload.get("model_loaded")),
            "version": payload.get("version", "unknown"),
            "error": payload.get("error"),
            "error_code": payload.get("error_code"),
            "suggestion": payload.get("suggestion"),
            "supported_tts_options": payload.get("supported_tts_options"),
        }
    except Exception as exc:
        return {
            "url": api_url,
            "available": False,
            "model_loaded": False,
            "version": "unknown",
            "error": str(exc),
        }


def get_mimo_status() -> dict[str, Any]:
    """返回 MiMo 配置状态，不暴露 API Key 内容。"""
    return {
        "configured": has_mimo_api_key(),
        "model": settings.tts.mimo_model,
        "api_url": settings.tts.mimo_api_url.rstrip("/"),
    }


def supported_tts_options(backend: str | None = None, indextts_health: dict[str, Any] | None = None) -> dict[str, bool]:
    """告诉前端哪些 TTS 参数可以展示为可用控件。"""
    selected_backend = normalize_tts_backend(backend)
    if selected_backend == "mimo_api":
        return MIMO_SUPPORTED_OPTIONS

    if selected_backend == "mock":
        return MOCK_SUPPORTED_OPTIONS

    health = indextts_health or get_indextts_health(timeout=1.5)
    external_options = health.get("supported_tts_options")
    if isinstance(external_options, dict):
        return {**INDEXTTS_SUPPORTED_OPTIONS, **external_options}
    return INDEXTTS_SUPPORTED_OPTIONS


def supported_tts_options_by_backend(indextts_health: dict[str, Any] | None = None) -> dict[str, dict[str, bool]]:
    """按后端返回可用 TTS 控件，前端切换时无需再猜。"""
    return {
        "indextts_api": supported_tts_options("indextts_api", indextts_health),
        "mimo_api": supported_tts_options("mimo_api"),
        "mock": supported_tts_options("mock"),
    }


def get_tts_backends(indextts_health: dict[str, Any], mimo_status: dict[str, Any]) -> list[dict[str, Any]]:
    """返回主 WebUI 可选择的 TTS 后端。"""
    return [
        {
            "value": "indextts_api",
            "label": TTS_BACKEND_LABELS["indextts_api"],
            "available": bool(indextts_health.get("available") or indextts_health.get("model_loaded")),
            "configured": True,
        },
        {
            "value": "mimo_api",
            "label": TTS_BACKEND_LABELS["mimo_api"],
            "available": bool(mimo_status.get("configured")),
            "configured": bool(mimo_status.get("configured")),
        },
        {
            "value": "mock",
            "label": TTS_BACKEND_LABELS["mock"],
            "available": True,
            "configured": True,
        },
    ]


def parse_optional_seed(value: str | None) -> int | None:
    """把表单里的随机种子转成整数；空值代表不固定种子。"""
    if value is None or value.strip() == "":
        return None
    try:
        seed = int(value)
    except ValueError as exc:
        raise ValueError("随机种子必须是整数") from exc
    if seed < 0 or seed > 2**32 - 1:
        raise ValueError("随机种子必须在 0 到 4294967295 之间")
    return seed


def validate_range(name: str, value: float, minimum: float, maximum: float) -> float:
    """校验前端传入的数值范围。"""
    if value < minimum or value > maximum:
        raise ValueError(f"{name} 必须在 {minimum} 到 {maximum} 之间")
    return value


def build_tts_options(
    backend: str,
    speed: float,
    volume_gain_db: float,
    seed: str | None,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    style_prompt: str | None = None,
) -> dict[str, Any]:
    """构造传给 TTS 后端的参数；mock 模式下保持空参数。"""
    selected_backend = normalize_tts_backend(backend)
    if selected_backend == "mimo_api":
        clean_style_prompt = (style_prompt or "").strip()
        if len(clean_style_prompt) > 500:
            raise ValueError("MiMo 风格指令不能超过 500 个字符")
        return {
            "style_prompt": clean_style_prompt,
            "format": "wav",
        }

    if selected_backend != "indextts_api":
        return {}

    return {
        "speed": validate_range("语速", float(speed), 0.75, 1.5),
        "volume_gain_db": validate_range("音量增益", float(volume_gain_db), -12.0, 12.0),
        "seed": parse_optional_seed(seed),
        "temperature": validate_range("temperature", float(temperature), 0.1, 2.0),
        "top_p": validate_range("top_p", float(top_p), 0.1, 1.0),
        "top_k": int(validate_range("top_k", int(top_k), 1, 100)),
        "repetition_penalty": validate_range("repetition_penalty", float(repetition_penalty), 1.0, 20.0),
    }


def subtitle_preview(script: str, max_cjk_chars: int | None = None) -> list[str]:
    """复用后端分句逻辑生成字幕预览。"""
    clean_script = script.strip()
    if not clean_script:
        return []
    return split_script_to_sentences(
        clean_script,
        max_cjk_chars=max_cjk_chars or settings.subtitle.max_chars_per_line_cjk,
    )


@app.get("/api/config")
def api_config() -> dict:
    """返回前端初始化所需配置。"""
    backend = get_tts_backend()
    indextts_health = get_indextts_health(timeout=1.5)
    mimo_status = get_mimo_status()
    options_by_backend = supported_tts_options_by_backend(indextts_health)
    return {
        "tts_backend": backend,
        "tts_backends": get_tts_backends(indextts_health, mimo_status),
        "indextts_available": indextts_health["available"],
        "indextts_api": indextts_health,
        "mimo_api": mimo_status,
        "supported_tts_options": options_by_backend.get(backend, MOCK_SUPPORTED_OPTIONS),
        "supported_tts_options_by_backend": options_by_backend,
        "aspect_ratios": [
            {"value": key, "label": f"{key}（{width}x{height}）", "width": width, "height": height}
            for key, (width, height) in ASPECT_RATIO_SIZES.items()
        ],
        "default_aspect_ratio": settings.video.default_aspect_ratio,
        "background_styles": [
            {"value": key, "label": label}
            for key, label in BACKGROUND_STYLES.items()
        ],
        "default_background_style": "blur",
        "subtitle_styles": [
            {"value": key, "label": label}
            for key, label in SUBTITLE_STYLES.items()
        ],
        "default_subtitle_style": settings.subtitle.default_style,
        "default_max_chars_per_line": settings.subtitle.max_chars_per_line_cjk,
        "max_script_chars": 1000,
    }


@app.get("/api/health")
def api_health() -> dict:
    """返回主程序和外部 TTS 服务状态。"""
    return {
        "app_status": "ok",
        "tts_backend": get_tts_backend(),
        "indextts_api": get_indextts_health(timeout=1.5),
        "mimo_api": get_mimo_status(),
    }


@app.get("/api/mimo/status")
def api_mimo_status() -> dict:
    """返回 MiMo API Key 配置状态，不暴露 Key 内容。"""
    return get_mimo_status()


@app.post("/api/mimo/key")
def api_save_mimo_key(payload: MimoApiKeyRequest) -> dict:
    """保存 MiMo API Key 到后端环境。"""
    try:
        save_mimo_api_key(payload.api_key)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"configured": True, "message": "MiMo API Key 已保存到后端"}


@app.post("/api/preview_subtitle")
def preview_subtitle(payload: SubtitlePreviewRequest) -> dict:
    """给前端提供与后端一致的字幕分句预览。"""
    lines = subtitle_preview(payload.script, payload.max_cjk_chars)
    return {"lines": lines, "count": len(lines)}


@app.post("/api/generate")
async def generate_video(
    image: UploadFile = File(...),
    audio: UploadFile = File(...),
    script: str = Form(...),
    aspect_ratio: str = Form(settings.video.default_aspect_ratio),
    background_style: str = Form("blur"),
    subtitle_style: str = Form(settings.subtitle.default_style),
    subtitle_enabled: bool = Form(True),
    subtitle_max_chars: int = Form(settings.subtitle.max_chars_per_line_cjk),
    tts_speed: float = Form(1.0),
    tts_volume_gain_db: float = Form(0.0),
    tts_seed: str | None = Form(None),
    tts_temperature: float = Form(0.8),
    tts_top_p: float = Form(0.8),
    tts_top_k: int = Form(30),
    tts_repetition_penalty: float = Form(10.0),
    tts_backend: str = Form(""),
    tts_style_prompt: str = Form(""),
) -> dict:
    """执行生成流程：参考音频 -> TTS 输出 -> 字幕 -> 静态图视频 -> final.mp4。"""
    task = create_task()
    task_id = task.task_id
    selected_tts_backend = "unknown"

    try:
        selected_tts_backend = normalize_tts_backend(tts_backend or get_tts_backend())
        logger.info(
            "Task %s received generate request: backend=%s, ratio=%s, background=%s, subtitle_style=%s",
            task_id,
            selected_tts_backend,
            aspect_ratio,
            background_style,
            subtitle_style,
        )

        clean_script = script.strip()
        if not clean_script:
            raise ValueError("文案不能为空")

        if aspect_ratio not in ASPECT_RATIO_SIZES:
            raise ValueError(f"不支持的视频比例：{aspect_ratio}")

        if background_style not in SUPPORTED_BACKGROUND_STYLES:
            raise ValueError(f"不支持的背景样式：{background_style}")

        if subtitle_style not in SUBTITLE_STYLES:
            raise ValueError(f"不支持的字幕样式：{subtitle_style}")

        if subtitle_max_chars < 8 or subtitle_max_chars > 36:
            raise ValueError("每行最大字数必须在 8 到 36 之间")

        if selected_tts_backend == "mimo_api" and not has_mimo_api_key():
            raise ValueError("未设置 MiMo API Key，请先在语音设置中填写并保存")

        tts_options = build_tts_options(
            backend=selected_tts_backend,
            speed=tts_speed,
            volume_gain_db=tts_volume_gain_db,
            seed=tts_seed,
            temperature=tts_temperature,
            top_p=tts_top_p,
            top_k=tts_top_k,
            repetition_penalty=tts_repetition_penalty,
            style_prompt=tts_style_prompt,
        )

        width, height = ASPECT_RATIO_SIZES[aspect_ratio]
        uploads_root = resolve_project_path(settings.paths.uploads_dir)
        outputs_root = resolve_project_path(settings.paths.outputs_dir)
        cache_root = resolve_project_path(settings.paths.cache_dir)

        task_upload_dir = uploads_root / task_id
        task_output_dir = outputs_root / task_id
        task_cache_dir = cache_root / task_id
        task_upload_dir.mkdir(parents=True, exist_ok=True)
        task_output_dir.mkdir(parents=True, exist_ok=True)
        task_cache_dir.mkdir(parents=True, exist_ok=True)

        image_suffix = get_upload_suffix(image)
        audio_suffix = get_upload_suffix(audio)
        image_path = task_upload_dir / f"source_image{image_suffix}"
        reference_audio_path = task_upload_dir / f"reference_audio{audio_suffix}"
        script_path = task_upload_dir / "script.txt"

        await save_upload_file(image, image_path)
        await save_upload_file(audio, reference_audio_path)
        script_path.write_text(clean_script, encoding="utf-8")
        logger.info(
            "Task %s uploaded files saved: image=%s, audio=%s, script_chars=%s",
            task_id,
            image_path.name,
            reference_audio_path.name,
            len(clean_script),
        )

        validate_image_file(image_path)
        reference_audio_path = ensure_wav_or_supported_audio(reference_audio_path)
        logger.info("Task %s media validation complete", task_id)

        processed_image_path = task_cache_dir / "processed.png"
        prepare_canvas_image(image_path, processed_image_path, width, height, background_style=background_style)
        logger.info("Task %s image prepared: %sx%s background=%s", task_id, width, height, background_style)

        tts_engine = get_tts_engine_for_backend(selected_tts_backend)
        generated_audio_path = task_cache_dir / "generated.wav"
        logger.info("Task %s starting TTS synthesis with backend=%s", task_id, selected_tts_backend)
        tts_engine.synthesize(clean_script, reference_audio_path, generated_audio_path, options=tts_options)
        audio_duration = get_audio_duration(generated_audio_path)
        logger.info("Task %s TTS finished: duration=%.2fs", task_id, audio_duration)

        sentences = subtitle_preview(clean_script, subtitle_max_chars)
        if not sentences:
            raise ValueError("文案无法切分出有效字幕")

        srt_path = task_output_dir / "subtitle.srt"
        ass_path = task_output_dir / "subtitle.ass"
        logger.info("Task %s subtitle split complete: %s lines", task_id, len(sentences))
        logger.info("Task %s generating subtitle files", task_id)
        generate_srt(
            sentences,
            audio_duration,
            srt_path,
            min_duration=settings.subtitle.min_duration,
        )
        generate_ass(
            sentences,
            audio_duration,
            ass_path,
            width=width,
            height=height,
            style_name=subtitle_style,
            min_duration=settings.subtitle.min_duration,
        )

        temp_video_path = task_cache_dir / "temp_video.mp4"
        final_video_path = task_output_dir / "final.mp4"
        logger.info("Task %s starting static video render", task_id)
        create_static_video(
            processed_image_path,
            generated_audio_path,
            temp_video_path,
            width=width,
            height=height,
            fps=settings.video.fps,
            crf=settings.video.crf,
            audio_bitrate=settings.video.audio_bitrate,
        )
        if subtitle_enabled:
            logger.info("Task %s burning subtitles with ffmpeg", task_id)
            burn_subtitles(temp_video_path, ass_path, final_video_path, crf=settings.video.crf)
        else:
            logger.info("Task %s subtitle burn disabled; copying temp video", task_id)
            shutil.copyfile(temp_video_path, final_video_path)

        video_url = f"/api/download/{task_id}"
        mark_task_success(task_id, video_url=video_url)
        logger.info("Task %s completed successfully: %s", task_id, final_video_path)
        return {
            "task_id": task_id,
            "status": "success",
            "video_url": video_url,
            "audio_backend": selected_tts_backend,
            "subtitle_preview": sentences,
            "message": "生成成功",
        }

    except ValueError as exc:
        mark_task_failed(task_id, str(exc))
        logger.warning("Task %s failed with validation error: %s", task_id, exc)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        mark_task_failed(task_id, str(exc))
        logger.exception("Task %s failed with unexpected error", task_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/api/download/{task_id}")
def download_video(task_id: str) -> FileResponse:
    """下载指定任务的最终 MP4 文件。"""
    final_video_path = resolve_project_path(settings.paths.outputs_dir) / task_id / "final.mp4"
    if not final_video_path.exists():
        raise HTTPException(status_code=404, detail="未找到生成的视频文件")

    return FileResponse(
        final_video_path,
        media_type="video/mp4",
        filename=f"{task_id}.mp4",
    )


@app.get("/api/tasks/{task_id}")
def get_task_status(task_id: str) -> dict:
    """返回任务状态；MVP 使用内存状态，若文件存在也视为成功。"""
    task = get_task(task_id)
    if task:
        return task.to_dict()

    final_video_path = resolve_project_path(settings.paths.outputs_dir) / task_id / "final.mp4"
    if final_video_path.exists():
        return {
            "task_id": task_id,
            "status": "success",
            "video_url": f"/api/download/{task_id}",
        }

    return {"task_id": task_id, "status": "failed", "error": "任务不存在或未生成成功"}
