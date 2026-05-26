$ErrorActionPreference = "Stop"

$script:ReleaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:RuntimeDir = Join-Path $script:ReleaseRoot "runtime"
$script:LogDir = Join-Path $script:ReleaseRoot "logs"
$script:WebPidFile = Join-Path $script:RuntimeDir "webui.pid"
$script:IndexPidFile = Join-Path $script:RuntimeDir "indextts.pid"
$script:ControllerPidFile = Join-Path $script:RuntimeDir "start_tts.pid"
$script:StartAllControllerPidFile = Join-Path $script:RuntimeDir "start.pid"
$script:PythonExe = Join-Path $script:RuntimeDir "venv\Scripts\python.exe"
$script:FfmpegBinDir = Join-Path $script:RuntimeDir "ffmpeg\bin"
$script:TtsWebUrl = "http://127.0.0.1:9000/"
$script:IndexHealthUrl = "http://127.0.0.1:9000/health"
$script:StartLogPath = Join-Path $script:LogDir "start_tts_release.log"
$script:IndexOutLog = Join-Path $script:LogDir "indextts.log"
$script:IndexErrLog = Join-Path $script:LogDir "indextts.err.log"
$script:LogOffsets = @{}

function Initialize-Console {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}

function Initialize-ReleaseDirs {
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir, $script:LogDir | Out-Null
}

function Write-StartLog {
    param([string]$Message)
    Add-Content -LiteralPath $script:StartLogPath -Encoding UTF8 -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Assert-ReleaseRuntime {
    $required = @(
        $script:PythonExe,
        (Join-Path $script:FfmpegBinDir "ffmpeg.exe"),
        (Join-Path $script:FfmpegBinDir "ffprobe.exe"),
        (Join-Path $script:ReleaseRoot "external\indextts_server.py"),
        (Join-Path $script:ReleaseRoot "static\indextts.html"),
        (Join-Path $script:ReleaseRoot "index-tts\checkpoints\config.yaml")
    )

    $missing = @()
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            $missing += $path
        }
    }
    if ($missing.Count -gt 0) {
        throw "Release runtime is incomplete. Missing: $($missing -join '; ')"
    }
}

function Set-ReleaseEnvironment {
    $env:PYTHONUNBUFFERED = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $env:PATH = "$script:FfmpegBinDir;$script:RuntimeDir\python;$env:PATH"
    $env:INDEXTTS_REPO = Join-Path $script:ReleaseRoot "index-tts"
    $env:INDEXTTS_MODEL_DIR = Join-Path $script:ReleaseRoot "index-tts\checkpoints"
    $env:INDEXTTS_CFG_PATH = Join-Path $script:ReleaseRoot "index-tts\checkpoints\config.yaml"
    $env:INDEXTTS_VERSION = "v2"
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
    throw "$Name port $Port is already used by PID(s): $($owners -join ', ')."
}

function Stop-PidFileProcess {
    param([string]$Name, [string]$PidFile)
    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return $false
    }
    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Host "[INFO] Stopping $Name PID $pidValue..."
    & taskkill.exe /PID $pidValue /T /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stop $Name PID $pidValue."
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    return $true
}

function Clear-StalePidFile {
    param([string]$PidFile)
    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -ne $pidValue -and -not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-ControllerIfRunning {
    param([string]$Name, [string]$PidFile)
    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue -or $pidValue -eq $PID) {
        return
    }
    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return
    }
    Write-Host "[0/4] Closing previous $Name controller PID $pidValue..."
    & taskkill.exe /PID $pidValue /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to close previous $Name controller PID $pidValue."
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
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
            if ([string]::IsNullOrWhiteSpace($line) -or $line -like '*"GET /health*') {
                continue
            }
            Write-Host "$Prefix $line"
        }
    }
    catch {}
}

function Show-AllNewLogs {
    Show-NewLogLines -Path $script:IndexOutLog -Prefix "[IndexTTS]"
    Show-NewLogLines -Path $script:IndexErrLog -Prefix "[IndexTTS:ERR]"
}

function Start-HiddenIndexTts {
    Reset-LogFile -Path $script:IndexOutLog
    Reset-LogFile -Path $script:IndexErrLog
    $process = Start-Process `
        -FilePath $script:PythonExe `
        -ArgumentList @("-u", "-m", "uvicorn", "external.indextts_server:app", "--host", "127.0.0.1", "--port", "9000") `
        -WorkingDirectory $script:ReleaseRoot `
        -RedirectStandardOutput $script:IndexOutLog `
        -RedirectStandardError $script:IndexErrLog `
        -WindowStyle Hidden `
        -PassThru
    Set-Content -LiteralPath $script:IndexPidFile -Value $process.Id -Encoding ASCII
    Write-Host "  IndexTTS API PID: $($process.Id)"
}

function Test-IndexWebReady {
    try {
        $response = Invoke-WebRequest -Uri $script:TtsWebUrl -UseBasicParsing -TimeoutSec 3
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
        [string]$FailureMessage,
        [scriptblock]$OnTick = $null
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }
        if ($OnTick) {
            & $OnTick
        }
        Start-Sleep -Seconds 2
    }
    throw $FailureMessage
}

function Watch-Console {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "IndexTTS standalone console"
    Write-Host "========================================"
    Write-Host "WebUI:    $script:TtsWebUrl"
    Write-Host "Health:   $script:IndexHealthUrl"
    Write-Host "Logs:     $script:LogDir"
    Write-Host "Running. Press Q to stop IndexTTS, or press Ctrl+C."
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
        Write-Host "Stopping IndexTTS..."
        Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile | Out-Null
        Clear-CurrentControllerPid
    }
}

try {
    Initialize-Console
    Initialize-ReleaseDirs
    Write-StartLog "start_tts_release.ps1 entered. root=$script:ReleaseRoot"
    Assert-ReleaseRuntime
    Set-ReleaseEnvironment

    Write-Host "========================================"
    Write-Host "IndexTTS Release standalone startup"
    Write-Host "========================================"
    Write-Host "Directory: $script:ReleaseRoot"
    Write-Host "Python:    $script:PythonExe"
    Write-Host "FFmpeg:    $script:FfmpegBinDir"
    Write-Host "Logs:      $script:LogDir"
    Write-Host ""

    Stop-ControllerIfRunning -Name "start_tts" -PidFile $script:ControllerPidFile
    Stop-ControllerIfRunning -Name "start" -PidFile $script:StartAllControllerPidFile
    Register-CurrentController

    Clear-StalePidFile -PidFile $script:IndexPidFile
    Clear-StalePidFile -PidFile $script:WebPidFile
    Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile | Out-Null

    Assert-PortAvailable -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile

    if (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile) {
        Write-Host "[1/4] IndexTTS API is already running from runtime/indextts.pid."
    }
    else {
        Write-Host "[1/4] Starting IndexTTS API with standalone WebUI..."
        Start-HiddenIndexTts
    }

    Write-Host "[2/4] Waiting for IndexTTS WebUI..."
    Wait-Until `
        -Condition { Test-IndexWebReady } `
        -TimeoutSeconds 600 `
        -FailureMessage "IndexTTS WebUI did not become ready. Check logs\indextts.err.log." `
        -OnTick { Show-AllNewLogs } | Out-Null

    Write-Host "[3/4] Opening browser..."
    Start-Process $script:TtsWebUrl
    Write-Host "[4/4] Ready."
    Write-StartLog "startup completed"

    Watch-Console
    exit 0
}
catch {
    Write-StartLog "ERROR: $($_.Exception.Message)"
    Write-Host "[ERROR] $($_.Exception.Message)"
    Write-Host ""
    Write-Host "If startup failed, check:"
    Write-Host "  logs\indextts.err.log"
    Write-Host "  logs\start_tts_release.log"
    Clear-CurrentControllerPid
    exit 1
}
