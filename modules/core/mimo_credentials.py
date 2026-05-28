from __future__ import annotations

import os


MIMO_API_KEY_ENV = "MIMO_API_KEY"


def get_mimo_api_key() -> str | None:
    """读取当前进程可用的 MiMo API Key。"""
    api_key = os.environ.get(MIMO_API_KEY_ENV, "").strip()
    if api_key:
        return api_key

    persisted_key = get_persisted_mimo_api_key()
    if persisted_key:
        os.environ[MIMO_API_KEY_ENV] = persisted_key
        return persisted_key

    return None


def has_mimo_api_key() -> bool:
    """返回是否已经配置 MiMo API Key，但不暴露 Key 内容。"""
    return get_mimo_api_key() is not None


def save_mimo_api_key(api_key: str) -> None:
    """保存 MiMo API Key 到当前进程；Windows 下同步写入用户环境变量。"""
    clean_key = api_key.strip()
    if not clean_key:
        raise ValueError("MiMo API Key 不能为空")

    os.environ[MIMO_API_KEY_ENV] = clean_key
    if os.name == "nt":
        save_windows_user_environment(MIMO_API_KEY_ENV, clean_key)


def get_persisted_mimo_api_key() -> str | None:
    """读取已持久化的 MiMo API Key；当前主要支持 Windows 用户环境变量。"""
    if os.name != "nt":
        return None

    import winreg

    registry_locations = (
        (winreg.HKEY_CURRENT_USER, "Environment"),
        (
            winreg.HKEY_LOCAL_MACHINE,
            r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
        ),
    )

    for root, subkey in registry_locations:
        try:
            with winreg.OpenKey(root, subkey) as key:
                value, _ = winreg.QueryValueEx(key, MIMO_API_KEY_ENV)
        except FileNotFoundError:
            continue
        except OSError:
            continue

        clean_value = str(value).strip()
        if clean_value:
            return clean_value

    return None


def save_windows_user_environment(name: str, value: str) -> None:
    """写入当前 Windows 用户环境变量，并通知系统环境已变更。"""
    import ctypes
    import winreg

    with winreg.CreateKeyEx(
        winreg.HKEY_CURRENT_USER,
        "Environment",
        0,
        winreg.KEY_SET_VALUE,
    ) as key:
        winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)

    hwnd_broadcast = 0xFFFF
    wm_settingchange = 0x001A
    smto_abortifhung = 0x0002
    result = ctypes.c_ulong()
    ctypes.windll.user32.SendMessageTimeoutW(
        hwnd_broadcast,
        wm_settingchange,
        0,
        "Environment",
        smto_abortifhung,
        5000,
        ctypes.byref(result),
    )
