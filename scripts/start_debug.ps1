. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs

function Start-DebugWindow {
    param(
        [string]$Name,
        [string]$Service,
        [string]$PidFile
    )

    $runner = Join-Path $PSScriptRoot "run_service_debug.ps1"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$runner`" -Service $Service"
    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $arguments `
        -WorkingDirectory $script:ProjectRoot `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
    Write-Host "  $Name window PID: $($process.Id)"
}

try {
    Write-Host "========================================"
    Write-Host "tts-video debug startup"
    Write-Host "========================================"
    Write-Host "Project: $script:ProjectRoot"
    Write-Host "Logs:    $script:LogDir"
    Write-Host "Runtime: $script:RuntimeDir"
    Write-Host ""

    Clear-StalePidFile -PidFile $script:IndexPidFile -Name "IndexTTS API"
    Clear-StalePidFile -PidFile $script:WebPidFile -Name "WebUI"

    Assert-PortAvailableOrOwned -Name "IndexTTS API" -Port 9000 -PidFile $script:IndexPidFile
    if (-not (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile)) {
        Write-Host "[1/5] Starting IndexTTS API debug window..."
        Start-DebugWindow -Name "IndexTTS API" -Service "indextts" -PidFile $script:IndexPidFile
    }
    else {
        Write-Host "[1/5] IndexTTS API is already running from runtime/indextts.pid."
    }

    Write-Host "[2/5] Waiting for IndexTTS model to load..."
    Wait-Until `
        -Condition { Test-IndexReady } `
        -TimeoutSeconds 600 `
        -FailureMessage "IndexTTS API did not become ready. Check the IndexTTS debug window or logs/indextts.log." | Out-Null

    Assert-PortAvailableOrOwned -Name "WebUI" -Port 8000 -PidFile $script:WebPidFile
    if (-not (Test-PortOwnedByPidFile -Port 8000 -PidFile $script:WebPidFile)) {
        Write-Host "[3/5] Starting WebUI debug window..."
        Start-DebugWindow -Name "WebUI" -Service "webui" -PidFile $script:WebPidFile
    }
    else {
        Write-Host "[3/5] WebUI is already running from runtime/webui.pid."
    }

    Write-Host "[4/5] Waiting for WebUI..."
    Wait-Until `
        -Condition { Test-WebReady } `
        -TimeoutSeconds 120 `
        -FailureMessage "WebUI did not become ready. Check the WebUI debug window or logs/webui.log." | Out-Null

    Write-Host "[5/5] Opening browser..."
    Start-Process $script:WebUrl
    Write-Host ""
    Write-Host "Debug mode is ready."
    Write-Host "Use stop_all.bat to stop both debug windows from their runtime PID files."
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
