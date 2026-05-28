from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

from modules.core.paths import PROJECT_ROOT


@dataclass
class AppConfig:
    """Web 服务配置。"""

    host: str = "127.0.0.1"
    port: int = 8000


@dataclass
class PathsConfig:
    """运行时目录配置，路径默认相对项目根目录。"""

    uploads_dir: str = "data/uploads"
    outputs_dir: str = "data/outputs"
    cache_dir: str = "data/cache"
    voices_dir: str = "data/voices"


@dataclass
class VideoConfig:
    """视频合成参数。"""

    default_aspect_ratio: str = "16:9"
    fps: int = 30
    crf: int = 18
    audio_bitrate: str = "192k"


@dataclass
class SubtitleConfig:
    """字幕生成参数。"""

    default_style: str = "yellow_black"
    max_chars_per_line_cjk: int = 18
    min_duration: float = 1.2


@dataclass
class TTSConfig:
    """TTS 后端配置；默认使用外部 IndexTTS API，mock 仅作为开发备用。"""

    backend: str = "indextts_api"
    indextts_api_url: str = "http://127.0.0.1:9000"
    request_timeout: int = 600
    split_by_sentence: bool = False
    mimo_api_url: str = "https://api.xiaomimimo.com/v1"
    mimo_model: str = "mimo-v2.5-tts-voiceclone"
    mimo_request_timeout: int = 600


@dataclass
class AppSettings:
    """应用总配置对象。"""

    app: AppConfig
    paths: PathsConfig
    video: VideoConfig
    subtitle: SubtitleConfig
    tts: TTSConfig


def load_config(config_path: Path | None = None) -> AppSettings:
    """从 YAML 加载配置；缺省字段会使用 dataclass 默认值。"""
    config_file = config_path or PROJECT_ROOT / "configs" / "default.yaml"
    raw_data = {}
    if config_file.exists():
        raw_data = yaml.safe_load(config_file.read_text(encoding="utf-8")) or {}

    return AppSettings(
        app=AppConfig(**raw_data.get("app", {})),
        paths=PathsConfig(**raw_data.get("paths", {})),
        video=VideoConfig(**raw_data.get("video", {})),
        subtitle=SubtitleConfig(**raw_data.get("subtitle", {})),
        tts=TTSConfig(**raw_data.get("tts", {})),
    )
