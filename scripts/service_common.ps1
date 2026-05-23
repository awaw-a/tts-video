$ErrorActionPreference = "Stop"

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:RuntimeDir = Join-Path $script:ProjectRoot "runtime"
$script:LogDir = Join-Path $script:ProjectRoot "logs"
$script:WebPidFile = Join-Path $script:RuntimeDir "webui.pid"
$script:IndexPidFile = Join-Path $script:RuntimeDir "indextts.pid"
$script:WebUrl = "http://127.0.0.1:8000"
$script:IndexHealthUrl = "http://127.0.0.1:9000/health"

function Initialize-ServiceDirs {
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir, $script:LogDir | Out-Null
}

function Get-ProjectPython {
    $candidates = @(
        (Join-Path $script:ProjectRoot ".venv310\Scripts\python.exe"),
        (Join-Path $script:ProjectRoot ".venv\Scripts\python.exe"),
        "python"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -eq "python") {
            $command = Get-Command python -ErrorAction SilentlyContinue
            if ($command) {
                return $command.Source
            }
        }
        elseif (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Python was not found. Please install dependencies or create .venv310 first."
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

function Clear-StalePidFile {
    param([string]$PidFile, [string]$Name)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name PID $pidValue has exited. Removing stale PID file."
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
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

function Assert-PortAvailableOrOwned {
    param([string]$Name, [int]$Port, [string]$PidFile)

    $owners = Get-PortOwnerPids -Port $Port
    if (-not $owners -or $owners.Count -eq 0) {
        return
    }

    if (Test-PortOwnedByPidFile -Port $Port -PidFile $PidFile) {
        return
    }

    $ownerText = ($owners -join ", ")
    throw "$Name port $Port is already used by PID(s): $ownerText. This script will not kill unrelated processes. Please close that program or change the port."
}

function Set-IndexTtsEnvironment {
    $env:INDEXTTS_REPO = Join-Path $script:ProjectRoot "index-tts"
    $env:INDEXTTS_MODEL_DIR = Join-Path $script:ProjectRoot "index-tts\checkpoints"
    $env:INDEXTTS_CFG_PATH = Join-Path $script:ProjectRoot "index-tts\checkpoints\config.yaml"
    $env:INDEXTTS_VERSION = "auto"
    $env:INDEXTTS_USE_FP16 = "true"
    $env:INDEXTTS_USE_CUDA_KERNEL = "false"
    $env:INDEXTTS_USE_DEEPSPEED = "false"
    $env:HF_HUB_CACHE = Join-Path $script:ProjectRoot "index-tts\checkpoints\hf_cache"
    $env:HF_HUB_OFFLINE = "1"
    $env:TRANSFORMERS_OFFLINE = "1"
}

function Set-PythonRuntimeEnvironment {
    $env:PYTHONUNBUFFERED = "1"
    $env:PYTHONIOENCODING = "utf-8"
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

function Stop-PidFileProcess {
    param([string]$Name, [string]$PidFile)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        Write-Host "[INFO] No PID file for $Name."
        return $false
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name process $pidValue has already exited. Removing stale PID file."
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "Stopping $Name PID $pidValue ..."
    & taskkill.exe /PID $pidValue /T /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Failed to stop $Name PID $pidValue."
        return $false
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Stopped $Name."
    return $true
}
