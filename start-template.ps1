# start.ps1 — NoLlama launcher
# Starts the server, waits for models to load, then opens the browser.
# Args are set by install.ps1 in the generated start.ps1

param(
    [string]$ServerArgs = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 8000
$Url = "http://localhost:$Port"

# Activate venv
& (Join-Path $ScriptDir "venv\Scripts\Activate.ps1")

# Start server in background
$AllArgs = @((Join-Path $ScriptDir "nollama.py"))
if ($ServerArgs) {
    $AllArgs += $ServerArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
}
$Server = Start-Process -FilePath python -ArgumentList $AllArgs `
    -NoNewWindow -PassThru

Write-Host ""
Write-Host "  NoLlama starting..." -ForegroundColor Cyan
Write-Host ""

# Poll /health until ready (or error/timeout)
$Spinner = @("|", "/", "-", "\")
$MaxWait = 120
$Elapsed = 0
$LastStatus = ""
$SpinIdx = 0

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Milliseconds 500
    $Elapsed += 0.5

    if ($Server.HasExited) {
        Write-Host ""
        Write-Host "  ERROR: Server process exited unexpectedly." -ForegroundColor Red
        exit 1
    }

    try {
        $resp = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 2 -ErrorAction Stop
        $Status = $resp.status

        if ($Status -ne $LastStatus) {
            $LastStatus = $Status
            $DeviceInfo = ""
            if ($resp.devices) {
                $parts = @()
                $resp.devices.PSObject.Properties | ForEach-Object {
                    $devName = $_.Name.ToUpper()
                    $st = $_.Value.status
                    $modelName = $_.Value.model
                    if ($st -and $st -ne "not_configured") {
                        $parts += "${devName}: ${modelName} (${st})"
                    }
                }
                $DeviceInfo = $parts -join "  |  "
            }
            Write-Host ""
            Write-Host "  $DeviceInfo" -ForegroundColor DarkGray
        }

        if ($Status -eq "ready") {
            Write-Host ""
            Write-Host "  Ready! Opening browser..." -ForegroundColor Green
            Write-Host ""
            Start-Process $Url
            break
        }

        $spin = $Spinner[$SpinIdx % 4]
        $SpinIdx++
        $bar = "#" * [math]::Min([int]($Elapsed / 2), 40)
        Write-Host "`r  [$spin] Loading models... $bar" -NoNewline
    } catch {
        $spin = $Spinner[$SpinIdx % 4]
        $SpinIdx++
        Write-Host "`r  [$spin] Waiting for server..." -NoNewline
    }
}

if ($Elapsed -ge $MaxWait) {
    Write-Host ""
    Write-Host "  WARNING: Server did not become ready within ${MaxWait}s" -ForegroundColor Yellow
    Write-Host "  Opening browser anyway..."
    Start-Process $Url
}

Write-Host "  Server running at $Url"
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

try {
    $Server.WaitForExit()
} catch {}

if (-not $Server.HasExited) {
    $Server.Kill()
}
