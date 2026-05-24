param(
    [string]$PythonVersion = "3.10.11",
    [string]$BuildRoot,
    [string]$DistDir,
    [string]$CacheDir,
    [string]$TempDir,
    [switch]$ReuseLocalSitePackages,
    [switch]$SkipDependencyInstall,
    [switch]$SkipZip
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BuildRoot = if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    Join-Path $ProjectRoot "release_build"
} else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildRoot)
}
$PackageName = "tts-video-windows-x64"
$PackageRoot = Join-Path $BuildRoot $PackageName
$DistDir = if ([string]::IsNullOrWhiteSpace($DistDir)) {
    Join-Path $ProjectRoot "dist"
} else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DistDir)
}
$ZipPath = Join-Path $DistDir "$PackageName-full.zip"
$ReleaseCacheDir = if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    Join-Path $ProjectRoot "data\cache\release"
} else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheDir)
}
$ReleaseTempDir = if ([string]::IsNullOrWhiteSpace($TempDir)) {
    Join-Path $ReleaseCacheDir "temp"
} else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TempDir)
}
$PythonTag = ($PythonVersion -replace "^(\d+)\.(\d+).*$", '$1$2')
$PythonEmbedZip = Join-Path $ReleaseCacheDir "python-$PythonVersion-embed-amd64.zip"
$PythonEmbedUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$GetPipPath = Join-Path $ReleaseCacheDir "get-pip.py"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"
$FfmpegZipPath = Join-Path $ReleaseCacheDir "ffmpeg-release-essentials.zip"
$FfmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
$LocalSitePackages = Join-Path $ProjectRoot ".venv310\Lib\site-packages"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $ProjectRoot
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "命令执行失败：$FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-RobocopyChecked {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExtraArgs = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $args = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:2", "/W:1") + $ExtraArgs
    & robocopy.exe @args | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "复制失败：$Source -> $Destination"
    }
}

function Assert-SafeGeneratedPath {
    param([string]$Path)

    $fullPath = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    $allowedRoots = @($ProjectRoot, $BuildRoot, $ReleaseCacheDir, $ReleaseTempDir) |
        ForEach-Object {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_).TrimEnd("\")
        }

    $isAllowed = $false
    foreach ($root in $allowedRoots) {
        if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($fullPath.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $isAllowed = $true
            break
        }
    }

    if (-not $isAllowed) {
        throw "拒绝删除非构建产物目录：$fullPath"
    }
}

function Remove-GeneratedDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Assert-SafeGeneratedPath -Path $Path
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Download-IfMissing {
    param([string]$Url, [string]$OutputPath)

    if (Test-Path -LiteralPath $OutputPath) {
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    Write-Host "下载：$Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath
}

function Initialize-BuildEnvironment {
    Write-Step "设置构建临时目录"

    New-Item -ItemType Directory -Force -Path $BuildRoot, $DistDir, $ReleaseCacheDir, $ReleaseTempDir | Out-Null
    $pipCache = Join-Path $ReleaseCacheDir "pip_cache"
    New-Item -ItemType Directory -Force -Path $pipCache | Out-Null

    $env:TEMP = $ReleaseTempDir
    $env:TMP = $ReleaseTempDir
    $env:PIP_CACHE_DIR = $pipCache

    Write-Host "TEMP/TMP:      $ReleaseTempDir"
    Write-Host "PIP_CACHE_DIR: $pipCache"
}

function Assert-RequiredSourceFiles {
    Write-Step "检查源码、模型和本地资源"

    $required = @(
        "app.py",
        "configs\default.yaml",
        "external\indextts_server.py",
        "modules",
        "static",
        "requirements.txt",
        "requirements-indextts.txt",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "index-tts\indextts",
        "index-tts\checkpoints\config.yaml",
        "index-tts\checkpoints\gpt.pth",
        "index-tts\checkpoints\s2mel.pth",
        "index-tts\checkpoints\qwen0.6bemo4-merge\model.safetensors",
        "index-tts\checkpoints\hf_cache"
    )

    $missing = @()
    foreach ($item in $required) {
        $path = Join-Path $ProjectRoot $item
        if (-not (Test-Path -LiteralPath $path)) {
            $missing += $item
        }
    }

    if ($missing.Count -gt 0) {
        throw "Release 打包前置资源不完整。请先运行 install.bat 完成 IndexTTS 和模型准备。缺少：`n$($missing -join "`n")"
    }

    Write-Ok "源码与模型关键文件存在"
}

function Initialize-PackageRoot {
    Write-Step "创建干净的 release_build 目录"

    Remove-GeneratedDirectory -Path $PackageRoot
    New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
}

function Copy-ProjectSource {
    Write-Step "复制 tts-video 源码到 Release 目录"

    foreach ($file in @(
        "app.py",
        "requirements.txt",
        "requirements-indextts.txt",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md"
    )) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $file) -Destination (Join-Path $PackageRoot $file) -Force
    }

    foreach ($dir in @("configs", "external", "modules", "static")) {
        Invoke-RobocopyChecked `
            -Source (Join-Path $ProjectRoot $dir) `
            -Destination (Join-Path $PackageRoot $dir) `
            -ExtraArgs @("/XD", "__pycache__", ".pytest_cache")
    }

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $PackageRoot "data\uploads"),
        (Join-Path $PackageRoot "data\outputs"),
        (Join-Path $PackageRoot "data\cache"),
        (Join-Path $PackageRoot "data\voices"),
        (Join-Path $PackageRoot "data\indextts_server\outputs"),
        (Join-Path $PackageRoot "logs"),
        (Join-Path $PackageRoot "runtime") | Out-Null

    Write-Ok "源码复制完成，运行时数据目录为空"
}

function Copy-ReleaseScripts {
    Write-Step "复制 Release 专用启动脚本"

    $releaseScriptsSource = Join-Path $ProjectRoot "scripts\release"
    $releaseScriptsDest = Join-Path $PackageRoot "scripts\release"
    Invoke-RobocopyChecked -Source $releaseScriptsSource -Destination $releaseScriptsDest

    Copy-Item -LiteralPath (Join-Path $releaseScriptsSource "start.bat") -Destination (Join-Path $PackageRoot "start.bat") -Force
    Copy-Item -LiteralPath (Join-Path $releaseScriptsSource "stop.bat") -Destination (Join-Path $PackageRoot "stop.bat") -Force
    Copy-Item -LiteralPath (Join-Path $releaseScriptsSource "README_小白使用说明.txt") -Destination (Join-Path $PackageRoot "README_小白使用说明.txt") -Force

    Write-Ok "Release 启动脚本复制完成"
}

function Copy-IndexTTS {
    Write-Step "复制 index-tts 代码与 checkpoints"

    Invoke-RobocopyChecked `
        -Source (Join-Path $ProjectRoot "index-tts") `
        -Destination (Join-Path $PackageRoot "index-tts") `
        -ExtraArgs @(
            "/XD",
            ".git",
            ".github",
            "__pycache__",
            ".pytest_cache",
            "outputs",
            "runs",
            "logs"
        )

    Write-Ok "index-tts 已复制"
}

function Ensure-FfmpegSource {
    $sourceBin = Join-Path $ProjectRoot "third_party\ffmpeg\windows\bin"
    $ffmpeg = Join-Path $sourceBin "ffmpeg.exe"
    $ffprobe = Join-Path $sourceBin "ffprobe.exe"
    if ((Test-Path -LiteralPath $ffmpeg) -and (Test-Path -LiteralPath $ffprobe)) {
        return $sourceBin
    }

    Write-Host "项目内未找到 ffmpeg.exe / ffprobe.exe，开始下载 gyan.dev release essentials。"
    Download-IfMissing -Url $FfmpegUrl -OutputPath $FfmpegZipPath

    $extractDir = Join-Path $ReleaseCacheDir "ffmpeg_extract"
    Remove-GeneratedDirectory -Path $extractDir
    Expand-Archive -LiteralPath $FfmpegZipPath -DestinationPath $extractDir -Force

    New-Item -ItemType Directory -Force -Path $sourceBin | Out-Null
    $downloadedFfmpeg = Get-ChildItem -Path $extractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    $downloadedFfprobe = Get-ChildItem -Path $extractDir -Recurse -Filter "ffprobe.exe" | Select-Object -First 1
    if (-not $downloadedFfmpeg -or -not $downloadedFfprobe) {
        throw "下载的 ffmpeg 压缩包中没有找到 ffmpeg.exe / ffprobe.exe"
    }

    Copy-Item -LiteralPath $downloadedFfmpeg.FullName -Destination $ffmpeg -Force
    Copy-Item -LiteralPath $downloadedFfprobe.FullName -Destination $ffprobe -Force
    return $sourceBin
}

function Copy-FfmpegRuntime {
    Write-Step "复制 ffmpeg 到 runtime\ffmpeg"

    $sourceBin = Ensure-FfmpegSource
    $destBin = Join-Path $PackageRoot "runtime\ffmpeg\bin"
    New-Item -ItemType Directory -Force -Path $destBin | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceBin "ffmpeg.exe") -Destination (Join-Path $destBin "ffmpeg.exe") -Force
    Copy-Item -LiteralPath (Join-Path $sourceBin "ffprobe.exe") -Destination (Join-Path $destBin "ffprobe.exe") -Force

    Write-Ok "ffmpeg 已写入 Release runtime"
}

function Write-EmbedPth {
    param([string]$Directory, [string[]]$Lines)

    $pth = Join-Path $Directory "python$PythonTag._pth"
    Set-Content -LiteralPath $pth -Value ($Lines -join "`r`n") -Encoding ASCII
}

function Initialize-PortablePython {
    Write-Step "创建便携 Python $PythonVersion"

    $runtimePython = Join-Path $PackageRoot "runtime\python"
    New-Item -ItemType Directory -Force -Path $runtimePython | Out-Null

    Download-IfMissing -Url $PythonEmbedUrl -OutputPath $PythonEmbedZip
    Expand-Archive -LiteralPath $PythonEmbedZip -DestinationPath $runtimePython -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $runtimePython "Lib\site-packages") | Out-Null
    Write-EmbedPth -Directory $runtimePython -Lines @(
        "python$PythonTag.zip",
        ".",
        "Lib\site-packages",
        "import site"
    )

    Download-IfMissing -Url $GetPipUrl -OutputPath $GetPipPath
    Invoke-Checked -FilePath (Join-Path $runtimePython "python.exe") -Arguments @($GetPipPath)

    Write-Ok "便携 Python 与 pip 准备完成"
}

function Install-PortableDependencies {
    if ($SkipDependencyInstall) {
        Write-Host "跳过依赖安装：使用 -SkipDependencyInstall。"
        return
    }

    if ($ReuseLocalSitePackages) {
        Copy-LocalSitePackagesDependencies
        return
    }

    Write-Step "在 Release 便携 Python 中安装依赖"

    $python = Join-Path $PackageRoot "runtime\python\python.exe"
    $env:PYTHONUNBUFFERED = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

    Invoke-Checked -FilePath $python -Arguments @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
    Invoke-Checked -FilePath $python -Arguments @("-m", "pip", "install", "-r", (Join-Path $PackageRoot "requirements.txt"))
    Invoke-Checked -FilePath $python -Arguments @("-m", "pip", "install", "-r", (Join-Path $PackageRoot "requirements-indextts.txt"))
    Invoke-Checked -FilePath $python -Arguments @("-m", "pip", "check")

    Write-Ok "Release Python 依赖安装完成"
}

function Copy-LocalSitePackagesDependencies {
    Write-Step "从本地 .venv310 复制已安装依赖"

    if (-not (Test-Path -LiteralPath $LocalSitePackages)) {
        throw "未找到本地依赖目录：$LocalSitePackages。请先运行 install.bat，或去掉 -ReuseLocalSitePackages 让脚本联网安装。"
    }

    $python = Join-Path $ProjectRoot ".venv310\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) {
        throw "未找到 .venv310 Python：$python"
    }

    Invoke-Checked -FilePath $python -Arguments @("-c", "import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 10) else 1)")
    Invoke-Checked -FilePath $python -Arguments @("-c", "import fastapi, uvicorn, torch, torchaudio, transformers, PIL, pydub, requests; print('local venv imports ok')")

    $targetSitePackages = Join-Path $PackageRoot "runtime\python\Lib\site-packages"
    New-Item -ItemType Directory -Force -Path $targetSitePackages | Out-Null
    Invoke-RobocopyChecked `
        -Source $LocalSitePackages `
        -Destination $targetSitePackages `
        -ExtraArgs @(
            "/XD",
            "__pycache__",
            ".pytest_cache"
        )

    Write-Ok "已复制本地 site-packages；没有复制整个 .venv310，因此不会携带 venv 的绝对路径启动脚本"
}

function New-PythonShim {
    Write-Step "创建 runtime\venv\Scripts\python.exe 便携入口"

    $runtimePython = Join-Path $PackageRoot "runtime\python"
    $scriptsDir = Join-Path $PackageRoot "runtime\venv\Scripts"
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

    foreach ($pattern in @("python.exe", "pythonw.exe", "python$PythonTag.dll", "python3.dll", "vcruntime*.dll")) {
        Get-ChildItem -LiteralPath $runtimePython -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $scriptsDir $_.Name) -Force
        }
    }

    Write-EmbedPth -Directory $scriptsDir -Lines @(
        "..\..\python\python$PythonTag.zip",
        "..\..\python",
        "..\..\python\Lib\site-packages",
        "import site"
    )

    Set-Content -LiteralPath (Join-Path $PackageRoot "runtime\venv\pyvenv.cfg") -Encoding UTF8 -Value @"
home = ..\python
include-system-site-packages = false
version = $PythonVersion
note = This is a relocatable shim for the bundled embeddable Python runtime.
"@

    Write-Ok "便携 python.exe 入口已创建"
}

function Copy-LicenseFiles {
    Write-Step "整理许可证与第三方说明"

    $licensesDir = Join-Path $PackageRoot "LICENSES"
    New-Item -ItemType Directory -Force -Path $licensesDir | Out-Null

    Copy-Item -LiteralPath (Join-Path $PackageRoot "LICENSE") -Destination (Join-Path $licensesDir "tts-video-MIT-LICENSE.txt") -Force

    $pythonLicense = Join-Path $PackageRoot "runtime\python\LICENSE.txt"
    if (Test-Path -LiteralPath $pythonLicense) {
        Copy-Item -LiteralPath $pythonLicense -Destination (Join-Path $licensesDir "PYTHON-LICENSE.txt") -Force
    }

    $ffmpegLicense = Join-Path $ProjectRoot "third_party\ffmpeg\windows\licenses\LICENSE"
    $ffmpegSource = Join-Path $ProjectRoot "third_party\ffmpeg\windows\SOURCE.txt"
    $ffmpegReadme = Join-Path $ProjectRoot "third_party\ffmpeg\windows\README.txt"
    if (Test-Path -LiteralPath $ffmpegLicense) {
        Copy-Item -LiteralPath $ffmpegLicense -Destination (Join-Path $licensesDir "FFMPEG-GPLv3-LICENSE.txt") -Force
    }
    if (Test-Path -LiteralPath $ffmpegSource) {
        Copy-Item -LiteralPath $ffmpegSource -Destination (Join-Path $licensesDir "FFMPEG-SOURCE.txt") -Force
    }
    if (Test-Path -LiteralPath $ffmpegReadme) {
        Copy-Item -LiteralPath $ffmpegReadme -Destination (Join-Path $licensesDir "FFMPEG-README.txt") -Force
    }

    foreach ($candidate in @(
        "index-tts\LICENSE",
        "index-tts\LICENSE.txt",
        "index-tts\checkpoints\LICENSE.txt",
        "index-tts\checkpoints\LICENSE_ZH.txt"
    )) {
        $source = Join-Path $PackageRoot $candidate
        if (Test-Path -LiteralPath $source) {
            $safeName = ($candidate -replace "[\\/]", "-")
            Copy-Item -LiteralPath $source -Destination (Join-Path $licensesDir $safeName) -Force
        }
    }

    if (Test-Path -LiteralPath (Join-Path $ProjectRoot "LICENSES\README.md")) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "LICENSES\README.md") -Destination (Join-Path $licensesDir "README.md") -Force
    }

    Write-Ok "许可证文件整理完成"
}

function Clear-GeneratedPythonCaches {
    param([string]$Root)

    Get-ChildItem -LiteralPath $Root -Force -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "__pycache__" -or $_.Name -eq ".pytest_cache" } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

    Get-ChildItem -LiteralPath $Root -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
}

function Assert-NoForbiddenReleaseContent {
    Write-Step "检查 Release 包中不应包含的开发文件"

    $forbidden = @(
        ".git",
        ".github",
        ".venv310",
        ".venv",
        "data\uploads\*",
        "data\outputs\*",
        "data\cache\*",
        "logs\*",
        "runtime\webui.pid",
        "runtime\indextts.pid"
    )

    $bad = @()
    $allItems = Get-ChildItem -LiteralPath $PackageRoot -Force -Recurse -ErrorAction SilentlyContinue
    foreach ($item in $allItems) {
        $relative = $item.FullName.Substring($PackageRoot.Length).TrimStart("\")
        foreach ($pattern in $forbidden) {
            if ($relative -like $pattern) {
                $bad += $item.FullName
            }
        }
        if ($item.Name -in @("__pycache__", ".pytest_cache")) {
            $bad += $item.FullName
        }
    }

    if ($bad.Count -gt 0) {
        throw "Release 包包含不应出现的开发/运行时文件：`n$($bad -join "`n")"
    }

    Write-Ok "未发现禁止内容"
}

function Test-ReleaseRuntime {
    param([string]$Root)

    $python = Join-Path $Root "runtime\venv\Scripts\python.exe"
    $ffmpeg = Join-Path $Root "runtime\ffmpeg\bin\ffmpeg.exe"
    $ffprobe = Join-Path $Root "runtime\ffmpeg\bin\ffprobe.exe"

    $requiredPaths = @(
        $python,
        $ffmpeg,
        $ffprobe,
        (Join-Path $Root "app.py"),
        (Join-Path $Root "configs"),
        (Join-Path $Root "external"),
        (Join-Path $Root "modules"),
        (Join-Path $Root "static"),
        (Join-Path $Root "index-tts\checkpoints\config.yaml"),
        (Join-Path $Root "index-tts\checkpoints\gpt.pth"),
        (Join-Path $Root "index-tts\checkpoints\s2mel.pth"),
        (Join-Path $Root "index-tts\checkpoints\qwen0.6bemo4-merge\model.safetensors"),
        (Join-Path $Root "index-tts\checkpoints\hf_cache")
    )

    $missing = @()
    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            $missing += $path
        }
    }
    if ($missing.Count -gt 0) {
        throw "Release 可移动性验证失败，缺少文件：`n$($missing -join "`n")"
    }

    $oldPath = $env:PATH
    try {
        $env:PATH = "$(Join-Path $Root "runtime\ffmpeg\bin");$(Join-Path $Root "runtime\python");$oldPath"
        Invoke-Checked -FilePath $python -Arguments @("-c", "import fastapi, uvicorn, torch, torchaudio, transformers, PIL, pydub, requests; print('release imports ok')")
        Invoke-Checked -FilePath $python -Arguments @("-c", "from pathlib import Path; import sys; root=Path.cwd(); raise SystemExit(0 if Path('app.py').exists() and Path('index-tts/checkpoints/config.yaml').exists() else 1)") -WorkingDirectory $Root
    }
    finally {
        $env:PATH = $oldPath
    }
}

function Test-MovablePackage {
    Write-Step "执行可移动性验证"

    $checkRoot = Join-Path $BuildRoot "_portable_check"
    $checkPackage = Join-Path $checkRoot $PackageName
    Remove-GeneratedDirectory -Path $checkRoot
    New-Item -ItemType Directory -Force -Path $checkRoot | Out-Null

    Invoke-RobocopyChecked -Source $PackageRoot -Destination $checkPackage
    try {
        Test-ReleaseRuntime -Root $checkPackage
        Write-Ok "移动目录后的 runtime\venv\Scripts\python.exe 可正常导入关键依赖"
        Clear-GeneratedPythonCaches -Root $checkPackage
        Remove-GeneratedDirectory -Path $checkRoot
    }
    catch {
        Write-Host "[ERROR] 可移动性验证失败，临时目录保留用于排查：$checkPackage" -ForegroundColor Red
        throw
    }
}

function Compress-ReleaseZip {
    if ($SkipZip) {
        Write-Host "跳过压缩：使用 -SkipZip。"
        return
    }

    Write-Step "生成 zip 文件"

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        # Windows PowerShell Compress-Archive 对 2GB+ 单文件容易失败。
        # bsdtar 的 zip writer 支持 Zip64，更适合包含 gpt.pth / torch wheel 这类大文件的离线包。
        Invoke-Checked -FilePath $tar.Source -Arguments @("-a", "-c", "-f", $ZipPath, "-C", $BuildRoot, $PackageName)
    }
    else {
        Compress-Archive -LiteralPath $PackageRoot -DestinationPath $ZipPath -CompressionLevel Optimal
    }

    Write-Ok "zip 已生成：$ZipPath"
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    Write-Host "tts-video Windows x64 Release 打包"
    Write-Host "项目目录：$ProjectRoot"
    Write-Host "构建目录：$BuildRoot"
    Write-Host "输出目录：$DistDir"
    Write-Host "缓存目录：$ReleaseCacheDir"
    Write-Host "临时目录：$ReleaseTempDir"
    Write-Host "Python：$PythonVersion embeddable x64"

    Initialize-BuildEnvironment
    Assert-RequiredSourceFiles
    Initialize-PackageRoot
    Copy-ProjectSource
    Copy-ReleaseScripts
    Copy-IndexTTS
    Copy-FfmpegRuntime
    Initialize-PortablePython
    Install-PortableDependencies
    New-PythonShim
    Copy-LicenseFiles
    Clear-GeneratedPythonCaches -Root $PackageRoot
    Assert-NoForbiddenReleaseContent
    Test-ReleaseRuntime -Root $PackageRoot
    Test-MovablePackage
    Clear-GeneratedPythonCaches -Root $PackageRoot
    Assert-NoForbiddenReleaseContent
    Compress-ReleaseZip

    Write-Host ""
    Write-Host "Release 打包完成：" -ForegroundColor Green
    Write-Host "  目录：$PackageRoot"
    if (-not $SkipZip) {
        Write-Host "  ZIP： $ZipPath"
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}



