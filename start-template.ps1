# start-template.ps1 — NoLlama launcher & selector
# Detects models, offers an interactive menu, and remembers the last choice.

param(
    [switch]$Select,
    [string]$ServerArgs = "" # legacy support
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 8000
$Url = "http://localhost:$Port"
$ModelsRoot = Join-Path $HOME "models"
$ConfigPath = Join-Path $ScriptDir "last_config.json"
$DevicesPath = Join-Path $ScriptDir "devices.json"

# ---------------------------------------------------------------------------
# 1. Load Hardware State
# ---------------------------------------------------------------------------
if (-not (Test-Path $DevicesPath)) {
    Write-Host "Hardware not detected. Please run install.ps1 first." -ForegroundColor Red
    exit 1
}
$DeviceInfo = Get-Content $DevicesPath -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# 2. Model Discovery
# ---------------------------------------------------------------------------
function Get-LocalModels {
    $models = @()
    $searchPaths = @($ModelsRoot, (Join-Path $ScriptDir "model"), (Join-Path $ScriptDir "gpu-model"))
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $items = @()
            if ($path -eq $ModelsRoot) {
                $items = Get-ChildItem -Path $path -Directory
            } else {
                # For ./model and ./gpu-model, check if they are valid OpenVINO models
                if ((Test-Path (Join-Path $path "openvino_language_model.bin")) -or (Test-Path (Join-Path $path "openvino_model.bin"))) {
                    $items = @(Get-Item $path)
                }
            }

            foreach ($item in $items) {
                $binPath = Join-Path $item.FullName "openvino_language_model.bin"
                if (-not (Test-Path $binPath)) { $binPath = Join-Path $item.FullName "openvino_model.bin" }
                
                if (Test-Path $binPath) {
                    # 1. Resolve effective name for NPU check (junction target name)
                    $effectiveName = $item.Name
                    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        $target = (Get-Item $item.FullName).Target
                        $effectiveName = Split-Path $target -Leaf
                    }
                    
                    # NPU needs int4-cw or cw-ov in the name
                    $npuOk = ($effectiveName -match "int4-cw" -or $effectiveName -match "cw-ov")
                    
                    # 2. Extract best display name
                    $displayName = $effectiveName # fallback to actual folder name
                    
                    # Priority 1: README.md base_model
                    $readmePath = Join-Path $item.FullName "README.md"
                    if (Test-Path $readmePath) {
                        try {
                            $readme = Get-Content $readmePath -Raw
                            # Improved regex: allows newlines after colon, handles optional YAML list dash '-'
                            # (?s) allows . to match newlines, though we use \s which already does.
                            if ($readme -match "(?s)base_model:\s*(?:-\s*)?([a-zA-Z0-9\-\._/]+)") {
                                $displayName = $Matches[1]
                            }
                        } catch {}
                    }
                    
                    # Priority 2: config.json (if README failed or doesn't have base_model)
                    if ($displayName -eq $effectiveName) {
                        $cfgPath = Join-Path $item.FullName "config.json"
                        if (Test-Path $cfgPath) {
                            try {
                                $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
                                if ($cfg._name_or_path) { 
                                    $displayName = Split-Path $cfg._name_or_path -Leaf 
                                } elseif ($cfg.model_type) { 
                                    $displayName = "$($cfg.model_type)" 
                                }
                            } catch {}
                        }
                    }
                    
                    # 3. NPU Compatibility
                    # Lenient check: optimization tags OR if it's the primary linked model
                    $npuOk = ($effectiveName -match "int4-cw" -or $effectiveName -match "cw-ov" -or $item.Name -eq "model")

                    # Add suffix if it's a project-local link (e.g. " (Primary)")
                    if ($item.Name -eq "model") { $displayName += " (Primary)" }
                    elseif ($item.Name -eq "gpu-model") { $displayName += " (GPU Model)" }

                    $models += [PSCustomObject]@{ Name = $displayName; Path = $item.FullName; NpuOk = $npuOk }

                }
            }
        }
    }
    return $models
}


# ---------------------------------------------------------------------------
# 3. Interactive Selection Logic
# ---------------------------------------------------------------------------
$LastConfig = $null
if (Test-Path $ConfigPath) {
    try { $LastConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {}
}

$ShouldShowMenu = $Select -or ($null -eq $LastConfig)

if ($ShouldShowMenu) {
    $LocalModels = Get-LocalModels
    if ($LocalModels.Count -eq 0) {
        Write-Host "No models found in $ModelsRoot. Please run install.ps1 to download some." -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host "=== NoLlama: Select Model & Device ===" -ForegroundColor Cyan
    Write-Host ""

    $menuItems = @()
    
    # --- Group: NPU ---
    if ($DeviceInfo.NPU) {
        Write-Host "[NPU] ($($DeviceInfo.NPU))" -ForegroundColor Yellow
        foreach ($m in $LocalModels) {
            if ($m.NpuOk) {
                $menuItems += [PSCustomObject]@{ Device = "NPU"; Model = $m }
                Write-Host "  $($menuItems.Count). $($m.Name)"
            }
        }
        # Show incompatible ones as well but with warning? No, keep it clean.
    }

    # --- Group: GPU ---
    if ($DeviceInfo.GPU) {
        Write-Host "[GPU] ($($DeviceInfo.GPU))" -ForegroundColor Yellow
        foreach ($m in $LocalModels) {
            $menuItems += [PSCustomObject]@{ Device = "GPU"; Model = $m }
            Write-Host "  $($menuItems.Count). $($m.Name)"
        }
    }

    # --- Group: CPU ---
    # Only show CPU if explicitly requested or if no NPU/GPU found, 
    # but the user said "CPU não é uma opçao disponivel".
    # We will hide it if NPU or GPU are present to reduce clutter.
    if (-not $DeviceInfo.NPU -and -not $DeviceInfo.GPU) {
        Write-Host "[CPU]" -ForegroundColor Yellow
        foreach ($m in $LocalModels) {
            $menuItems += [PSCustomObject]@{ Device = "CPU"; Model = $m }
            Write-Host "  $($menuItems.Count). $($m.Name)"
        }
    }


    Write-Host ""
    while ($true) {
        $choice = Read-Host "Pick a configuration [1-$($menuItems.Count)]"
        $num = 0
        if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $menuItems.Count) {
            $selection = $menuItems[$num - 1]
            $LastConfig = [PSCustomObject]@{
                Device = $selection.Device
                ModelPath = $selection.Model.Path
                ModelName = $selection.Model.Name
            }
            $LastConfig | ConvertTo-Json | Set-Content $ConfigPath
            break
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Start Server
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Starting $($LastConfig.ModelName) on $($LastConfig.Device) (Quick Start)..." -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop or run '.\start.ps1 -Select' to change." -ForegroundColor DarkGray
Write-Host ""

# Activate venv
& (Join-Path $ScriptDir "venv\Scripts\Activate.ps1")

$AllArgs = @((Join-Path $ScriptDir "nollama.py"), "--device", $LastConfig.Device, "--model-dir", $LastConfig.ModelPath)
if ($ServerArgs) {
    $AllArgs += $ServerArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
}

$Server = Start-Process -FilePath python -ArgumentList $AllArgs -NoNewWindow -PassThru

# ---------------------------------------------------------------------------
# 5. Wait & Open Browser
# ---------------------------------------------------------------------------
$Spinner = @("|", "/", "-", "\")
$MaxWait = 120
$Elapsed = 0
$LastStatus = ""
$SpinIdx = 0

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Milliseconds 500
    $Elapsed += 0.5
    if ($Server.HasExited) { Write-Host "`nERROR: Server process exited unexpectedly." -ForegroundColor Red; exit 1 }

    try {
        $resp = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 2 -ErrorAction Stop
        if ($resp.status -eq "ready") {
            Write-Host "`nReady! Opening browser..." -ForegroundColor Green
            Start-Process $Url
            break
        }
        $spin = $Spinner[$SpinIdx % 4]; $SpinIdx++; $bar = "#" * [math]::Min([int]($Elapsed / 2), 40)
        Write-Host "`r  [$spin] Loading model... $bar" -NoNewline
    } catch {
        $spin = $Spinner[$SpinIdx % 4]; $SpinIdx++
        Write-Host "`r  [$spin] Waiting for server..." -NoNewline
    }
}

try { $Server.WaitForExit() } catch {}
if (-not $Server.HasExited) { $Server.Kill() }
