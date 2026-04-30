# install.ps1 — NoLlama setup: venv, dependencies, model selection
#
# Usage:
#     .\install.ps1              # interactive setup
#     .\install.ps1 -SkipModel   # venv + deps only
#
# Detects available devices (NPU, GPU, CPU), then walks the user
# through model selection. NPU-first: if you have an NPU, that's
# your primary chat device.

param(
    [switch]$SkipModel
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModelsRoot = Join-Path $HOME "models"
$StartScript = Join-Path $ScriptDir "start.ps1"
Push-Location $ScriptDir


Write-Host ""
Write-Host "=== NoLlama Install ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Create venv
# ---------------------------------------------------------------------------

$VenvDir = Join-Path $ScriptDir "venv"
if (Test-Path $VenvDir) {
    Write-Host "[OK] venv already exists"
} else {
    Write-Host "Creating Python venv..."
    python -m venv $VenvDir
    if (-not $?) { Write-Host "ERROR: Failed to create venv. Is Python installed?" -ForegroundColor Red; Pop-Location; exit 1 }
    Write-Host "[OK] venv created"

    Write-Host "Upgrading pip core tools..."
    # Only upgrade pip and wheel; avoid setuptools to prevent torch conflicts
    & (Join-Path $VenvDir "Scripts\python.exe") -m pip install --no-cache-dir --upgrade pip wheel --quiet
}

$ActivateScript = Join-Path $VenvDir "Scripts\Activate.ps1"
& $ActivateScript

Write-Host "Installing dependencies..."
# Temporarily allow Continue to handle pip resolver warnings without crashing
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"

python -m pip install --no-cache-dir -r (Join-Path $ScriptDir "requirements.txt") --quiet
$pipResult = $LASTEXITCODE

$ErrorActionPreference = $oldEAP

if ($pipResult -ne 0) {
    Write-Host "ERROR: pip install failed (exit code $pipResult)" -ForegroundColor Red
    Pop-Location; exit 1
}
Write-Host "[OK] Dependencies installed"
Write-Host ""


# ---------------------------------------------------------------------------
# 2. Detect devices
# ---------------------------------------------------------------------------

Write-Host "Detecting devices..." -ForegroundColor Cyan
$DeviceInfo = python -c @"
import openvino as ov, json
core = ov.Core()
d = {}
for dev in core.get_available_devices():
    try: d[dev] = core.get_property(dev, 'FULL_DEVICE_NAME')
    except: d[dev] = dev
print(json.dumps(d))
"@ | ConvertFrom-Json
$DeviceInfo | ConvertTo-Json | Set-Content (Join-Path $ScriptDir "devices.json")

$HasNPU = $null -ne $DeviceInfo.NPU
$HasGPU = $null -ne $DeviceInfo.GPU

Write-Host ""
if ($HasNPU) { Write-Host "  [+] NPU: $($DeviceInfo.NPU)" -ForegroundColor Green }
else         { Write-Host "  [-] NPU: not found" -ForegroundColor DarkGray }
if ($HasGPU) { Write-Host "  [+] GPU: $($DeviceInfo.GPU)" -ForegroundColor Green }
else         { Write-Host "  [-] GPU: not found" -ForegroundColor DarkGray }
Write-Host "  [+] CPU: $($DeviceInfo.CPU)" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Scan existing local models in ~/models/
# ---------------------------------------------------------------------------

$LocalModels = @()
if (Test-Path $ModelsRoot) {
    $LocalModels = @(Get-ChildItem -Path $ModelsRoot -Directory | Where-Object {
        (Test-Path (Join-Path $_.FullName "openvino_language_model.bin")) -or
        (Test-Path (Join-Path $_.FullName "openvino_model.bin"))
    } | ForEach-Object {
        $vlmBin = Join-Path $_.FullName "openvino_language_model.bin"
        $llmBin = Join-Path $_.FullName "openvino_model.bin"
        $binPath = if (Test-Path $vlmBin) { $vlmBin } else { $llmBin }
        $binSize = (Get-Item $binPath).Length
        $sizeGB = [math]::Round($binSize / 1GB, 1)
        $mtype = "llm"
        $cfgPath = Join-Path $_.FullName "config.json"
        if (Test-Path $cfgPath) {
            try {
                $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
                $arch = ""
                if ($cfg.architectures -and $cfg.architectures.Count -gt 0) { $arch = $cfg.architectures[0].ToLower() }
                $mt = if ($cfg.model_type) { $cfg.model_type.ToLower() } else { "" }
                if ($arch -match "vl|vision|llava|qwen2vl|internvl|minicpm" -or $mt -match "vl|vision") {
                    $mtype = "vlm"
                }
            } catch {}
        }
        # Detect NPU compatibility: needs int4-cw quantization and reasonable size
        $npuOk = ($_.Name -match "int4-cw" -or $_.Name -match "cw-ov") -and $sizeGB -lt 10
        [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName; SizeGB = $sizeGB; Type = $mtype; NpuOk = $npuOk }
    })
}

if ($LocalModels.Count -gt 0) {
    Write-Host "  Local models ($ModelsRoot):" -ForegroundColor DarkGray
    foreach ($lm in $LocalModels) {
        Write-Host "    $($lm.Name)  ($($lm.SizeGB) GB, $($lm.Type.ToUpper()))" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($SkipModel) {
    Write-Host "Skipping model selection (-SkipModel)"
    Write-Host ""
    Write-Host "=== Install complete (no model) ===" -ForegroundColor Yellow
    Pop-Location; exit 0
}

# ---------------------------------------------------------------------------
# Helper: show a model menu and return the selection
# ---------------------------------------------------------------------------

$Registry = Get-Content (Join-Path $ScriptDir "models.json") -Raw | ConvertFrom-Json

function Show-ModelMenu {
    param(
        [string]$Title,
        [array]$RegistryModels,
        [array]$LocalModels,
        [string]$LocalLabel = "Already on disk",
        [bool]$AllowSkip = $false
    )

    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ""

    $localMap = @{}
    foreach ($lm in $LocalModels) {
        $localMap[$lm.Name.ToLower()] = $lm
    }

    $items = @()

    # 1. Registry models — check if already on disk
    foreach ($dm in $RegistryModels) {
        $repoName = ($dm.hf_id -split '/')[-1].ToLower()
        $isLocal = $localMap.ContainsKey($repoName)
        
        $item = [PSCustomObject]@{
            Name = $dm.name
            SizeGB = $dm.est_size_gb
            Notes = $dm.notes
        }

        if ($isLocal) {
            $lm = $localMap[$repoName]
            $item | Add-Member -MemberType NoteProperty -Name "Action" -Value "local"
            $item | Add-Member -MemberType NoteProperty -Name "Path"   -Value $lm.Path
            $item.SizeGB = $lm.SizeGB
            $item.Notes = "Already on disk (Instant)"
            $localMap.Remove($repoName) # mark as handled
        } else {
            $item | Add-Member -MemberType NoteProperty -Name "Action" -Value $dm.source
            $item | Add-Member -MemberType NoteProperty -Name "Path"   -Value $null
            $item | Add-Member -MemberType NoteProperty -Name "HfId"   -Value $dm.hf_id
            $item | Add-Member -MemberType NoteProperty -Name "Source" -Value $dm.source
            $item | Add-Member -MemberType NoteProperty -Name "Weight" -Value $dm.weight_format
            $item | Add-Member -MemberType NoteProperty -Name "Trust"  -Value $dm.trust_remote_code
        }
        $items += $item
    }

    # 2. Remaining local models (custom/manual)
    foreach ($lm in $localMap.Values) {
        $items += [PSCustomObject]@{
            Action = "local"; Name = $lm.Name; Path = $lm.Path; SizeGB = $lm.SizeGB; Notes = "Manual install (local)"
            HfId = $null; Source = $null; Weight = $null; Trust = $false
        }
    }

    # Display list
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $idx = $i + 1
        $color = if ($it.Action -eq "local") { "Green" } else { "Gray" }
        
        Write-Host "    $idx. $($it.Name)" -NoNewline
        Write-Host "  ($($it.SizeGB) GB)" -ForegroundColor DarkGray -NoNewline
        
        if ($it.Action -eq "local") {
            Write-Host "  [LOCAL]" -ForegroundColor Green -NoNewline
        } else {
            $tag = if ($it.Action -eq "pre-exported") { "download" } else { "convert" }
            Write-Host "  ($tag)" -ForegroundColor DarkGray -NoNewline
        }
        
        Write-Host "  $($it.Notes)" -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($AllowSkip) {
        $prompt = "Pick a model [1-$($items.Count)] or press Enter to skip"
    } else {
        $prompt = "Pick a model [1-$($items.Count)]"
    }

    while ($true) {
        $choice = Read-Host $prompt
        if ($AllowSkip -and [string]::IsNullOrWhiteSpace($choice)) {
            return $null
        }
        $num = 0
        if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $items.Count) {
            return $items[$num - 1]
        }
        Write-Host "Enter a number between 1 and $($items.Count)" -ForegroundColor Red
    }
}


# ---------------------------------------------------------------------------
# Helper: download or link a model into a target directory
# ---------------------------------------------------------------------------

function Install-Model {
    param(
        [PSCustomObject]$Selected,
        [string]$TargetDir
    )

    # 1. Check if the target directory already has this exact model
    if (Test-Path $TargetDir) {
        $item = Get-Item $TargetDir
        $isJunction = $item.Attributes -band [System.IO.FileAttributes]::ReparsePoint
        
        if ($Selected.Action -eq "local") {
            if ($isJunction) {
                $currentTarget = (Get-Item $TargetDir).Target
                if ($currentTarget -eq $Selected.Path) {
                    Write-Host "  [OK] Model '$($Selected.Name)' is already configured." -ForegroundColor Green
                    return $true
                }
            }
        } else {
            # For non-local (download/convert), if it's a real directory, 
            # we don't have a reliable way to know if it's the SAME model 
            # without checking config.json or similar, but usually if the 
            # directory exists and we aren't linking, it's safer to proceed 
            # or ask. However, the user said "pule para a próxima etapa".
            # So if it's a real directory and it's a model, we'll assume it's okay.
            if (-not $isJunction -and (Test-Path (Join-Path $TargetDir "config.json"))) {
                Write-Host "  [OK] Model directory already exists at $TargetDir. Skipping download." -ForegroundColor Green
                return $true
            }
        }
    }

    if ($Selected.Action -eq "local") {
        Write-Host "Linking: $($Selected.Name) -> $($Selected.Path)" -ForegroundColor Cyan
        if (Test-Path $TargetDir) {
            if ((Get-Item $TargetDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                cmd /c rmdir "`"$TargetDir`""
            } else {
                Remove-Item -Recurse -Force $TargetDir
            }
        }
        cmd /c mklink /J "`"$TargetDir`"" "`"$($Selected.Path)`""
        if (-not $?) { Write-Host "ERROR: Failed to create junction link." -ForegroundColor Red; return $false }
        Write-Host "[OK] Linked" -ForegroundColor Green
        return $true
    }

    if ($Selected.Action -eq "pre-exported") {
        Write-Host "Downloading $($Selected.Name)..." -ForegroundColor Cyan
        Write-Host "  From: $($Selected.HfId)"
        Write-Host ""
        if (Test-Path $TargetDir) {
            if ((Get-Item $TargetDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                cmd /c rmdir "`"$TargetDir`""
            } else {
                Remove-Item -Recurse -Force $TargetDir
            }
        }
        $env:PYTHONIOENCODING = "utf-8"
        hf download $Selected.HfId --local-dir $TargetDir
        if (-not $?) {
            Write-Host "ERROR: Download failed." -ForegroundColor Red
            return $false
        }
        Write-Host "[OK] Downloaded" -ForegroundColor Green
        return $true
    }


    if ($Selected.Action -eq "convert") {
        Write-Host "Converting $($Selected.Name)..." -ForegroundColor Cyan
        Write-Host "  From: $($Selected.HfId)"
        Write-Host "  This may take 5-20 minutes."
        Write-Host ""
        if (Test-Path $TargetDir) {
            if ((Get-Item $TargetDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                cmd /c rmdir "`"$TargetDir`""
            } else {
                Remove-Item -Recurse -Force $TargetDir
            }
        }
        $args = @("export", "openvino", "--model", $Selected.HfId, "--weight-format", $Selected.Weight)
        if ($Selected.Trust) { $args += "--trust-remote-code" }
        $args += $TargetDir
        Write-Host "Running: optimum-cli $($args -join ' ')" -ForegroundColor DarkGray
        & optimum-cli @args
        if (-not $?) {
            Write-Host "ERROR: Conversion failed." -ForegroundColor Red
            return $false
        }
        Write-Host "[OK] Converted" -ForegroundColor Green
        return $true
    }

    Write-Host "ERROR: Unknown action '$($Selected.Action)'" -ForegroundColor Red
    return $false
}


# ---------------------------------------------------------------------------
# 4. Model selection
# ---------------------------------------------------------------------------

$ModelDir = Join-Path $ScriptDir "model"
$GpuModelDir = Join-Path $ScriptDir "gpu-model"
$WhisperModelDir = Join-Path $ScriptDir "whisper-model"

# --- Check for existing models to avoid re-selection ---
function Get-ModelName($path) {
    if (Test-Path (Join-Path $path "openvino_language_model.bin")) {
        return (Get-Item $path).Target -replace '^.*\\models\\', ''
    }
    if (Test-Path (Join-Path $path "openvino_model.bin")) {
        return (Get-Item $path).Target -replace '^.*\\models\\', ''
    }
    return $null
}

$currPrimary = Get-ModelName $ModelDir
$currGpu = Get-ModelName $GpuModelDir
$currWhisper = Get-ModelName $WhisperModelDir

if ($currPrimary -or $currGpu -or $currWhisper) {
    Write-Host "Current model configuration detected:" -ForegroundColor Cyan
    if ($currPrimary) { Write-Host "  [Primary] $currPrimary" -ForegroundColor DarkGray }
    if ($currGpu)     { Write-Host "  [GPU]     $currGpu"     -ForegroundColor DarkGray }
    if ($currWhisper) { Write-Host "  [Whisper] $currWhisper" -ForegroundColor DarkGray }
    Write-Host ""
    $keep = Read-Host "Keep current models? [Y/n]"
    if ($keep -eq "" -or $keep -match "^y") {
        Write-Host "Skipping model selection." -ForegroundColor Green
        # ---------------------------------------------------------------------------
        # 5. Generate start.ps1 (fast path)
        # ---------------------------------------------------------------------------
        $Content = @'
param([switch]$Select)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir "start-template.ps1") -Select:$Select
'@
        Set-Content -Path $StartScript -Value $Content -Encoding UTF8
        Write-Host "[OK] Generated start.ps1" -ForegroundColor Green
        Write-Host ""
        Write-Host "=== NoLlama install complete ===" -ForegroundColor Green
        Write-Host "To start the server: .\start.ps1"
        Pop-Location; exit 0
    }
}

$StartArgs = @()  # collect args for start.ps1


if ($HasNPU) {
    # --- Step 1: NPU chat model ---
    # Only show local models that are NPU-compatible (int4-cw, reasonable size)
    $npuLocal = @($LocalModels | Where-Object { $_.Type -eq "llm" -and $_.NpuOk })
    $sel = Show-ModelMenu -Title "Step 1: Chat Model (NPU)" `
        -RegistryModels $Registry.npu `
        -LocalModels $npuLocal `
        -LocalLabel "Already converted (instant)"

    $NpuSelectedName = $null
    if ($sel) {
        $NpuSelectedName = $sel.Name
        $ok = Install-Model -Selected $sel -TargetDir $ModelDir
        if (-not $ok) { Write-Host ""; Write-Host "Model installation failed. You can re-run install.ps1 to try again." -ForegroundColor Yellow; Pop-Location; exit 1 }
        $StartArgs += @("--device", "NPU")
        Write-Host ""
    }

    # --- Step 2: GPU model (optional) ---
    if ($HasGPU) {
        Write-Host ""
        Write-Host "=== Step 2: GPU Model (optional) ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  You also have an Intel ARC GPU. What do you want to use it for?"
        Write-Host ""
        Write-Host "    A. Vision model  - image understanding alongside NPU chat"
        Write-Host "    B. Bigger LLM    - much smarter chat than the NPU model"
        Write-Host "    C. Skip          - NPU chat only"
        Write-Host ""
        while ($true) {
            $gpuChoice = (Read-Host "  [A/B/C]").ToUpper()
            if ($gpuChoice -in @("A", "B", "C", "")) { break }
            Write-Host "  Enter A, B, or C" -ForegroundColor Red
        }

        if ($gpuChoice -eq "A") {
            $vlmLocal = @($LocalModels | Where-Object { $_.Type -eq "vlm" })
            $sel = Show-ModelMenu -Title "GPU Vision Model" `
                -RegistryModels $Registry.gpu_vlm `
                -LocalModels $vlmLocal
            if ($sel) {
                $ok = Install-Model -Selected $sel -TargetDir $GpuModelDir
                if ($ok) { $StartArgs += @("--gpu-model-dir", "gpu-model") }
                Write-Host ""
            }
        } elseif ($gpuChoice -eq "B") {
            $llmLocal = @($LocalModels | Where-Object { $_.Type -eq "llm" -and $_.Name -ne $NpuSelectedName })
            $sel = Show-ModelMenu -Title "GPU LLM (bigger chat model)" `
                -RegistryModels $Registry.gpu_llm `
                -LocalModels $llmLocal
            if ($sel) {
                $ok = Install-Model -Selected $sel -TargetDir $GpuModelDir
                if ($ok) { $StartArgs += @("--gpu-model-dir", "gpu-model") }
                Write-Host ""
            }
        }
    }
} elseif ($HasGPU) {
    # --- No NPU, GPU only ---
    Write-Host "No NPU detected. Selecting a GPU model." -ForegroundColor Yellow
    Write-Host ""
    $allGpu = @($Registry.gpu_vlm) + @($Registry.gpu_llm)
    $sel = Show-ModelMenu -Title "GPU Model" `
        -RegistryModels $allGpu `
        -LocalModels $LocalModels
    if ($sel) {
        $ok = Install-Model -Selected $sel -TargetDir $ModelDir
        if (-not $ok) { Pop-Location; exit 1 }
        $StartArgs += @("--device", "GPU")
        Write-Host ""
    }
} else {
    # --- No NPU, no GPU — CPU fallback ---
    Write-Host "No NPU or GPU detected. Models will run on CPU (slower)." -ForegroundColor Yellow
    Write-Host ""
    $sel = Show-ModelMenu -Title "CPU Model" `
        -RegistryModels $Registry.npu `
        -LocalModels @($LocalModels | Where-Object { $_.Type -eq "llm" })
    if ($sel) {
        $ok = Install-Model -Selected $sel -TargetDir $ModelDir
        if (-not $ok) { Pop-Location; exit 1 }
        $StartArgs += @("--device", "CPU")
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# 5. Generate start.ps1
# ---------------------------------------------------------------------------

# Generate start.ps1
$Content = @'
param([switch]$Select)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir "start-template.ps1") -Select:$Select
'@
Set-Content -Path $StartScript -Value $Content -Encoding UTF8
Write-Host "[OK] Generated start.ps1" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== NoLlama install complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "To start the server:"
Write-Host "  .\start.ps1"
Write-Host ""

Pop-Location
