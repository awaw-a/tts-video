. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs

$PythonExe = Get-ProjectPython
$IndexOutLog = Join-Path $script:LogDir "indextts.log"
$IndexErrLog = Join-Path $script:LogDir "indextts.err.log"
$ControllerPidFile = Join-Path $script:RuntimeDir "start_tts.pid"
$StartAllControllerPidFile = Join-Path $script:RuntimeDir "start_all.pid"
$script:LogOffsets = @{}
$script:TtsWebUrl = "http://127.0.0.1:9000/"

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
            if ($line -like '*"GET /health*') {
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
    Show-NewLogLines -Path $IndexOutLog -Prefix "[IndexTTS]"
    Show-NewLogLines -Path $IndexErrLog -Prefix "[IndexTTS:ERR]"
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

    Write-Host "[0/4] Previous $Name console detected. Closing controller PID $pidValue..."
    & taskkill.exe /PID $pidValue /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to close previous $Name controller PID $pidValue."
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
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

function Stop-TrackedWebUIIfRunning {
    $pidValue = Read-PidFile -PidFile $script:WebPidFile
    if ($null -eq $pidValue) {
        return
    }

    if (-not (Test-ProcessAlive -PidValue $pidValue)) {
        Remove-Item -LiteralPath $script:WebPidFile -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host "[1/4] Stopping tracked WebUI because this mode only runs IndexTTS..."
    Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile | Out-Null
}

function Start-Or-ReuseIndexTts {
    Clear-StalePidFile -PidFile $script:IndexPidFile -Name "IndexTTS API"
    Assert-PortAvailableOrOwned -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile

    if (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile) {
        Write-Host "[2/4] IndexTTS API is already running from runtime/indextts.pid."
        return
    }

    Write-Host "[2/4] Starting IndexTTS API with standalone WebUI..."
    Reset-LogFile -Path $IndexOutLog
    Reset-LogFile -Path $IndexErrLog
    Set-PythonRuntimeEnvironment
    Set-IndexTtsEnvironment

    $process = Start-Process `
        -FilePath $PythonExe `
        -ArgumentList @("-u", "-m", "uvicorn", "external.indextts_server:app", "--host", "127.0.0.1", "--port", "9000") `
        -WorkingDirectory $script:ProjectRoot `
        -RedirectStandardOutput $IndexOutLog `
        -RedirectStandardError $IndexErrLog `
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

function Watch-Console {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "IndexTTS standalone console"
    Write-Host "========================================"
    Write-Host "WebUI:    $script:TtsWebUrl"
    Write-Host "Health:   $($script:IndexHealthUrl)"
    Write-Host "Logs:     $($script:LogDir)"
    Write-Host "Runtime:  $($script:RuntimeDir)"
    Write-Host ""
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
    Write-Host "========================================"
    Write-Host "IndexTTS standalone startup"
    Write-Host "========================================"
    Write-Host "Project: $script:ProjectRoot"
    Write-Host "Python:  $PythonExe"
    Write-Host "Logs:    $script:LogDir"
    Write-Host "Runtime: $script:RuntimeDir"
    Write-Host ""

    Stop-ControllerIfRunning -Name "start_tts" -PidFile $ControllerPidFile
    Stop-ControllerIfRunning -Name "start_all" -PidFile $StartAllControllerPidFile
    Register-CurrentController

    Ensure-LogFile -Path $IndexOutLog
    Ensure-LogFile -Path $IndexErrLog

    Stop-TrackedWebUIIfRunning
    Start-Or-ReuseIndexTts

    Write-Host "[3/4] Waiting for IndexTTS WebUI..."
    Wait-Until `
        -Condition { Test-IndexWebReady } `
        -TimeoutSeconds 600 `
        -FailureMessage "IndexTTS WebUI did not become ready. Check logs/indextts.err.log." `
        -OnTick { Show-AllNewLogs } | Out-Null

    Write-Host "[4/4] Opening browser..."
    Start-Process $script:TtsWebUrl

    Watch-Console
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    Write-Host "Logs:"
    Write-Host "  $IndexOutLog"
    Write-Host "  $IndexErrLog"
    Clear-CurrentControllerPid
    exit 1
}
