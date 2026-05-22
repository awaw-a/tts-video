from dataclasses import dataclass
from pathlib import Path

from modules.subtitle.splitter import display_units


@dataclass
class SubtitleSegment:
    """字幕片段，供 SRT 和 ASS 复用。"""

    index: int
    text: str
    start: float
    end: float


def build_subtitle_timeline(
    sentences: list[str],
    total_duration: float,
    min_duration: float = 1.2,
) -> list[SubtitleSegment]:
    """根据音频总时长和文字长度，按比例分配字幕时间轴。"""
    clean_sentences = [sentence.strip() for sentence in sentences if sentence.strip()]
    if not clean_sentences:
        return []
    if total_duration <= 0:
        raise ValueError("音频时长必须大于 0")

    weights = [max(display_units(sentence), 1) for sentence in clean_sentences]
    total_weight = sum(weights)
    count = len(clean_sentences)

    # 如果音频足够长，每句保底 min_duration，再按文字长度分配剩余时间。
    if total_duration >= count * min_duration:
        remaining = total_duration - count * min_duration
        durations = [min_duration + remaining * weight / total_weight for weight in weights]
    else:
        # 极短音频无法满足最短时长时，优先保证总时长与音频一致。
        durations = [total_duration * weight / total_weight for weight in weights]

    segments: list[SubtitleSegment] = []
    cursor = 0.0
    for index, (sentence, duration) in enumerate(zip(clean_sentences, durations), start=1):
        start = cursor
        end = total_duration if index == count else min(total_duration, cursor + duration)
        segments.append(SubtitleSegment(index=index, text=sentence, start=start, end=end))
        cursor = end

    return segments


def format_srt_time(seconds: float) -> str:
    """格式化为 SRT 时间：HH:MM:SS,mmm。"""
    milliseconds = max(0, round(seconds * 1000))
    hours = milliseconds // 3_600_000
    milliseconds %= 3_600_000
    minutes = milliseconds // 60_000
    milliseconds %= 60_000
    secs = milliseconds // 1000
    millis = milliseconds % 1000
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def generate_srt(
    sentences: list[str],
    total_duration: float,
    output_path: Path,
    min_duration: float = 1.2,
) -> Path:
    """生成 SRT 字幕文件。"""
    segments = build_subtitle_timeline(sentences, total_duration, min_duration=min_duration)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    blocks: list[str] = []
    for segment in segments:
        blocks.append(
            "\n".join(
                [
                    str(segment.index),
                    f"{format_srt_time(segment.start)} --> {format_srt_time(segment.end)}",
                    segment.text,
                ]
            )
        )

    output_path.write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
    return output_path

