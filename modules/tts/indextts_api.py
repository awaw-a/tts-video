from pathlib import Path
from typing import Any
import logging

import requests

from modules.tts.base import BaseTTS

logger = logging.getLogger("tts_video")


class IndexTTSApiTTS(BaseTTS):
    """通过 HTTP 调用外部 IndexTTS API 服务的 TTS 后端。"""

    def __init__(self, api_url: str, timeout: int = 600):
        self.api_url = api_url.rstrip("/")
        self.timeout = timeout

    def synthesize(
        self,
        text: str,
        voice_ref_path: Path,
        output_path: Path,
        options: dict[str, Any] | None = None,
    ) -> Path:
        """把文案和参考音频发送给外部服务，并把返回的 wav 保存到本地。"""
        clean_text = text.strip()
        if not clean_text:
            raise ValueError("TTS 文案不能为空")
        if not voice_ref_path.exists() or voice_ref_path.stat().st_size == 0:
            raise ValueError("参考音频文件为空或不存在")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        synthesize_url = f"{self.api_url}/synthesize"
        logger.info("Calling IndexTTS API: url=%s, text_chars=%s", synthesize_url, len(clean_text))

        with voice_ref_path.open("rb") as voice_file:
            files = {
                "voice": (
                    voice_ref_path.name,
                    voice_file,
                    "application/octet-stream",
                )
            }
            data = {"text": clean_text}
            # 只透传后端真实支持的参数，避免前端展示“假开关”。
            for key, value in (options or {}).items():
                if value is not None and value != "":
                    data[key] = str(value)

            response = requests.post(
                synthesize_url,
                data=data,
                files=files,
                timeout=self.timeout,
            )

        if response.status_code != 200:
            error_text = response.text.strip() or response.reason
            logger.error("IndexTTS API failed: status=%s, error=%s", response.status_code, error_text[:500])
            raise RuntimeError(f"IndexTTS API 调用失败：HTTP {response.status_code}，{error_text}")

        logger.info("IndexTTS API response received: status=%s, bytes=%s", response.status_code, len(response.content))

        if not response.content:
            logger.error("IndexTTS API returned empty audio content")
            raise RuntimeError("IndexTTS API 返回了空音频内容")

        output_path.write_bytes(response.content)
        if output_path.stat().st_size == 0:
            logger.error("IndexTTS generated audio file is empty: %s", output_path)
            raise RuntimeError("IndexTTS 生成的音频文件为空")

        logger.info("IndexTTS API audio saved: %s bytes", output_path.stat().st_size)
        return output_path
