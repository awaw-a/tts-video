from pathlib import Path

from PIL import Image, ImageFilter


SUPPORTED_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


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


def resize_to_contain(image: Image.Image, width: int, height: int) -> Image.Image:
    """等比例缩放图片，确保主体完整显示在画布中。"""
    source_width, source_height = image.size
    scale = min(width / source_width, height / source_height)
    resized_size = (round(source_width * scale), round(source_height * scale))
    return image.resize(resized_size, Image.Resampling.LANCZOS)


def prepare_canvas_image(
    image_path: Path,
    output_path: Path,
    width: int,
    height: int,
    blur_radius: int = 36,
) -> Path:
    """生成目标比例画布：模糊背景填充，清晰前景居中显示。"""
    validate_image_file(image_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(image_path) as source_image:
        source_image = source_image.convert("RGB")

        background = resize_to_cover(source_image, width, height)
        background = background.filter(ImageFilter.GaussianBlur(radius=blur_radius))

        # 略微压暗背景，让前景角色和字幕更清晰。
        overlay = Image.new("RGB", (width, height), (0, 0, 0))
        background = Image.blend(background, overlay, alpha=0.18)

        foreground = resize_to_contain(source_image, width, height)
        left = (width - foreground.width) // 2
        top = (height - foreground.height) // 2
        background.paste(foreground, (left, top))
        background.save(output_path, format="PNG")

    return output_path

