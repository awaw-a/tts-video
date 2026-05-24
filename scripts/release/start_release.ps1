$ErrorActionPreference = "Stop"

$script:ReleaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:RuntimeDir = Join-Path $script:ReleaseRoot "runtime"
$script:LogDir = Join-Path $script:ReleaseRoot "logs"
$script:WebPidFile = Join-Path $script:RuntimeDir "webui.pid"
$script:IndexPidFile = Join-Path $script:RuntimeDir "indextts.pid"
$script:ControllerPidFile = Join-Path $script:RuntimeDir "start.pid"
$script:PythonExe = Join-Path $script:RuntimeDir "venv\Scripts\python.exe"
$script:RuntimePythonDir = Join-Path $script:RuntimeDir "python"
$script:FfmpegBinDir = Join-Path $script:RuntimeDir "ffmpeg\bin"
$script:WebUrl = "http://127.0.0.1:8000"
$script:IndexHealthUrl = "http://127.0.0.1:9000/health"
$script:LogOffsets = @{}
$script:StartLogPath = Join-Path $script:LogDir "start_release.log"

function Initialize-Console {
    try { chcp.com 65001 | Out-Null } catch {}
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}

function Initialize-ReleaseDirs {
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir, $script:LogDir | Out-Null
    foreach ($path in @(
        "data\uploads",
        "data\outputs",
        "data\cache",
        "data\voices",
        "data\indextts_server\outputs"
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:ReleaseRoot $path) | Out-Null
    }
}

function Write-StartLog {
    param([string]$Message)

    try {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        Add-Content -LiteralPath $script:StartLogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
    }
    catch {
        # 启动早期日志不能影响主流程。
    }
}

function Assert-ReleaseRuntime {
    $missing = @()
    foreach ($path in @(
        $script:PythonExe,
        (Join-Path $script:FfmpegBinDir "ffmpeg.exe"),
        (Join-Path $script:FfmpegBinDir "ffprobe.exe"),
        (Join-Path $script:ReleaseRoot "app.py"),
        (Join-Path $script:ReleaseRoot "external\indextts_server.py"),
        (Join-Path $script:ReleaseRoot "index-tts\checkpoints\config.yaml")
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            $missing += $path
        }
    }

    if ($missing.Count -gt 0) {
        throw "Release 包不完整，缺少文件：`n$($missing -join "`n")"
    }
}

function Set-ReleaseEnvironment {
    $env:PYTHONUNBUFFERED = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $env:PATH = "$script:FfmpegBinDir;$script:RuntimePythonDir;$env:PATH"

    $env:INDEXTTS_REPO = Join-Path $script:ReleaseRoot "index-tts"
    $env:INDEXTTS_MODEL_DIR = Join-Path $script:ReleaseRoot "index-tts\checkpoints"
    $env:INDEXTTS_CFG_PATH = Join-Path $script:ReleaseRoot "index-tts\checkpoints\config.yaml"
    $env:INDEXTTS_VERSION = "auto"
    $env:INDEXTTS_USE_FP16 = "true"
    $env:INDEXTTS_USE_CUDA_KERNEL = "false"
    $env:INDEXTTS_USE_DEEPSPEED = "false"
    $env:HF_HUB_CACHE = Join-Path $script:ReleaseRoot "index-tts\checkpoints\hf_cache"
    $env:HF_HUB_OFFLINE = "1"
    $env:TRANSFORMERS_OFFLINE = "1"
}

function Read-PidFile {
    param([string]$PidFile)

    if (-not (Test-Path -LiteralPath $PidFile)) {
        return $null
    }

    $text = (Get-Content -LiteralPath $PidFile -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
    $pidValue = 0
    if (-not [int]::TryParse($text, [ref]$pidValue)) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    return $pidValue
}

function Test-ProcessAlive {
    param([int]$PidValue)
    return $null -ne (Get-Process -Id $PidValue -ErrorAction SilentlyContinue)
}

function Get-PortOwnerPids {
    param([int]$Port)

    $owners = @()
    try {
        $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        $owners += $connections | Select-Object -ExpandProperty OwningProcess
    }
    catch {
        $lines = & netstat.exe -ano 2>$null | Select-String -Pattern ":$Port\s+.*LISTENING"
        foreach ($line in $lines) {
            $parts = ($line.ToString().Trim() -split "\s+")
            if ($parts.Length -ge 5) {
                $owners += [int]$parts[-1]
            }
        }
    }

    return $owners | Sort-Object -Unique
}

function Test-PortOwnedByPidFile {
    param([int]$Port, [string]$PidFile)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return $false
    }

    $owners = Get-PortOwnerPids -Port $Port
    return $owners -contains $pidValue
}

function Assert-PortAvailable {
    param([string]$Name, [int]$Port, [string]$PidFile)

    $owners = Get-PortOwnerPids -Port $Port
    if (-not $owners -or $owners.Count -eq 0) {
        return
    }

    if (Test-PortOwnedByPidFile -Port $Port -PidFile $PidFile) {
        return
    }

    throw "$Name 端口 $Port 已被其他程序占用，PID：$($owners -join ', ')。脚本不会结束未知进程，请手动关闭占用程序后重试。"
}

function Stop-PidFileProcess {
    param([string]$Name, [string]$PidFile)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return $false
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name PID $pidValue 已退出，清理 PID 文件。"
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "[INFO] 停止旧的 $Name PID $pidValue..."
    & taskkill.exe /PID $pidValue /T /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "无法停止旧的 $Name PID $pidValue，请手动关闭后重试。"
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    return $true
}

function Clear-StalePidFile {
    param([string]$PidFile, [string]$Name)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name PID $pidValue 已退出，清理旧 PID 文件。"
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-PreviousControllerIfRunning {
    $pidValue = Read-PidFile -PidFile $script:ControllerPidFile
    if ($null -eq $pidValue -or $pidValue -eq $PID) {
        return
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $script:ControllerPidFile -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host "[0/4] 检测到旧的启动控制台，正在关闭 PID $pidValue..."
    & taskkill.exe /PID $pidValue /F | Out-Null
    Remove-Item -LiteralPath $script:ControllerPidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Register-CurrentController {
    Set-Content -LiteralPath $script:ControllerPidFile -Value $PID -Encoding ASCII
}

function Clear-CurrentControllerPid {
    $pidValue = Read-PidFile -PidFile $script:ControllerPidFile
    if ($pidValue -eq $PID) {
        Remove-Item -LiteralPath $script:ControllerPidFile -Force -ErrorAction SilentlyContinue
    }
}

function Restart-TrackedServices {
    $hasWeb = $null -ne (Read-PidFile -PidFile $script:WebPidFile)
    $hasIndex = $null -ne (Read-PidFile -PidFile $script:IndexPidFile)
    if (-not $hasWeb -and -not $hasIndex) {
        return
    }

    Write-Host "[0/4] 检测到本项目旧服务，先安全停止再重新启动。"
    $stoppedWeb = Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile
    $stoppedIndex = Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile
    if ($stoppedWeb -or $stoppedIndex) {
        Start-Sleep -Seconds 2
    }
}

function Ensure-LogFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
    if (-not $script:LogOffsets.ContainsKey($Path)) {
        $script:LogOffsets[$Path] = (Get-Item -LiteralPath $Path).Length
    }
}

function Reset-LogFile {
    param([string]$Path)
    Ensure-LogFile -Path $Path
    Clear-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    $script:LogOffsets[$Path] = 0L
}

function Show-NewLogLines {
    param([string]$Path, [string]$Prefix)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if (-not $script:LogOffsets.ContainsKey($Path)) {
                $script:LogOffsets[$Path] = 0L
            }
            if ($script:LogOffsets[$Path] -gt $stream.Length) {
                $script:LogOffsets[$Path] = 0L
            }

            $stream.Seek([int64]$script:LogOffsets[$Path], [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            $text = $reader.ReadToEnd()
            $script:LogOffsets[$Path] = $stream.Position
        }
        finally {
            $stream.Close()
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            return
        }

        $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
        foreach ($line in ($text -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line -like '*"GET /health*' -or $line -like '*"GET /api/health*') {
                continue
            }
            Write-Host "$Prefix $line"
        }
    }
    catch {
        # 服务可能正在写日志，下一轮继续读取。
    }
}

function Show-AllNewLogs {
    Show-NewLogLines -Path (Join-Path $script:LogDir "webui.log") -Prefix "[WebUI]"
    Show-NewLogLines -Path (Join-Path $script:LogDir "webui.err.log") -Prefix "[WebUI:ERR]"
    Show-NewLogLines -Path (Join-Path $script:LogDir "indextts.log") -Prefix "[IndexTTS]"
    Show-NewLogLines -Path (Join-Path $script:LogDir "indextts.err.log") -Prefix "[IndexTTS:ERR]"
}

function Start-HiddenService {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$PidFile,
        [string]$StdoutLog,
        [string]$StderrLog
    )

    Reset-LogFile -Path $StdoutLog
    Reset-LogFile -Path $StderrLog

    $process = Start-Process `
        -FilePath $script:PythonExe `
        -ArgumentList $Arguments `
        -WorkingDirectory $script:ReleaseRoot `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
    Write-Host "  $Name PID: $($process.Id)"
}

function Test-IndexReady {
    try {
        $response = Invoke-RestMethod -Uri $script:IndexHealthUrl -TimeoutSec 3
        return ($response.model_loaded -eq $true)
    }
    catch {
        return $false
    }
}

function Test-WebReady {
    try {
        $response = Invoke-WebRequest -Uri "$($script:WebUrl)/" -UseBasicParsing -TimeoutSec 3
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds,
        [string]$FailureMessage
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }
        Show-AllNewLogs
        Start-Sleep -Seconds 2
    }

    throw $FailureMessage
}

function Watch-Console {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "tts-video 控制台"
    Write-Host "========================================"
    Write-Host "WebUI:    $($script:WebUrl)"
    Write-Host "IndexTTS: $($script:IndexHealthUrl)"
    Write-Host "日志目录: $($script:LogDir)"
    Write-Host "运行中，按 Q 停止服务，或按 Ctrl+C 退出。"
    Write-Host "========================================"
    Write-Host ""

    $oldMode = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try {
        while ($true) {
            Show-AllNewLogs
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Q) {
                    break
                }
                if ($key.Key -eq [ConsoleKey]::C -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
                    break
                }
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $oldMode
        Write-Host ""
        Write-Host "正在停止服务..."
        & (Join-Path $PSScriptRoot "stop_release.ps1")
        Clear-CurrentControllerPid
    }
}

try {
    Initialize-Console
    Set-Location $script:ReleaseRoot
    Initialize-ReleaseDirs
    Write-StartLog "start_release.ps1 entered. root=$script:ReleaseRoot"
    Assert-ReleaseRuntime
    Set-ReleaseEnvironment
    Write-StartLog "runtime checked. python=$script:PythonExe ffmpeg=$script:FfmpegBinDir"

    Write-Host "========================================"
    Write-Host "tts-video Release 一键启动"
    Write-Host "========================================"
    Write-Host "目录:   $script:ReleaseRoot"
    Write-Host "Python: $script:PythonExe"
    Write-Host "FFmpeg: $script:FfmpegBinDir"
    Write-Host "日志:   $script:LogDir"
    Write-Host ""

    Stop-PreviousControllerIfRunning
    Register-CurrentController

    Clear-StalePidFile -PidFile $script:IndexPidFile -Name "IndexTTS API"
    Clear-StalePidFile -PidFile $script:WebPidFile -Name "WebUI"
    Restart-TrackedServices

    Assert-PortAvailable -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile
    Assert-PortAvailable -Name "WebUI" -Port 8000 -PidFile $script:WebPidFile

    Write-Host "[1/4] 启动 IndexTTS API..."
    Start-HiddenService `
        -Name "IndexTTS API" `
        -Arguments @("-u", "-m", "uvicorn", "external.indextts_server:app", "--host", "127.0.0.1", "--port", "9000") `
        -PidFile $script:IndexPidFile `
        -StdoutLog (Join-Path $script:LogDir "indextts.log") `
        -StderrLog (Join-Path $script:LogDir "indextts.err.log")

    Write-Host "[2/4] IndexTTS 正在后台加载模型..."
    Write-Host "      WebUI 会先启动；模型加载完成前请先不要点击生成。"
    Write-StartLog "IndexTTS process started; WebUI will start while model is loading."

    Write-Host "[3/4] 启动 WebUI..."
    Start-HiddenService `
        -Name "WebUI" `
        -Arguments @("-u", "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "8000") `
        -PidFile $script:WebPidFile `
        -StdoutLog (Join-Path $script:LogDir "webui.log") `
        -StderrLog (Join-Path $script:LogDir "webui.err.log")

    Write-Host "[4/4] 等待 WebUI..."
    Wait-Until `
        -Condition { Test-WebReady } `
        -TimeoutSeconds 120 `
        -FailureMessage "WebUI 启动超时，请查看 logs\webui.err.log 和 logs\webui.log。" | Out-Null

    Write-Host "[4/4] 打开浏览器..."
    Start-Process $script:WebUrl
    Write-StartLog "startup completed"

    Watch-Console
    exit 0
}
catch {
    Write-StartLog "ERROR: $($_.Exception.Message)"
    Write-Host "[ERROR] $($_.Exception.Message)"
    Write-Host ""
    Write-Host "如果启动失败，请优先查看："
    Write-Host "  logs\indextts.err.log"
    Write-Host "  logs\webui.err.log"
    Clear-CurrentControllerPid
    exit 1
}



