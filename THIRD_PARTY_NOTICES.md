# Third Party Notices

本文件说明 `tts-video` 项目中涉及的第三方组件、模型和二进制文件的许可边界。

这不是法律意见；如果要做商业发行、离线整包分发或面向大量用户提供服务，建议再由专业法律顾问复核。

## tts-video

- 许可：MIT License
- 适用范围：本仓库中由项目作者编写的源码、脚本、配置和静态前端文件。
- 许可文件：`LICENSE`

MIT License 不自动覆盖下列第三方组件、模型文件、用户上传素材或生成内容。

## IndexTTS / IndexTTS2

- 上游仓库：https://github.com/index-tts/index-tts
- 许可：bilibili Model Use License Agreement
- 适用范围：IndexTTS 代码、IndexTTS2 模型、checkpoints、模型权重以及基于模型形成的相关衍生使用。

注意事项：

- IndexTTS 不是本项目 MIT License 的一部分。
- 本项目默认通过外部 API 调用 IndexTTS，建议用户按上游仓库说明单独安装和使用。
- 如果分发 IndexTTS、模型 checkpoints 或其衍生作品，需要保留上游版权声明、许可协议和免责声明。
- 上游协议包含额外使用限制，例如超大规模商业使用需单独授权、不得用于违法或高风险场景、不得滥用声音克隆能力等。
- 使用参考音频时，只应使用本人或已获得授权的声音素材。

本仓库通过 `.gitignore` 排除了 `index-tts/`，避免把外部仓库和大型模型文件纳入 `tts-video` 的 MIT 源码仓库。

## FFmpeg

- 上游项目：https://ffmpeg.org/
- 当前 Windows 构建来源：https://www.gyan.dev/ffmpeg/builds/
- 本项目记录文件：`third_party/ffmpeg/windows/SOURCE.txt`
- 当前 Windows 构建许可：GPLv3
- GPLv3 文本：`third_party/ffmpeg/windows/licenses/LICENSE`

注意事项：

- FFmpeg 不是本项目 MIT License 的一部分。
- 本项目通过命令行调用 FFmpeg 来生成视频、读取音频信息和烧录字幕。
- 如果只发布源码仓库，且不包含 FFmpeg 二进制文件，应在安装说明中引导用户自行安装或下载 FFmpeg。
- 如果发布包含 `ffmpeg.exe` / `ffprobe.exe` 的 Windows 离线包，需要同时附带 GPLv3 文本、来源、版本、构建信息和对应源码链接。
- 当前仓库通过 `.gitignore` 排除了 `third_party/ffmpeg/windows/bin/*.exe`，安装脚本会按需下载二进制文件。

## Python 依赖

`requirements.txt` 和 `requirements-indextts.txt` 中的 Python 包分别遵循其上游许可证。

如果将依赖包、wheel、虚拟环境或完整运行时一起分发，应额外生成并附带对应的第三方依赖许可清单。

## Windows Release 聚合包

如果使用 `scripts/build_release_windows.bat` / `scripts/build_release_windows.ps1` 生成
`dist/tts-video-windows-x64-full.zip`，该 zip 是面向 Windows x64 用户的一键聚合包，通常会包含：

- tts-video 本项目源码。
- 便携 Python 3.10 运行时。
- 已安装的 Python 依赖，包括 PyTorch、Torchaudio、Transformers 等。
- FFmpeg / FFprobe Windows 二进制文件。
- IndexTTS 上游代码。
- IndexTTS checkpoints 和 Hugging Face 缓存模型文件。

该 Release 包只是为了降低安装门槛而做的聚合分发，不表示整个 zip 都只受 MIT License 约束。
本项目源码许可证只覆盖 tts-video 自身代码；Python、FFmpeg、IndexTTS、PyTorch、Transformers、
模型文件和其他依赖仍然遵循各自上游许可证、模型协议和使用限制。

分发完整离线包时，应至少保留：

- 根目录 `LICENSE`
- 根目录 `THIRD_PARTY_NOTICES.md`
- Release 包内 `LICENSES/` 目录
- FFmpeg GPLv3 文本、来源和构建说明
- Python 运行时许可证
- IndexTTS / checkpoints 附带的许可文件

用户和分发者需要自行确认自己的使用场景是否符合第三方许可证和模型协议。

## 用户素材与生成内容

用户上传的图片、参考音频、文案，以及生成的视频文件不属于本项目 MIT License 授权范围。

使用者需要自行确保：

- 对上传图片、音频和文案拥有合法权利或授权。
- 不使用未授权声音进行克隆、冒充、诈骗、误导或其他违法违规用途。
- 生成内容符合所在地法律法规、平台规则和第三方权利要求。
