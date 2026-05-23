param(
    [switch]$SkipModels
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot

$PythonPath = Join-Path $ProjectRoot ".venv310\Scripts\python.exe"
$PipPath = Join-Path $ProjectRoot ".venv310\Scripts\pip.exe"
$HfPath = Join-Path $ProjectRoot ".venv310\Scripts\hf.exe"
$FfmpegBinDir = Join-Path $ProjectRoot "third_party\ffmpeg\windows\bin"
$IndexTTSRepo = Join-Path $ProjectRoot "index-tts"
$IndexTTSCheckpoints = Join-Path $IndexTTSRepo "checkpoints"
$IndexTTSCache = Join-Path $IndexTTSCheckpoints "hf_cache"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

function Test-Python310 {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments -c "import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 10) else 1)" *> $null
    return $LASTEXITCODE -eq 0
}

function Ensure-Venv310 {
    if (Test-Path $PythonPath) {
        Write-Host ".venv310 already exists."
        return
    }

    Write-Step "Creating .venv310"

    if (Test-Command "py" -and (Test-Python310 "py" @("-3.10"))) {
        Invoke-Checked "py" @("-3.10", "-m", "venv", ".venv310")
        return
    }

    if (Test-Command "python" -and (Test-Python310 "python")) {
        Invoke-Checked "python" @("-m", "venv", ".venv310")
        return
    }

    if (Test-Command "uv") {
        Invoke-Checked "uv" @("python", "install", "3.10")
        Invoke-Checked "uv" @("venv", ".venv310", "--python", "3.10")
        return
    }

    throw "Python 3.10 was not found. Please install Python 3.10, or install uv, then run install.bat again."
}

function Install-PythonRequirements {
    Write-Step "Installing Python requirements"
    Invoke-Checked $PythonPath @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
    Invoke-Checked $PythonPath @("-m", "pip", "install", "-r", "requirements.txt")
    Invoke-Checked $PythonPath @("-m", "pip", "install", "-r", "requirements-indextts.txt")
    Invoke-Checked $PythonPath @("-m", "pip", "check")
}

function Install-Ffmpeg {
    Write-Step "Checking ffmpeg"

    $ffmpeg = Join-Path $FfmpegBinDir "ffmpeg.exe"
    $ffprobe = Join-Path $FfmpegBinDir "ffprobe.exe"
    if ((Test-Path $ffmpeg) -and (Test-Path $ffprobe)) {
        Write-Host "ffmpeg already exists in third_party."
        return
    }

    New-Item -ItemType Directory -Force -Path $FfmpegBinDir | Out-Null

    $cacheDir = Join-Path $ProjectRoot "data\cache\install"
    $zipPath = Join-Path $cacheDir "ffmpeg-release-essentials.zip"
    $extractDir = Join-Path $cacheDir "ffmpeg_extract"
    $url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    if (-not (Test-Path $zipPath)) {
        Write-Host "Downloading ffmpeg from $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath
    }

    if (Test-Path $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $downloadedFfmpeg = Get-ChildItem -Path $extractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    $downloadedFfprobe = Get-ChildItem -Path $extractDir -Recurse -Filter "ffprobe.exe" | Select-Object -First 1
    if (-not $downloadedFfmpeg -or -not $downloadedFfprobe) {
        throw "Downloaded ffmpeg archive did not contain ffmpeg.exe and ffprobe.exe."
    }

    Copy-Item -LiteralPath $downloadedFfmpeg.FullName -Destination $ffmpeg -Force
    Copy-Item -LiteralPath $downloadedFfprobe.FullName -Destination $ffprobe -Force
    Write-Host "ffmpeg installed to third_party\ffmpeg\windows\bin"
}

function Ensure-IndexTTSRepo {
    Write-Step "Checking IndexTTS repository"

    if (Test-Path (Join-Path $IndexTTSRepo "indextts")) {
        Write-Host "index-tts already exists."
        return
    }

    if (-not (Test-Command "git")) {
        throw "git was not found. Please install Git, then run install.bat again."
    }

    Invoke-Checked "git" @("clone", "https://github.com/index-tts/index-tts.git", "index-tts")
}

function Patch-IndexTTSCachePath {
    Write-Step "Patching IndexTTS local cache path"

    $inferV2 = Join-Path $IndexTTSRepo "indextts\infer_v2.py"
    if (-not (Test-Path $inferV2)) {
        Write-Host "infer_v2.py was not found; skipping patch."
        return
    }

    $text = Get-Content -LiteralPath $inferV2 -Raw -Encoding UTF8
    $old = "os.environ['HF_HUB_CACHE'] = './checkpoints/hf_cache'"
    if (-not $text.Contains($old)) {
        Write-Host "IndexTTS cache path patch is already applied or not needed."
        return
    }

    $new = @'
# 默认把 IndexTTS 运行时依赖模型缓存到仓库自己的 checkpoints/hf_cache。
# 如果外部服务或用户已经设置 HF_HUB_CACHE，则尊重外部配置。
_DEFAULT_HF_CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "checkpoints", "hf_cache")
)
os.environ.setdefault("HF_HUB_CACHE", _DEFAULT_HF_CACHE)
'@

    $text = $text.Replace($old, $new.TrimEnd())
    Set-Content -LiteralPath $inferV2 -Value $text -Encoding UTF8
    Write-Host "Patched index-tts\indextts\infer_v2.py"
}

function Download-IndexTTSModels {
    if ($SkipModels) {
        Write-Host "Skipping model downloads because --SkipModels was provided."
        return
    }

    Write-Step "Downloading IndexTTS model files"

    New-Item -ItemType Directory -Force -Path $IndexTTSCheckpoints | Out-Null
    New-Item -ItemType Directory -Force -Path $IndexTTSCache | Out-Null

    $env:HF_HUB_CACHE = $IndexTTSCache
    Remove-Item Env:HF_HUB_OFFLINE -ErrorAction SilentlyContinue
    Remove-Item Env:TRANSFORMERS_OFFLINE -ErrorAction SilentlyContinue

    if (-not (Test-Path $HfPath)) {
        throw "hf CLI was not found. requirements-indextts.txt may not have installed correctly."
    }

    $mainReady =
        (Test-Path (Join-Path $IndexTTSCheckpoints "config.yaml")) -and
        (Test-Path (Join-Path $IndexTTSCheckpoints "gpt.pth")) -and
        (Test-Path (Join-Path $IndexTTSCheckpoints "s2mel.pth")) -and
        (Test-Path (Join-Path $IndexTTSCheckpoints "qwen0.6bemo4-merge\model.safetensors"))

    if ($mainReady) {
        Write-Host "IndexTTS-2 main checkpoints already exist."
    } else {
        Invoke-Checked $HfPath @("download", "IndexTeam/IndexTTS-2", "--local-dir", $IndexTTSCheckpoints, "--max-workers", "4")
    }

    Invoke-Checked $HfPath @("download", "facebook/w2v-bert-2.0", "--max-workers", "4")
    Invoke-Checked $HfPath @("download", "amphion/MaskGCT", "semantic_codec/model.safetensors", "--max-workers", "2")
    Invoke-Checked $HfPath @("download", "funasr/campplus", "campplus_cn_common.bin", "--max-workers", "2")
    Invoke-Checked $HfPath @("download", "nvidia/bigvgan_v2_22khz_80band_256x", "--max-workers", "4")
}

function Verify-Install {
    Write-Step "Verifying installation"

    Invoke-Checked $PythonPath @("-c", "import fastapi, uvicorn, requests, torch, torchaudio, transformers, huggingface_hub; print('Python dependencies OK')")
    Invoke-Checked $PythonPath @("-c", "from pathlib import Path; missing=[p for p in ['third_party/ffmpeg/windows/bin/ffmpeg.exe','third_party/ffmpeg/windows/bin/ffprobe.exe','index-tts/indextts'] if not Path(p).exists()]; raise SystemExit('Missing: '+', '.join(missing) if missing else 0)")

    if (-not $SkipModels) {
        Invoke-Checked $PythonPath @("-c", "from pathlib import Path; missing=[p for p in ['index-tts/checkpoints/config.yaml','index-tts/checkpoints/gpt.pth','index-tts/checkpoints/s2mel.pth','index-tts/checkpoints/qwen0.6bemo4-merge/model.safetensors'] if not Path(p).exists()]; raise SystemExit('Missing model files: '+', '.join(missing) if missing else 0)")
    }
}

Write-Host "tts-video Windows installer"
Write-Host "Project: $ProjectRoot"

Ensure-Venv310
Install-PythonRequirements
Install-Ffmpeg
Ensure-IndexTTSRepo
Patch-IndexTTSCachePath
Download-IndexTTSModels
Verify-Install

Write-Host ""
Write-Host "Install complete. Run start_all.bat to start the project." -ForegroundColor Green
