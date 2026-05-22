import re


SENTENCE_PATTERN = re.compile(r"[^。！？；.!?;]+[。！？；.!?;]?")


def is_cjk_char(char: str) -> bool:
    """判断字符是否属于常见中日韩文字范围。"""
    return "\u4e00" <= char <= "\u9fff"


def display_units(text: str) -> int:
    """估算字幕宽度：中文按 2 单位，英文和数字按 1 单位。"""
    units = 0
    for char in text:
        if char.isspace():
            units += 1
        elif is_cjk_char(char):
            units += 2
        else:
            units += 1
    return units


def split_long_sentence(sentence: str, max_units: int) -> list[str]:
    """将过长句子继续切分，尽量避免单条字幕过宽。"""
    parts: list[str] = []
    buffer = ""

    for char in sentence:
        if buffer and display_units(buffer + char) > max_units:
            parts.append(buffer.strip())
            buffer = char
        else:
            buffer += char

    if buffer.strip():
        parts.append(buffer.strip())

    return [part for part in parts if part]


def split_script_to_sentences(
    script: str,
    max_cjk_chars: int = 18,
    max_latin_chars: int = 36,
) -> list[str]:
    """按中英文标点分句，并把过长句子拆成更适合烧录的字幕。"""
    clean_script = re.sub(r"\s+", " ", script.strip())
    if not clean_script:
        return []

    max_units = max(max_cjk_chars * 2, max_latin_chars)
    raw_sentences = [match.group(0).strip() for match in SENTENCE_PATTERN.finditer(clean_script)]

    sentences: list[str] = []
    for raw_sentence in raw_sentences:
        if not raw_sentence:
            continue
        sentences.extend(split_long_sentence(raw_sentence, max_units))

    return sentences

