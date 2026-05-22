from __future__ import annotations

from pathlib import Path


# modules/core/paths.py -> modules/core -> modules -> 项目根目录
PROJECT_ROOT = Path(__file__).resolve().parents[2]


def resolve_project_path(path_value: str | Path) -> Path:
    """将配置路径解析为绝对路径。"""
    path = Path(path_value)
    if path.is_absolute():
        return path
    return PROJECT_ROOT / path


def ensure_runtime_dirs(paths_config) -> None:
    """首次运行时自动创建 data 相关目录。"""
    for path_value in (
        paths_config.uploads_dir,
        paths_config.outputs_dir,
        paths_config.cache_dir,
        paths_config.voices_dir,
    ):
        resolve_project_path(path_value).mkdir(parents=True, exist_ok=True)
