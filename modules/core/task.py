from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from uuid import uuid4


@dataclass
class TaskRecord:
    """MVP 阶段使用的内存任务状态。"""

    task_id: str
    status: str = "processing"
    video_url: str | None = None
    error: str | None = None
    created_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))
    updated_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))

    def to_dict(self) -> dict:
        """转换为接口可返回的字典。"""
        return asdict(self)


TASKS: dict[str, TaskRecord] = {}


def create_task_id() -> str:
    """生成唯一任务 ID。"""
    return uuid4().hex


def create_task() -> TaskRecord:
    """创建任务并写入内存状态表。"""
    task = TaskRecord(task_id=create_task_id())
    TASKS[task.task_id] = task
    return task


def get_task(task_id: str) -> TaskRecord | None:
    """查询任务状态。"""
    return TASKS.get(task_id)


def mark_task_success(task_id: str, video_url: str) -> None:
    """标记任务成功。"""
    task = TASKS.get(task_id)
    if task:
        task.status = "success"
        task.video_url = video_url
        task.error = None
        task.updated_at = datetime.now().isoformat(timespec="seconds")


def mark_task_failed(task_id: str, error: str) -> None:
    """标记任务失败。"""
    task = TASKS.get(task_id)
    if task:
        task.status = "failed"
        task.error = error
        task.updated_at = datetime.now().isoformat(timespec="seconds")
