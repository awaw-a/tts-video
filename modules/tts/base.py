from pathlib import Path


class BaseTTS:
    """TTS 基类，后续接入 IndexTTS/F5-TTS/CosyVoice 时复用该接口。"""

    def synthesize(self, text: str, voice_ref_path: Path, output_path: Path) -> Path:
        raise NotImplementedError

