$ErrorActionPreference = "Stop"

$script:ReleaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:RuntimeDir = Join-Path $script:ReleaseRoot "runtime"
$script:WebPidFile = Join-Path $script:RuntimeDir "webui.pid"
$script:IndexPidFile = Join-Path $script:RuntimeDir "indextts.pid"

function Initialize-Console {
    try { chcp.com 65001 | Out-Null } catch {}
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
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

function Stop-PidFileProcess {
    param([string]$Name, [string]$PidFile)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        Write-Host "[INFO] 没有找到 $Name 的 PID 文件。"
        return $false
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name 进程 $pidValue 已退出，正在清理失效 PID 文件。"
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "正在停止 $Name PID $pidValue..."
    & taskkill.exe /PID $pidValue /T /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] 停止 $Name PID $pidValue 失败。"
        return $false
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] $Name 已停止。"
    return $true
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

try {
    Initialize-Console
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir | Out-Null

    Write-Host "========================================"
    Write-Host "tts-video Release 停止服务"
    Write-Host "========================================"
    Write-Host "只停止 runtime/*.pid 中记录的本项目进程，不会按端口强杀未知程序。"
    Write-Host ""

    $hadPid = (Test-Path -LiteralPath $script:WebPidFile) -or (Test-Path -LiteralPath $script:IndexPidFile)
    Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile | Out-Null
    Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile | Out-Null

    if (-not $hadPid) {
        Write-Host ""
        Write-Host "[INFO] 没有找到正在运行的本项目服务。"
    }

    foreach ($port in @(8000, 9000)) {
        $owners = Get-PortOwnerPids -Port $port
        if ($owners -and $owners.Count -gt 0) {
            Write-Host "[INFO] 端口 $port 仍被 PID $($owners -join ', ') 占用。它们不是当前 PID 文件记录的进程，本脚本不会停止。"
        }
    }

    Write-Host ""
    Write-Host "完成。"
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}

