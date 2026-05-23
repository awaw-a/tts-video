param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("indextts", "webui")]
    [string]$Service
)

. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs
Set-PythonRuntimeEnvironment

$python = Get-ProjectPython

if ($Service -eq "indextts") {
    Set-IndexTtsEnvironment
    $logPath = Join-Path $script:LogDir "indextts.log"
    New-Item -ItemType File -Force -Path (Join-Path $script:LogDir "indextts.err.log") | Out-Null
    Write-Host "Starting IndexTTS API Server..."
    Write-Host "Log: $logPath"
    & $python -u -m uvicorn external.indextts_server:app --host 127.0.0.1 --port 9000 2>&1 |
        Tee-Object -FilePath $logPath -Append
}
else {
    $logPath = Join-Path $script:LogDir "webui.log"
    New-Item -ItemType File -Force -Path (Join-Path $script:LogDir "webui.err.log") | Out-Null
    Write-Host "Starting WebUI Server..."
    Write-Host "Log: $logPath"
    & $python -u -m uvicorn app:app --host 127.0.0.1 --port 8000 2>&1 |
        Tee-Object -FilePath $logPath -Append
}
