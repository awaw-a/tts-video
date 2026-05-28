from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path

from modules.core.paths import PROJECT_ROOT


SUPPORTED_TTS_TOOL_MODES = {"indextts", "mimo"}
DEFAULT_TTS_TOOL_MODE = "indextts"
TTS_TOOL_URLS = {
    "indextts": "http://127.0.0.1:9000/",
    "mimo": "http://127.0.0.1:9021/",
}

MODE_FILE = PROJECT_ROOT / "runtime" / "tts_mode.json"
SWITCH_REQUEST_FILE = PROJECT_ROOT / "runtime" / "tts_switch_request.json"


def normalize_tts_tool_mode(mode: str | None) -> str:
    """规范化 TTS 工具模式。"""
    clean_mode = (mode or "").strip().lower()
    if clean_mode not in SUPPORTED_TTS_TOOL_MODES:
        raise ValueError(f"不支持的 TTS 工具：{mode}")
    return clean_mode


def get_tts_tool_url(mode: str) -> str:
    """返回指定 TTS 工具的本地 WebUI 地址。"""
    return TTS_TOOL_URLS[normalize_tts_tool_mode(mode)]


def read_tts_tool_mode() -> str:
    """读取当前 TTS 工具模式；没有记录时默认 IndexTTS。"""
    if not MODE_FILE.exists():
        return DEFAULT_TTS_TOOL_MODE
    try:
        payload = json.loads(MODE_FILE.read_text(encoding="utf-8"))
        return normalize_tts_tool_mode(payload.get("mode"))
    except Exception:
        return DEFAULT_TTS_TOOL_MODE


def write_tts_tool_mode(mode: str) -> None:
    """持久化当前 TTS 工具模式。"""
    normalized = normalize_tts_tool_mode(mode)
    MODE_FILE.parent.mkdir(parents=True, exist_ok=True)
    MODE_FILE.write_text(
        json.dumps(
            {
                "mode": normalized,
                "url": get_tts_tool_url(normalized),
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def request_tts_tool_switch(target_mode: str, source_mode: str | None = None) -> dict:
    """写入切换请求，由启动控制脚本负责停旧启新。"""
    target = normalize_tts_tool_mode(target_mode)
    source = normalize_tts_tool_mode(source_mode) if source_mode else read_tts_tool_mode()
    SWITCH_REQUEST_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source_mode": source,
        "target_mode": target,
        "target_url": get_tts_tool_url(target),
        "requested_at": datetime.now().isoformat(timespec="seconds"),
    }
    SWITCH_REQUEST_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return payload
