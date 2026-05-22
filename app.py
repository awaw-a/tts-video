from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from modules.core.config import load_config
from modules.core.paths import PROJECT_ROOT, ensure_runtime_dirs, resolve_project_path
from modules.core.task import create_task, get_task, mark_task_failed, mark_task_success
from modules.media.audio_utils import ensure_wav_or_supported_audio, get_audio_duration
from modules.media.image_utils import prepare_canvas_image, validate_image_file
from modules.render.image_video import burn_subtitles, create_static_video
from modules.subtitle.ass_generator import generate_ass
from modules.subtitle.splitter import split_script_to_sentences
from modules.subtitle.srt_generator import generate_srt
from modules.tts.factory import get_tts_engine


settings = load_config()
ensure_runtime_dirs(settings.paths)

app = FastAPI(title="tts-video", version="0.2.0")
app.mount("/static", StaticFiles(directory=PROJECT_ROOT / "static"), name="static")


ASPECT_RATIO_SIZES = {
    "16:9": (1920, 1080),
    "9:16": (1080, 1920),
    "1:1": (1080, 1080),
}

SUBTITLE_STYLES = {"white_black", "yellow_black", "bilibili_large"}


@app.get("/")
def index() -> FileResponse:
    """返回前端首页。"""
    return FileResponse(PROJECT_ROOT / "static" / "index.html")


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


@app.post("/api/generate")
async def generate_video(
    image: UploadFile = File(...),
    audio: UploadFile = File(...),
    script: str = Form(...),
    aspect_ratio: str = Form(settings.video.default_aspect_ratio),
    subtitle_style: str = Form(settings.subtitle.default_style),
) -> dict:
    """执行生成流程：参考音频 -> TTS 输出 -> 字幕 -> 静态图视频 -> final.mp4。"""
    task = create_task()
    task_id = task.task_id

    try:
        clean_script = script.strip()
        if not clean_script:
            raise ValueError("文案不能为空")

        if aspect_ratio not in ASPECT_RATIO_SIZES:
            raise ValueError(f"不支持的视频比例：{aspect_ratio}")

        if subtitle_style not in SUBTITLE_STYLES:
            raise ValueError(f"不支持的字幕样式：{subtitle_style}")

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

        validate_image_file(image_path)
        reference_audio_path = ensure_wav_or_supported_audio(reference_audio_path)

        # 图片预处理和 TTS 输出都放在 cache 中，uploads 只保留用户原始素材。
        processed_image_path = task_cache_dir / "processed.png"
        prepare_canvas_image(image_path, processed_image_path, width, height)

        # audio 现在是参考音频；真正进入视频的是 TTS 后端生成的 generated.wav。
        tts_engine = get_tts_engine(settings)
        generated_audio_path = task_cache_dir / "generated.wav"
        tts_engine.synthesize(clean_script, reference_audio_path, generated_audio_path)
        audio_duration = get_audio_duration(generated_audio_path)

        sentences = split_script_to_sentences(
            clean_script,
            max_cjk_chars=settings.subtitle.max_chars_per_line_cjk,
        )
        if not sentences:
            raise ValueError("文案无法切分出有效字幕")

        srt_path = task_output_dir / "subtitle.srt"
        ass_path = task_output_dir / "subtitle.ass"
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
        burn_subtitles(temp_video_path, ass_path, final_video_path, crf=settings.video.crf)

        video_url = f"/api/download/{task_id}"
        mark_task_success(task_id, video_url=video_url)
        return {"task_id": task_id, "status": "success", "video_url": video_url}

    except ValueError as exc:
        mark_task_failed(task_id, str(exc))
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        mark_task_failed(task_id, str(exc))
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
