# tts-video

一个“静态角色口播视频生成器”MVP。当前版本专注跑通完整链路：

角色图片 + 音频 + 文案 -> 字幕文件 -> 静态图视频 -> 烧录字幕 -> MP4。

当前默认使用 `indextts_api`：主 WebUI 会调用外部 IndexTTS API 服务，根据参考音频和文案生成克隆语音。`mock` 后端仍保留，但只作为开发调试或无模型环境下的备用模式。

## 当前功能

- 上传 png/jpg/jpeg/webp 角色图片。
- 上传 wav/mp3/m4a 参考音频 / 测试音频。
- 输入文案并自动切分字幕。
- 支持 16:9、4:3、9:16、3:4、1:1 五种视频比例。
- 支持图片模糊填充、纯白、纯红、纯蓝、渐变蓝、渐变红六种背景样式。
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

手动安装时，主 WebUI 可使用 Python 3.10 或更高版本；若要在同一环境中完整运行默认的 IndexTTS 链路，推荐使用 Python 3.10。Windows 一键安装脚本也会优先创建 `.venv310`，因为 IndexTTS 的部分依赖对更高版本 Python 兼容性较差。

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

一键脚本默认使用项目内的 `tts-video/index-tts`。如果你希望把 IndexTTS 放在兄弟目录，请不要直接使用默认一键脚本启动 IndexTTS；可以手动设置环境变量后运行服务，或按需修改 `scripts/service_common.ps1` / `scripts/run_indextts_server.*` 中的路径。

手动启动兄弟目录 IndexTTS 示例。

Linux / Mac:

```bash
export INDEXTTS_REPO="../index-tts"
export INDEXTTS_MODEL_DIR="../index-tts/checkpoints"
export INDEXTTS_CFG_PATH="../index-tts/checkpoints/config.yaml"
uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
```

Windows PowerShell:

```powershell
$env:INDEXTTS_REPO = "..\index-tts"
$env:INDEXTTS_MODEL_DIR = "..\index-tts\checkpoints"
$env:INDEXTTS_CFG_PATH = "..\index-tts\checkpoints\config.yaml"
uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000
```

如果使用默认的项目内 `tts-video/index-tts`，可以直接启动 IndexTTS API 服务：

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

确认 IndexTTS API 服务已经启动且 `/health` 返回 `model_loaded: true` 后，再启动主程序：

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

脚本会在后台启动 IndexTTS API 和 WebUI，不再为每个服务单独弹出窗口。如果检测到 `runtime/*.pid` 中记录的本项目旧服务仍在运行，会先停止这些旧进程再重新启动。它会等待 `http://127.0.0.1:9000/health` 返回 `model_loaded: true`，再启动 `http://127.0.0.1:8000` 并自动打开浏览器。主控制窗口会实时显示 WebUI / IndexTTS 的合并日志；运行中按 `Q` 或 `Ctrl+C` 可以安全停止服务并退出。若检测到 8000/9000 端口已被非 `runtime/*.pid` 记录的程序占用，脚本会报错并提示手动关闭或修改端口，不会自动结束未知进程。

只使用 TTS 语音工作台，不启动视频生成 WebUI：

```bat
start_tts.bat
```

该模式会读取 `runtime/tts_mode.json` 中记录的工具模式；首次使用默认启动 IndexTTS，并打开 `http://127.0.0.1:9000`。页面顶部可以在 IndexTTS 和 MiMoTTS 之间切换。切换时启动控制脚本会停止当前 TTS 服务，再启动目标工具并打开新页面。

- IndexTTS：本地模型推理，支持语速、音量、随机种子、temperature、top_p、top_k、repetition_penalty 等参数。
- MiMoTTS：调用小米 MiMo `mimo-v2.5-tts-voiceclone` 云 API 做音色克隆，打开 `http://127.0.0.1:9021`。如果后端未检测到 `MIMO_API_KEY`，页面会要求输入 API Key；保存后会写入当前系统用户环境变量，并只在后端使用，不会再返回给前端。

使用 MiMoTTS 时，文本和参考音频会发送到 MiMo API 服务；请只上传本人或已获授权的音频素材。

运行时文件位置：

- PID 文件：`runtime/webui.pid`、`runtime/indextts.pid`、`runtime/mimo_tts.pid`、`runtime/start_tts.pid`
- WebUI 日志：`logs/webui.log`、`logs/webui.err.log`
- IndexTTS 日志：`logs/indextts.log`、`logs/indextts.err.log`
- MiMoTTS 日志：`logs/mimo_tts.log`、`logs/mimo_tts.err.log`

开发调试模式：

```bat
start_debug.bat
```

该模式会打开独立的 WebUI 和 IndexTTS 控制台窗口，方便分别观察原始输出；它同样会写入 `runtime/*.pid`，可以用 `stop_all.bat` 统一停止，也可以手动关闭调试窗口。

Windows 一键关闭服务：

```bat
stop_all.bat
```

它只读取 `runtime/*.pid` 中记录的 PID，并只关闭这些 PID 对应的 tts-video / IndexTTS 进程；如果 PID 文件不存在但端口仍被占用，脚本只会提示占用 PID，不会询问或强制结束无关进程。

手动启动主程序时，默认 `indextts_api` 模式需要先启动 IndexTTS API 服务：

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

### PNG 透明背景支持

支持上传带 alpha 通道的 PNG 角色图。生成视频时，程序会先在 Pillow 中把透明区域正确合成到所选视频画布背景上，再输出无透明通道的 `processed.png` 交给 ffmpeg 编码。

需要注意：MP4 / H.264 / yuv420p 本身不会保留透明通道，因此最终视频不是透明视频，而是已经合成到背景上的普通 MP4。如果希望控制透明区域背后的颜色或观感，可以在 WebUI 的“背景样式”中选择图片模糊填充、纯白、纯红、纯蓝、渐变蓝或渐变红。

手动测试方式：

1. 上传一张透明背景 PNG 角色图。
2. 上传参考音频。
3. 输入一段文案。
4. 选择不同背景样式并生成视频。
5. 检查透明区域不应变黑，角色半透明边缘不应出现明显黑边。

### 上传文件过大

当前 MVP 没有接入对象存储和任务队列，建议使用较短测试音频和适中尺寸图片。生产环境应增加文件大小限制、异步队列和清理策略。

### 路径包含中文或空格

后端使用 `pathlib` 管理路径，并在烧录字幕时尽量使用相对字幕路径。若 Windows 下仍遇到路径问题，建议先将项目放在纯英文路径中测试。

## 声音克隆合规提醒

后续接入音色克隆功能时，只应使用本人或已获得授权的参考音频。请勿在未授权情况下克隆、模仿或传播他人声音。

## 许可证与第三方组件

本项目自身源码采用 MIT License，详见根目录 `LICENSE`。MIT License 仅覆盖本仓库中由项目作者编写的 Python、HTML、CSS、JavaScript、脚本和配置文件，不覆盖第三方模型、第三方二进制文件、Python 依赖、用户上传素材或生成内容。

更完整的第三方许可说明见 `THIRD_PARTY_NOTICES.md`。

主要许可边界如下：

- `tts-video` 自身源码：MIT License。
- IndexTTS / IndexTTS2 / checkpoints：遵循上游 bilibili Model Use License Agreement，不属于本项目 MIT 授权范围。默认 `indextts_api` 模式只是通过外部 API 调用 IndexTTS，用户需要自行遵守 IndexTTS 上游协议、模型协议和声音克隆合规要求。
- FFmpeg：Windows 预置/下载的 gyan.dev static build 按 GPLv3 授权。若发布包含 `ffmpeg.exe` / `ffprobe.exe` 的离线包，需要同时附带 GPLv3 文本、来源、版本、构建信息和对应源码链接。
- Python 依赖：遵循各自上游许可证。如果分发完整虚拟环境、wheel 或运行时包，应额外附带对应依赖的许可清单。
- 用户素材和生成视频：由用户自行负责权利来源、授权和合规使用。本项目不授予用户克隆未授权声音、使用第三方素材或制作误导性内容的权利。
