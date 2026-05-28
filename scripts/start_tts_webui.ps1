. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs

$PythonExe = Get-ProjectPython
$MimoPidFile = Join-Path $script:RuntimeDir "mimo_tts.pid"
$ControllerPidFile = Join-Path $script:RuntimeDir "start_tts.pid"
$StartAllControllerPidFile = Join-Path $script:RuntimeDir "start_all.pid"
$ModeFile = Join-Path $script:RuntimeDir "tts_mode.json"
$SwitchRequestFile = Join-Path $script:RuntimeDir "tts_switch_request.json"
$IndexOutLog = Join-Path $script:LogDir "indextts.log"
$IndexErrLog = Join-Path $script:LogDir "indextts.err.log"
$MimoOutLog = Join-Path $script:LogDir "mimo_tts.log"
$MimoErrLog = Join-Path $script:LogDir "mimo_tts.err.log"
$script:LogOffsets = @{}
$script:CurrentMode = $null

function Get-ToolUrl {
    param([string]$Mode)
    if ($Mode -eq "mimo") {
        return "http://127.0.0.1:9021/"
    }
    return "http://127.0.0.1:9000/"
}

function Normalize-ToolMode {
    param([string]$Mode)
    $clean = ""
    if ($null -ne $Mode) {
        $clean = $Mode.Trim().ToLowerInvariant()
    }
    if ($clean -in @("indextts", "mimo")) {
        return $clean
    }
    return "indextts"
}

function Read-ToolMode {
    if (-not (Test-Path -LiteralPath $ModeFile)) {
        return "indextts"
    }
    try {
        $payload = Get-Content -LiteralPath $ModeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return Normalize-ToolMode -Mode $payload.mode
    }
    catch {
        return "indextts"
    }
}

function Write-ToolMode {
    param([string]$Mode)
    $clean = Normalize-ToolMode -Mode $Mode
    $payload = [ordered]@{
        mode = $clean
        url = Get-ToolUrl -Mode $clean
        updated_at = (Get-Date).ToString("s")
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $ModeFile -Encoding UTF8
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
            if ($line -like '*"GET /health*' -or $line -like '*"GET /api/mimo/status*') {
                continue
            }
            Write-Host "$Prefix $line"
        }
    }
    catch {
        # The service can be writing at the same time. The next poll will retry.
    }
}

function Show-CurrentLogs {
    if ($script:CurrentMode -eq "mimo") {
        Show-NewLogLines -Path $MimoOutLog -Prefix "[MiMoTTS]"
        Show-NewLogLines -Path $MimoErrLog -Prefix "[MiMoTTS:ERR]"
    }
    else {
        Show-NewLogLines -Path $IndexOutLog -Prefix "[IndexTTS]"
        Show-NewLogLines -Path $IndexErrLog -Prefix "[IndexTTS:ERR]"
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
    Write-Host "[INFO] Stopping tracked video WebUI because TTS tool mode does not use it..."
    Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile | Out-Null
}

function Stop-ModeService {
    param([string]$Mode)
    $clean = Normalize-ToolMode -Mode $Mode
    if ($clean -eq "mimo") {
        Stop-PidFileProcess -Name "MiMoTTS" -PidFile $MimoPidFile | Out-Null
    }
    else {
        Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile | Out-Null
    }
}

function Stop-AllTtsServices {
    Stop-PidFileProcess -Name "MiMoTTS" -PidFile $MimoPidFile | Out-Null
    Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile | Out-Null
}

function Start-IndexTts {
    Clear-StalePidFile -PidFile $script:IndexPidFile -Name "IndexTTS API"
    Assert-PortAvailableOrOwned -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile

    if (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile) {
        Write-Host "  IndexTTS API is already running from runtime/indextts.pid."
        return
    }

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

function Start-MimoTts {
    Clear-StalePidFile -PidFile $MimoPidFile -Name "MiMoTTS"
    Assert-PortAvailableOrOwned -Name "MiMoTTS" -Port 9021 -PidFile $MimoPidFile

    if (Test-PortOwnedByPidFile -Port 9021 -PidFile $MimoPidFile) {
        Write-Host "  MiMoTTS is already running from runtime/mimo_tts.pid."
        return
    }

    Reset-LogFile -Path $MimoOutLog
    Reset-LogFile -Path $MimoErrLog
    Set-PythonRuntimeEnvironment

    $process = Start-Process `
        -FilePath $PythonExe `
        -ArgumentList @("-u", "-m", "uvicorn", "external.mimo_tts_server:app", "--host", "127.0.0.1", "--port", "9021") `
        -WorkingDirectory $script:ProjectRoot `
        -RedirectStandardOutput $MimoOutLog `
        -RedirectStandardError $MimoErrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -LiteralPath $MimoPidFile -Value $process.Id -Encoding ASCII
    Write-Host "  MiMoTTS PID: $($process.Id)"
}

function Test-ToolReady {
    param([string]$Mode)
    try {
        $response = Invoke-WebRequest -Uri (Get-ToolUrl -Mode $Mode) -UseBasicParsing -TimeoutSec 3
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Start-ModeService {
    param([string]$Mode)
    $clean = Normalize-ToolMode -Mode $Mode
    $script:CurrentMode = $clean
    Write-ToolMode -Mode $clean

    if ($clean -eq "mimo") {
        Write-Host "[2/4] Starting MiMoTTS standalone WebUI..."
        Start-MimoTts
    }
    else {
        Write-Host "[2/4] Starting IndexTTS standalone WebUI..."
        Start-IndexTts
    }

    Write-Host "[3/4] Waiting for $clean WebUI..."
    Wait-Until `
        -Condition { Test-ToolReady -Mode $clean } `
        -TimeoutSeconds 600 `
        -FailureMessage "$clean WebUI did not become ready. Check logs directory." `
        -OnTick { Show-CurrentLogs } | Out-Null
}

function Read-SwitchRequest {
    if (-not (Test-Path -LiteralPath $SwitchRequestFile)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $SwitchRequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Remove-Item -LiteralPath $SwitchRequestFile -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Handle-SwitchRequest {
    $request = Read-SwitchRequest
    if ($null -eq $request) {
        return
    }

    Remove-Item -LiteralPath $SwitchRequestFile -Force -ErrorAction SilentlyContinue
    $target = Normalize-ToolMode -Mode $request.target_mode
    if ($target -eq $script:CurrentMode) {
        return
    }

    Write-Host ""
    Write-Host "[SWITCH] Switching TTS tool from $script:CurrentMode to $target ..."
    Start-Sleep -Seconds 2
    Stop-ModeService -Mode $script:CurrentMode
    Start-ModeService -Mode $target
    Write-Host "[SWITCH] Opening $target WebUI..."
    Start-Process (Get-ToolUrl -Mode $target)
}

function Watch-Console {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "TTS tool console"
    Write-Host "========================================"
    Write-Host "Mode:     $script:CurrentMode"
    Write-Host "WebUI:    $(Get-ToolUrl -Mode $script:CurrentMode)"
    Write-Host "Logs:     $($script:LogDir)"
    Write-Host "Runtime:  $($script:RuntimeDir)"
    Write-Host ""
    Write-Host "Running. Press Q to stop TTS tools, or press Ctrl+C."
    Write-Host "========================================"
    Write-Host ""

    $oldMode = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try {
        while ($true) {
            Show-CurrentLogs
            Handle-SwitchRequest
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
        Write-Host "Stopping TTS tools..."
        Stop-AllTtsServices
        Clear-CurrentControllerPid
    }
}

try {
    Write-Host "========================================"
    Write-Host "TTS tool startup"
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
    Ensure-LogFile -Path $MimoOutLog
    Ensure-LogFile -Path $MimoErrLog
    Remove-Item -LiteralPath $SwitchRequestFile -Force -ErrorAction SilentlyContinue

    Stop-TrackedWebUIIfRunning
    $mode = Read-ToolMode
    Start-ModeService -Mode $mode

    Write-Host "[4/4] Opening browser..."
    Start-Process (Get-ToolUrl -Mode $script:CurrentMode)

    Watch-Console
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    Write-Host "Logs:"
    Write-Host "  $IndexOutLog"
    Write-Host "  $IndexErrLog"
    Write-Host "  $MimoOutLog"
    Write-Host "  $MimoErrLog"
    Clear-CurrentControllerPid
    exit 1
}
