from pathlib import Path

from PIL import Image, ImageFilter, ImageOps


SUPPORTED_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}
DEFAULT_ALPHA_MATTE = (243, 244, 246)
SUPPORTED_BACKGROUND_STYLES = {
    "blur",
    "white",
    "red",
    "blue",
    "gradient_blue",
    "gradient_red",
}

SOLID_BACKGROUND_COLORS = {
    "white": (255, 255, 255),
    "red": (255, 0, 0),
    "blue": (0, 0, 255),
}

GRADIENT_BACKGROUND_COLORS = {
    "gradient_blue": ((219, 234, 254), (37, 99, 235)),
    "gradient_red": ((254, 226, 226), (239, 68, 68)),
}


def has_alpha(image: Image.Image) -> bool:
    """判断图片是否包含透明信息。"""
    if image.mode in ("RGBA", "LA"):
        return True
    return image.mode == "P" and "transparency" in image.info


def convert_image_to_rgba(image: Image.Image) -> Image.Image:
    """统一把带透明信息的图片转为 RGBA，便于后续 alpha 合成。"""
    return image.convert("RGBA")


def load_image_keep_alpha(image_path: Path) -> Image.Image:
    """读取图片并修正 EXIF 方向；透明图保留 RGBA，普通图转为 RGB。"""
    with Image.open(image_path) as image:
        image = ImageOps.exif_transpose(image)
        if has_alpha(image):
            return convert_image_to_rgba(image)
        return image.convert("RGB")


def validate_image_file(image_path: Path) -> bool:
    """校验图片扩展名和文件内容。"""
    if not image_path.exists() or image_path.stat().st_size == 0:
        raise ValueError("图片文件为空或不存在")

    suffix = image_path.suffix.lower()
    if suffix not in SUPPORTED_IMAGE_SUFFIXES:
        raise ValueError("图片格式仅支持 png、jpg、jpeg、webp")

    try:
        with Image.open(image_path) as image:
            image.verify()
    except Exception as exc:
        raise ValueError("图片文件无法打开或已损坏") from exc

    return True


def resize_to_cover(image: Image.Image, width: int, height: int) -> Image.Image:
    """等比例放大图片并居中裁剪，用作模糊背景。"""
    source_width, source_height = image.size
    scale = max(width / source_width, height / source_height)
    resized_size = (round(source_width * scale), round(source_height * scale))
    resized = image.resize(resized_size, Image.Resampling.LANCZOS)

    left = (resized.width - width) // 2
    top = (resized.height - height) // 2
    return resized.crop((left, top, left + width, top + height))


def resize_to_contain(
    image: Image.Image,
    width: int,
    height: int,
    alpha_matte: tuple[int, int, int] = DEFAULT_ALPHA_MATTE,
) -> Image.Image:
    """等比例缩放图片，确保主体完整显示在画布中。"""
    source_width, source_height = image.size
    scale = min(width / source_width, height / source_height)
    resized_size = (round(source_width * scale), round(source_height * scale))
    resize_source = normalize_alpha_rgb(image, alpha_matte) if has_alpha(image) else image
    return resize_source.resize(resized_size, Image.Resampling.LANCZOS)


def flatten_alpha_to_rgb(image: Image.Image, color: tuple[int, int, int] = DEFAULT_ALPHA_MATTE) -> Image.Image:
    """把带 alpha 的图片合成到指定底色上，避免透明像素直接转 RGB 后变黑。"""
    if not has_alpha(image):
        return image.convert("RGB")

    foreground = convert_image_to_rgba(image)
    background = Image.new("RGB", foreground.size, color)
    return alpha_composite_on_background(foreground, background)


def alpha_composite_on_background(foreground: Image.Image, background: Image.Image) -> Image.Image:
    """把 RGBA 前景合成到 RGB 背景上，返回不带 alpha 的 RGB 图片。"""
    canvas = background.convert("RGBA")
    foreground_rgba = convert_image_to_rgba(foreground)
    canvas.paste(foreground_rgba, (0, 0), foreground_rgba.getchannel("A"))
    return canvas.convert("RGB")


def normalize_alpha_rgb(image: Image.Image, matte: tuple[int, int, int] = DEFAULT_ALPHA_MATTE) -> Image.Image:
    """清理透明像素里的 RGB 垃圾色，降低缩放后出现黑边/白边的概率。"""
    if not has_alpha(image):
        return image.convert("RGB")

    rgba = convert_image_to_rgba(image)
    alpha = rgba.getchannel("A")
    flattened_rgb = flatten_alpha_to_rgb(rgba, matte)
    return Image.merge("RGBA", (*flattened_rgb.split(), alpha))


def paste_center_with_alpha(canvas: Image.Image, foreground: Image.Image) -> Image.Image:
    """把前景图居中贴到 RGB 画布；RGBA 前景使用 alpha mask 合成。"""
    left = (canvas.width - foreground.width) // 2
    top = (canvas.height - foreground.height) // 2

    if foreground.mode == "RGBA":
        canvas.paste(foreground, (left, top), foreground.getchannel("A"))
    else:
        canvas.paste(foreground.convert("RGB"), (left, top))
    return canvas


def create_gradient_background(width: int, height: int, start_color: tuple[int, int, int], end_color: tuple[int, int, int]) -> Image.Image:
    """创建竖向渐变背景。"""
    background = Image.new("RGB", (width, height), start_color)
    if height <= 1:
        return background

    for y in range(height):
        ratio = y / (height - 1)
        color = tuple(
            round(start + (end - start) * ratio)
            for start, end in zip(start_color, end_color)
        )
        background.paste(Image.new("RGB", (width, 1), color), (0, y))
    return background


def create_background_canvas(
    source_image: Image.Image,
    width: int,
    height: int,
    background_style: str,
    blur_radius: int,
) -> Image.Image:
    """根据背景样式创建目标画布。"""
    if background_style == "blur":
        # 透明图先合成到浅色底，再生成模糊背景，避免透明区域参与缩放后变成黑底。
        background_source = flatten_alpha_to_rgb(source_image)
        background = resize_to_cover(background_source, width, height)
        background = background.filter(ImageFilter.GaussianBlur(radius=blur_radius))

        # 略微压暗背景，让前景角色和字幕更清晰。
        overlay = Image.new("RGB", (width, height), (0, 0, 0))
        return Image.blend(background, overlay, alpha=0.18)

    if background_style in SOLID_BACKGROUND_COLORS:
        return Image.new("RGB", (width, height), SOLID_BACKGROUND_COLORS[background_style])

    if background_style in GRADIENT_BACKGROUND_COLORS:
        start_color, end_color = GRADIENT_BACKGROUND_COLORS[background_style]
        return create_gradient_background(width, height, start_color, end_color)

    raise ValueError(f"不支持的背景样式：{background_style}")


def get_alpha_matte_for_style(background_style: str) -> tuple[int, int, int]:
    """为透明边缘选择一个接近背景的消色差底色。"""
    if background_style in SOLID_BACKGROUND_COLORS:
        return SOLID_BACKGROUND_COLORS[background_style]
    if background_style in GRADIENT_BACKGROUND_COLORS:
        return GRADIENT_BACKGROUND_COLORS[background_style][0]
    return DEFAULT_ALPHA_MATTE


def prepare_canvas_image(
    image_path: Path,
    output_path: Path,
    width: int,
    height: int,
    background_style: str = "blur",
    blur_radius: int = 36,
) -> Path:
    """生成目标比例画布：模糊背景填充，清晰前景居中显示。"""
    if background_style not in SUPPORTED_BACKGROUND_STYLES:
        raise ValueError(f"不支持的背景样式：{background_style}")

    validate_image_file(image_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    source_image = load_image_keep_alpha(image_path)
    background = create_background_canvas(source_image, width, height, background_style, blur_radius)
    foreground = resize_to_contain(
        source_image,
        width,
        height,
        alpha_matte=get_alpha_matte_for_style(background_style),
    )
    final_image = paste_center_with_alpha(background, foreground).convert("RGB")
    final_image.save(output_path, format="PNG")

    return output_path

