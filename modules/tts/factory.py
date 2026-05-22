from typing import Any

from modules.tts.base import BaseTTS
from modules.tts.indextts_api import IndexTTSApiTTS
from modules.tts.mock_tts import MockTTS


def get_config_value(config: Any, key_path: str, default: Any = None) -> Any:
    """兼容 dict 和 dataclass/对象两种配置读取方式。"""
    current = config
    for key in key_path.split("."):
        if current is None:
            return default
        if isinstance(current, dict):
            current = current.get(key, default)
        else:
            current = getattr(current, key, default)
    return current


def get_tts_engine(config: Any) -> BaseTTS:
    """根据配置创建 TTS 后端实例。"""
    backend = str(get_config_value(config, "tts.backend", "mock")).strip().lower()

    if backend == "mock":
        return MockTTS()

    if backend == "indextts_api":
        api_url = str(
            get_config_value(config, "tts.indextts_api_url", "http://127.0.0.1:9000")
        )
        timeout = int(get_config_value(config, "tts.request_timeout", 600))
        return IndexTTSApiTTS(api_url=api_url, timeout=timeout)

    raise ValueError(f"不支持的 TTS 后端：{backend}")
