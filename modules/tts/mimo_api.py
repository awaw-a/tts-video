from __future__ import annotations

import base64
import logging
from pathlib import Path
from typing import Any

import requests

from modules.core.mimo_credentials import get_mimo_api_key
from modules.render.ffmpeg_utils import run_ffmpeg
from modules.tts.base import BaseTTS


logger = logging.getLogger("tts_video")

MIMO_DEFAULT_API_URL = "https://api.xiaomimimo.com/v1"
MIMO_DEFAULT_MODEL = "mimo-v2.5-tts-voiceclone"
MIMO_MAX_BASE64_BYTES = 10 * 1024 * 1024
MIMO_AUDIO_MIME_TYPES = {
    ".mp3": "audio/mpeg",
    ".wav": "audio/wav",
}


class MimoApiTTS(BaseTTS):
    """通过小米 MiMo API 进行音色克隆的 TTS 后端。"""

    def __init__(
        self,
        api_url: str = MIMO_DEFAULT_API_URL,
        model: str = MIMO_DEFAULT_MODEL,
        timeout: int = 600,
        max_base64_bytes: int = MIMO_MAX_BASE64_BYTES,
    ):
        self.api_url = api_url.rstrip("/")
        self.model = model
        self.timeout = timeout
        self.max_base64_bytes = max_base64_bytes

    def synthesize(
        self,
        text: str,
        voice_ref_path: Path,
        output_path: Path,
        options: dict[str, Any] | None = None,
    ) -> Path:
        """调用 MiMo voiceclone API，并把返回音频写入本地 WAV。"""
        clean_text = text.strip()
        if not clean_text:
            raise ValueError("MiMo TTS 文本不能为空")
        if not voice_ref_path.exists() or voice_ref_path.stat().st_size == 0:
            raise ValueError("参考音频文件为空或不存在")

        api_key = get_mimo_api_key()
        if not api_key:
            raise ValueError("未设置 MIMO_API_KEY，请先在 MiMo 页面填写 API Key")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        prepared_voice_path = self.prepare_voice_audio(voice_ref_path, output_path.parent)
        voice_data_uri = self.build_voice_data_uri(prepared_voice_path)
        style_prompt = str((options or {}).get("style_prompt") or "")
        audio_format = str((options or {}).get("format") or "wav")
        messages: list[dict[str, str]] = []
        if style_prompt.strip():
            messages.append({"role": "user", "content": style_prompt.strip()})
        messages.append({"role": "assistant", "content": clean_text})

        request_url = f"{self.api_url}/chat/completions"
        payload = {
            "model": self.model,
            "messages": messages,
            "audio": {
                "format": audio_format,
                "voice": voice_data_uri,
            },
        }
        logger.info(
            "Calling MiMo TTS API: model=%s, text_chars=%s, style_chars=%s",
            self.model,
            len(clean_text),
            len(style_prompt),
        )
        response = requests.post(
            request_url,
            headers={
                "api-key": api_key,
                "Content-Type": "application/json",
            },
            json=payload,
            timeout=self.timeout,
        )

        if response.status_code != 200:
            raise RuntimeError(
                f"MiMo TTS API 调用失败：HTTP {response.status_code}，"
                f"{self.extract_error_message(response)}"
            )

        audio_data = self.extract_audio_data(response)
        audio_bytes = base64.b64decode(audio_data)
        if not audio_bytes:
            raise RuntimeError("MiMo TTS API 返回了空音频内容")

        output_path.write_bytes(audio_bytes)
        if output_path.stat().st_size == 0:
            raise RuntimeError("MiMo TTS 生成的音频文件为空")

        logger.info("MiMo TTS audio saved: %s bytes", output_path.stat().st_size)
        return output_path

    def prepare_voice_audio(self, voice_ref_path: Path, work_dir: Path) -> Path:
        """MiMo voiceclone 仅支持 mp3/wav；其他支持格式先转为 WAV。"""
        suffix = voice_ref_path.suffix.lower()
        if suffix in MIMO_AUDIO_MIME_TYPES:
            return voice_ref_path

        if suffix == ".m4a":
            converted_path = work_dir / "mimo_reference.wav"
            run_ffmpeg(
                [
                    "-i",
                    voice_ref_path,
                    "-vn",
                    "-acodec",
                    "pcm_s16le",
                    "-ar",
                    "44100",
                    "-ac",
                    "1",
                    converted_path,
                ]
            )
            return converted_path

        raise ValueError("MiMo 音色克隆参考音频仅支持 wav、mp3、m4a")

    def build_voice_data_uri(self, voice_path: Path) -> str:
        """构造 MiMo API 要求的 data URI。"""
        suffix = voice_path.suffix.lower()
        mime_type = MIMO_AUDIO_MIME_TYPES.get(suffix)
        if not mime_type:
            raise ValueError("MiMo 音色克隆参考音频仅支持 wav、mp3")

        encoded = base64.b64encode(voice_path.read_bytes()).decode("utf-8")
        if len(encoded.encode("utf-8")) > self.max_base64_bytes:
            raise ValueError("参考音频过大，Base64 后不能超过 10 MB，请换用更短的音频")
        return f"data:{mime_type};base64,{encoded}"

    def extract_audio_data(self, response: requests.Response) -> str:
        """从 MiMo OpenAI-compatible 响应中取出 base64 音频。"""
        try:
            payload = response.json()
            choices = payload.get("choices") or []
            message = choices[0].get("message") or {}
            audio = message.get("audio") or {}
            data = audio.get("data")
        except Exception as exc:
            raise RuntimeError("MiMo TTS API 返回格式无法解析") from exc

        if not data:
            raise RuntimeError("MiMo TTS API 响应中没有 audio.data")
        return str(data)

    def extract_error_message(self, response: requests.Response) -> str:
        """提取错误信息，避免把请求头或 API Key 泄露到异常里。"""
        try:
            payload = response.json()
        except Exception:
            return (response.text or response.reason or "").strip()[:500]

        error = payload.get("error")
        if isinstance(error, dict):
            return str(error.get("message") or error.get("code") or error)[:500]
        if error:
            return str(error)[:500]
        return str(payload)[:500]
