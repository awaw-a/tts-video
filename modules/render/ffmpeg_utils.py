from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Sequence


def check_ffmpeg_installed() -> None:
    """检查系统是否可以找到 ffmpeg 命令。"""
    if not shutil.which("ffmpeg"):
        raise RuntimeError("未找到 ffmpeg，请先安装 ffmpeg 并将其加入 PATH")


def run_ffmpeg(arguments: Sequence[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    """运行 ffmpeg 命令，失败时抛出包含 stderr 的异常。"""
    check_ffmpeg_installed()
    command = ["ffmpeg", "-y", *[str(argument) for argument in arguments]]
    result = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "ffmpeg 执行失败\n"
            f"命令：{' '.join(command)}\n"
            f"stderr：\n{result.stderr}"
        )

    return result


def has_ffmpeg_filter(filter_name: str) -> bool:
    """检查当前 ffmpeg 是否内置指定滤镜。"""
    check_ffmpeg_installed()
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-h", f"filter={filter_name}"],
        capture_output=True,
        text=True,
        check=False,
    )
    output = f"{result.stdout}\n{result.stderr}"
    return "Unknown filter" not in output
