. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs

$PythonExe = Get-ProjectPython
$WebOutLog = Join-Path $script:LogDir "webui.log"
$WebErrLog = Join-Path $script:LogDir "webui.err.log"
$IndexOutLog = Join-Path $script:LogDir "indextts.log"
$IndexErrLog = Join-Path $script:LogDir "indextts.err.log"
$ControllerPidFile = Join-Path $script:RuntimeDir "start_all.pid"
$script:LogOffsets = @{}

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
        # The service can be writing at the same time. The next poll will retry.
    }
}

function Show-AllNewLogs {
    Show-NewLogLines -Path $WebOutLog -Prefix "[WebUI]"
    Show-NewLogLines -Path $WebErrLog -Prefix "[WebUI:ERR]"
    Show-NewLogLines -Path $IndexOutLog -Prefix "[IndexTTS]"
    Show-NewLogLines -Path $IndexErrLog -Prefix "[IndexTTS:ERR]"
}

function Stop-PreviousControllerIfRunning {
    $pidValue = Read-PidFile -PidFile $ControllerPidFile
    if ($null -eq $pidValue) {
        return
    }

    if ($pidValue -eq $PID) {
        return
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $ControllerPidFile -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host "[0/4] Previous start_all console detected. Closing controller PID $pidValue..."
    & taskkill.exe /PID $pidValue /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to close previous start_all controller PID $pidValue."
    }
    Remove-Item -LiteralPath $ControllerPidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Register-CurrentController {
    Set-Content -LiteralPath $ControllerPidFile -Value $PID -Encoding ASCII
}

function Clear-CurrentControllerPid {
    $pidValue = Read-PidFile -PidFile $ControllerPidFile
    if ($pidValue -eq $PID) {
        Remove-Item -LiteralPath $ControllerPidFile -Force -ErrorAction SilentlyContinue
    }
}

function Start-HiddenService {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$PidFile,
        [string]$StdoutLog,
        [string]$StderrLog,
        [scriptblock]$ConfigureEnvironment = $null
    )

    Reset-LogFile -Path $StdoutLog
    Reset-LogFile -Path $StderrLog
    Set-PythonRuntimeEnvironment
    if ($ConfigureEnvironment) {
        & $ConfigureEnvironment
    }

    $process = Start-Process `
        -FilePath $PythonExe `
        -ArgumentList $Arguments `
        -WorkingDirectory $script:ProjectRoot `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
    Write-Host "  $Name PID: $($process.Id)"
}

function Stop-TrackedServiceIfRunning {
    param([string]$Name, [string]$PidFile)

    $pidValue = Read-PidFile -PidFile $PidFile
    if ($null -eq $pidValue) {
        return $false
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Write-Host "[INFO] $Name PID $pidValue has exited. Removing stale PID file."
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "[0/4] Existing $Name detected from PID file. Stopping PID $pidValue before restart..."
    & taskkill.exe /PID $pidValue /T /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stop existing $Name PID $pidValue. Please run stop_all.bat or close it manually."
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Existing $Name stopped."
    return $true
}

function Restart-TrackedProjectServices {
    $hadWebPid = $null -ne (Read-PidFile -PidFile $script:WebPidFile)
    $hadIndexPid = $null -ne (Read-PidFile -PidFile $script:IndexPidFile)

    if (-not $hadWebPid -and -not $hadIndexPid) {
        return
    }

    Write-Host "[0/4] Runtime PID files found. start_all.bat will restart tracked project services."
    $stoppedWeb = Stop-TrackedServiceIfRunning -Name "WebUI" -PidFile $script:WebPidFile
    $stoppedIndex = Stop-TrackedServiceIfRunning -Name "IndexTTS API" -PidFile $script:IndexPidFile

    if ($stoppedWeb -or $stoppedIndex) {
        Start-Sleep -Seconds 2
    }
}

function Start-Or-ReuseIndexTts {
    Clear-StalePidFile -PidFile $script:IndexPidFile -Name "IndexTTS API"
    Assert-PortAvailableOrOwned -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile

    if (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile) {
        Write-Host "[1/4] IndexTTS API is already running from runtime/indextts.pid."
        return
    }

    Write-Host "[1/4] Starting IndexTTS API..."
    Start-HiddenService `
        -Name "IndexTTS API" `
        -Arguments @("-u", "-m", "uvicorn", "external.indextts_server:app", "--host", "127.0.0.1", "--port", "9000") `
        -PidFile $script:IndexPidFile `
        -StdoutLog $IndexOutLog `
        -StderrLog $IndexErrLog `
        -ConfigureEnvironment { Set-IndexTtsEnvironment }
}

function Start-Or-ReuseWebUI {
    Clear-StalePidFile -PidFile $script:WebPidFile -Name "WebUI"
    Assert-PortAvailableOrOwned -Name "WebUI" -Port 8000 -PidFile $script:WebPidFile

    if (Test-PortOwnedByPidFile -Port 8000 -PidFile $script:WebPidFile) {
        Write-Host "[3/4] WebUI is already running from runtime/webui.pid."
        return
    }

    Write-Host "[3/4] Starting WebUI..."
    Start-HiddenService `
        -Name "WebUI" `
        -Arguments @("-u", "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "8000") `
        -PidFile $script:WebPidFile `
        -StdoutLog $WebOutLog `
        -StderrLog $WebErrLog
}

function Watch-Console {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "tts-video console"
    Write-Host "========================================"
    Write-Host "WebUI:    $($script:WebUrl)"
    Write-Host "IndexTTS: $($script:IndexHealthUrl)"
    Write-Host "Logs:     $($script:LogDir)"
    Write-Host "Runtime:  $($script:RuntimeDir)"
    Write-Host ""
    Write-Host "Running. Press Q to stop services, or press Ctrl+C."
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
        Write-Host "Stopping services..."
        & (Join-Path $PSScriptRoot "stop_all.ps1")
        Clear-CurrentControllerPid
    }
}

try {
    Write-Host "========================================"
    Write-Host "tts-video console"
    Write-Host "========================================"
    Write-Host "Project: $script:ProjectRoot"
    Write-Host "Python:  $PythonExe"
    Write-Host "Logs:    $script:LogDir"
    Write-Host "Runtime: $script:RuntimeDir"
    Write-Host ""

    Stop-PreviousControllerIfRunning
    Register-CurrentController

    Ensure-LogFile -Path $WebOutLog
    Ensure-LogFile -Path $WebErrLog
    Ensure-LogFile -Path $IndexOutLog
    Ensure-LogFile -Path $IndexErrLog

    Restart-TrackedProjectServices

    Start-Or-ReuseIndexTts

    Write-Host "[2/4] Waiting for IndexTTS model to load..."
    Wait-Until `
        -Condition { Test-IndexReady } `
        -TimeoutSeconds 600 `
        -FailureMessage "IndexTTS API did not become ready. Check logs/indextts.err.log." `
        -OnTick { Show-AllNewLogs } | Out-Null

    Start-Or-ReuseWebUI

    Write-Host "[4/4] Waiting for WebUI..."
    Wait-Until `
        -Condition { Test-WebReady } `
        -TimeoutSeconds 120 `
        -FailureMessage "WebUI did not become ready. Check logs/webui.err.log." `
        -OnTick { Show-AllNewLogs } | Out-Null

    Write-Host "[4/4] Opening browser..."
    Start-Process $script:WebUrl

    Watch-Console
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    Write-Host "Logs:"
    Write-Host "  $WebOutLog"
    Write-Host "  $WebErrLog"
    Write-Host "  $IndexOutLog"
    Write-Host "  $IndexErrLog"
    Clear-CurrentControllerPid
    exit 1
}
