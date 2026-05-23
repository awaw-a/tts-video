from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from modules.render.ffmpeg_utils import has_ffmpeg_filter, run_ffmpeg


def create_static_video(
    image_path: Path,
    audio_path: Path,
    output_path: Path,
    width: int,
    height: int,
    fps: int = 30,
    crf: int = 18,
    audio_bitrate: str = "192k",
) -> Path:
    """用一张静态图片和音频生成临时 MP4 视频。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    run_ffmpeg(
        [
            "-loop",
            "1",
            "-framerate",
            str(fps),
            "-i",
            image_path,
            "-i",
            audio_path,
            "-vf",
            f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
            f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p",
            "-c:v",
            "libx264",
            "-tune",
            "stillimage",
            "-c:a",
            "aac",
            "-b:a",
            audio_bitrate,
            "-pix_fmt",
            "yuv420p",
            "-shortest",
            "-r",
            str(fps),
            "-crf",
            str(crf),
            output_path,
        ]
    )
    return output_path


def burn_subtitles(
    input_video_path: Path,
    subtitle_path: Path,
    output_path: Path,
    crf: int = 18,
) -> Path:
    """使用 ffmpeg ass 滤镜把 ASS 字幕烧录进视频。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if not has_ffmpeg_filter("ass"):
        return burn_subtitles_with_pillow_fallback(input_video_path, subtitle_path, output_path, crf)

    # 使用 cwd + 文件名可以避开 Windows 绝对路径中的冒号和反斜杠转义问题。
    run_ffmpeg(
        [
            "-i",
            input_video_path,
            "-vf",
            f"ass=filename={subtitle_path.name}",
            "-c:v",
            "libx264",
            "-crf",
            str(crf),
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "copy",
            output_path,
        ],
        cwd=subtitle_path.parent,
    )
    return output_path


def burn_subtitles_with_pillow_fallback(
    input_video_path: Path,
    subtitle_path: Path,
    output_path: Path,
    crf: int = 18,
) -> Path:
    """当 ffmpeg 缺少 ass/drawtext 滤镜时，用 Pillow 预渲染字幕图片再合成视频。"""
    frames_dir = output_path.parent / "_subtitle_frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    base_frame_path = frames_dir / "base.png"
    concat_path = frames_dir / "concat.txt"

    run_ffmpeg(["-i", input_video_path, "-frames:v", "1", base_frame_path])

    segments = parse_ass_events(subtitle_path)
    style = parse_ass_style(subtitle_path)
    if not segments:
        raise RuntimeError("ASS 字幕文件中没有可用 Dialogue 事件")

    with Image.open(base_frame_path) as base_image:
        base_image = base_image.convert("RGB")
        frame_entries: list[tuple[Path, float]] = []
        cursor = 0.0

        for index, segment in enumerate(segments):
            start, end, text = segment
            if start > cursor:
                frame_entries.append((save_subtitle_frame(base_image, "", style, frames_dir, len(frame_entries)), start - cursor))
            frame_entries.append((save_subtitle_frame(base_image, text, style, frames_dir, len(frame_entries)), end - start))
            cursor = end

    concat_path.write_text(build_concat_file(frame_entries), encoding="utf-8")
    run_ffmpeg(
        [
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            concat_path,
            "-i",
            input_video_path,
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "libx264",
            "-crf",
            str(crf),
            "-pix_fmt",
            "yuv420p",
            "-r",
            "30",
            "-c:a",
            "copy",
            "-shortest",
            output_path,
        ]
    )
    return output_path


def parse_ass_time(time_text: str) -> float:
    """解析 ASS 时间格式 H:MM:SS.cc。"""
    hours_text, minutes_text, seconds_text = time_text.split(":")
    seconds = float(seconds_text)
    return int(hours_text) * 3600 + int(minutes_text) * 60 + seconds


def parse_ass_events(subtitle_path: Path) -> list[tuple[float, float, str]]:
    """从 ASS 文件中读取 Dialogue 事件。"""
    events: list[tuple[float, float, str]] = []
    for line in subtitle_path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("Dialogue:"):
            continue
        payload = line.removeprefix("Dialogue:").strip()
        parts = payload.split(",", 9)
        if len(parts) < 10:
            continue
        start = parse_ass_time(parts[1])
        end = parse_ass_time(parts[2])
        text = parts[9].replace("\\N", "\n").strip()
        if end > start and text:
            events.append((start, end, text))
    return events


def parse_ass_color(color_text: str) -> tuple[int, int, int]:
    """解析 ASS 颜色格式 &HAABBGGRR，返回 RGB。"""
    hex_text = color_text.strip().removeprefix("&H").zfill(8)
    blue = int(hex_text[2:4], 16)
    green = int(hex_text[4:6], 16)
    red = int(hex_text[6:8], 16)
    return red, green, blue


def parse_ass_style(subtitle_path: Path) -> dict:
    """读取 Default 样式，给 Pillow 兜底渲染使用。"""
    default_style = {
        "font_size": 56,
        "fill": (255, 255, 0),
        "stroke_width": 4,
        "stroke_fill": (0, 0, 0),
        "margin_v": 90,
        "bold": False,
    }

    for line in subtitle_path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("Style: Default,"):
            continue
        parts = line.removeprefix("Style:").strip().split(",")
        if len(parts) < 22:
            return default_style
        default_style.update(
            {
                "font_size": int(float(parts[2])),
                "fill": parse_ass_color(parts[3]),
                "stroke_fill": parse_ass_color(parts[5]),
                "bold": parts[7].strip() == "1",
                "stroke_width": max(1, int(float(parts[16]))),
                "margin_v": int(float(parts[21])),
            }
        )
        return default_style

    return default_style


def load_subtitle_font(font_size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """尽量加载支持中文的系统字体，找不到时回退到 Pillow 默认字体。"""
    font_candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    if bold:
        font_candidates.insert(0, "/System/Library/Fonts/Supplemental/Arial Bold.ttf")

    for font_path in font_candidates:
        path = Path(font_path)
        if path.exists():
            try:
                return ImageFont.truetype(str(path), font_size)
            except OSError:
                continue

    return ImageFont.load_default()


def wrap_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont, max_width: int) -> list[str]:
    """按像素宽度把字幕拆成多行。"""
    wrapped_lines: list[str] = []
    for raw_line in text.splitlines() or [text]:
        line = ""
        for char in raw_line:
            candidate = line + char
            bbox = draw.textbbox((0, 0), candidate, font=font)
            if line and bbox[2] - bbox[0] > max_width:
                wrapped_lines.append(line)
                line = char
            else:
                line = candidate
        if line:
            wrapped_lines.append(line)
    return wrapped_lines


def save_subtitle_frame(
    base_image: Image.Image,
    text: str,
    style: dict,
    frames_dir: Path,
    index: int,
) -> Path:
    """保存一张已经画好字幕的静态帧。"""
    frame = base_image.copy()
    if text:
        draw = ImageDraw.Draw(frame)
        font = load_subtitle_font(style["font_size"], bold=style["bold"])
        max_width = int(frame.width * 0.88)
        lines = wrap_text(draw, text, font, max_width)
        line_boxes = [draw.textbbox((0, 0), line, font=font, stroke_width=style["stroke_width"]) for line in lines]
        line_heights = [box[3] - box[1] for box in line_boxes]
        line_gap = max(8, int(style["font_size"] * 0.18))
        total_height = sum(line_heights) + line_gap * max(0, len(lines) - 1)
        y = frame.height - style["margin_v"] - total_height

        for line, box, line_height in zip(lines, line_boxes, line_heights):
            line_width = box[2] - box[0]
            x = (frame.width - line_width) / 2
            draw.text(
                (x, y),
                line,
                font=font,
                fill=style["fill"],
                stroke_width=style["stroke_width"],
                stroke_fill=style["stroke_fill"],
            )
            y += line_height + line_gap

    frame_path = frames_dir / f"frame_{index:04d}.png"
    frame.save(frame_path, format="PNG")
    return frame_path


def escape_concat_path(path: Path) -> str:
    """转义 ffmpeg concat 文件里的单引号。"""
    return str(path).replace("'", "'\\''")


def build_concat_file(frame_entries: list[tuple[Path, float]]) -> str:
    """生成 concat demuxer 所需的文件列表。"""
    if not frame_entries:
        raise RuntimeError("没有可用于合成的视频帧")

    lines: list[str] = []
    for frame_path, duration in frame_entries:
        lines.append(f"file '{escape_concat_path(frame_path)}'")
        lines.append(f"duration {max(duration, 0.04):.6f}")
    lines.append(f"file '{escape_concat_path(frame_entries[-1][0])}'")
    return "\n".join(lines) + "\n"
