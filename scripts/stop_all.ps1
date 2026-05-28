. "$PSScriptRoot\service_common.ps1"

$ErrorActionPreference = "Stop"
Set-Location $script:ProjectRoot
Initialize-ServiceDirs
$MimoPidFile = Join-Path $script:RuntimeDir "mimo_tts.pid"

Write-Host "========================================"
Write-Host "tts-video stop services"
Write-Host "========================================"
Write-Host "This script only stops processes recorded in runtime/*.pid."
Write-Host "It does not kill unrelated programs that use ports 8000 or 9000."
Write-Host ""

$hadAnyPid = (Test-Path -LiteralPath $script:WebPidFile) -or (Test-Path -LiteralPath $script:IndexPidFile) -or (Test-Path -LiteralPath $MimoPidFile)

$stoppedWeb = Stop-PidFileProcess -Name "WebUI" -PidFile $script:WebPidFile
$stoppedIndex = Stop-PidFileProcess -Name "IndexTTS API" -PidFile $script:IndexPidFile
$stoppedMimo = Stop-PidFileProcess -Name "MiMoTTS" -PidFile $MimoPidFile

if (-not $hadAnyPid) {
    Write-Host ""
    Write-Host "[INFO] No running project services were found from runtime PID files."
}

$webOwners = Get-PortOwnerPids -Port 8000
if ($webOwners -and $webOwners.Count -gt 0 -and -not (Test-PortOwnedByPidFile -Port 8000 -PidFile $script:WebPidFile)) {
    Write-Host "[INFO] Port 8000 is still in use by PID(s): $($webOwners -join ', '). This script will not stop them."
}

$indexOwners = Get-PortOwnerPids -Port 9000
if ($indexOwners -and $indexOwners.Count -gt 0 -and -not (Test-PortOwnedByPidFile -Port 9000 -PidFile $script:IndexPidFile)) {
    Write-Host "[INFO] Port 9000 is still in use by PID(s): $($indexOwners -join ', '). This script will not stop them."
}

$mimoOwners = Get-PortOwnerPids -Port 9021
if ($mimoOwners -and $mimoOwners.Count -gt 0 -and -not (Test-PortOwnedByPidFile -Port 9021 -PidFile $MimoPidFile)) {
    Write-Host "[INFO] Port 9021 is still in use by PID(s): $($mimoOwners -join ', '). This script will not stop them."
}

Write-Host ""
Write-Host "Done."
exit 0
