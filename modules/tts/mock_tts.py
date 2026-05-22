import shutil
from pathlib import Path

from modules.tts.base import BaseTTS


class MockTTS(BaseTTS):
    """MVP 阶段的假 TTS：直接复制用户上传的音频。"""

    def synthesize(self, text: str, voice_ref_path: Path, output_path: Path) -> Path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(voice_ref_path, output_path)
        return output_path

