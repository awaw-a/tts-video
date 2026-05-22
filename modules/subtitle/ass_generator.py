from pathlib import Path

from modules.subtitle.srt_generator import build_subtitle_timeline


def format_ass_time(seconds: float) -> str:
    """格式化为 ASS 时间：H:MM:SS.cc。"""
    centiseconds = max(0, round(seconds * 100))
    hours = centiseconds // 360_000
    centiseconds %= 360_000
    minutes = centiseconds // 6_000
    centiseconds %= 6_000
    secs = centiseconds // 100
    centis = centiseconds % 100
    return f"{hours}:{minutes:02d}:{secs:02d}.{centis:02d}"


def escape_ass_text(text: str) -> str:
    """转义 ASS 文本中可能影响渲染的字符。"""
    return text.replace("{", "（").replace("}", "）").replace("\n", "\\N")


def get_style_line(style_name: str, width: int, height: int) -> str:
    """根据样式名称和分辨率生成 ASS Style 行。"""
    min_side = min(width, height)
    normal_font_size = max(42, int(min_side * 0.052))
    large_font_size = max(58, int(min_side * 0.074))

    if style_name == "white_black":
        font_size = normal_font_size
        primary = "&H00FFFFFF"
        outline = 3
        bold = 0
        margin_v = max(58, int(height * 0.085))
    elif style_name == "bilibili_large":
        font_size = large_font_size
        primary = "&H0000FFFF"
        outline = 6
        bold = 1
        margin_v = max(80, int(height * 0.115))
    else:
        font_size = normal_font_size
        primary = "&H0000FFFF"
        outline = 4
        bold = 0
        margin_v = max(58, int(height * 0.085))

    # Alignment=2 表示底部居中，BorderStyle=1 表示描边字幕。
    return (
        "Style: Default,Arial,"
        f"{font_size},{primary},&H000000FF,&H00000000,&H64000000,"
        f"{bold},0,0,0,100,100,0,0,1,{outline},0,2,60,60,{margin_v},1"
    )


def generate_ass(
    sentences: list[str],
    total_duration: float,
    output_path: Path,
    width: int,
    height: int,
    style_name: str = "yellow_black",
    min_duration: float = 1.2,
) -> Path:
    """生成 ASS 字幕文件，用于 ffmpeg ass 滤镜烧录。"""
    segments = build_subtitle_timeline(sentences, total_duration, min_duration=min_duration)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    header = [
        "[Script Info]",
        "ScriptType: v4.00+",
        f"PlayResX: {width}",
        f"PlayResY: {height}",
        "ScaledBorderAndShadow: yes",
        "",
        "[V4+ Styles]",
        "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding",
        get_style_line(style_name, width, height),
        "",
        "[Events]",
        "Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text",
    ]

    events = [
        "Dialogue: 0,"
        f"{format_ass_time(segment.start)},{format_ass_time(segment.end)},"
        f"Default,,0,0,0,,{escape_ass_text(segment.text)}"
        for segment in segments
    ]

    output_path.write_text("\n".join(header + events) + "\n", encoding="utf-8")
    return output_path

