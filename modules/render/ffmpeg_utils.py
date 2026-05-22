from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Sequence

from modules.core.paths import PROJECT_ROOT


def get_project_ffmpeg_bin_dir() -> Path | None:
    """返回项目内置 ffmpeg 的 bin 目录；当前仓库内置 Windows 构建。"""
    if os.name == "nt":
        return PROJECT_ROOT / "third_party" / "ffmpeg" / "windows" / "bin"
    return None


def get_project_ffmpeg_tool(tool_name: str) -> Path | None:
    """查找项目内置的 ffmpeg/ffprobe 可执行文件。"""
    bin_dir = get_project_ffmpeg_bin_dir()
    if not bin_dir:
        return None

    executable_name = f"{tool_name}.exe" if os.name == "nt" else tool_name
    tool_path = bin_dir / executable_name
    if tool_path.exists():
        return tool_path
    return None


def ensure_project_ffmpeg_on_path() -> None:
    """把项目内置 ffmpeg 目录临时加入当前进程 PATH，供 pydub/ffprobe 使用。"""
    bin_dir = get_project_ffmpeg_bin_dir()
    if not bin_dir or not bin_dir.exists():
        return

    bin_dir_text = str(bin_dir)
    path_parts = os.environ.get("PATH", "").split(os.pathsep)
    if bin_dir_text not in path_parts:
        os.environ["PATH"] = bin_dir_text + os.pathsep + os.environ.get("PATH", "")


def resolve_ffmpeg_tool(tool_name: str = "ffmpeg") -> str:
    """优先使用项目内置 ffmpeg，找不到时再回退到系统 PATH。"""
    project_tool = get_project_ffmpeg_tool(tool_name)
    if project_tool:
        ensure_project_ffmpeg_on_path()
        return str(project_tool)

    ensure_project_ffmpeg_on_path()
    system_tool = shutil.which(tool_name)
    if system_tool:
        return system_tool

    raise RuntimeError(
        f"未找到 {tool_name}，请确认项目内置 ffmpeg 文件存在，或将 {tool_name} 加入 PATH"
    )


def check_ffmpeg_installed() -> None:
    """检查当前环境是否可以找到 ffmpeg 命令。"""
    resolve_ffmpeg_tool("ffmpeg")


def run_ffmpeg(arguments: Sequence[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    """运行 ffmpeg 命令，失败时抛出包含 stderr 的异常。"""
    command = [resolve_ffmpeg_tool("ffmpeg"), "-y", *[str(argument) for argument in arguments]]
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
    result = subprocess.run(
        [resolve_ffmpeg_tool("ffmpeg"), "-hide_banner", "-h", f"filter={filter_name}"],
        capture_output=True,
        text=True,
        check=False,
    )
    output = f"{result.stdout}\n{result.stderr}"
    return "Unknown filter" not in output
