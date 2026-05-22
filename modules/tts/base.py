from pathlib import Path
from typing import Any


class BaseTTS:
    """TTS 基类，后续接入更多语音后端时复用同一接口。"""

    def synthesize(
        self,
        text: str,
        voice_ref_path: Path,
        output_path: Path,
        options: dict[str, Any] | None = None,
    ) -> Path:
        raise NotImplementedError
