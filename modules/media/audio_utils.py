import wave
from pathlib import Path


SUPPORTED_AUDIO_SUFFIXES = {".wav", ".mp3", ".m4a"}


def ensure_wav_or_supported_audio(audio_path: Path) -> Path:
    """确认上传音频格式在 MVP 支持范围内。"""
    if not audio_path.exists() or audio_path.stat().st_size == 0:
        raise ValueError("音频文件为空或不存在")

    suffix = audio_path.suffix.lower()
    if suffix not in SUPPORTED_AUDIO_SUFFIXES:
        raise ValueError("音频格式仅支持 wav、mp3、m4a")

    return audio_path


def get_wav_duration(audio_path: Path) -> float:
    """使用标准库 wave 读取 WAV 时长。"""
    with wave.open(str(audio_path), "rb") as wave_file:
        frames = wave_file.getnframes()
        rate = wave_file.getframerate()
        if rate <= 0:
            raise ValueError("WAV 采样率无效")
        return frames / float(rate)


def get_audio_duration(audio_path: Path) -> float:
    """获取音频时长；WAV 优先走标准库，其他格式使用 pydub。"""
    ensure_wav_or_supported_audio(audio_path)

    try:
        if audio_path.suffix.lower() == ".wav":
            duration = get_wav_duration(audio_path)
        else:
            # pydub 依赖 ffmpeg/ffprobe 读取 mp3/m4a，按需导入可减少启动噪声。
            from pydub import AudioSegment

            audio = AudioSegment.from_file(audio_path)
            duration = len(audio) / 1000.0
    except Exception as exc:
        raise RuntimeError(
            "无法读取音频时长，请确认音频文件有效，并已安装 ffmpeg/ffprobe"
        ) from exc

    if duration <= 0:
        raise ValueError("音频时长必须大于 0")
    return duration
