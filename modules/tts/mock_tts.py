import shutil
from pathlib import Path
from typing import Any

from modules.render.ffmpeg_utils import run_ffmpeg
from modules.tts.base import BaseTTS


class MockTTS(BaseTTS):
    """开发调试用的假 TTS：直接复用用户上传的参考音频。"""

    def synthesize(
        self,
        text: str,
        voice_ref_path: Path,
        output_path: Path,
        options: dict[str, Any] | None = None,
    ) -> Path:
        output_path.parent.mkdir(parents=True, exist_ok=True)

        # 如果目标是 generated.wav，则把 mp3/m4a 转成真正的 WAV，
        # 避免“扩展名是 wav、内容却是 mp3”的文件影响后续时长读取。
        if output_path.suffix.lower() == ".wav" and voice_ref_path.suffix.lower() != ".wav":
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
                    "2",
                    output_path,
                ]
            )
            return output_path

        shutil.copyfile(voice_ref_path, output_path)
        return output_path
