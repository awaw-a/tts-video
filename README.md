# tts-video

一个“静态角色口播视频生成器”MVP。当前版本专注跑通完整链路：

角色图片 + 音频 + 文案 -> 字幕文件 -> 静态图视频 -> 烧录字幕 -> MP4。

当前默认使用 `indextts_api`：主 WebUI 会调用外部 IndexTTS API 服务，根据参考音频和文案生成克隆语音。`mock` 后端仍保留，但只作为开发调试或无模型环境下的备用模式。

## 当前功能

- 上传 png/jpg/jpeg/webp 角色图片。
- 上传 wav/mp3/m4a 参考音频 / 测试音频。
- 输入文案并自动切分字幕。
- 支持 16:9、9:16、1:1 三种视频比例。
- 支持 white_black、yellow_black、bilibili_large 三种 ASS 字幕样式。
- 使用 ffmpeg 合成静态图片视频并烧录字幕。
- 输出 `data/outputs/{task_id}/final.mp4`。
- 默认使用 `indextts_api` TTS 后端；`mock` 仅用于开发调试。

## 后续计划

- 增加分句 TTS，提高字幕与语音同步准确度。
- 接入 F5-TTS。
- 接入 CosyVoice。
- 接入 LLM 文案生成。
- 增加批量生成。
- 增加更多字幕模板。

## 安装

Windows 用户克隆仓库后，建议直接运行一键安装脚本：

```bat
install.bat
```

脚本会自动完成：

- 创建 `.venv310` 虚拟环境。
- 安装 `requirements.txt` 中的主 WebUI 依赖。
- 安装 `requirements-indextts.txt` 中的 IndexTTS / GPU / AI 推理依赖。
- 下载 Windows 版 ffmpeg 到 `third_party/ffmpeg/windows/bin/`。
- 克隆 `index-tts` 外部仓库。
- 下载 IndexTTS-2 checkpoints 和运行时依赖模型。
- 修补 IndexTTS 的 Hugging Face 缓存路径，使其使用项目内的 `index-tts/checkpoints/hf_cache`。

如果暂时不下载模型，只完成依赖、ffmpeg 和仓库准备，可以运行：

```bat
install.bat -SkipModels
```

手动安装时，主程序建议使用 Python 3.10 或更高版本。若要在同一环境中运行 IndexTTS，建议使用 Python 3.10；IndexTTS 的部分依赖不支持 Python 3.14。

```bash
python -m venv .venv310
```

macOS / Linux:

```bash
source .venv310/bin/activate
```

Windows PowerShell:

```powershell
.venv310\Scripts\Activate.ps1
```

主 WebUI 基础依赖：

```bash
pip install -r requirements.txt
```

完整运行默认的 `indextts_api` 链路，还需要安装 IndexTTS API 服务依赖：

```bash
pip install -r requirements-indextts.txt
```

`requirements.txt` 只包含 FastAPI、Pillow、pydub、requests 等主程序依赖；`requirements-indextts.txt` 包含 torch、torchaudio、transformers、IndexTTS 运行时等较重依赖。拆分后，主 WebUI 和开发调试环境更轻，完整声音克隆链路则需要额外准备 IndexTTS 依赖与模型。

## ffmpeg 说明

本项目使用 ffmpeg 命令行合成视频、读取部分音频格式和烧录字幕。Windows 用户运行 `install.bat` 后，会自动下载 `third_party/ffmpeg/windows/bin/ffmpeg.exe` 和 `ffprobe.exe`，正常情况下不需要手动安装 ffmpeg。

下载版本来自 gyan.dev 的 Windows release essentials 静态构建，包含本项目需要的 libx264、AAC、libass 等能力。程序会优先使用项目内的 ffmpeg；如果文件不存在，则回退查找系统 PATH 中的 `ffmpeg`。

macOS / Linux 暂未内置二进制文件，需要自行安装 ffmpeg：

macOS:

```bash
brew install ffmpeg
```

Ubuntu / Debian:

```bash
sudo apt update
sudo apt install ffmpeg
```

如需更新 Windows 内置 ffmpeg，可从 https://www.gyan.dev/ffmpeg/builds/ 下载 `ffmpeg-release-essentials.zip`，并替换 `third_party/ffmpeg/windows/bin/` 下的 `ffmpeg.exe` 和 `ffprobe.exe`。

## 接入 IndexTTS

当前支持两种 TTS 后端：

- `indextts_api`：默认后端，调用外部 IndexTTS 服务，使用参考音频生成克隆语音。
- `mock`：备用后端，复制上传音频，适合开发调试或无模型环境下验证视频合成流程。

推荐目录结构：

```text
tts-video/
  index-tts/
```

IndexTTS 准备方式：

1. 克隆 IndexTTS 官方仓库到 `tts-video/index-tts`。
2. 按 IndexTTS 官方 README 安装依赖并下载 checkpoints。
3. 先确认 IndexTTS 自己的 demo 可以生成语音。

本仓库将依赖拆成两层：`requirements.txt` 是主 WebUI 基础依赖，`requirements-indextts.txt` 是 IndexTTS / GPU / AI 推理依赖。Windows + NVIDIA 环境安装 `requirements-indextts.txt` 时会下载 PyTorch CUDA 12.8 轮子，体积较大，建议预留 10GB 以上磁盘空间。

如果你希望把 IndexTTS 放在兄弟目录，也可以启动服务前设置：

```bash
export INDEXTTS_REPO="../index-tts"
export INDEXTTS_MODEL_DIR="../index-tts/checkpoints"
export INDEXTTS_CFG_PATH="../index-tts/checkpoints/config.yaml"
```

启动 IndexTTS API 服务：

Windows:

```bat
scripts\run_indextts_server.bat
```

Linux / Mac:

```bash
bash scripts/run_indextts_server.sh
```

也可以手动启动：

```bash
uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
```

健康检查：

```text
http://127.0.0.1:9000/health
```

如果模型加载成功，应返回 `model_loaded: true`。

项目默认已经是 IndexTTS API 模式，`configs/default.yaml` 应保持：

```yaml
tts:
  backend: "indextts_api"
  indextts_api_url: "http://127.0.0.1:9000"
  request_timeout: 600
  split_by_sentence: false
```

启动主程序：

```bash
uvicorn app:app --reload
```

如果只是开发调试 WebUI 或验证视频合成流程，没有准备模型，可以临时把 `configs/default.yaml` 改成：

```yaml
tts:
  backend: "mock"
```

mock 模式会直接把上传音频作为最终音频使用，不会生成克隆语音。

使用方式：

1. 上传图片。
2. 上传参考音频。
3. 输入文案。
4. 点击生成。
5. 下载 `final.mp4`。

常见问题：

- `/health` 访问失败：IndexTTS 服务没启动，或端口不是 9000。
- `model_loaded: false`：检查 `INDEXTTS_REPO`、`INDEXTTS_MODEL_DIR`、`INDEXTTS_CFG_PATH` 是否正确。
- 500 错误：通常是模型路径、checkpoints、CUDA 环境或 IndexTTS 依赖不正确。
- CUDA OOM：关闭并发、缩短文本、开启 FP16，或换更大显存显卡。
- 生成很慢：首次加载模型较慢，后续请求通常会快一些。
- Mac 开发：Mac 可以跑 tts-video 主程序，IndexTTS 服务建议在 Windows + NVIDIA 机器上跑。
- 中文路径问题：建议项目和模型路径使用英文目录。

合规提醒：

- 只使用本人或已获得授权的参考音频。
- 不要用来冒充真人或制作误导性内容。

## 启动

Windows 一键启动完整链路（IndexTTS API + tts-video 主程序）：

```bat
start_all.bat
```

脚本会在后台启动 IndexTTS API 和 WebUI，不再为每个服务单独弹出窗口。它会等待 `http://127.0.0.1:9000/health` 返回 `model_loaded: true`，再启动 `http://127.0.0.1:8000` 并自动打开浏览器。主控制窗口会实时显示 WebUI / IndexTTS 的合并日志；运行中按 `Q` 可以安全停止服务并退出。若检测到旧服务已经占用 8000/9000 端口但没有 PID 文件，脚本会询问是否停止旧进程并重新接管。

运行时文件位置：

- PID 文件：`runtime/webui.pid`、`runtime/indextts.pid`
- WebUI 日志：`logs/webui.log`、`logs/webui.err.log`
- IndexTTS 日志：`logs/indextts.log`、`logs/indextts.err.log`

开发调试模式：

```bat
start_debug.bat
```

该模式会打开独立的 WebUI 和 IndexTTS 控制台窗口，方便分别观察原始输出；调试窗口通常手动关闭。

Windows 一键关闭服务：

```bat
stop_all.bat
```

它会优先读取 `runtime/*.pid` 中记录的 PID，只关闭由本项目启动脚本创建的 tts-video / IndexTTS 进程；如果 PID 文件不存在但端口仍被占用，脚本会列出占用进程并询问是否停止，不会无确认地强制结束无关进程。

手动启动主程序：

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
3. 上传一段 wav/mp3/m4a 参考音频 / 测试音频。
4. 输入中文或英文文案。
5. 选择视频比例和字幕样式。
6. 点击生成。
7. 生成完成后点击下载，或在 `data/outputs/{task_id}/final.mp4` 查看文件。

## 常见问题

### 找不到 ffmpeg

如果接口返回“未找到 ffmpeg”，请先确认 `third_party/ffmpeg/windows/bin/ffmpeg.exe` 是否存在。非 Windows 系统需要自行安装 ffmpeg，并确保 `ffmpeg`、`ffprobe` 在 PATH 中。

### 字幕乱码

ASS 字幕默认使用 Arial 或系统字体回退。如果中文显示异常，请安装常见中文字体，并确认 ffmpeg/libass 可以访问系统字体。

### 上传文件过大

当前 MVP 没有接入对象存储和任务队列，建议使用较短测试音频和适中尺寸图片。生产环境应增加文件大小限制、异步队列和清理策略。

### 路径包含中文或空格

后端使用 `pathlib` 管理路径，并在烧录字幕时尽量使用相对字幕路径。若 Windows 下仍遇到路径问题，建议先将项目放在纯英文路径中测试。

## 声音克隆合规提醒

后续接入音色克隆功能时，只应使用本人或已获得授权的参考音频。请勿在未授权情况下克隆、模仿或传播他人声音。
