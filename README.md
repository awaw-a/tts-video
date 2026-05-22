# tts-video

一个“静态角色口播视频生成器”MVP。当前版本专注跑通完整链路：

角色图片 + 音频 + 文案 -> 字幕文件 -> 静态图视频 -> 烧录字幕 -> MP4。

当前 MVP 不接入真实 IndexTTS、F5-TTS、LLM，也不做角色动作、口型同步。音频会直接使用用户上传的测试音频，后续可以替换为真实 TTS 模块。

## 当前功能

- 上传 png/jpg/jpeg/webp 角色图片。
- 上传 wav/mp3/m4a 音频。
- 输入文案并自动切分字幕。
- 支持 16:9、9:16、1:1 三种视频比例。
- 支持 white_black、yellow_black、bilibili_large 三种 ASS 字幕样式。
- 使用 ffmpeg 合成静态图片视频并烧录字幕。
- 输出 `data/outputs/{task_id}/final.mp4`。

## 后续计划

- 接入 IndexTTS。
- 接入 F5-TTS。
- 接入 CosyVoice。
- 接入 LLM 文案生成。
- 增加批量生成。
- 增加更多字幕模板。

## 安装

建议使用 Python 3.10 或更高版本。

```bash
python -m venv .venv
```

macOS / Linux:

```bash
source .venv/bin/activate
```

Windows PowerShell:

```powershell
.venv\Scripts\Activate.ps1
```

安装依赖：

```bash
pip install -r requirements.txt
```

## 安装 ffmpeg

本项目使用 ffmpeg 命令行合成视频、读取部分音频格式和烧录字幕。请先安装 ffmpeg，并确保 `ffmpeg`、`ffprobe` 已加入 PATH。优先推荐安装包含 libass 的 ffmpeg；如果当前 ffmpeg 没有 `ass` 字幕滤镜，程序会自动使用 Pillow 预渲染字幕图片作为兜底方案。

macOS:

```bash
brew install ffmpeg
```

Ubuntu / Debian:

```bash
sudo apt update
sudo apt install ffmpeg
```

Windows:

1. 从 https://ffmpeg.org/download.html 下载 ffmpeg。
2. 解压后将 `bin` 目录加入系统 PATH。
3. 打开新终端执行 `ffmpeg -version` 验证。

## 启动

```bash
uvicorn app:app --reload
```

访问：

```text
http://127.0.0.1:8000
```

## 使用方法

1. 打开页面。
2. 上传一张角色图片。
3. 上传一段 wav/mp3/m4a 音频。
4. 输入中文或英文文案。
5. 选择视频比例和字幕样式。
6. 点击生成。
7. 生成完成后点击下载，或在 `data/outputs/{task_id}/final.mp4` 查看文件。

## 常见问题

### 找不到 ffmpeg

如果接口返回“未找到 ffmpeg”，说明系统没有安装 ffmpeg，或 ffmpeg 不在 PATH 中。安装后请重新打开终端，再启动服务。

### 字幕乱码

ASS 字幕默认使用 Arial 或系统字体回退。如果中文显示异常，请安装常见中文字体，并确认 ffmpeg/libass 可以访问系统字体。

### 上传文件过大

当前 MVP 没有接入对象存储和任务队列，建议使用较短测试音频和适中尺寸图片。生产环境应增加文件大小限制、异步队列和清理策略。

### 路径包含中文或空格

后端使用 `pathlib` 管理路径，并在烧录字幕时尽量使用相对字幕路径。若 Windows 下仍遇到路径问题，建议先将项目放在纯英文路径中测试。

## 声音克隆合规提醒

后续接入音色克隆功能时，只应使用本人或已获得授权的参考音频。请勿在未授权情况下克隆、模仿或传播他人声音。
